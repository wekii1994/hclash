import 'dart:async';

import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _CloseListener with CoreEventListener {
  final order = <String>[];
  final completed = Completer<void>();

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

void main() {
  test(
    'dispatch final cumulative counters before retiring the connection',
    () async {
      final listener = _CloseListener();
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
              },
            ],
          ),
        );
        await listener.completed.future.timeout(const Duration(seconds: 2));
        expect(listener.order, ['sample:123', 'closed']);
      } finally {
        coreEventManager.removeListener(listener);
      }
    },
  );
}
