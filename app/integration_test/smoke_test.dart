/// On-device smoke test (G1/G2): real app, real SharedPreferences, real
/// navigation. Runs on the CI emulator via `flutter test integration_test`.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 exports Override from misc.dart, not the main library.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pumps real time until [condition] holds (integration tests run live,
/// and file work finishes on its own schedule, not the frame's).
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail('Timed out after ${timeout.inSeconds} s waiting for $what.');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> pumpRealApp(
  WidgetTester tester,
  SharedPreferences prefs, {
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(PrefsSettingsStore(prefs)),
        shellStateStoreProvider.overrideWithValue(PrefsShellStateStore(prefs)),
        ...overrides,
      ],
      child: const CodeForgeApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('smoke: welcome → demo → tabs → terminal → settings', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await pumpRealApp(tester, prefs);

    // Welcome appears on first launch and dismisses.
    expect(find.byKey(const ValueKey('welcome_dismiss')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();

    // One tap into the workbench. Home opens the workspace first (on first
    // run that writes the demo project as real files), so the route
    // changes only when the device's file work is done: wait for it rather
    // than for frames.
    // Home's list may need to scroll to it (Phase 3 W3).
    await tester.ensureVisible(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('terminal_toggle')).evaluate().isNotEmpty,
      what: 'the workbench to open',
    );
    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
    await pumpUntil(
      tester,
      () => find.text('main.js').evaluate().isNotEmpty,
      what: 'main.js to open',
    );
    await tester.pumpAndSettle();
    expect(find.text('main.js'), findsOneWidget);

    // Terminal opens and closes.
    await tester.tap(find.byKey(const ValueKey('terminal_toggle')));
    await tester.pumpAndSettle();
    expect(find.text('TERMINAL'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminal_close')));
    await tester.pumpAndSettle();

    // Palette → settings.
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

    // Persisted envelope exists on device.
    final reloaded = await SharedPreferences.getInstance();
    expect(reloaded.getString(settingsStorageKey), isNotNull);
    expect(reloaded.getString(shellStateStorageKey), isNotNull);
  });
}
