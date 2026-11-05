/// Accessibility gates (docs/phases/PHASE_1_PLAN.md §4):
///  * G3 — text scale 1.3 on every route at every gate size without overflow
///    (any RenderFlex overflow fails the test).
///  * G7 — every tappable element is labelled and offers a ≥ 48 dp target.
/// TalkBack itself is spot-checked by hand at phase exit; everything a
/// machine can check is asserted here.
library;

import 'package:codeforge/design_system/components/file_tree.dart';
import 'package:codeforge/design_system/components/workbench_chrome.dart';
import 'package:codeforge/design_system/tokens/geometry.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_harness.dart';

/// The G3 gate surfaces (same as workbench_layout_test).
const List<(double, double)> _gateSizes = [
  (360, 800),
  (412, 915),
  (800, 1280),
  (1280, 800),
  (800, 360),
];

final class _Scenario {
  const _Scenario(this.name, this.shell, {this.settings});

  final String name;
  final ShellState shell;
  final AppSettings? settings;
}

const List<_Scenario> _scenarios = [
  _Scenario('first-run home + welcome', ShellState(), settings: AppSettings()),
  _Scenario('home', ShellState()),
  _Scenario(
    'workspace + terminal',
    ShellState(lastRoute: '/workspace', terminalStop: TerminalStop.half),
  ),
  _Scenario('settings', ShellState(lastRoute: '/settings')),
];

const _settings = _Scenario('settings', ShellState(lastRoute: '/settings'));
const _workspace = _Scenario('workspace', ShellState(lastRoute: '/workspace'));

Future<void> _pump(WidgetTester tester, _Scenario scenario) async {
  // A fresh container per pump: a replaced ProviderScope keeps the old one.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    TestHarness(settings: scenario.settings, shell: scenario.shell).app(),
  );
  await tester.pumpAndSettle();
}

/// Let the shell's debounced persistence timer fire before teardown.
Future<void> _flush(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 500));

const List<String> _settingsPages = ['Appearance', 'About CodeForge'];

Future<void> _openSettingsPage(WidgetTester tester, String title) async {
  await _pump(tester, _settings);
  await tester.scrollUntilVisible(
    find.text(title),
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

Future<void> _openPalette(WidgetTester tester) async {
  await _pump(tester, _workspace);
  await tester.tap(find.byKey(const ValueKey('palette_button')));
  await tester.pumpAndSettle();
}

bool _insideMaterialButton(Element element) {
  var inside = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    // Material buttons pad their own tap target outside the InkWell; the
    // stock guideline below measures those through their semantics node.
    if (widget is ButtonStyleButton || widget is SegmentedButton<Object?>) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

String _describe(Element element) {
  final key = element.widget.key;
  if (key is ValueKey<String>) return key.value;
  String? text;
  void visit(Element child) {
    if (text != null) return;
    final widget = child.widget;
    if (widget is Text && widget.data != null) {
      text = widget.data;
      return;
    }
    child.visitChildren(visit);
  }

  element.visitChildren(visit);
  return text != null ? '"$text"' : element.widget.toStringShort();
}

/// Flutter's stock guidelines plus a stricter size sweep. The stock
/// androidTapTargetGuideline skips any target that touches the edge of a
/// scrollable or of the screen (it might be partially scrolled away) —
/// which would exempt every tab, tree row, palette row and the top bar —
/// so every enabled InkWell is also measured directly.
Future<void> _expectAccessibleTargets(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

  final failures = <String>[];
  final inkWells = find.byWidgetPredicate(
    (widget) => widget is InkWell && widget.onTap != null,
  );
  for (final element in inkWells.evaluate()) {
    if (_insideMaterialButton(element)) continue;
    final size = (element.renderObject! as RenderBox).size;
    const min = CfSpacing.minTouchTarget - 0.01;
    if (size.width < min || size.height < min) {
      failures.add(
        '${_describe(element)}: '
        '${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}',
      );
    }
  }
  expect(failures, isEmpty, reason: 'tap targets below 48x48 dp');
}

void main() {
  group('G3 text scale 1.3', () {
    for (final scenario in _scenarios) {
      testWidgets('${scenario.name}: no overflow at any gate size', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final (width, height) in _gateSizes) {
          setSurface(tester, width, height);
          await _pump(tester, scenario);
          expect(
            tester.takeException(),
            isNull,
            reason: '${scenario.name} at ${width.toInt()}x${height.toInt()}',
          );
        }
        await _flush(tester);
      });
    }

    testWidgets('settings sub-pages and palette: no overflow at any size', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final (width, height) in _gateSizes) {
        setSurface(tester, width, height);
        final at = '${width.toInt()}x${height.toInt()}';
        for (final title in _settingsPages) {
          await _openSettingsPage(tester, title);
          expect(tester.takeException(), isNull, reason: '$title at $at');
        }
        await _openPalette(tester);
        expect(tester.takeException(), isNull, reason: 'palette at $at');
      }
      await _flush(tester);
    });
  });

  group('G7 labels and 48 dp targets', () {
    for (final scenario in _scenarios) {
      for (final (width, height) in _gateSizes) {
        testWidgets('${scenario.name} at ${width.toInt()}x${height.toInt()}', (
          tester,
        ) async {
          final semantics = tester.ensureSemantics();
          setSurface(tester, width, height);
          await _pump(tester, scenario);
          await _expectAccessibleTargets(tester);
          await _flush(tester);
          semantics.dispose();
        });
      }
    }

    testWidgets('workbench chrome is actually covered by the sweep', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      setSurface(tester, 1280, 800);
      await _pump(tester, _workspace);
      // Docked explorer rows, an open tab with its close button, top bar.
      expect(find.byType(CfTreeRow), findsWidgets);
      expect(find.byType(CfTabStrip), findsOneWidget);
      expect(find.byKey(const ValueKey('tab_close_main.js')), findsOneWidget);
      expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
      await _expectAccessibleTargets(tester);
      await _flush(tester);
      semantics.dispose();
    });

    testWidgets('settings sub-pages', (tester) async {
      final semantics = tester.ensureSemantics();
      setSurface(tester, 412, 915);
      for (final title in _settingsPages) {
        await _openSettingsPage(tester, title);
        await _expectAccessibleTargets(tester);
      }
      await _flush(tester);
      semantics.dispose();
    });

    testWidgets('command palette', (tester) async {
      final semantics = tester.ensureSemantics();
      setSurface(tester, 412, 915);
      await _openPalette(tester);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is InkWell &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('palette_'),
        ),
        findsWidgets,
      );
      await _expectAccessibleTargets(tester);
      await _flush(tester);
      semantics.dispose();
    });

    testWidgets('settings switch row is one labelled node', (tester) async {
      final semantics = tester.ensureSemantics();
      setSurface(tester, 412, 915);
      await _pump(tester, _settings);
      // getSemantics walks up to the node the Switch is merged into.
      final node = tester.getSemantics(find.byType(Switch));
      expect(
        node,
        isSemantics(
          hasTapAction: true,
          hasToggledState: true,
          isToggled: false,
        ),
      );
      expect(node.getSemanticsData().label, contains('Reduced motion'));
      await _flush(tester);
      semantics.dispose();
    });
  });
}
