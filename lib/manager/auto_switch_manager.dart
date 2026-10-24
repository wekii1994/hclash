import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AutoSwitchManager {
  static final AutoSwitchManager instance = AutoSwitchManager._();
  AutoSwitchManager._();

  Timer? _debounceTimer;
  DateTime? _lastExecutedTime;

  static const int _debounceMs = 1500;
  static const int _cooldownSeconds = 10;
  static const int _resumeCooldownSeconds = 30;

  void onNetworkChanged(List<ConnectivityResult> results, WidgetRef ref) {
    if (results.contains(ConnectivityResult.none)) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: _debounceMs), () {
      _execute(ref: ref, isNetworkChange: true);
    });
  }

  void onAppResumed(WidgetRef ref) {
    final now = DateTime.now();
    if (_lastExecutedTime != null &&
        now.difference(_lastExecutedTime!).inSeconds < _resumeCooldownSeconds) {
      return;
    }
    _execute(ref: ref, isNetworkChange: false);
  }

  Future<void> _execute({
    required WidgetRef ref,
    required bool isNetworkChange,
  }) async {
    final isStart = ref.read(isStartProvider);
    if (!isStart) {
      return;
    }

    final now = DateTime.now();
    if (_lastExecutedTime != null &&
        now.difference(_lastExecutedTime!).inSeconds < _cooldownSeconds) {
      return;
    }
    _lastExecutedTime = now;

    try {
      if (isNetworkChange) {
        // Close dead connections and reset DNS resolver on network change
        await coreController.closeConnections();
        await coreController.resetConnections();
        commonPrint.log(
          '[AutoSwitch] Closed dead connections and reset resolver due to network change.',
        );
      }

      final groups = ref.read(groupsProvider);
      final autoGroups =
          groups.where((g) => g.type.isComputedSelected).toList();

      if (autoGroups.isEmpty) {
        return;
      }

      commonPrint.log(
        '[AutoSwitch] Triggering delay test for ${autoGroups.length} auto-select group(s): ${autoGroups.map((g) => g.name).toList()}',
      );

      final proxiesAction = ref.read(proxiesActionProvider.notifier);
      for (final group in autoGroups) {
        unawaited(
          proxiesAction.delayTestPageGroup(group.name, matchSearch: false),
        );
      }
    } catch (e) {
      commonPrint.log(
        '[AutoSwitch] Failed to execute auto switch: $e',
        logLevel: LogLevel.warning,
      );
    }
  }
}

final autoSwitchManager = AutoSwitchManager.instance;
