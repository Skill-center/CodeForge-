/// Zero-loss gate, part B (Phase 2 W5, G4): after CI crashed the editor's
/// renderer and force-stopped the app, launch fresh and check that main.js
/// came back exactly as part A typed it — the same text, still unsaved,
/// with the cursor where it was. No prefs.clear() here.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'edit_a_test.dart' show editGateCursor, editGateText;
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('edit B: unsaved typing survives process death', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await pumpRealApp(tester, prefs);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    final host = container.read(editorHostProvider);
    await pumpUntil(
      tester,
      () =>
          container.read(documentControllerProvider).isOpen('main.js') &&
          host.status.phase == EditorHostPhase.ready,
      what: 'main.js to reopen in the editor',
      timeout: const Duration(seconds: 60),
    );
    final state = container.read(documentControllerProvider);
    expect(state.activePath, 'main.js');
    final doc = state.documents['main.js']!;
    expect(doc.dirty, isTrue, reason: 'restored edits stay unsaved');
    expect(doc.conflict, isNull);
    expect(doc.savedText, DemoWorkspace.files['main.js']);

    // The app's copy, then the page's own: the exact text and the cursor.
    expect(host.textOf(doc.docId), editGateText);
    final snapshot = (await host.snapshot(doc.docId)).orThrow;
    expect(snapshot.text, editGateText);
    expect(snapshot.selection?.anchor, editGateCursor);
    expect(snapshot.selection?.head, editGateCursor);

    // The tab shows the unsaved dot, not a close cross.
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('tab_close_main.js')),
        matching: find.byIcon(Icons.close),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('tab_close_main.js')), findsOneWidget);
    expect(find.byKey(const ValueKey('conflict_dialog')), findsNothing);
    debugPrint(
      'edit-gate: restored ${editGateText.length} chars, cursor '
      '${snapshot.selection?.head}, dirty ${doc.dirty}',
    );
  });
}
