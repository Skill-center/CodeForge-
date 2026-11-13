/// Screen goldens at the G3 gate sizes (docs/phases/PHASE_1_PLAN.md §4):
/// portrait/landscape pairs for small phone, phone and tablet — home and the
/// workspace (terminal half-open) in the default dark theme, plus light-theme
/// spot checks. Baselines are generated on the CI Linux runner via the
/// [bootstrap] flow and committed; overflow is asserted on every pump.
@Tags(['golden'])
library;

import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../widget/test_harness.dart';

const List<(double, double)> _sizes = [
  (360, 800),
  (800, 360),
  (412, 915),
  (915, 412),
  (800, 1280),
  (1280, 800),
];

const List<(String, ShellState)> _screens = [
  ('home', ShellState()),
  (
    'workspace',
    ShellState(lastRoute: '/workspace', terminalStop: TerminalStop.half),
  ),
];

const _light = AppSettings(welcomeSeen: true, themeMode: ThemeMode.light);

Future<void> _expectGolden(
  WidgetTester tester, {
  required double width,
  required double height,
  required ShellState shell,
  required String file,
  AppSettings? settings,
}) async {
  setSurface(tester, width, height);
  await tester.pumpWidget(TestHarness(settings: settings, shell: shell).app());
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  await expectLater(find.byType(MaterialApp), matchesGoldenFile(file));
  // Let the shell's debounced persistence timer fire before teardown.
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  for (final (width, height) in _sizes) {
    final size = '${width.toInt()}x${height.toInt()}';
    for (final (name, shell) in _screens) {
      testWidgets('$name $size dark', (tester) async {
        await _expectGolden(
          tester,
          width: width,
          height: height,
          shell: shell,
          file: 'screens/${name}_${size}_dark.png',
        );
      });
    }
  }

  for (final (width, height) in const [(412.0, 915.0), (1280.0, 800.0)]) {
    final size = '${width.toInt()}x${height.toInt()}';
    for (final (name, shell) in _screens) {
      testWidgets('$name $size light', (tester) async {
        await _expectGolden(
          tester,
          width: width,
          height: height,
          shell: shell,
          settings: _light,
          file: 'screens/${name}_${size}_light.png',
        );
      });
    }
  }

  testWidgets('settings 412x915 dark', (tester) async {
    await _expectGolden(
      tester,
      width: 412,
      height: 915,
      shell: const ShellState(lastRoute: '/settings'),
      file: 'screens/settings_412x915_dark.png',
    );
  });
}
