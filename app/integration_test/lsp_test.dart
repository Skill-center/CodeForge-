/// Gate G5, the lsp group (Phase 6 W5; PHASE_6_PLAN §5): the language
/// features in the real app on the emulator, on the sealed runtime, with the
/// real servers and the real editor page.
///   1. Python in a project (Pyright): an error underlined (the page took
///      it), listed (the Problems sheet's state), fixed, then cleared.
///   2. Completion through the page: the page asks after `gre`, its list
///      opens, and the item is taken into the text.
///   3. Hover at a name: the page asks, the server answers with its text.
///   4. Definition into another file: it opens at the place.
///   5. A rename across files, through the dialog: the open documents
///      change in the editor, one undo each takes it back; the closed file
///      is written.
///   6. TypeScript: an error listed, and completion through the page.
///   7. Pyright killed (SIGKILL): it comes back with its documents, whose
///      unsaved error it reports again.
///   8. Killed again and again: three restarts, then *Restart* offered, the
///      editor still editing, and *Restart* bringing it back.
///   9. A folder through its copy (ADR-0013): the gate folder, picked in
///      Android's picker (the host's folder_driver answers); an error found
///      in the copy, and a definition opening the folder's file.
/// The gate reads the LSP_GATE lines (app/tool/ci/emulator_gate.sh).
library;

import 'dart:io';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/lsp/lsp_controller.dart';
import 'package:codeforge/application/lsp/lsp_features.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/design_system/components/feedback.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/storage/drift_session_store.dart'
    show appDatabaseFileName;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_fixture.dart';
import 'folder_gate.dart';
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

void _report(String line) => debugPrint('LSP_GATE $line');

const String _people = 'def greet(name: str) -> str:\n    return "Hello, " + name\n';
const String _main =
    'from people import greet\n\nprint(greet("you"))\nprint(undefined_name)\n';
const String _other = 'from people import greet\n\ngreet("other")\n';

const String _tsBroken = 'const count: number = "three";\nconsole.lo';

const String _folderPeople = 'def wave(who: str) -> str:\n    return who\n';
const String _folderMain =
    'from lsp_people import wave\n\nwave("you")\nprint(missing_name)\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'lsp: diagnostics, completion, hover, definition, rename, TypeScript, '
    'a killed server, three crashes, a folder',
    timeout: const Timeout(Duration(minutes: 25)),
    (tester) async {
      final gate = await FolderGate.start();
      // A clean slate: no session database, no project from an earlier
      // attempt.
      final appFiles = await applicationFilesPath();
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('$appFiles/$appDatabaseFileName$suffix');
        if (file.existsSync()) {
          file.deleteSync();
        }
      }
      final projects = Directory(await projectsRootPath());
      if (projects.existsSync()) {
        projects.deleteSync(recursive: true);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await pumpRealApp(
        tester,
        prefs,
        languageServers: true,
        overrides: [
          folderPickerStartProvider.overrideWithValue(gateFolderStartUri),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CodeForgeApp)),
        listen: false,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('explore_demo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('explore_demo')));
      await tester.pump();
      await pumpUntil(
        tester,
        () {
          final status = container.read(runtimeControllerProvider);
          return (status.usable && !status.auditing) ||
              status.state == RuntimeState.failed ||
              status.state == RuntimeState.unavailable;
        },
        what: 'the runtime to be ready',
        timeout: const Duration(minutes: 12),
      );
      final runtime = container.read(runtimeControllerProvider);
      expect(runtime.state, RuntimeState.ready, reason: runtime.detail);

      final host = container.read(editorHostProvider);
      final documents = container.read(documentControllerProvider.notifier);

      String docIdOf(String path) =>
          container.read(documentControllerProvider).documents[path]!.docId;
      LspStatus statusOf(LspServerId server) =>
          container.read(lspControllerProvider).statusOf(server);
      ProblemCounts countsOf(String path) =>
          container.read(lspFeaturesProvider).countsOf(path);

      Future<void> write(String path, String text) async {
        final written = await container
            .read(fileServiceProvider)
            .writeText(path, text);
        expect(written.isOk, isTrue, reason: '$written');
      }

      Future<void> open(String path) async {
        final opened = await documents.open(path);
        expect(opened.isOk, isTrue, reason: '$opened');
        await tester.pumpAndSettle();
      }

      Future<void> waitRunning(LspServerId server, String when) => pumpUntil(
        tester,
        () => statusOf(server).running,
        what: '${server.title} to run ($when; now ${statusOf(server)})',
        timeout: const Duration(minutes: 3),
      );

      /// Runs editor [command] and waits for the page's answer to a request
      /// of [type] that it makes.
      Future<Object?> asks(String command, String type) async {
        final before = host.pageAnswers(type);
        expect((await host.exec(command)).isOk, isTrue);
        await pumpUntil(
          tester,
          () => host.pageAnswers(type) > before,
          what: 'the page to ask $type and hear the answer',
          timeout: const Duration(seconds: 30),
        );
        return host.lastPageResult(type);
      }

      /// Opens the page's completion list at the cursor and takes its item
      /// once it is there; the labels it offered.
      Future<List<String>> complete(String docId, String expected) async {
        expect((await host.exec('focus')).isOk, isTrue);
        final result = await asks('startCompletion', 'lsp.complete');
        final labels = [
          for (final item
              in (result! as Map<String, Object?>)['items']! as List<Object?>)
            (item! as Map<String, Object?>)['label']! as String,
        ];
        for (var i = 0; i < 50 && !host.textOf(docId)!.endsWith(expected); i++) {
          await host.exec('acceptCompletion');
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(host.textOf(docId), endsWith(expected), reason: '$labels');
        return labels;
      }

      /// Kills Pyright's process with SIGKILL, through the runtime.
      Future<void> killPyright() async {
        final exec = container.read(runtimeServiceProvider).exec;
        // The brackets keep the launcher, whose arguments hold the pattern,
        // out of the match.
        final killed = await exec('pkill', ['-9', '-f', '[l]angserver.index.js']);
        final result = killed.valueOrNull;
        if (result != null && result.failure == null && result.exitCode == 0) {
          return;
        }
        final found = (await exec('pgrep', [
          '-f',
          '[l]angserver.index.js',
        ])).valueOrNull;
        final pids = (found?.stdout ?? '').trim().split(RegExp(r'\s+'));
        expect(pids.where((p) => p.isNotEmpty), isNotEmpty, reason: '$found');
        final sent = await exec('kill', ['-9', ...pids]);
        expect(sent.valueOrNull?.exitCode, 0, reason: '$sent');
      }

      // ── 1. Diagnostics: underlined, listed, cleared ──────────────────────
      final started = Stopwatch()..start();
      await write('people.py', _people);
      await write('other.py', _other);
      await write('main.py', _main);
      await open('main.py');
      final mainId = docIdOf('main.py');
      await waitRunning(LspServerId.pyright, 'main.py open');
      final readyMs = started.elapsedMilliseconds;
      await pumpUntil(
        tester,
        () => countsOf('main.py').errors >= 1,
        what: "Pyright's error in main.py",
        timeout: const Duration(seconds: 90),
      );
      final listed = countsOf('main.py').total;
      await pumpUntil(
        tester,
        () => host.diagnosticsShown(mainId) == listed,
        what: 'the page to underline what is listed',
      );
      _report(
        'diagnostics listed=$listed shown=${host.diagnosticsShown(mainId)} '
        'ready_ms=$readyMs first_ms=${started.elapsedMilliseconds}',
      );
      final fixed = Stopwatch()..start();
      expect(
        (await host.replaceText(
          mainId,
          _main.replaceFirst('print(undefined_name)\n', ''),
        )).isOk,
        isTrue,
      );
      await pumpUntil(
        tester,
        () => countsOf('main.py').total == 0 && host.diagnosticsShown(mainId) == 0,
        what: 'the fixed error to clear',
        timeout: const Duration(seconds: 60),
      );
      _report('diagnostics cleared ms=${fixed.elapsedMilliseconds}');

      // ── 2. Completion through the page ──────────────────────────────────
      expect((await host.gotoLine(99)).isOk, isTrue);
      expect((await host.insert('gre')).isOk, isTrue);
      await pumpUntil(
        tester,
        () => host.textOf(mainId)!.endsWith('gre'),
        what: 'the typed word to reach the app',
      );
      final labels = await complete(mainId, 'greet');
      expect(labels, contains('greet'));
      _report('completion items=${labels.length} accepted=greet');

      // ── 3. Hover ─────────────────────────────────────────────────────────
      expect((await host.gotoLine(3, column: 8)).isOk, isTrue);
      final hover = await asks('showHover', 'lsp.hover');
      final contents =
          ((hover! as Map<String, Object?>)['contents']! as Map<String, Object?>)['value']!
              as String;
      expect(contents, contains('greet'));
      _report('hover chars=${contents.length}');

      // ── 4. Definition into another file ─────────────────────────────────
      expect((await host.gotoLine(3, column: 8)).isOk, isTrue);
      final found = await asks('goToDefinition', 'lsp.definition');
      expect(found, {'found': 1});
      await pumpUntil(
        tester,
        () => container.read(documentControllerProvider).activePath == 'people.py',
        what: 'people.py to open at the definition',
      );
      final peopleId = docIdOf('people.py');
      await pumpUntil(
        tester,
        () => host.viewStateOf(peopleId)?.selection?.head == 4,
        what: 'the cursor at greet in people.py',
      );
      _report('definition opened=people.py line=1');

      // ── 5. Rename across files, through the dialog, with undo ───────────
      await open('main.py');
      expect((await host.gotoLine(3, column: 8)).isOk, isTrue);
      expect((await host.exec('renameSymbol')).isOk, isTrue);
      await pumpUntil(
        tester,
        () => find.byKey(const ValueKey('rename_dialog')).evaluate().isNotEmpty,
        what: 'the rename dialog',
      );
      await tester.enterText(find.byKey(const ValueKey('rename_field')), 'welcome');
      await tester.tap(find.byKey(const ValueKey('rename_confirm')));
      await pumpUntil(
        tester,
        () => find.byKey(const ValueKey('rename_summary')).evaluate().isNotEmpty,
        what: 'the rename summary',
        timeout: const Duration(seconds: 60),
      );
      final summary = tester
          .widget<SnackBar>(find.byKey(const ValueKey('rename_summary')))
          .content as Text;
      expect(summary.data, startsWith('Renamed greet to welcome in 3 files'));
      expect(host.textOf(mainId), contains('print(welcome("you"))'));
      expect(host.textOf(peopleId), startsWith('def welcome('));
      final otherOnDisk = (await container
              .read(fileServiceProvider)
              .readText('other.py'))
          .valueOrNull
          ?.text;
      expect(otherOnDisk, contains('welcome("other")'));
      // One undo per open file takes it back there.
      expect((await host.exec('undo')).isOk, isTrue);
      await pumpUntil(
        tester,
        () => host.textOf(mainId)!.contains('print(greet("you"))'),
        what: "main.py's undo",
      );
      await open('people.py');
      expect((await host.exec('undo')).isOk, isTrue);
      await pumpUntil(
        tester,
        () => host.textOf(peopleId)!.startsWith('def greet('),
        what: "people.py's undo",
      );
      _report('rename files=3 written=1 undone=2 "${summary.data}"');

      // ── 6. TypeScript: an error, and completion ─────────────────────────
      await write('broken.ts', _tsBroken);
      await open('broken.ts');
      final tsId = docIdOf('broken.ts');
      await waitRunning(LspServerId.typescript, 'broken.ts open');
      await pumpUntil(
        tester,
        () => countsOf('broken.ts').errors >= 1,
        what: "TypeScript's error in broken.ts",
        timeout: const Duration(seconds: 90),
      );
      expect((await host.gotoLine(99, column: 99)).isOk, isTrue);
      final tsLabels = await complete(tsId, 'console.log');
      expect(tsLabels, contains('log'));
      _report(
        'typescript errors=${countsOf('broken.ts').errors} '
        'completion items=${tsLabels.length}',
      );

      // ── 7. Pyright killed: back with its documents ──────────────────────
      await open('main.py');
      expect((await host.gotoLine(99)).isOk, isTrue);
      expect((await host.insert('\nprint(only_in_the_editor)')).isOk, isTrue);
      await pumpUntil(
        tester,
        () => countsOf('main.py').errors >= 1,
        what: 'the unsaved error in main.py',
        timeout: const Duration(seconds: 60),
      );
      final killed = Stopwatch()..start();
      await killPyright();
      await pumpUntil(
        tester,
        () => statusOf(LspServerId.pyright).phase == LspPhase.restarting,
        what: 'Pyright to restart',
        timeout: const Duration(seconds: 30),
      );
      await waitRunning(LspServerId.pyright, 'after the kill');
      // Only an editor's document can hold this error: it was opened again.
      await pumpUntil(
        tester,
        () => countsOf('main.py').errors >= 1,
        what: 'the unsaved error again from the restarted server',
        timeout: const Duration(seconds: 90),
      );
      _report('killed back_ms=${killed.elapsedMilliseconds} documents=reopened');

      // ── 8. Three restarts, then Restart offered ─────────────────────────
      var ends = 1;
      while (!statusOf(LspServerId.pyright).canRestart && ends < 6) {
        await waitRunning(LspServerId.pyright, 'before end ${ends + 1}');
        await killPyright();
        ends += 1;
        await pumpUntil(
          tester,
          () {
            final status = statusOf(LspServerId.pyright);
            return status.phase == LspPhase.restarting || status.canRestart;
          },
          what: 'Pyright to restart or give up (end $ends)',
          timeout: const Duration(seconds: 30),
        );
      }
      expect(statusOf(LspServerId.pyright).canRestart, isTrue);
      expect(ends, 4, reason: 'three restarts, then Restart is offered');
      final chip = tester.widget<CfStatusChip>(
        find.byKey(const ValueKey('status_lsp')),
      );
      expect(chip.onTap, isNotNull);
      // The editor still edits.
      final before = host.textOf(mainId)!;
      expect((await host.insert('\n# still editing')).isOk, isTrue);
      await pumpUntil(
        tester,
        () => host.textOf(mainId) == '$before\n# still editing',
        what: 'an edit with the server given up',
      );
      // Completion falls back to words meanwhile.
      final fallback = await host.exec('startCompletion');
      expect(fallback.isOk, isTrue);
      await tester.ensureVisible(find.byKey(const ValueKey('status_lsp')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('status_lsp')));
      await waitRunning(LspServerId.pyright, 'after Restart');
      _report('gave_up ends=$ends restarts=3 editing=ok restart=ok');

      // ── 9. A folder through its copy ────────────────────────────────────
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
      final folder = container.read(currentWorkspaceProvider) as FolderLocation;
      await write('lsp_people.py', _folderPeople);
      await write('lsp_main.py', _folderMain);
      // The server runs in the folder's copy, once it is brought up to date.
      await open('lsp_people.py');
      await pumpUntil(
        tester,
        () {
          final client = container
              .read(lspControllerProvider.notifier)
              .clientFor(LspServerId.pyright);
          return client != null &&
              client.workspace == LspWorkspace.copy(folder.id) &&
              client.status.running;
        },
        what: "Pyright to run in the folder's copy",
        timeout: const Duration(minutes: 3),
      );
      await open('lsp_main.py');
      // The deliberate error alone: the import resolves in the copy.
      await pumpUntil(
        tester,
        () {
          final counts = countsOf('lsp_main.py');
          return counts.errors == 1 && counts.total == 1;
        },
        what: 'only the deliberate error in lsp_main.py',
        timeout: const Duration(seconds: 120),
      );
      final folderMain = docIdOf('lsp_main.py');
      expect(host.diagnosticsShown(folderMain), 1);
      expect((await host.gotoLine(3, column: 2)).isOk, isTrue);
      expect(await asks('goToDefinition', 'lsp.definition'), {'found': 1});
      await pumpUntil(
        tester,
        () =>
            container.read(documentControllerProvider).activePath ==
            'lsp_people.py',
        what: "the folder's lsp_people.py at the definition",
      );
      final starts = container.read(lspControllerProvider).statuses.length;
      _report(
        'folder copy=${folder.id.substring(0, 12)} errors=1 '
        'definition=lsp_people.py servers=$starts',
      );
    },
  );
}
