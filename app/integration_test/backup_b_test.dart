/// Backup gate, part B (Phase 3 W1, G6, ADR-0012): after CI backed the app
/// up with the switch on, uninstalled it and installed it again, Android
/// has restored it. The project, its saved file, the unsaved edit, the
/// settings and the switch are back; the logs are not. Then the switch goes
/// off through the UI, for CI's second backup (backup_c_test).
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/logging/logger.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/logging/file_log_sink.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_a_test.dart'
    show
        appContainer,
        backupGateFile,
        backupGateSaved,
        backupGateText,
        backupLogMarker,
        hostBackupStatus,
        logSessions,
        setBackupFromHome,
        waitForMainJs;
import 'smoke_test.dart' show pumpRealApp;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('backup B: a reinstall brings the project back', (tester) async {
    // The switch came back, with the pass that wrote everything.
    final status = await hostBackupStatus();
    expect(status.enabled, isTrue, reason: 'the switch was not restored');
    expect(status.lastRunContent, 'everything');
    expect(status.lastRunAt, isNotNull);

    // The settings came back (no prefs.clear() here).
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(settingsStorageKey), isNotNull);

    // The logs did not: this process opened the only session in the file.
    final log = await startFileLog(appLogger);
    expect(log, isNotNull, reason: 'the log file did not open');
    final logText = await log!.readRecent(maxBytes: 4 << 20);
    expect(logSessions(logText), 1, reason: 'logs came back with the backup');
    expect(logText, isNot(contains(backupLogMarker)));

    await pumpRealApp(tester, prefs);
    expect(find.byKey(const ValueKey('welcome_dismiss')), findsNothing);
    final container = appContainer(tester);
    final docId = await waitForMainJs(tester);
    final doc = container.read(documentControllerProvider).documents['main.js']!;
    expect(doc.dirty, isTrue, reason: 'the unsaved edit stays unsaved');
    expect(doc.savedText, DemoWorkspace.files['main.js']);
    expect(container.read(editorHostProvider).textOf(docId), backupGateText);

    final saved = await container
        .read(fileServiceProvider)
        .readText(backupGateFile);
    expect(saved.orThrow.text, backupGateSaved);
    debugPrint(
      'backup-gate B: restored $backupGateFile, ${backupGateText.length} '
      'unsaved chars in main.js, the settings and the switch; '
      'log sessions ${logSessions(logText)}',
    );

    // Off, through the UI, for the second backup.
    await tester.tap(find.byKey(const ValueKey('workbench_home')));
    await tester.pumpAndSettle();
    await setBackupFromHome(tester, on: false);
    debugPrint('backup-gate B: switch off');
  });
}
