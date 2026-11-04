import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'route_state.dart';

final failoverStatsProvider =
    AsyncNotifierProvider.autoDispose<FailoverStatsNotifier, FailoverStats>(
  FailoverStatsNotifier.new,
);

class FailoverStatsNotifier extends AsyncNotifier<FailoverStats> {
  Timer? _midnightTimer;
  int _activeEpoch = 0;

  @override
  Future<FailoverStats> build() async {
    final epoch = ++_activeEpoch;

    // Cache tracker while ref is mounted and active
    final tracker = ref.read(routeTrackerProvider.notifier);
    tracker.attach();
    ref.onDispose(() {
      _midnightTimer?.cancel();
      // Use cached tracker directly to avoid UnmountedRefException
      tracker.detach();
    });

    ref.watch(routeTrackerProvider.select((s) => s.routeVersion));
    final coreStatus = ref.watch(coreStatusProvider);
    final isInit = ref.watch(initProvider);
    final isVisible = ref.watch(appVisibleProvider);

    _scheduleMidnightTimer();

    if (!isInit || coreStatus != CoreStatus.connected || !isVisible) {
      return state.value ?? const FailoverStats();
    }

    FailoverStats? stats;
    try {
      stats = await coreController.getFailoverStats();
    } catch (e) {
      if (!ref.mounted) {
        return state.value ?? const FailoverStats();
      }
      if (epoch != _activeEpoch) {
        return Completer<FailoverStats>().future;
      }
      rethrow;
    }

    if (!ref.mounted) {
      return state.value ?? const FailoverStats();
    }
    if (epoch != _activeEpoch) {
      return Completer<FailoverStats>().future;
    }
    return stats ?? const FailoverStats();
  }

  void _scheduleMidnightTimer() {
    _midnightTimer?.cancel();
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    final duration = nextMidnight.difference(now) + const Duration(seconds: 1);
    _midnightTimer = Timer(duration, () {
      if (ref.mounted) {
        refresh();
      }
    });
  }

  Future<void> refresh() async {
    final epoch = ++_activeEpoch;
    state = const AsyncValue.loading();
    final next = await AsyncValue.guard(() async {
      final stats = await coreController.getFailoverStats();
      return stats ?? const FailoverStats();
    });
    if (!ref.mounted || epoch != _activeEpoch) {
      return;
    }
    state = next;
  }

  Future<void> reset() async {
    final epoch = ++_activeEpoch;
    state = const AsyncValue.loading();
    final next = await AsyncValue.guard(() async {
      final stats = await coreController.resetFailoverStats();
      return stats ?? const FailoverStats();
    });
    if (!ref.mounted || epoch != _activeEpoch) {
      return;
    }
    state = next;
  }
}
