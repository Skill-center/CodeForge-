/// Soft-keyboard gate (G3). While the IME is up the Scaffold shrinks the
/// workbench body; nothing may overflow at any gate size, terminal stop or G3
/// text scale, and the command palette — where Phase 1 actually raises the
/// keyboard — must still fit. Phase gate 42110297015 caught a real 79 px
/// editor overflow here on an emulator running Gboard (restore_a typed into
/// the palette with the terminal half-open); until then no widget test had
/// applied view insets.
library;

import 'dart:async';

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/find_controller.dart';
import 'package:codeforge/core/editor/large_files.dart';
import 'package:codeforge/design_system/components/dialogs.dart';
import 'package:codeforge/design_system/components/workbench_chrome.dart';
import 'package:codeforge/features/settings/appearance_screen.dart';
import 'package:codeforge/features/workbench/panels/editor_pane.dart';
import 'package:codeforge/features/workbench/panels/find_bar.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/memory_file_service.dart';
import 'test_harness.dart';
import 'workbench_dialogs.dart';

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

/// The workspace at [stop] with a file big enough for the large-file banner
/// (W7) open, and the find bar too when [withFind].
Future<void> _pumpLargeFile(
  WidgetTester tester,
  TerminalStop stop, {
  bool withFind = false,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  final harness = TestHarness(
    shell: ShellState(lastRoute: '/workspace', terminalStop: stop),
    files: MemoryFileService()
      ..putText('big.js', 'x' * (plainTextAboveChars + 1)),
  );
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(EditorPane)),
    listen: false,
  );
  unawaited(container.read(documentControllerProvider.notifier).open('big.js'));
  await tester.pumpAndSettle();
  if (withFind) {
    unawaited(container.read(findControllerProvider.notifier).open());
    await tester.pumpAndSettle();
  }
}

/// Lets debounced writes fire before the test's timer check.
Future<void> _flush(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 500));

/// The open dialog lies whole in the [room] above the keyboard, its
/// [confirm] action on it and its text [field], when it has one, at least
/// partly in view; nothing overflowed. Then it is closed.
Future<void> _expectDialogFits(
  WidgetTester tester,
  double room,
  String at, {
  required String confirm,
  String? field,
}) async {
  expect(tester.takeException(), isNull, reason: at);
  final dialog = find.byType(CfAlertDialog);
  expect(dialog, findsOneWidget, reason: at);
  final surface = tester.getRect(
    find.descendant(of: dialog, matching: find.byType(Material)).first,
  );
  expect(surface.top, greaterThanOrEqualTo(-0.5), reason: at);
  expect(surface.bottom, lessThanOrEqualTo(room + 0.5), reason: at);
  final action = tester.getRect(find.byKey(ValueKey(confirm)));
  expect(surface.inflate(0.5).intersect(action), action, reason: at);
  if (field != null) {
    // The first is the dialog's own, holding its title and content.
    final scrollViews = find.descendant(
      of: dialog,
      matching: find.byType(SingleChildScrollView),
    );
    final view = tester.getRect(scrollViews.first);
    final box = tester.getRect(find.byKey(ValueKey(field)));
    expect(box.overlaps(view), isTrue, reason: at);
  }
  Navigator.of(tester.element(dialog)).pop();
  await tester.pumpAndSettle();
}

void main() {
  for (final scale in const [1.0, 1.3]) {
    group('keyboard up at ${scale}x text', () {
      for (final (width, height, label) in _gateSizes) {
        testWidgets('$label: no overflow at any terminal stop', (tester) async {
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

      testWidgets('find and replace fit at every gate size (W6)', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final (width, height, label) in _gateSizes) {
          setSurface(tester, width, height);
          _raiseKeyboard(tester, width, height);
          await _pumpWorkspace(tester, TerminalStop.half);
          final pane = find.byType(EditorPane);
          final container = ProviderScope.containerOf(
            tester.element(pane),
            listen: false,
          );
          unawaited(
            container.read(findControllerProvider.notifier).open(replace: true),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: label);
          // The field being typed into stays mounted, keeping the keyboard,
          // and shows whole whenever the pane can hold its row.
          final field = find.byKey(const ValueKey('find_query'));
          expect(field, findsOneWidget, reason: label);
          final paneRect = tester.getRect(pane);
          if (paneRect.height >= FindBar.heightFor(1)) {
            expect(
              tester.getRect(field).bottom,
              lessThanOrEqualTo(paneRect.bottom + 0.5),
              reason: label,
            );
          }
        }
        await _flush(tester);
      });

      testWidgets('dialogs fit beside the keyboard at every gate size (G8)', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final (width, height, label) in _gateSizes) {
          setSurface(tester, width, height);
          _raiseKeyboard(tester, width, height);
          final room = height - _keyboardHeight(width, height);
          await _pumpWorkspace(tester, TerminalStop.half);
          // Home's (Phase 3 W6) open over the workbench here: a dialog
          // lays out the same over any screen.
          for (final dialog in [...workbenchDialogs, ...homeDialogs]) {
            unawaited(dialog.open(tester.element(find.byType(EditorPane))));
            await tester.pumpAndSettle();
            await _expectDialogFits(
              tester,
              room,
              '${dialog.name} at $label',
              confirm: dialog.confirm,
              field: dialog.field,
            );
          }

          // The toolbar keys, typed in Settings > Appearance: the keyboard
          // comes up once the dialog's field takes the focus.
          tester.view.resetViewInsets();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(TestHarness().wrap(const AppearanceScreen()));
          await tester.pumpAndSettle();
          final tile = find.byKey(const ValueKey('toolbar_keys_tile'));
          await tester.scrollUntilVisible(tile, 100);
          // Lay out its last scroll before tapping where the tile now is.
          await tester.pumpAndSettle();
          await tester.tap(tile);
          await tester.pumpAndSettle();
          _raiseKeyboard(tester, width, height);
          await tester.pumpAndSettle();
          await _expectDialogFits(
            tester,
            room,
            'toolbar keys at $label',
            confirm: 'toolbar_keys_save',
            field: 'toolbar_keys_field',
          );
        }
        await _flush(tester);
      });
    });
  }

  testWidgets('the large-file banner fits or steps aside (W7)', (tester) async {
    final banner = find.byKey(const ValueKey('large_file_notice'));
    final shownAt = <String>{};
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final scale in const [1.0, 1.3]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      for (final keyboard in const [false, true]) {
        for (final (width, height, label) in _gateSizes) {
          setSurface(tester, width, height);
          if (keyboard) {
            _raiseKeyboard(tester, width, height);
          } else {
            tester.view.resetViewInsets();
          }
          for (final stop in const [TerminalStop.closed, TerminalStop.half]) {
            for (final withFind in const [false, true]) {
              final at =
                  '$label ${scale}x keyboard=$keyboard ${stop.name} '
                  'find=$withFind';
              await _pumpLargeFile(tester, stop, withFind: withFind);
              expect(tester.takeException(), isNull, reason: at);
              if (banner.evaluate().isEmpty) {
                continue;
              }
              shownAt.add(label);
              // Shown, it leaves the editor at least two touch rows.
              final body = tester.getRect(
                find.byKey(const ValueKey('editor_body')),
              );
              expect(body.height, greaterThanOrEqualTo(95.5), reason: at);
            }
          }
        }
      }
    }
    // Not vacuous: there is room for it on a phone and a tablet.
    expect(shownAt, containsAll(['phone portrait', 'tablet portrait']));
    await _flush(tester);
  });

  testWidgets('the find bar outlives the banner and toolbar leaving together', (
    tester,
  ) async {
    final harness = TestHarness(
      files: MemoryFileService()
        ..putText('big.js', 'x' * (plainTextAboveChars + 1)),
    );
    final height = ValueNotifier<double>(500);
    addTearDown(height.dispose);
    await tester.pumpWidget(
      harness.wrap(
        ValueListenableBuilder<double>(
          valueListenable: height,
          builder: (context, value, _) => Align(
            alignment: Alignment.topCenter,
            child: SizedBox(height: value, child: const EditorPane()),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(EditorPane)),
      listen: false,
    );
    await container.read(documentControllerProvider.notifier).open('big.js');
    await tester.pumpAndSettle();
    unawaited(container.read(findControllerProvider.notifier).open());
    await tester.pumpAndSettle();
    final banner = find.byKey(const ValueKey('large_file_notice'));
    expect(banner, findsOneWidget);
    expect(find.byType(CfSymbolToolbar), findsOneWidget);
    final bar = tester.state(find.byType(FindBar));

    // The keyboard rising on a small phone: the banner and the toolbar go
    // in one layout, the tabs and the find row stay. The bar, and the field
    // holding the keyboard, must be the same element afterwards.
    height.value = 170;
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(find.byType(CfSymbolToolbar), findsNothing);
    expect(find.byType(CfTabStrip), findsOneWidget);
    expect(tester.state(find.byType(FindBar)), same(bar));
    expect(tester.takeException(), isNull);
  });

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
