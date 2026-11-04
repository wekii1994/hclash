import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

final failoverStatsProvider =
    AsyncNotifierProvider.autoDispose<FailoverStatsNotifier, FailoverStats>(
  FailoverStatsNotifier.new,
);

class FailoverStatsNotifier extends AsyncNotifier<FailoverStats> {
  int _activeEpoch = 0;

  @override
  Future<FailoverStats> build() async {
    final epoch = ++_activeEpoch;

    final coreStatus = ref.watch(coreStatusProvider);
    final isInit = ref.watch(initProvider);
    final isVisible = ref.watch(appVisibleProvider);

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
