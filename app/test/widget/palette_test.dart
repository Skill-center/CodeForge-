import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_harness.dart';

void main() {
  testWidgets('palette opens, filters, and executes a real command', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('palette_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('palette_input')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('palette_input')),
      'light',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('palette_theme.light')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('palette_theme.light')));
    await tester.pumpAndSettle();

    expect(harness.settingsStore.load().themeMode, ThemeMode.light);
    expect(find.byKey(const ValueKey('palette_input')), findsNothing);
  });

  testWidgets('palette navigates to settings', (tester) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('palette_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('palette_input')),
      'open settings',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('palette_nav.settings')));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    // Shell persistence is debounced 400ms; advance past it before reading.
    await tester.pump(const Duration(milliseconds: 500));
    expect(harness.shellStore.load().lastRoute, '/settings');
  });
}
