import 'package:codeforge/features/home/home_screen.dart';
import 'package:codeforge/features/settings/about_screen.dart';
import 'package:codeforge/features/settings/appearance_screen.dart';
import 'package:codeforge/features/settings/settings_screen.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'test_harness.dart';

void main() {
  testWidgets('welcome sheet appears once and dismisses for good', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(settings: const AppSettings());
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('welcome_dismiss')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('welcome_dismiss')), findsNothing);
    expect(harness.settingsStore.load().welcomeSeen, isTrue);

    // Rebuild the app from the same store: no welcome again.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('welcome_dismiss')), findsNothing);
  });

  testWidgets('home → demo workspace in one tap (G2)', (tester) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness();
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await openDemoWorkspace(tester);
    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
    expect(find.text('main.js'), findsOneWidget);
    // Shell persistence is debounced 400ms; advance past it before reading.
    await tester.pump(const Duration(milliseconds: 500));
    expect(harness.shellStore.load().lastRoute, '/workspace');
  });

  testWidgets('home → settings in one tap; the theme change is real', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness();
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    // From home: 1 tap.
    await tester.tap(find.byKey(const ValueKey('home_settings')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    // Appearance → theme change is real.
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(harness.settingsStore.load().themeMode, ThemeMode.light);

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.light);
    // Drain the shell route debounce so no timer outlives the test.
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('every destination is ≤2 taps from home (G2)', (tester) async {
    setSurface(tester, 412, 915);
    Future<void> fromHome(List<Finder> taps, Type destination) async {
      // A fresh tree per path: a replaced ProviderScope keeps its container.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(TestHarness().app());
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      for (final target in taps) {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
      }
      expect(find.byType(destination), findsOneWidget, reason: '$destination');
    }

    const settings = ValueKey('home_settings');
    await fromHome([
      find.byKey(const ValueKey('explore_demo')),
    ], WorkbenchScreen);
    await fromHome([find.byKey(settings)], SettingsScreen);
    await fromHome([
      find.byKey(settings),
      find.text('Appearance'),
    ], AppearanceScreen);
    await fromHome([
      find.byKey(settings),
      find.text('About CodeForge'),
    ], AboutScreen);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('workbench → settings in ≤2 taps on phone and tablet (G2)', (
    tester,
  ) async {
    // Phone: the top bar's home button, then home's settings entry.
    setSurface(tester, 412, 915);
    final phone = TestHarness(shell: const ShellState(lastRoute: '/workspace'));
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    expect(find.byType(WorkbenchScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workbench_home')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home_settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    // Tablet: the rail's trailing settings entry, one tap.
    await tester.pumpWidget(const SizedBox.shrink());
    setSurface(tester, 1280, 800);
    final tablet = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(tablet.app());
    await tester.pumpAndSettle();
    expect(find.byType(WorkbenchScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('activity_settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('workbench restores as initial route (G5 first frame)', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    // First settled frame is already the workbench — no home flash.
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('explore_demo')), findsNothing);
  });

  testWidgets('reduced motion setting disables animations', (tester) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      settings: const AppSettings(welcomeSeen: true, reducedMotion: true),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    final media = MediaQuery.of(tester.element(find.byType(Scaffold).first));
    expect(media.disableAnimations, isTrue);
  });
}
