/// Backup gate, part A (Phase 3 W1, G6, ADR-0012): turn Android's backup on
/// in Settings → Privacy, save a file in the project, and leave an unsaved
/// edit in main.js. CI then backs the app up to Android's local transport
/// (it stands in for Google Drive), uninstalls it, and reinstalls it:
/// backup_b_test checks what came back, turns the switch off, and after a
/// second backup and reinstall backup_c_test checks that nothing but the
/// switch did.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/backup_controller.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/editor/journal.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/logging/logger.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/logging/file_log_sink.dart';
import 'package:codeforge/services/platform/backup_channel.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpRealApp, pumpUntil;

/// The file part A saves in the project before the backup.
const String backupGateFile = 'backup-gate.md';
const String backupGateSaved = '# Backup gate\n\nSaved before the backup.\n';

/// What part A types at the start of main.js, never saved.
const String backupGateMarker = '// unsaved, kept by Android backup ✓\n';
String get backupGateText => backupGateMarker + DemoWorkspace.files['main.js']!;

/// A record part A logs: the logs are never part of a backup.
const String backupLogMarker = 'backup_gate_log_marker';

/// The switch as the host has it (BackupSwitch.kt), not as the UI shows it.
Future<BackupStatus> hostBackupStatus() async =>
    (await const ChannelBackupService().status()).orThrow;

/// How many sessions the log file holds: one per process that opened it.
int logSessions(String text) => '=== session '.allMatches(text).length;

ProviderContainer appContainer(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );

/// From Home: Settings → Privacy, flip the backup switch to [on] through
/// the UI, and wait until the host saved it.
Future<void> setBackupFromHome(WidgetTester tester, {required bool on}) async {
  await tester.tap(find.byKey(const ValueKey('home_settings')));
  await tester.pumpAndSettle();
  final container = appContainer(tester);
  await pumpUntil(
    tester,
    () => !container.read(backupControllerProvider).loading,
    what: 'the backup switch to load',
  );
  expect(container.read(backupControllerProvider).available, isTrue);
  expect(container.read(backupControllerProvider).enabled, !on);
  final toggle = find.descendant(
    of: find.byKey(const ValueKey('settings_backup')),
    matching: find.byType(Switch),
  );
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await pumpUntil(tester, () {
    final state = container.read(backupControllerProvider);
    return !state.busy && state.enabled == on;
  }, what: 'the host to save the backup switch');
  expect((await hostBackupStatus()).enabled, on);
}

/// Waits until main.js is open in the real editor page.
Future<String> waitForMainJs(WidgetTester tester) async {
  final container = appContainer(tester);
  final host = container.read(editorHostProvider);
  await pumpUntil(
    tester,
    () =>
        container.read(documentControllerProvider).isOpen('main.js') &&
        host.status.phase == EditorHostPhase.ready &&
        host.syncs >= 1,
    what: 'main.js to open in the editor',
    timeout: const Duration(seconds: 60),
  );
  return container.read(documentControllerProvider).documents['main.js']!.docId;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('backup A: switch on, a saved file, an unsaved edit', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    // The default: off, until the user turns it on.
    expect((await hostBackupStatus()).enabled, isFalse);

    final log = await startFileLog(appLogger);
    expect(log, isNotNull, reason: 'the log file did not open');
    appLogger.error('gate', backupLogMarker);

    await pumpRealApp(tester, prefs);
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();
    await setBackupFromHome(tester, on: true);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();

    final container = appContainer(tester);
    final docId = await waitForMainJs(tester);
    final files = container.read(fileServiceProvider);
    final saved = await files.writeText(
      backupGateFile,
      backupGateSaved,
      mode: WriteMode.replace,
    );
    expect(saved.isOk, isTrue);

    final host = container.read(editorHostProvider);
    expect((await host.insert(backupGateMarker)).isOk, isTrue);
    await pumpUntil(
      tester,
      () => host.textOf(docId) == backupGateText,
      what: 'the edit to reach the app',
    );

    // The backup comes later, from another process: wait until the journal
    // and the tabs hold the edit.
    final store = container.read(sessionStoreProvider);
    final documents = container.read(documentControllerProvider.notifier);
    var stored = false;
    for (var attempt = 0; attempt < 50 && !stored; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
      await documents.persisted;
      final journal =
          (await store.loadJournal(DemoWorkspace.id)).valueOrNull ??
          const <JournalEntry>[];
      final tabs =
          (await store.loadTabs(DemoWorkspace.id)).valueOrNull ??
          const <SavedTab>[];
      final entry = journal.where((e) => e.path == 'main.js').firstOrNull;
      stored =
          entry != null &&
          replayJournal(
                text: entry.snapshot.text,
                version: entry.snapshot.version,
                changes: entry.changes,
              ).text ==
              backupGateText &&
          tabs.any((t) => t.path == 'main.js' && t.active);
    }
    expect(stored, isTrue, reason: 'the journal and tabs never held the edit');
    // Let the shell remember the workbench (its writes are debounced).
    await tester.pump(const Duration(seconds: 1));
    debugPrint(
      'backup-gate A: switch on, $backupGateFile saved, '
      '${backupGateText.length} chars journaled in main.js, unsaved',
    );
  });
}
