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
import 'package:codeforge/design_system/components/workbench_chrome.dart';
import 'package:codeforge/design_system/tokens/icons.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
          host.status.phase == EditorHostPhase.ready &&
          // The page has every document open, not just announced itself.
          host.syncs >= 1,
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
        matching: find.byIcon(CfIcons.close),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('tab_close_main.js')), findsOneWidget);
    expect(find.byKey(const ValueKey('conflict_dialog')), findsNothing);
    debugPrint(
      'edit-gate: restored ${editGateText.length} chars, cursor '
      '${snapshot.selection?.head}, dirty ${doc.dirty}',
    );

    // Rotation: the activity handles it itself (the manifest's
    // configChanges), and the editor pane moves to the docked layout under
    // its key. The page must not reload, and nothing may change.
    final starts = host.pageStarts;
    Future<void> rotate(
      DeviceOrientation orientation, {
      required bool docked,
    }) async {
      await SystemChrome.setPreferredOrientations([orientation]);
      await pumpUntil(
        tester,
        () => find.byType(CfNavRail).evaluate().isNotEmpty == docked,
        what: docked ? 'the docked landscape layout' : 'portrait again',
      );
      await tester.pump(const Duration(seconds: 1));
      final after = (await host.snapshot(doc.docId)).orThrow;
      final where = orientation.name;
      expect(after.text, editGateText, reason: where);
      expect(after.selection?.anchor, editGateCursor, reason: where);
      expect(after.selection?.head, editGateCursor, reason: where);
      expect(
        container.read(documentControllerProvider).documents['main.js']!.dirty,
        isTrue,
        reason: where,
      );
      expect(host.pageStarts, starts, reason: '$where: the page reloaded');
    }

    await rotate(DeviceOrientation.landscapeLeft, docked: true);
    await rotate(DeviceOrientation.portraitUp, docked: false);
    await SystemChrome.setPreferredOrientations(const []);
    debugPrint(
      'edit-gate: rotated to landscape and back; page starts $starts '
      'before and ${host.pageStarts} after, text and cursor kept',
    );
  });
}
