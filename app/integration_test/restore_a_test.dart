/// Restore gate, part A (G5): establish a distinctive state — light theme,
/// workspace route, terminal half-open — and let it persist. CI force-stops
/// the process after this test; restore_b_test verifies survival.
library;

import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpRealApp;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('restore A: set light theme + workspace + terminal half', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await pumpRealApp(tester, prefs);

    // Fresh state: dismiss welcome, enter workspace.
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();

    // Terminal half-open.
    await tester.tap(find.byKey(const ValueKey('terminal_toggle')));
    await tester.pumpAndSettle();

    // Let the debounced shell persist land (real timers on device).
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();

    // Light theme via settings.
    await tester.tap(find.byKey(const ValueKey('palette_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('palette_input')),
      'light',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('palette_theme.light')));
    await tester.pumpAndSettle();

    final reloaded = await SharedPreferences.getInstance();
    final settingsRaw = reloaded.getString(settingsStorageKey);
    final shellRaw = reloaded.getString(shellStateStorageKey);
    expect(settingsRaw, contains('"themeMode":"light"'));
    expect(shellRaw, contains('"lastRoute":"/workspace"'));
    expect(shellRaw, contains('"terminalStop":"half"'));
  });
}
