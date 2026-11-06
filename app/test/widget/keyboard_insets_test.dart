/// Soft-keyboard gate (G3). While the IME is up the Scaffold shrinks the
/// workbench body; nothing may overflow at any gate size, terminal stop or G3
/// text scale, and the command palette — where Phase 1 actually raises the
/// keyboard — must still fit. Phase gate 42110297015 caught a real 79 px
/// editor overflow here on an emulator running Gboard (restore_a typed into
/// the palette with the terminal half-open); until then no widget test had
/// applied view insets.
library;

import 'package:codeforge/features/workbench/panels/editor_pane.dart';
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

/// Generous IME heights: 40 % of a portrait surface (Gboard took about 36 %
/// of the gate emulator's 914 dp) and 55 % of a landscape one.
double _keyboardHeight(double width, double height) =>
    height > width ? height * 0.4 : height * 0.55;

/// Raises a fake soft keyboard. setSurface uses devicePixelRatio 1, so
/// physical and logical pixels coincide.
void _raiseKeyboard(WidgetTester tester, double width, double height) {
  tester.view.viewInsets = FakeViewPadding(
    bottom: _keyboardHeight(width, height),
  );
  addTearDown(tester.view.resetViewInsets);
}

Future<void> _pumpWorkspace(WidgetTester tester, TerminalStop stop) async {
  // A fresh tree per state: a replaced ProviderScope keeps its container.
  await tester.pumpWidget(const SizedBox.shrink());
  final harness = TestHarness(
    shell: ShellState(lastRoute: '/workspace', terminalStop: stop),
  );
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
}

/// Lets debounced writes fire before the test's timer check.
Future<void> _flush(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 500));

void main() {
  for (final scale in const [1.0, 1.3]) {
    group('keyboard up at ${scale}x text', () {
      for (final (width, height, label) in _gateSizes) {
        testWidgets('$label: no overflow at any terminal stop', (
          tester,
        ) async {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          setSurface(tester, width, height);
          _raiseKeyboard(tester, width, height);
          for (final stop in TerminalStop.values) {
            await _pumpWorkspace(tester, stop);
            expect(
              tester.takeException(),
              isNull,
              reason: 'terminal=${stop.name}',
            );
          }
          await _flush(tester);
        });
      }

      testWidgets('command palette fits at every gate size', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final (width, height, label) in _gateSizes) {
          setSurface(tester, width, height);
          _raiseKeyboard(tester, width, height);
          await _pumpWorkspace(tester, TerminalStop.half);
          await tester.tap(find.byKey(const ValueKey('palette_button')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('palette_input')),
            findsOneWidget,
            reason: label,
          );
          expect(tester.takeException(), isNull, reason: label);
        }
        await _flush(tester);
      });
    });
  }

  testWidgets('compact portrait: terminal yields, editor keeps 191 dp', (
    tester,
  ) async {
    // Body = screen − keyboard; terminal cap = body − 264 (top bar 49 +
    // status strip 24 + the 191 dp editor floor), so half and full both
    // leave the editor exactly its floor while the keyboard is up.
    for (final (width, height) in const [(360.0, 800.0), (412.0, 915.0)]) {
      setSurface(tester, width, height);
      _raiseKeyboard(tester, width, height);
      for (final stop in const [TerminalStop.half, TerminalStop.full]) {
        await _pumpWorkspace(tester, stop);
        expect(
          tester.getSize(find.byType(EditorPane)).height,
          moreOrLessEquals(191, epsilon: 0.5),
          reason: '${width.toInt()}x${height.toInt()} ${stop.name}',
        );
      }
    }
    await _flush(tester);
  });
}
