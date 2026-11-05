/// Zero-overflow gate (G3/G7) at the four gate sizes plus a short-landscape
/// stress case, across terminal stops and both themes.
library;

import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_harness.dart';

const List<(double, double, String)> _gateSizes = [
  (360, 800, 'small phone portrait'),
  (412, 915, 'phone portrait'),
  (800, 1280, 'tablet portrait'),
  (1280, 800, 'tablet landscape'),
  (800, 360, 'phone landscape (short)'),
];

void main() {
  for (final (width, height, label) in _gateSizes) {
    for (final stop in TerminalStop.values) {
      testWidgets('no overflow: $label, terminal=${stop.name}', (tester) async {
        setSurface(tester, width, height);
        final harness = TestHarness(
          shell: ShellState(lastRoute: '/workspace', terminalStop: stop),
        );
        await tester.pumpWidget(harness.app());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('no overflow in light theme at gate sizes', (tester) async {
    for (final (width, height, _) in _gateSizes) {
      setSurface(tester, width, height);
      final harness = TestHarness(
        settings: const AppSettings(
          welcomeSeen: true,
          themeMode: ThemeMode.light,
        ),
        shell: const ShellState(
          lastRoute: '/workspace',
          terminalStop: TerminalStop.half,
        ),
      );
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('compact portrait shows activity bar; tablet shows rail', (
    tester,
  ) async {
    setSurface(tester, 360, 800);
    final phone = TestHarness(shell: const ShellState(lastRoute: '/workspace'));
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('activity_explorer')), findsOneWidget);

    // Tear down the phone tree so the tablet harness gets a fresh container
    // (a replaced ProviderScope would otherwise keep the old one).
    await tester.pumpWidget(const SizedBox.shrink());
    setSurface(tester, 1280, 800);
    final tablet = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(tablet.app());
    await tester.pumpAndSettle();
    // Sidebar explorer is docked: tree rows visible without opening a sheet.
    expect(find.byKey(const ValueKey('tree_main.js')), findsOneWidget);
  });

  testWidgets('terminal toggle opens and closes the pane', (tester) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.text('TERMINAL'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('terminal_toggle')));
    await tester.pumpAndSettle();
    expect(find.text('TERMINAL'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('terminal_close')));
    await tester.pumpAndSettle();
    expect(find.text('TERMINAL'), findsNothing);
  });

  testWidgets('explorer sheet opens files into real tabs on phone', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('activity_explorer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tree_app.py')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tree_app.py')));
    await tester.pumpAndSettle();
    expect(find.text('app.py'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
