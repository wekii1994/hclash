import 'package:fl_clash/manager/theme_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart';

void main() {
  testWidgets('page scaling across 100 percent preserves the active route', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: PrismApp(
          navigatorKey: navigator,
          builder: (_, child) => ThemeManager(
            child: Stack(
              children: [
                child!,
                const _ScaleProbe(key: ValueKey('manager')),
              ],
            ),
          ),
          home: const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => const _ScaleProbe(key: ValueKey('route')),
        transitionDuration: Duration.zero,
      ),
    );
    await tester.pumpAndSettle();
    final route = find.byKey(const ValueKey('route'));
    final manager = find.byKey(const ValueKey('manager'));
    final state = tester.state(route);
    final managerState = tester.state(manager);
    final navigatorState = navigator.currentState;
    for (final scale in [0.6, 1.2, 1.0, 0.8, 1.0]) {
      final settings = container.read(themeSettingProvider.notifier);
      settings.value = settings.value.copyWith(pageScale: scale);
      await tester.pumpAndSettle();
      expect(navigator.currentState, same(navigatorState));
      expect(route, findsOneWidget);
      expect(tester.state(route), same(state));
      expect(tester.state(manager), same(managerState));
      final context = tester.element(route);
      expect(MediaQuery.sizeOf(context).width, closeTo(800 / scale, 0.01));
    }
  });

  testWidgets('a theme setting the theme does not read keeps the same theme', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final themes = <ThemeData>[];
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (_, ref, _) {
            ref.watch(themeSettingProvider);
            themes.add(watchAppTheme(ref, Brightness.dark));
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    void update(ThemeProps Function(ThemeProps props) change) {
      final notifier = container.read(themeSettingProvider.notifier);
      notifier.value = change(notifier.value);
    }

    update((props) => props.copyWith(sidebarBlur: !props.sidebarBlur));
    await tester.pump();
    update((props) => props.copyWith(pureBlack: !props.pureBlack));
    await tester.pump();

    expect(themes, hasLength(3));
    expect(themes[1], same(themes[0]));
    expect(themes[2], isNot(same(themes[1])));
  });
}

class _ScaleProbe extends StatefulWidget {
  const _ScaleProbe({super.key});

  @override
  State<_ScaleProbe> createState() => _ScaleProbeState();
}

class _ScaleProbeState extends State<_ScaleProbe> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
