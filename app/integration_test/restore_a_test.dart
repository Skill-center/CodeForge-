/// Restore gate, part A (G5, and G3's tabs): establish a distinctive state —
/// light theme, workspace route, terminal half-open, a second tab active —
/// and let it persist (prefs for the shell, the app database for tabs). CI force-stops the process after this test;
/// restore_b_test verifies survival.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpRealApp, pumpUntil;

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

    // A second tab, active: main.js opened on its own, app.py from here.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    await pumpUntil(
      tester,
      () => container.read(documentControllerProvider).isOpen('main.js'),
      what: 'main.js to open',
    );
    final opened = await container
        .read(documentControllerProvider.notifier)
        .open('app.py');
    expect(opened.isOk, isTrue);
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
    // The palette executes setThemeMode without awaiting it; give the
    // platform channel time to flush the write to disk before CI force-stops
    // the process (reading prefs here would only see the in-memory cache).
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();

    final reloaded = await SharedPreferences.getInstance();
    final settingsRaw = reloaded.getString(settingsStorageKey);
    final shellRaw = reloaded.getString(shellStateStorageKey);
    expect(settingsRaw, contains('"themeMode":"light"'));
    expect(shellRaw, contains('"lastRoute":"/workspace"'));
    expect(shellRaw, contains('"terminalStop":"half"'));

    // Tabs live in the app database (ADR-0008), not the envelope: wait for
    // every write asked for, then read them back.
    await container.read(documentControllerProvider.notifier).persisted;
    final tabs =
        (await container.read(sessionStoreProvider).loadTabs('demo'))
            .valueOrNull ??
        const <SavedTab>[];
    expect([for (final tab in tabs) tab.path], ['main.js', 'app.py']);
    expect([for (final tab in tabs) if (tab.active) tab.path], ['app.py']);
    expect(shellRaw, isNot(contains('main.js')));
  });
}
