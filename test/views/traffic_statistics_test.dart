import 'package:fl_clash/features/traffic_stats/traffic_stats.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/traffic_statistics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets(
    'persistence error banner updates reactively on store failure and recovery without full page rebuild',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      globalState.container = container;

      final store = TrafficStatsStore.instance;
      store.lastPersistenceError = null;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TestApp(
            locale: Locale('zh'),
            child: PersistenceErrorBanner(),
          ),
        ),
      );
      await tester.pump();

      // 1. Initially no error banner text
      final errorFinder = find.textContaining('统计文件读取或保存失败');
      expect(errorFinder, findsNothing);

      // 2. Async error occurs (e.g. periodic save or async init failed)
      store.lastPersistenceError = 'Disk I/O error simulated';
      await tester.pump();

      // Banner must be displayed
      expect(errorFinder, findsOneWidget);

      // 3. Normal traffic samples arrive without error change -> banner does not rebuild
      store.notifyListeners();
      await tester.pump();
      expect(errorFinder, findsOneWidget);

      // 4. Save succeeds and recovers error
      store.lastPersistenceError = null;
      await tester.pump();

      // Banner must disappear
      expect(errorFinder, findsNothing);
    },
  );
}
