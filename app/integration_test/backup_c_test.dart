/// Backup gate, part C (Phase 3 W1, G6, ADR-0012): after CI backed the app
/// up with the switch off, uninstalled it and installed it again, Android
/// restored a backup that held the switch alone. The app starts fresh: no
/// settings, no saved file, no unsaved edit, and the switch is off.
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
        hostBackupStatus,
        logSessions,
        waitForMainJs;
import 'smoke_test.dart' show pumpRealApp;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('backup C: with the switch off, a reinstall is a fresh app', (
    tester,
  ) async {
    // A restore did run: it brought back the switch, off, as written by the
    // pass that held nothing else.
    final status = await hostBackupStatus();
    expect(status.enabled, isFalse);
    expect(
      status.lastRunContent,
      'switch',
      reason: 'no restore, or one that held more than the switch',
    );
    expect(status.lastRunAt, isNotNull);

    // Nothing else came back.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(settingsStorageKey), isNull);
    final log = await startFileLog(appLogger);
    expect(log, isNotNull, reason: 'the log file did not open');
    final logText = await log!.readRecent(maxBytes: 4 << 20);
    expect(logSessions(logText), 1);

    await pumpRealApp(tester, prefs);
    expect(find.byKey(const ValueKey('welcome_dismiss')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();

    final container = appContainer(tester);
    final docId = await waitForMainJs(tester);
    final doc = container
        .read(documentControllerProvider)
        .documents['main.js']!;
    expect(doc.dirty, isFalse, reason: 'an unsaved edit came back');
    expect(
      container.read(editorHostProvider).textOf(docId),
      DemoWorkspace.files['main.js'],
    );
    final saved = await container
        .read(fileServiceProvider)
        .readText(backupGateFile);
    expect(
      saved.failureOrNull,
      isA<FileFailure>().having(
        (failure) => failure.problem,
        'problem',
        FileProblem.notFound,
      ),
    );
    debugPrint(
      'backup-gate C: fresh app, switch off, last pass '
      '${status.lastRunContent}; no $backupGateFile, main.js clean',
    );
  });
}
