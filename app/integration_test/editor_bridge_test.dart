/// Phase 2 on the CI emulator: the real, verified editor page in the
/// Android System WebView, talking to the real host over the real bridge,
/// over real files in the app's workspace folder. Widget tests cover the
/// host against a scripted page and the files in memory; this proves the
/// page, the JavaScript channel, the WebView hardening and the file
/// service work together (W2), that saves reach the disk byte for byte
/// (W4, G2) and that a dozen tabs each keep their own text, cursor, scroll
/// and undo (W4, G3).
library;

import 'dart:convert';
import 'dart:io';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpRealApp, pumpUntil;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('editor bridge: real page, edits, page restart, save', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await pumpRealApp(tester, prefs);
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();
    final opened = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    final host = container.read(editorHostProvider);

    // The verified page loads in the WebView and announces itself.
    await pumpUntil(
      tester,
      () =>
          host.status.phase == EditorHostPhase.ready ||
          host.status.phase == EditorHostPhase.failed,
      what: 'the editor page to start',
    );
    expect(
      host.status.phase,
      EditorHostPhase.ready,
      reason: host.status.message,
    );
    await pumpUntil(tester, () => host.syncs >= 1, what: 'the first sync');
    debugPrint(
      'editor-bridge: ready and synced ${opened.elapsedMilliseconds} ms '
      'after opening the workbench (engine ${host.status.engineVersion})',
    );

    final documents = container.read(documentControllerProvider.notifier);
    String docIdOf(String path) =>
        container.read(documentControllerProvider).documents[path]!.docId;
    await pumpUntil(
      tester,
      () => container.read(documentControllerProvider).isOpen('main.js'),
      what: 'main.js to open from the workspace',
    );
    final docId = docIdOf('main.js');
    final original = host.textOf(docId)!;
    expect(host.versionOf(docId), 0);

    // An edit made in the page comes back as an incremental change.
    expect((await host.insert('// hi\n')).isOk, isTrue);
    await pumpUntil(
      tester,
      () => (host.versionOf(docId) ?? 0) > 0,
      what: 'doc.changed for the insert',
    );
    expect(host.textOf(docId), '// hi\n$original');
    final edited = (await host.snapshot(docId)).orThrow;
    expect(edited.text, host.textOf(docId));
    expect(edited.version, host.versionOf(docId));
    expect(host.resyncs, 0);
    await tester.pumpAndSettle();
    expect(
      container.read(documentControllerProvider).documents['main.js']!.dirty,
      isTrue,
    );

    // A page restart loses nothing: every document reopens from its shadow,
    // edits and version included.
    final versionBefore = host.versionOf(docId);
    await host.reloadPage();
    await pumpUntil(
      tester,
      () =>
          host.pageStarts >= 2 &&
          host.syncs >= 2 &&
          host.status.phase == EditorHostPhase.ready,
      what: 'the reloaded page to resync',
    );
    final restored = (await host.snapshot(docId)).orThrow;
    expect(restored.text, '// hi\n$original');
    expect(restored.version, versionBefore);
    expect(host.resyncs, 0);

    // Save writes what the editor holds, to the file on the device (G2).
    expect((await documents.save('main.js')).isOk, isTrue);
    await tester.pumpAndSettle();
    expect(
      container.read(documentControllerProvider).documents['main.js']!.dirty,
      isFalse,
    );
    final root = await demoWorkspacePath();
    expect(File('$root/main.js').readAsStringSync(), '// hi\n$original');

    // A Windows-style file keeps its byte-order mark and CRLF line breaks
    // through an edit and a save, and Save As copies it exactly (G2).
    final files = container.read(fileServiceProvider);
    final created = await files.writeText(
      'notes/win.txt',
      'one\ntwo\n',
      format: const TextFormat(lineEnding: LineEnding.crlf, bom: true),
      mode: WriteMode.createNew,
    );
    expect(created.isOk, isTrue);
    expect((await documents.open('notes/win.txt')).isOk, isTrue);
    final winId = docIdOf('notes/win.txt');
    expect((await host.insert('zero\n')).isOk, isTrue);
    await pumpUntil(
      tester,
      () => (host.versionOf(winId) ?? 0) > 0,
      what: 'doc.changed for win.txt',
    );
    expect(host.textOf(winId), 'zero\none\ntwo\n');
    expect((await documents.save('notes/win.txt')).isOk, isTrue);
    final winBytes = File('$root/notes/win.txt').readAsBytesSync();
    expect(winBytes, [...utf8Bom, ...utf8.encode('zero\r\none\r\ntwo\r\n')]);
    final savedAs = await documents.saveAs(
      'notes/win.txt',
      'notes/win_copy.txt',
    );
    expect(savedAs.isOk, isTrue);
    expect(File('$root/notes/win_copy.txt').readAsBytesSync(), winBytes);
    expect(File('$root/notes/win.txt').readAsBytesSync(), winBytes);
    expect(docIdOf('notes/win_copy.txt'), winId, reason: 'the same document');

    // Ten more tabs, twelve in all. Each gets its own paste, which moves
    // its cursor and scrolls its view; switching back to each one later
    // finds its text, cursor and scroll as they were (G3).
    final paths = [for (var i = 1; i <= 10; i++) 'tabs/t$i.txt'];
    final pasted = <String, String>{};
    final scrolled = <String, double>{};
    for (final (index, path) in paths.indexed) {
      final made = await files.writeText(
        path,
        'end of $path\n',
        mode: WriteMode.createNew,
      );
      expect(made.isOk, isTrue);
      expect((await documents.open(path)).isOk, isTrue);
      final id = docIdOf(path);
      final paste = [
        for (var line = 0; line < 80 + index * 10; line++) '$path line $line',
      ].join('\n');
      pasted[path] = '$paste\n';
      expect((await host.insert('$paste\n')).isOk, isTrue);
      await pumpUntil(
        tester,
        () => (host.versionOf(id) ?? 0) > 0,
        what: 'doc.changed for $path',
      );
      // Let the view finish scrolling to the cursor.
      await tester.pump(const Duration(milliseconds: 500));
      final snapshot = (await host.snapshot(id)).orThrow;
      expect(snapshot.selection?.head, pasted[path]!.length, reason: path);
      expect(snapshot.scrollTop, greaterThan(0), reason: '$path scrolled');
      scrolled[path] = snapshot.scrollTop!;
    }
    expect(container.read(documentControllerProvider).openPaths, hasLength(12));
    for (final path in paths.reversed) {
      final id = docIdOf(path);
      documents.activate(path);
      await tester.pump(const Duration(milliseconds: 500));
      final snapshot = (await host.snapshot(id)).orThrow;
      expect(snapshot.text, '${pasted[path]}end of $path\n', reason: path);
      expect(
        snapshot.selection?.head,
        pasted[path]!.length,
        reason: '$path cursor',
      );
      expect(
        snapshot.scrollTop,
        closeTo(scrolled[path]!, 24),
        reason: '$path scroll',
      );
    }
    debugPrint(
      'editor-bridge: 12 tabs kept their cursors; scroll tops '
      '${[for (final p in paths) scrolled[p]!.round()]}',
    );

    // Undo belongs to each document, and undoing back to the saved text
    // makes the tab clean again.
    documents.activate('tabs/t3.txt');
    await tester.pump(const Duration(milliseconds: 300));
    expect((await host.exec('undo')).isOk, isTrue);
    await pumpUntil(
      tester,
      () => host.textOf(docIdOf('tabs/t3.txt')) == 'end of tabs/t3.txt\n',
      what: 'undo in t3',
    );
    expect(
      host.textOf(docIdOf('tabs/t4.txt')),
      '${pasted['tabs/t4.txt']}end of tabs/t4.txt\n',
      reason: 'undo in one tab leaves the others alone',
    );
    await tester.pumpAndSettle();
    final afterUndo = container.read(documentControllerProvider);
    expect(afterUndo.documents['tabs/t3.txt']!.dirty, isFalse);
    expect(afterUndo.documents['tabs/t4.txt']!.dirty, isTrue);

    expect(host.droppedMessages, 0);
    expect(host.resyncs, 0);
    debugPrint(
      'editor-bridge: ok (page starts ${host.pageStarts}, syncs '
      '${host.syncs}, resyncs ${host.resyncs})',
    );
  });
}
