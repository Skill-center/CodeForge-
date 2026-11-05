/// On-device smoke test (G1/G2): real app, real SharedPreferences, real
/// navigation. Runs on the CI emulator via `flutter test integration_test`.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpRealApp(WidgetTester tester, SharedPreferences prefs) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(PrefsSettingsStore(prefs)),
        shellStateStoreProvider.overrideWithValue(PrefsShellStateStore(prefs)),
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

    // One tap into the workbench.
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
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
