import 'dart:async';

import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/traffic_stats/traffic_stats_persistence.dart';
import 'package:fl_clash/features/traffic_stats/traffic_stats_store.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _CloseListener with CoreEventListener {
  _CloseListener(this.store);

  final TrafficStatsStore store;
  final order = <String>[];
  final completed = Completer<void>();

  @override
  void onRequestTrafficSamples(List<RequestTrafficSample> samples) {
    store.recordRequestTrafficSamples(samples);
  }

  @override
  void onRequestTraffic(Map<String, RequestTraffic> traffic) {
    final value = traffic['hclash-close-regression'];
    if (value != null) order.add('sample:${value.download}');
  }

  @override
  void onRequestsClosed(Set<String> ids) {
    if (ids.contains('hclash-close-regression')) {
      order.add('closed');
      if (!completed.isCompleted) completed.complete();
    }
  }
}

class _MemoryPersistence implements TrafficStatsPersistence {
  @override
  Future<Map<String, dynamic>?> read() async => null;

  @override
  Future<void> write(Map<String, dynamic> snapshot) async {}
}

void main() {
  test(
    'dispatch final cumulative counters before retiring the connection',
    () async {
      final store = TrafficStatsStore(persistence: _MemoryPersistence());
      addTearDown(store.dispose);
      final listener = _CloseListener(store);
      coreEventManager.addListener(listener);
      try {
        coreEventManager.sendEvent(
          const CoreEvent(
            type: CoreEventType.requestTraffic,
            data: [
              {
                'id': 'hclash-close-regression',
                'upload': 0,
                'download': 123,
                'closed': true,
                'host': 'example.com',
                'process': 'browser',
              },
            ],
          ),
        );
        await listener.completed.future.timeout(const Duration(seconds: 2));
        expect(listener.order, ['sample:123', 'closed']);
        expect(store.todayDownload, 123);
        expect(store.targetSiteUsages['example.com']?.download, 123);
        expect(store.targetSiteUsages['example.com']?.process, 'browser');
        expect(store.trackedConnections, 0);
      } finally {
        coreEventManager.removeListener(listener);
      }
    },
  );
}
