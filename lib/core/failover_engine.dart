import 'dart:async';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart' show NetworkState;

/// Non-intrusive companion engine for FlClash RS.
/// Coordinates instant failover upon network transitions (Wi-Fi <-> Cellular)
/// and active-lease health monitoring without kernel modification.
class FailoverEngine {
  final Ref _ref;

  FailoverEngine(this._ref);

  CoreController get _core => _ref.read(coreHandlerProvider);

  int _networkEpoch = 0;
  bool _isProbing = false;
  bool _disposed = false;
  Timer? _healthSentryTimer;

  static const _networkSettleDelay = Duration(milliseconds: 300);
  static const _networkRetryBackoff = Duration(milliseconds: 1200);
  static const _sentryInterval = Duration(seconds: 90);
  static const _probeTimeoutMs = 2800;
  static const _sentryTimeoutMs = 2500;
  static const _primaryProbeConcurrency = 3;
  static const _probeCandidateConcurrency = 5;

  /// Initializes lifecycle listeners for the failover engine.
  void init() {
    _ref.listen<CoreStatus>(coreStatusProvider, (prev, next) {
      if (next == CoreStatus.connected) {
        _startHealthSentry();
      } else {
        _stopHealthSentry();
      }
    }, fireImmediately: true);
  }

  /// Disposes background timers and resources.
  void dispose() {
    _disposed = true;
    _stopHealthSentry();
  }

  /// Triggered whenever physical network state transitions occur.
  Future<void> onNetworkChanged(NetworkState state) async {
    if (_disposed || _ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }

    // Inform core backend on desktop
    if (system.isDesktop) {
      unawaited(_ref.read(coreActionProvider.notifier).reportNetworkChange());
    }

    final currentEpoch = ++_networkEpoch;

    // Phase 1: Wait for network settle (DHCP/route assignment stabilization)
    await Future.delayed(_networkSettleDelay);
    if (_disposed || currentEpoch != _networkEpoch) {
      commonPrint.log(
        '[Failover] Aborted obsolete probe round (newer network change detected)',
        logLevel: LogLevel.info,
      );
      return;
    }

    // Phase 2: Execute primary group probe and self-healing
    await _probeAndFailover(currentEpoch);
  }

  /// Classifies proxy groups into primary (actively carrying traffic) and secondary.
  ({List<GroupInfo> primary, List<GroupInfo> secondary}) classifyAutoGroups(
    List<GroupInfo> allGroups,
  ) {
    final groupMap = {for (final g in allGroups) g.name: g};
    final activeCarryingGroups = <GroupInfo>[];

    // 1. Trace active selectors down the hierarchy up to depth 6
    // to find the exact groups actively carrying traffic.
    for (final group in allGroups) {
      if (group.type.toLowerCase() != 'select') continue;
      var curr = group;
      final visited = <String>{curr.name};

      for (var depth = 0; depth < 6; depth++) {
        final nowName = curr.now;
        if (nowName == null || nowName.isEmpty) break;

        final next = groupMap[nowName];
        if (next == null) {
          // nowName is a leaf proxy node (not another group).
          // That means 'curr' is directly carrying traffic!
          if (curr.all != null && curr.all!.isNotEmpty) {
            if (!activeCarryingGroups.any((g) => g.name == curr.name)) {
              activeCarryingGroups.add(curr);
            }
          }
          break;
        }

        if (!visited.add(next.name)) break; // Loop detected

        final nextType = next.type.toLowerCase();
        if (nextType == 'url-test' || nextType == 'fallback') {
          // 'next' is an active auto group carrying traffic!
          if (!activeCarryingGroups.any((g) => g.name == next.name)) {
            activeCarryingGroups.add(next);
          }
          break;
        }

        curr = next;
      }
    }

    final primary = <GroupInfo>[];
    final secondary = <GroupInfo>[];

    if (activeCarryingGroups.isNotEmpty) {
      primary.addAll(activeCarryingGroups);

      // Remaining url-test / fallback groups are secondary
      for (final group in allGroups) {
        final type = group.type.toLowerCase();
        final isAuto = type == 'url-test' || type == 'fallback';
        if (isAuto && !primary.any((g) => g.name == group.name)) {
          secondary.add(group);
        }
      }
    } else {
      // Fallback heuristics when no active carrying group is found:
      // Groups with primary keywords (and no secondary keywords) are primary.
      for (final group in allGroups) {
        final type = group.type.toLowerCase();
        final isAuto = type == 'url-test' || type == 'fallback';
        if (!isAuto) continue;

        if (_hasPrimaryKeyword(group.name) && !_hasSecondaryKeyword(group.name)) {
          primary.add(group);
        } else {
          secondary.add(group);
        }
      }
    }

    if (primary.isEmpty && secondary.isNotEmpty) {
      return (primary: secondary, secondary: const <GroupInfo>[]);
    }

    return (primary: primary, secondary: secondary);
  }

  static bool _hasPrimaryKeyword(String name) {
    final lower = name.toLowerCase();
    for (final kw in const [
      '自动',
      'auto',
      'url-test',
      'best',
      '优选',
      '极速',
      '主力',
    ]) {
      if (lower.contains(kw)) return true;
    }
    return false;
  }

  static bool _hasSecondaryKeyword(String name) {
    final lower = name.toLowerCase();
    for (final kw in const [
      'standby',
      'backup',
      '备用',
      '备选',
    ]) {
      if (lower.contains(kw)) return true;
    }
    return false;
  }

  Future<void> _probeAndFailover(int epoch) async {
    if (_isProbing) return;
    _isProbing = true;

    try {
      final groupsDto = await _core.api.proxyGroups();
      final allGroups = groupsDto.groups;
      if (allGroups.isEmpty) return;

      final classified = classifyAutoGroups(allGroups);
      final primaryGroups = classified.primary;
      if (primaryGroups.isEmpty) return;

      commonPrint.log(
        '[Failover] Network settled (epoch: $epoch). Probing ${primaryGroups.length} primary groups: ${primaryGroups.map((g) => g.name).toList()}',
        logLevel: LogLevel.info,
      );

      final beforeSelections = {
        for (final g in primaryGroups) g.name: g.now ?? '',
      };

      var anySuccess = false;
      final switchTime = DateTime.now();

      // Bounded concurrency by batches of 3 groups
      final batches = <List<GroupInfo>>[];
      for (var i = 0; i < primaryGroups.length; i += _primaryProbeConcurrency) {
        batches.add(
          primaryGroups.sublist(
            i,
            math.min(i + _primaryProbeConcurrency, primaryGroups.length),
          ),
        );
      }

      for (final batch in batches) {
        if (_disposed || epoch != _networkEpoch) return;
        final results = await Future.wait(batch.map(_probeGroup));
        for (final success in results) {
          if (success) anySuccess = true;
        }
      }

      // Retry backoff if all primary probes failed (e.g. cellular DNS was slow to initialize)
      if (!anySuccess && epoch == _networkEpoch && !_disposed) {
        commonPrint.log(
          '[Failover] All primary probes timed out. Retrying once after DNS flush...',
          logLevel: LogLevel.warning,
        );
        await Future.delayed(_networkRetryBackoff);
        if (_disposed || epoch != _networkEpoch) return;

        await _core.api.clearDnsCache();
        for (final batch in batches) {
          if (_disposed || epoch != _networkEpoch) return;
          await Future.wait(batch.map(_probeGroup));
        }
      }

      // Post-switch surgical connection eviction: evict only connections on old degraded nodes
      final afterGroupsDto = await _core.api.proxyGroups();
      final afterMap = {
        for (final g in afterGroupsDto.groups) g.name: g.now ?? '',
      };

      for (final entry in beforeSelections.entries) {
        final groupName = entry.key;
        final beforeProxy = entry.value;
        final afterProxy = afterMap[groupName];

        if (beforeProxy.isNotEmpty &&
            afterProxy != null &&
            afterProxy.isNotEmpty &&
            beforeProxy != afterProxy) {
          commonPrint.log(
            '[Failover] Group $groupName auto-switched from [$beforeProxy] to [$afterProxy]',
            logLevel: LogLevel.info,
          );
          await closeGroupStaleConnections(groupName, beforeProxy, switchTime);
        }
      }
    } catch (e) {
      commonPrint.log(
        '[Failover] Failover error: $e',
        logLevel: LogLevel.warning,
      );
    } finally {
      _isProbing = false;
    }
  }

  /// Probes candidates of a group and selects the lowest-latency alive node if changed.
  Future<bool> _probeGroup(GroupInfo group) async {
    final candidates = group.all;
    if (candidates == null || candidates.isEmpty) {
      return false;
    }

    final proxyCandidates = candidates.where((c) {
      final lower = c.toLowerCase();
      return lower != 'direct' && lower != 'reject' && lower != 'compatible';
    }).toList();

    if (proxyCandidates.isEmpty) {
      return false;
    }

    final testUrl = group.testUrl.isNotEmpty ? group.testUrl : null;
    final delays = <String, int>{};

    try {
      final stream = _core.api.runDelays(
        proxyCandidates,
        url: testUrl,
        timeout: _probeTimeoutMs,
        concurrency: _probeCandidateConcurrency,
      );

      await for (final event in stream) {
        if (_disposed) return false;
        switch (event) {
          case DelayRunResult(:final result):
            if (result.value > 0) {
              delays[result.name] = result.value;
            }
          case DelayRunDone():
            break;
        }
      }
    } catch (e) {
      commonPrint.log(
        '[Failover] Delay test stream error on ${group.name}: $e',
        logLevel: LogLevel.warning,
      );
      return false;
    }

    if (delays.isEmpty) {
      return false;
    }

    // Pick candidate with minimum positive delay
    String? bestProxy;
    var lowestDelay = 999999;
    for (final candidate in proxyCandidates) {
      final delay = delays[candidate];
      if (delay != null && delay > 0 && delay < lowestDelay) {
        lowestDelay = delay;
        bestProxy = candidate;
      }
    }

    if (bestProxy != null && bestProxy != group.now) {
      commonPrint.log(
        '[Failover] Selecting optimal node for ${group.name}: $bestProxy (${lowestDelay}ms, previous: ${group.now})',
        logLevel: LogLevel.info,
      );
      await _ref.read(proxiesActionProvider.notifier).changeProxy(
        groupName: group.name,
        proxyName: bestProxy,
      );
    }

    return true;
  }

  /// Surgically closes only the hung connections traversing the old proxy in the given group.
  Future<void> closeGroupStaleConnections(
    String groupName,
    String oldProxyName,
    DateTime switchTime,
  ) async {
    try {
      final book = _ref.read(connectionBookProvider);
      final staleIds = <int>[];
      for (final tracker in book.list()) {
        if (tracker.start.isBefore(switchTime) &&
            tracker.chains.contains(groupName) &&
            tracker.chains.contains(oldProxyName)) {
          staleIds.add(tracker.id);
        }
      }

      if (staleIds.isNotEmpty) {
        await _core.api.closeConnections(ids: staleIds);
        commonPrint.log(
          '[Failover] Closed ${staleIds.length} stale connections on $groupName ($oldProxyName)',
          logLevel: LogLevel.info,
        );
      }
    } catch (e) {
      commonPrint.log(
        '[Failover] Error closing stale connections: $e',
        logLevel: LogLevel.warning,
      );
    }
  }

  // --- Active-Lease Health Sentry (痛点 1：平时节点劣化/超时检测) ---

  void _startHealthSentry() {
    _healthSentryTimer?.cancel();
    _healthSentryTimer = Timer.periodic(_sentryInterval, (_) {
      unawaited(_checkActivePrimaryHealth());
    });
  }

  void _stopHealthSentry() {
    _healthSentryTimer?.cancel();
    _healthSentryTimer = null;
  }

  /// Runs a zero-overhead single-node probe on the active primary node.
  Future<void> _checkActivePrimaryHealth() async {
    if (_disposed ||
        _isProbing ||
        _ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }

    try {
      final groupsDto = await _core.api.proxyGroups();
      final classified = classifyAutoGroups(groupsDto.groups);
      final primaryGroups = classified.primary;
      if (primaryGroups.isEmpty) return;

      final primary = primaryGroups.first;
      final currentNode = primary.now;
      if (currentNode == null ||
          currentNode.isEmpty ||
          currentNode.toLowerCase() == 'direct' ||
          currentNode.toLowerCase() == 'reject') {
        return;
      }

      final testUrl = primary.testUrl.isNotEmpty ? primary.testUrl : null;
      final result = await _core.api.testDelay(
        currentNode,
        url: testUrl,
        timeout: _sentryTimeoutMs,
      );

      // If active node timed out or failed (<= 0), immediately trigger full group probe to failover!
      if (result.value <= 0) {
        commonPrint.log(
          '[Failover] Primary node [$currentNode] in ${primary.name} degraded (delay: ${result.value}ms). Initiating failover...',
          logLevel: LogLevel.warning,
        );
        final switchTime = DateTime.now();
        final beforeProxy = currentNode;
        final switched = await _probeGroup(primary);
        if (switched) {
          final afterDto = await _core.api.proxyGroups();
          final afterGroup = afterDto.groups.firstWhere(
            (g) => g.name == primary.name,
            orElse: () => primary,
          );
          if (afterGroup.now != null && afterGroup.now != beforeProxy) {
            await closeGroupStaleConnections(
              primary.name,
              beforeProxy,
              switchTime,
            );
          }
        }
      }
    } catch (e) {
      commonPrint.log(
        '[Failover] Health sentry error: $e',
        logLevel: LogLevel.debug,
      );
    }
  }
}

final failoverEngineProvider = Provider<FailoverEngine>((ref) {
  final engine = FailoverEngine(ref);
  ref.onDispose(engine.dispose);
  return engine;
});
