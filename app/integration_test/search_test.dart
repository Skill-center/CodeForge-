/// Search across files on the emulator (Phase 4 W6, gate G8), in the build
/// that carries the runtime. Every part prints `search gate:` lines, and the
/// test ends with its report as `SEARCH_JSON <part>/<parts>` lines, which the
/// gate script joins into search.json. The figures are evidence for a budget
/// (docs/PERFORMANCE.md), never judged here; the counts are, exactly.
/// 1. A project of 10,000 files (10 × 10 folders of 100) the test writes,
///    with a `.gitignore`, a skipped folder and a binary file beside them,
///    searched by the runtime's ripgrep once the runtime is ready: a literal,
///    a whole word, a regular expression, globs, case, a pattern ripgrep
///    refuses. The time to the first result and to the end, three runs.
/// 2. Cancelling a search that would find 10,000 lines, at its first
///    results: the host says cancelled, and no ripgrep is left running.
/// 3. The Search panel: a query typed and run, its result tapped, the file
///    open with the cursor on the match.
/// 4. The gate folder, picked in Android's picker: its 1,000-file folder
///    `many/` and the fixture scanned by CodeForge's own scan through the
///    provider, with the same figures.
/// 5. ADR-0013's figure: every file of the gate folder copied into the
///    app's storage through the storage broker, one file at a time.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/application/search/search_controller.dart';
import 'package:codeforge/application/workspace_switcher.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/search/search_models.dart';
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

/// How many runs each timing takes; the median is reported.
const int _runs = 3;

/// The project's shape: 10 × 10 folders of 100 files.
const int _top = 10;
const int _sub = 10;
const int _perFolder = 100;
const int _projectFiles = _top * _sub * _perFolder;

/// What the gate script writes into the gate folder (emulator_gate.sh).
const int _manyFiles = 1000;

int _median(List<int> values) => ([...values]..sort())[values.length ~/ 2];

Map<String, Object> _timing(List<int> times) => {
  'medianMs': _median(times),
  'runsMs': times,
};

void _say(String line) => debugPrint('search gate: $line');

/// A project file: its path, its id, and on f07 a needle, on f08 needles.
String _content(int m, int s, int f) {
  final name = 'f${f.toString().padLeft(2, '0')}';
  final out = StringBuffer('// m$m/s$s/$name\n')
    ..write("export const id = 'm$m-s$s-$name';\n");
  if (f == 7) {
    out.write("const marker = 'needle';\n");
  } else if (f == 8) {
    out.write("const marker = 'needles';\n");
  }
  return out.toString();
}

/// [report] as lines of at most 600 characters, for the gate to join.
void _printReport(Map<String, Object> report) {
  final json = jsonEncode(report);
  const size = 600;
  final parts = (json.length + size - 1) ~/ size;
  for (var part = 0; part < parts; part++) {
    final end = (part + 1) * size;
    debugPrint(
      'SEARCH_JSON ${part + 1}/$parts '
      '${json.substring(part * size, end > json.length ? json.length : end)}',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'search: ripgrep in a 10,000-file project, the scan in the gate folder, '
    'cancelling, a result opened at its line',
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
      final report = <String, Object>{
        'schema': 1,
        'kind': 'codeforge-search',
        'runs': _runs,
      };

      // The workbench starts the runtime's install, as on a phone.
      await tester.ensureVisible(find.byKey(const ValueKey('explore_demo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('explore_demo')));
      await tester.pump();

      // ── 1. A project of 10,000 files ──────────────────────────────────
      final switcher = container.read(workspaceSwitcherProvider);
      final created = await switcher.createProject('search10k');
      final project = created.valueOrNull;
      expect(project, isNotNull, reason: 'create the project: $created');
      final root = '${projects.path}/${project!.folder}';
      final fill = Stopwatch()..start();
      for (var m = 0; m < _top; m++) {
        for (var s = 0; s < _sub; s++) {
          final folder = Directory('$root/m$m/s$s')
            ..createSync(recursive: true);
          await Future.wait([
            for (var f = 0; f < _perFolder; f++)
              File(
                '${folder.path}/f${f.toString().padLeft(2, '0')}.js',
              ).writeAsString(_content(m, s, f)),
          ]);
        }
      }
      // Beside them, what a search must leave out: an ignored folder, a
      // skipped one and a binary file, each holding the needle.
      File('$root/.gitignore').writeAsStringSync('ignored/\n');
      for (var i = 0; i < 10; i++) {
        File('$root/ignored/i$i.js')
          ..createSync(recursive: true)
          ..writeAsStringSync("const marker = 'needle';\n");
      }
      File('$root/node_modules/pkg/index.js')
        ..createSync(recursive: true)
        ..writeAsStringSync("const marker = 'needle';\n");
      File('$root/bin/blob.dat')
        ..createSync(recursive: true)
        ..writeAsBytesSync([...utf8.encode('needle\n'), 0, 1, 2]);
      _say(
        'project of $_projectFiles files written in '
        '${fill.elapsedMilliseconds} ms (setup)',
      );

      final opened = await switcher.open(project);
      expect(opened.isOk, isTrue, reason: 'open the project: $opened');
      await tester.pumpAndSettle();
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

      final search = container.read(searchControllerProvider.notifier);
      Future<SearchState> run(SearchQuery query, String what) async {
        search.search(query);
        await pumpUntil(
          tester,
          () =>
              container.read(searchControllerProvider).phase ==
              SearchPhase.finished,
          what: what,
          timeout: const Duration(minutes: 3),
        );
        final state = container.read(searchControllerProvider);
        final summary = state.summary!;
        _say(
          '$what: ${summary.engine.name} ${summary.outcome.name}'
          '${summary.problem == null ? '' : ' (${summary.problem!.name})'} '
          '${state.lines} lines in ${state.files.length} files'
          '${summary.filesSearched == null ? '' : ' of ${summary.filesSearched}'}; '
          'first ${state.firstResultMs} ms, '
          'all ${state.elapsedMs} ms (host ${summary.firstResultMs} / '
          '${summary.elapsedMs} ms)',
        );
        return state;
      }

      Map<String, Object?> figures(SearchState state) => {
        'engine': state.summary!.engine.name,
        'outcome': state.summary!.outcome.name,
        'files': state.files.length,
        'lines': state.lines,
        'searched': state.summary!.filesSearched,
        'firstMs': state.firstResultMs,
        'allMs': state.elapsedMs,
        'hostFirstMs': state.summary!.firstResultMs,
        'hostAllMs': state.summary!.elapsedMs,
      };

      final timed = <SearchState>[];
      for (var i = 0; i < _runs; i++) {
        timed.add(
          await run(const SearchQuery(text: 'needle'), 'needle run ${i + 1}'),
        );
      }
      final literal = timed.last;
      expect(literal.summary!.engine, SearchEngine.ripgrep);
      expect(literal.summary!.outcome, SearchOutcome.done);
      expect(literal.files.length, 200, reason: 'f07 and f08 in 100 folders');
      expect(literal.lines, 200);
      // ripgrep does not say how many files it read; the scan does.
      expect(literal.summary!.filesSearched, isNull);
      final paths = literal.files.map((f) => f.path).toSet();
      expect(
        paths.where(
          (p) =>
              p.startsWith('ignored/') ||
              p.startsWith('node_modules/') ||
              p.startsWith('bin/'),
        ),
        isEmpty,
        reason: '.gitignore, node_modules and binary files stay out',
      );

      final word = await run(
        const SearchQuery(text: 'needle', wholeWord: true),
        'whole word',
      );
      expect(word.files.length, 100);
      final sample = word.files.firstWhere((f) => f.path == 'm0/s0/f07.js');
      expect(sample.lines.single.line, 3);
      expect(sample.lines.single.column, 17);

      final regex = await run(
        const SearchQuery(text: r"id = 'm[0-4]-s0-f\d+'", regex: true),
        'regular expression',
      );
      expect(regex.files.length, 500);

      final included = await run(
        const SearchQuery(text: 'needle', wholeWord: true, includes: ['m2']),
        'include m2',
      );
      expect(included.files.length, 10);
      expect(included.files.every((f) => f.path.startsWith('m2/')), isTrue);

      final excluded = await run(
        const SearchQuery(text: 'needle', wholeWord: true, excludes: ['s0']),
        'exclude s0',
      );
      expect(excluded.files.length, 90);

      final cased = await run(
        const SearchQuery(text: 'NEEDLE', caseSensitive: true),
        'match case',
      );
      expect(cased.summary!.outcome, SearchOutcome.done);
      expect(cased.lines, 0);

      final refused = await run(
        const SearchQuery(text: "(?<=marker = ')needle", regex: true),
        'look-around',
      );
      expect(refused.summary!.outcome, SearchOutcome.failed);
      expect(refused.summary!.problem, SearchProblem.badQuery);
      expect(refused.summary!.detail, contains('look-around'));

      report['project'] = {
        'files': _projectFiles,
        'setupMs': fill.elapsedMilliseconds,
        'needle': {
          'firstMs': _timing([for (final s in timed) s.firstResultMs ?? -1]),
          'allMs': _timing([for (final s in timed) s.elapsedMs ?? -1]),
          'hostFirstMs': _timing([
            for (final s in timed) s.summary!.firstResultMs ?? -1,
          ]),
          'hostAllMs': _timing([for (final s in timed) s.summary!.elapsedMs]),
          'last': figures(literal),
        },
        'wholeWord': figures(word),
        'regex': figures(regex),
        'include': figures(included),
        'exclude': figures(excluded),
        'matchCase': figures(cased),
        'refused': {'problem': refused.summary!.problem!.name},
      };

      // ── 2. Cancelling at the first results ────────────────────────────
      // Every file has one such line, so ripgrep must read all 10,000
      // files to reach the cap; Stop comes as the first file arrives.
      var stopAsked = -1;
      final stopWatch = Stopwatch();
      final subscription = container.listen(searchControllerProvider, (
        before,
        after,
      ) {
        if (stopAsked < 0 &&
            after.phase == SearchPhase.running &&
            after.files.isNotEmpty) {
          stopAsked = after.lines;
          stopWatch.start();
          unawaited(search.stop());
        }
      });
      final cancelled = await run(
        const SearchQuery(text: '^export const id', regex: true),
        'cancelled at the first results',
      );
      stopWatch.stop();
      subscription.close();
      expect(stopAsked, greaterThan(0), reason: 'Stop was never asked for');
      expect(cancelled.summary!.outcome, SearchOutcome.cancelled);
      expect(cancelled.lines, lessThan(_projectFiles));
      // No ripgrep left: the launcher ended it with everything it started.
      String? left;
      final leftWatch = Stopwatch()..start();
      while (leftWatch.elapsed < const Duration(seconds: 5)) {
        final counted = await container
            .read(runtimeServiceProvider)
            .exec('bash', [
              '-c',
              r'n=0; for f in /proc/[0-9]*/comm; do read -r c < "$f" 2>/dev/null && [ "$c" = rg ] && n=$((n + 1)); done; echo $n',
            ], timeout: const Duration(seconds: 20));
        left = counted.valueOrNull?.stdout.trim();
        if (left == '0') {
          break;
        }
        await tester.pump(const Duration(milliseconds: 250));
      }
      _say(
        'cancelled: Stop asked at $stopAsked lines, ended with '
        '${cancelled.lines} lines, '
        '${stopWatch.elapsedMilliseconds} ms from Stop to the summary; '
        'ripgrep processes left: $left',
      );
      expect(left, '0', reason: 'a ripgrep process outlived its search');
      report['cancel'] = {
        'stopAtLines': stopAsked,
        'endedWithLines': cancelled.lines,
        'stopToSummaryMs': stopWatch.elapsedMilliseconds,
        'ripgrepLeft': left ?? '?',
      };

      // ── 3. The Search panel: run a query, open its result ─────────────
      // The panel starts from the last query; this one narrows to one file.
      await run(
        const SearchQuery(text: 'x', wholeWord: true, includes: ['m0/s0']),
        'the panel query, prepared',
      );
      await tester.tap(find.byKey(const ValueKey('activity_search')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('search_query')),
        'needle',
      );
      await tester.tap(find.byKey(const ValueKey('search_go')));
      await pumpUntil(
        tester,
        () {
          final state = container.read(searchControllerProvider);
          return state.query.text == 'needle' &&
              state.phase == SearchPhase.finished;
        },
        what: "the panel's search",
      );
      await tester.pumpAndSettle();
      final panel = container.read(searchControllerProvider);
      expect(panel.files.map((f) => f.path), ['m0/s0/f07.js']);
      final row = find.byKey(const ValueKey('search_line_m0/s0/f07.js:3'));
      expect(row, findsOneWidget);
      await tester.tap(row);
      final content = File('$root/m0/s0/f07.js').readAsStringSync();
      final lines = content.split('\n');
      final expectedHead =
          lines[0].length + 1 + lines[1].length + 1 + lines[2].indexOf('needle');
      await pumpUntil(
        tester,
        () {
          final docId = container.read(documentControllerProvider).active?.docId;
          if (container.read(documentControllerProvider).activePath !=
                  'm0/s0/f07.js' ||
              docId == null) {
            return false;
          }
          return container
                  .read(editorHostProvider)
                  .viewStateOf(docId)
                  ?.selection
                  ?.head ==
              expectedHead;
        },
        what: 'm0/s0/f07.js open with the cursor on its match',
      );
      _say('opened m0/s0/f07.js at line 3, column 17 (offset $expectedHead)');
      report['open'] = {'path': 'm0/s0/f07.js', 'line': 3, 'column': 17};
      await tester.pumpAndSettle();

      // ── 4. The gate folder, through Android's picker and provider ─────
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

      final scans = <SearchState>[];
      for (var i = 0; i < _runs; i++) {
        scans.add(
          await run(
            const SearchQuery(text: r'^1\d\d$', regex: true),
            'folder scan run ${i + 1}',
          ),
        );
      }
      final scanned = scans.last;
      expect(scanned.summary!.engine, SearchEngine.scan);
      expect(scanned.summary!.outcome, SearchOutcome.done);
      expect(scanned.files.length, 100, reason: 'many/0100.txt to 0199.txt');
      expect(
        scanned.summary!.filesSearched,
        greaterThanOrEqualTo(_manyFiles),
      );
      final needle = await run(
        const SearchQuery(text: 'needle'),
        'folder needle',
      );
      expect(needle.files.map((f) => f.path), ['extra/needle.txt']);
      expect(needle.summary!.skippedBinary, greaterThanOrEqualTo(1));
      final answer = await run(
        const SearchQuery(text: '42', wholeWord: true),
        'folder whole word',
      );
      expect(answer.files.map((f) => f.path).toSet(), {
        'many/0042.txt',
        'src/lib/util.js',
      });
      report['folder'] = {
        'files': scanned.summary!.filesSearched,
        'scan': {
          'firstMs': _timing([for (final s in scans) s.firstResultMs ?? -1]),
          'allMs': _timing([for (final s in scans) s.elapsedMs ?? -1]),
          'hostFirstMs': _timing([
            for (final s in scans) s.summary!.firstResultMs ?? -1,
          ]),
          'hostAllMs': _timing([for (final s in scans) s.summary!.elapsedMs]),
          'last': figures(scanned),
        },
        'needle': figures(needle),
        'wholeWord': figures(answer),
      };

      // ── 5. ADR-0013: the gate folder copied into the app's storage ────
      final folder = container.read(currentWorkspaceProvider) as FolderLocation;
      final broker = container.read(storageBrokerProvider);
      final target = Directory('$appFiles/copy-measure');
      if (target.existsSync()) {
        target.deleteSync(recursive: true);
      }
      var copiedFiles = 0;
      var copiedBytes = 0;
      var copiedFolders = 0;
      final copy = Stopwatch()..start();
      final pending = <String>[''];
      while (pending.isNotEmpty) {
        final path = pending.removeLast();
        final listed = await broker.list(folder.treeUri, path);
        final entries = listed.valueOrNull;
        expect(entries, isNotNull, reason: 'list "$path": $listed');
        Directory(path.isEmpty ? target.path : '${target.path}/$path')
            .createSync(recursive: true);
        copiedFolders++;
        for (final entry in entries!) {
          final child = path.isEmpty ? entry.name : '$path/${entry.name}';
          if (entry.isDirectory) {
            pending.add(child);
            continue;
          }
          final read = await broker.read(
            folder.treeUri,
            child,
            maxBytes: 10 * 1024 * 1024,
          );
          final bytes = read.valueOrNull?.bytes;
          expect(bytes, isNotNull, reason: 'read "$child": $read');
          await File('${target.path}/$child').writeAsBytes(bytes!);
          copiedFiles++;
          copiedBytes += bytes.length;
        }
      }
      copy.stop();
      target.deleteSync(recursive: true);
      _say(
        'copy of the gate folder into app storage, through the broker one '
        'file at a time: $copiedFiles files and $copiedFolders folders, '
        '$copiedBytes bytes, in ${copy.elapsedMilliseconds} ms',
      );
      expect(copiedFiles, greaterThanOrEqualTo(_manyFiles));
      report['copy'] = {
        'files': copiedFiles,
        'folders': copiedFolders,
        'bytes': copiedBytes,
        'ms': copy.elapsedMilliseconds,
        'how': 'StorageBroker.list and read from Dart, dart:io writes',
      };

      _printReport(report);
      gate.done();
    },
  );
}
