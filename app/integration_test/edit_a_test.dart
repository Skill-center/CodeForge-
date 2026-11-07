/// Zero-loss gate, part A (Phase 2 W5, G4): type into main.js through the
/// real editor page without saving, and wait until the hot-exit journal and
/// the saved tabs hold the text and the cursor. Nothing pauses the app and
/// nothing is saved: CI then crashes the editor's renderer, force-stops the
/// app, and edit_b_test checks that the text, the unsaved state and the
/// cursor all came back.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/editor/journal.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpRealApp, pumpUntil;

/// What part A types at the start of main.js: two lines, with non-ASCII
/// text and a character outside the Basic Multilingual Plane.
const String editGateMarker =
    '// unsaved — zero-loss gate ✓\n// é 中 \u{1F600} end\n';

/// main.js as part A leaves it, never saved.
String get editGateText => editGateMarker + DemoWorkspace.files['main.js']!;

/// Where part A leaves the cursor: just after what it typed.
int get editGateCursor => editGateMarker.length;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('edit A: unsaved typing reaches the journal', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await pumpRealApp(tester, prefs);
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    final host = container.read(editorHostProvider);
    await pumpUntil(
      tester,
      () =>
          container.read(documentControllerProvider).isOpen('main.js') &&
          host.status.phase == EditorHostPhase.ready &&
          // The page has every document open, not just announced itself.
          host.syncs >= 1,
      what: 'main.js to open in the editor',
      timeout: const Duration(seconds: 60),
    );
    final docId = container
        .read(documentControllerProvider)
        .documents['main.js']!
        .docId;
    expect(host.textOf(docId), DemoWorkspace.files['main.js']);

    // Typed through the page, as the symbol toolbar types: a real editor
    // transaction, reported to the app as a change set.
    expect((await host.insert(editGateMarker)).isOk, isTrue);
    await pumpUntil(
      tester,
      () =>
          host.textOf(docId) == editGateText &&
          host.viewStateOf(docId)?.selection?.head == editGateCursor,
      what: 'the edit and the cursor to reach the app',
    );
    expect(
      container.read(documentControllerProvider).documents['main.js']!.dirty,
      isTrue,
    );

    // The kill comes without warning: wait until the journal and the tabs
    // hold it all.
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
      final tab = tabs.where((t) => t.path == 'main.js').firstOrNull;
      stored =
          entry != null &&
          replayJournal(
                text: entry.snapshot.text,
                version: entry.snapshot.version,
                changes: entry.changes,
              ).text ==
              editGateText &&
          tab != null &&
          tab.active &&
          tab.selectionAnchor == editGateCursor &&
          tab.selectionHead == editGateCursor;
    }
    expect(stored, isTrue, reason: 'the journal and tabs never held the edit');
    debugPrint(
      'edit-gate: journaled ${editGateText.length} chars, cursor '
      '$editGateCursor, unsaved',
    );
  });
}
