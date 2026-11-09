/// Accessibility gates (docs/phases/PHASE_1_PLAN.md §4):
///  * G3 — text scale 1.3 on every route at every gate size without overflow
///    (any RenderFlex overflow fails the test).
///  * G7 — every tappable element is labelled and offers a ≥ 48 dp target.
/// TalkBack itself is spot-checked by hand at phase exit; everything a
/// machine can check is asserted here.
library;

import 'dart:async';

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/core/editor/large_files.dart';
import 'package:codeforge/design_system/components/file_tree.dart';
import 'package:codeforge/design_system/components/workbench_chrome.dart';
import 'package:codeforge/design_system/tokens/geometry.dart';
import 'package:codeforge/features/settings/about_screen.dart';
import 'package:codeforge/features/settings/appearance_screen.dart';
import 'package:codeforge/features/workbench/panels/editor_pane.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/memory_file_service.dart';
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

typedef _SettingsPage = ({String title, Type screen});

const List<_SettingsPage> _settingsPages = [
  (title: 'Appearance', screen: AppearanceScreen),
  (title: 'About CodeForge', screen: AboutScreen),
];

Future<void> _openSettingsPage(WidgetTester tester, _SettingsPage page) async {
  await _pump(tester, _settings);
  final tile = find.text(page.title);
  await tester.scrollUntilVisible(
    tile,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  // Built is not the same as on screen (lists build ahead of the viewport):
  // bring the tile fully into view before tapping, then prove the
  // destination really opened, so a missed tap cannot make a check vacuous.
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
  expect(
    find.byType(page.screen),
    findsOneWidget,
    reason: 'opened ${page.title}',
  );
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
  // Unkeyed InkWells (e.g. inside CfIconButton): name the nearest keyed or
  // tooltipped ancestor a few levels up.
  String? owner;
  var depth = 0;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    final ancestorKey = widget.key;
    if (ancestorKey is ValueKey<String>) {
      owner = ancestorKey.value;
    } else if (widget is Tooltip && widget.message != null) {
      owner = 'tooltip "${widget.message}"';
    }
    return owner == null && ++depth < 8;
  });
  if (owner != null) return owner!;
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
        for (final page in _settingsPages) {
          await _openSettingsPage(tester, page);
          expect(
            tester.takeException(),
            isNull,
            reason: '${page.title} at $at',
          );
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

    testWidgets('large-file banner (W7)', (tester) async {
      final semantics = tester.ensureSemantics();
      setSurface(tester, 412, 915);
      final harness = TestHarness(
        shell: const ShellState(lastRoute: '/workspace'),
        files: MemoryFileService()
          ..putText('big.js', 'x' * (plainTextAboveChars + 1)),
      );
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EditorPane)),
        listen: false,
      );
      unawaited(
        container.read(documentControllerProvider.notifier).open('big.js'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('large_file_notice')), findsOneWidget);
      await _expectAccessibleTargets(tester);
      await _flush(tester);
      semantics.dispose();
    });

    testWidgets('settings sub-pages', (tester) async {
      final semantics = tester.ensureSemantics();
      setSurface(tester, 412, 915);
      for (final page in _settingsPages) {
        await _openSettingsPage(tester, page);
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
