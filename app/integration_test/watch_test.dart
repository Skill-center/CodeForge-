/// Files changed behind the app's back, on the emulator (Phase 3 W5, gate
/// G4), in both kinds of workspace: the demo project in the app's own
/// storage, changed by the host through `run-as` (`FOLDERGATE pput|prm`),
/// then the gate folder on shared storage, picked in Android's real picker
/// and changed by the host as the shell user (`FOLDERGATE put|rm`), which
/// Android's own storage provider then reports. On each:
/// - a clean open document shows the new text exactly, within 2 s of the
///   write (the host answers the device's clock just before it);
/// - the app's own save causes no reload, notices and re-checks included;
/// - a document with unsaved text keeps it, shows the conflict banner, and
///   the file keeps the other program's text until the user picks;
/// - a new file appears in the explorer and a deleted one goes; a clean
///   tab whose file is deleted closes;
/// - a change made while the app is in the background (the host presses
///   Home, then brings it back: `FOLDERGATE home|front`) shows within 2 s
///   of coming back, and not before.
/// Nothing here pumps frames while the app is in the background: Flutter
/// draws nothing then, and a pump would wait for it to come back.
library;

import 'dart:io';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/workspace_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/logging/logger.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/storage/drift_session_store.dart'
    show appDatabaseFileName;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_fixture.dart';
import 'folder_gate.dart';
import 'restore_a_test.dart' show waitForPage;
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

/// G4: an outside change reaches a clean open document within this.
const Duration _budget = Duration(seconds: 2);

/// The conflict banner's [label] button.
Finder _inBanner(String label) => find.descendant(
  of: find.byKey(const ValueKey('disk_conflict_notice')),
  matching: find.text(label),
);

/// The names in the workspace root's listing, as the explorer has it.
List<String> _rootNames(ProviderContainer container) => [
  for (final entry
      in container
              .read(workspaceControllerProvider)
              .listings['']
              ?.valueOrNull ??
          const <FileEntry>[])
    entry.name,
];

/// Waits with plain timers, not frames, until [condition] holds.
Future<void> _waitPlain(
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail('Timed out after ${timeout.inSeconds} s waiting for $what.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Pumps frames for [duration].
Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < duration) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _away() {
  final state = WidgetsBinding.instance.lifecycleState;
  return state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
}

/// The test's view of the app: the controllers, and the log since a mark.
final class _App {
  _App(this.tester, this.container, this.gate);

  final WidgetTester tester;
  final ProviderContainer container;
  final FolderGate gate;
  final List<LogRecord> records = [];

  EditorHost get host => container.read(editorHostProvider);

  DocumentController get documents =>
      container.read(documentControllerProvider.notifier);

  DocumentsState get state => container.read(documentControllerProvider);

  OpenDocument doc(String path) => state.documents[path]!;

  /// Types [marker] at the cursor of the active document, [docId], and
  /// waits until the app has it; the document's whole text afterwards.
  Future<String> type(String path, String docId, String marker) async {
    final before = host.textOf(docId)!;
    expect((await host.insert(marker)).isOk, isTrue);
    await pumpUntil(
      tester,
      () =>
          host.textOf(docId)?.length == before.length + marker.length &&
          doc(path).dirty,
      what: 'the typed text in $path',
    );
    return host.textOf(docId)!;
  }

  /// The host rewrites [path] as [word] ([write]); the clean, open
  /// document must show exactly that within [_budget] of the write.
  Future<void> reloads({
    required String label,
    required String path,
    required String docId,
    required String word,
    required Future<DateTime?> Function() write,
  }) async {
    expect(doc(path).dirty, isFalse, reason: '$label: $path is not clean');
    final text = '$word\n';
    final written = await write();
    final from = written ?? DateTime.now();
    await pumpUntil(
      tester,
      () => host.textOf(docId) == text,
      what: '$label: $path to show the new text',
      timeout: const Duration(seconds: 15),
    );
    final ms = DateTime.now().difference(from).inMilliseconds;
    debugPrint(
      'watch gate: reload $label $ms ms '
      '(${written == null ? 'from the answer' : 'device clock'})',
    );
    expect(
      (await host.snapshot(docId)).orThrow.text,
      text,
      reason: '$label: the page shows the file exactly',
    );
    expect(doc(path).dirty, isFalse);
    expect(doc(path).savedText, text);
    expect(
      ms,
      lessThan(_budget.inMilliseconds),
      reason: '$label: the new text took $ms ms',
    );
  }

  /// Saves [path] after typing [marker], then waits [quiet]: the save's
  /// own notices and a periodic re-check pass, and nothing reloads.
  Future<String> savesQuietly({
    required String label,
    required String path,
    required String docId,
    required String marker,
    Duration quiet = const Duration(seconds: 6),
  }) async {
    final text = await type(path, docId, marker);
    final mark = records.length;
    expect((await documents.save(path)).isOk, isTrue);
    await _pumpFor(tester, quiet);
    final events = [
      for (final record in records.skip(mark))
        if (record.event.startsWith('disk_') && record.fields['path'] == path)
          record.event,
    ];
    // A stamp that moved without new text is only taken in, never shown
    // again; counted, so the evidence says whether it happened.
    final taken = events.where((event) => event != 'disk_touched').toList();
    expect(taken, isEmpty, reason: '$label: the app took in its own save');
    expect(doc(path).dirty, isFalse);
    expect(doc(path).conflict, isNull);
    expect((await host.snapshot(docId)).orThrow.text, text);
    debugPrint(
      'watch gate: $label own save, no reload '
      '(stamp re-read ${events.length} times)',
    );
    return text;
  }

  /// Unsaved text in [path]; the host rewrites the file ([write]); the
  /// text stays and the banner asks. Answers the unsaved text.
  Future<String> conflicts({
    required String label,
    required String path,
    required String docId,
    required Future<DateTime?> Function() write,
  }) async {
    final typed = await type(path, docId, '// unsaved, $label\n');
    await write();
    await pumpUntil(
      tester,
      () => doc(path).conflict == DocumentConflict.changedWhileOpen,
      what: '$label: the conflict in $path',
      timeout: const Duration(seconds: 15),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('disk_conflict_notice')), findsOneWidget);
    expect(host.textOf(docId), typed, reason: '$label: unsaved text replaced');
    expect((await host.snapshot(docId)).orThrow.text, typed);
    expect(doc(path).dirty, isTrue);
    debugPrint('watch gate: $label unsaved text kept');
    return typed;
  }

  /// A new file the host made shows in the explorer, and goes when the
  /// host deletes it.
  Future<void> followsInExplorer({
    required String label,
    required String name,
    required Future<DateTime?> Function() make,
    required Future<DateTime?> Function() delete,
  }) async {
    await make();
    await pumpUntil(
      tester,
      () => _rootNames(container).contains(name),
      what: '$label: $name in the listing',
      timeout: const Duration(seconds: 15),
    );
    await tester.tap(find.byKey(const ValueKey('activity_explorer')));
    await pumpUntil(
      tester,
      () => find.byKey(ValueKey('tree_$name')).evaluate().isNotEmpty,
      what: '$label: $name in the explorer',
    );
    await tester.pumpAndSettle();
    await delete();
    await pumpUntil(
      tester,
      () =>
          !_rootNames(container).contains(name) &&
          find.byKey(ValueKey('tree_$name')).evaluate().isEmpty,
      what: '$label: $name to leave the explorer',
      timeout: const Duration(seconds: 15),
    );
    if (find.byType(DraggableScrollableSheet).evaluate().isNotEmpty) {
      await tester.tapAt(const Offset(200, 40));
      await tester.pumpAndSettle();
    }
    debugPrint('watch gate: $label explorer followed');
  }

  /// The host deletes the file of [path], open and clean: its tab closes.
  Future<void> closesDeleted({
    required String label,
    required String path,
    required Future<DateTime?> Function() delete,
  }) async {
    expect((await documents.open(path)).isOk, isTrue);
    await tester.pumpAndSettle();
    expect(doc(path).dirty, isFalse);
    await delete();
    await pumpUntil(
      tester,
      () => !state.isOpen(path),
      what: '$label: the tab of the deleted $path to close',
      timeout: const Duration(seconds: 15),
    );
    debugPrint('watch gate: $label deleted tab closed');
  }

  /// The app goes to the background; the host rewrites [path] as [word]
  /// ([write]); nothing changes until the app comes back, and then the
  /// new text shows within [_budget].
  Future<void> catchesUpOnResume({
    required String label,
    required String path,
    required String docId,
    required String word,
    required Future<DateTime?> Function() write,
  }) async {
    expect(doc(path).dirty, isFalse, reason: '$label: $path is not clean');
    final before = host.textOf(docId);
    final text = '$word\n';
    await gate.home();
    await _waitPlain(_away, what: '$label: the app to go to the background');
    await write();
    // Nothing is taken in while away: the notices wait.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(host.textOf(docId), before, reason: '$label: taken in while away');
    await gate.front();
    await _waitPlain(
      () => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      what: '$label: the app to come back',
    );
    final back = DateTime.now();
    await pumpUntil(
      tester,
      () => host.textOf(docId) == text,
      what: '$label: the change made while away',
      timeout: const Duration(seconds: 15),
    );
    final ms = DateTime.now().difference(back).inMilliseconds;
    debugPrint('watch gate: resume $label $ms ms (from coming back)');
    expect((await host.snapshot(docId)).orThrow.text, text);
    expect(
      ms,
      lessThan(_budget.inMilliseconds),
      reason: '$label: caught up $ms ms after coming back',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'watch: outside changes reach a project and a folder',
    timeout: const Timeout(Duration(minutes: 12)),
    (tester) async {
      final gate = await FolderGate.start();
      // A clean slate, as in the explorer group: no session database, no
      // demo project from an earlier attempt.
      final appFiles = await applicationFilesPath();
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('$appFiles/$appDatabaseFileName$suffix');
        if (file.existsSync()) {
          file.deleteSync();
        }
      }
      final root = await demoWorkspacePath();
      if (Directory(root).existsSync()) {
        Directory(root).deleteSync(recursive: true);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await pumpRealApp(
        tester,
        prefs,
        overrides: [
          folderPickerStartProvider.overrideWithValue(gateFolderStartUri),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('explore_demo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('explore_demo')));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(CodeForgeApp)),
        listen: false,
      );
      final app = _App(tester, container, gate);
      void keep(LogRecord record) => app.records.add(record);
      appLogger.addSink(keep);
      addTearDown(() => appLogger.removeSink(keep));
      await pumpUntil(
        tester,
        () =>
            app.state.isOpen('main.js') &&
            app.host.status.phase == EditorHostPhase.ready,
        what: 'the demo project and the editor page',
        timeout: const Duration(seconds: 60),
      );

      // ── The project: the app's own storage, changed through run-as ────
      final mainId = await waitForPage(
        tester,
        container,
        'main.js',
        DemoWorkspace.files['main.js']!,
      );
      await tester.pumpAndSettle();
      await app.reloads(
        label: 'project',
        path: 'main.js',
        docId: mainId,
        word: 'w5-project-1',
        write: () => gate.putInProject('demo/main.js', 'w5-project-1'),
      );
      final saved = await app.savesQuietly(
        label: 'project',
        path: 'main.js',
        docId: mainId,
        marker: '// own save\n',
      );
      expect(File('$root/main.js').readAsStringSync(), saved);
      await app.conflicts(
        label: 'project',
        path: 'main.js',
        docId: mainId,
        write: () => gate.putInProject('demo/main.js', 'w5-project-2'),
      );
      expect(File('$root/main.js').readAsStringSync(), 'w5-project-2\n');
      // The file wins: through the banner, and the question it asks.
      await tester.tap(_inBanner('Use the file'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm_ok')));
      await pumpUntil(
        tester,
        () => app.host.textOf(mainId) == 'w5-project-2\n',
        what: 'the file to replace the unsaved text',
      );
      await tester.pumpAndSettle();
      expect(app.doc('main.js').dirty, isFalse);
      expect(find.byKey(const ValueKey('disk_conflict_notice')), findsNothing);
      await app.followsInExplorer(
        label: 'project',
        name: 'aaa-w5.txt',
        make: () => gate.putInProject('demo/aaa-w5.txt', 'fresh'),
        delete: () => gate.removeInProject('demo/aaa-w5.txt'),
      );
      await app.closesDeleted(
        label: 'project',
        path: 'utils.js',
        delete: () => gate.removeInProject('demo/utils.js'),
      );
      expect(app.state.activePath, 'main.js');
      await app.catchesUpOnResume(
        label: 'project',
        path: 'main.js',
        docId: mainId,
        word: 'w5-project-bg',
        write: () => gate.putInProject('demo/main.js', 'w5-project-bg'),
      );
      debugPrint('watch gate: project done');

      // ── The folder: Android's picker and provider, changed by the shell ─
      await tester.tap(find.byKey(const ValueKey('workbench_home')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('open_folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open_folder')));
      await tester.pump();
      expect(
        await gate.ask(
          'pick $gateFolderName',
          timeout: const Duration(seconds: 240),
        ),
        'picked',
      );
      await pumpUntil(
        tester,
        () =>
            container.read(currentWorkspaceProvider) is FolderLocation &&
            find.byKey(const ValueKey('terminal_toggle')).evaluate().isNotEmpty,
        what: 'the picked folder to open in the workbench',
        timeout: const Duration(seconds: 60),
      );
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect((await app.documents.open('hello.txt')).isOk, isTrue);
      await tester.pumpAndSettle();
      final helloId = await waitForPage(
        tester,
        container,
        'hello.txt',
        gateFixture['hello.txt']!,
      );
      await app.reloads(
        label: 'folder',
        path: 'hello.txt',
        docId: helloId,
        word: 'w5-folder-1',
        write: () => gate.put('hello.txt', 'w5-folder-1'),
      );
      final ownSave = await app.savesQuietly(
        label: 'folder',
        path: 'hello.txt',
        docId: helloId,
        marker: '// own save\n',
      );
      expect(await gate.disk('hello.txt'), sha256Of(ownSave));
      final kept = await app.conflicts(
        label: 'folder',
        path: 'hello.txt',
        docId: helloId,
        write: () => gate.put('hello.txt', 'w5-folder-2'),
      );
      expect(await gate.disk('hello.txt'), sha256Of('w5-folder-2\n'));
      // The unsaved text wins: kept through the banner, then saved over
      // the file without another question.
      await tester.tap(_inBanner('Keep mine'));
      await tester.pumpAndSettle();
      expect(app.doc('hello.txt').conflict, isNull);
      expect(app.doc('hello.txt').dirty, isTrue);
      expect((await app.documents.save('hello.txt')).isOk, isTrue);
      expect(await gate.disk('hello.txt'), sha256Of(kept));
      await app.followsInExplorer(
        label: 'folder',
        name: 'aaa-w5.txt',
        make: () => gate.put('aaa-w5.txt', 'fresh'),
        delete: () => gate.remove('aaa-w5.txt'),
      );
      await app.closesDeleted(
        label: 'folder',
        path: 'notes/todo.md',
        delete: () => gate.remove('notes/todo.md'),
      );
      expect(app.state.activePath, 'hello.txt');
      await app.catchesUpOnResume(
        label: 'folder',
        path: 'hello.txt',
        docId: helloId,
        word: 'w5-folder-bg',
        write: () => gate.put('hello.txt', 'w5-folder-bg'),
      );
      debugPrint('watch gate: folder done');

      gate.done();
    },
  );
}
