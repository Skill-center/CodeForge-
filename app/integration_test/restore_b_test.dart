/// Restore gate, part B (G5, and G3's tabs): after CI force-stopped the
/// process, launch fresh and assert the persisted state is restored on the
/// first frame — workbench route, light theme, terminal half-open — and
/// that both tabs reopen from the workspace files with app.py active. No
/// prefs.clear() here.
///
/// And the log file (Phase 3 W1, G6): part A's last record, an error logged
/// just before the kill, is on disk before this session's marker.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/core/logging/logger.dart';
import 'package:codeforge/services/logging/file_log_sink.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'restore_a_test.dart' show restoreLogMarker;
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('restore B: state survives process death', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    // Precondition: part A ran and persisted.
    expect(
      prefs.getString(settingsStorageKey),
      contains('"themeMode":"light"'),
    );

    await pumpRealApp(tester, prefs);

    // Restored directly into the workbench — no home, no welcome.
    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('explore_demo')), findsNothing);
    expect(find.byKey(const ValueKey('welcome_dismiss')), findsNothing);

    // Theme restored.
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.light);

    // Terminal stop restored.
    expect(find.text('TERMINAL'), findsOneWidget);

    // Envelope decodes to the exact state.
    final shell = decodeShellState(prefs.getString(shellStateStorageKey));
    expect(shell.lastRoute, '/workspace');
    expect(shell.terminalStop, TerminalStop.half);

    // Tabs reopen from the files, in order, with the same one active.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    await pumpUntil(
      tester,
      () => container.read(documentControllerProvider).openPaths.length == 2,
      what: 'both tabs to reopen',
    );
    final documents = container.read(documentControllerProvider);
    expect(documents.openPaths, ['main.js', 'app.py']);
    expect(documents.activePath, 'app.py');
    expect(documents.active!.language, 'python');

    // The log file survived the kill: part A's last record comes before
    // this session's marker, so it was on disk before the process died.
    final log = await startFileLog(appLogger);
    expect(log, isNotNull, reason: 'the log file did not open');
    final text = await log!.readRecent(maxBytes: 4 << 20);
    final marker = text.indexOf(restoreLogMarker);
    final session = text.lastIndexOf(log.marker!);
    expect(marker, isNonNegative, reason: "part A's record is not on disk");
    expect(marker, lessThan(session));
    expect(text, contains('[error] gate/log_marker'));
    debugPrint(
      'restore-gate: log file ${text.length} chars, part A record at '
      '$marker, this session from $session',
    );
  });
}
