/// The language budgets on a phone (Phase 6 W6, gate G6; PERFORMANCE §2,
/// LSP_ARCHITECTURE §3), in the real app with the real servers and the
/// real editor page, on the gate's 200-file project in each language
/// (LanguageServerTest's generators, ported):
///
/// - **Completion** within 300 ms at the 95th percentile, warm, after an
///   edit (W1's rule): a comment line typed at the end of the file, then
///   completion asked at `thing.`, 50 times after 5 to warm up. Each is
///   timed in the page (editor/src/editor/timings.ts) from its request to
///   the end of the frame that drew the list, and read with `probe.read`.
/// - **Diagnostics** within 1 s of a save, judged at the 95th percentile
///   as well: a line typed and the file saved at once, 20 times after 4 to
///   warm up, every other time adding an error and then commenting it out.
///   Each is timed from the save to the page's taking the set that lists
///   the change; the save sends the edit first, so the server's analysis
///   of it is included.
/// - **Memory** (the owner's decision of 2026-11-22, PHASE_6_PLAN §10
///   item 3): each server's process tree within 300 MB of PSS, as the
///   host reads it every 10 s (LspHost.kt); the app's and its renderers'
///   PSS (`dumpsys meminfo`, through the gate: folder_gate.dart) and the
///   total recorded.
///
/// Firebase Test Lab runs it on its arm64 phone in the same entrypoint as
/// the store, search and the terminal (sync_modes_test.dart calls
/// [phoneLspTests]). The figures go to the device log as `RUNTIME_GATE
/// lsp_phone_*` lines, which tool/ci/gate_results.py holds to the budgets
/// (`--require`), and as a CODEFORGE_LSP_JSON document. The emulator
/// gate's lsp group runs this file too and keeps its `LSP_GATE budget`
/// lines, never judged (app/tool/ci/emulator_gate.sh).
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/lsp/lsp_controller.dart';
import 'package:codeforge/application/lsp/lsp_features.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/application/workspace_switcher.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_gate.dart';
import 'smoke_test.dart' show pumpRealApp, pumpUntil;
import 'terminal_measure.dart'
    show buildMode, memoryFrom, percentile, printReport;

/// PERFORMANCE §2: completion within 300 ms at the 95th percentile, warm.
const double completionBudgetMs = 300;

/// PERFORMANCE §2: diagnostics within 1 s of a save.
const double diagnosticsBudgetMs = 1000;

/// The owner's decision of 2026-11-22: each server's process tree within
/// 300 MB of PSS on the gate's 200-file project, on the phone.
const double serverMemoryBudgetMb = 300;

/// The project the budgets are measured in.
const String _project = 'lsp-gate';

/// Modules in each language's project, as in LanguageServerTest.
const int _modules = 200;

const int _completionWarmup = 5;
const int _completions = 50;

/// Even, so that the first timed save adds an error.
const int _saveWarmup = 4;
const int _saves = 20;

/// Past any file's last line: `cmd.gotoLine` stops at the last.
const int _lastLine = 100000;

String _lines(List<String> content) => '${content.join('\n')}\n';

String _n(int index) => index.toString().padLeft(3, '0');

/// A Python project of 200 modules, and a main file that imports all of
/// them and names one undefined thing (LanguageServerTest.pythonProject).
Map<String, String> _pythonProject() {
  final files = <String, String>{'pkg/__init__.py': ''};
  final imports = StringBuffer();
  for (var index = 0; index < _modules; index++) {
    final n = _n(index);
    files['pkg/m$n.py'] = _lines([
      'class Thing$n:',
      '    """Thing number $index."""',
      '',
      '    def __init__(self, value: int) -> None:',
      '        self.value = value',
      '',
      '    def double(self) -> int:',
      '        return self.value * 2',
      '',
      '    def describe(self) -> str:',
      '        return "thing $index: " + str(self.value)',
      '',
      '',
      'def make_$n(value: int) -> Thing$n:',
      '    return Thing$n(value)',
    ]);
    imports.write('from pkg.m$n import make_$n\n');
  }
  final last = _n(_modules - 1);
  files['main.py'] =
      imports.toString() +
      _lines([
        '',
        'thing = make_$last(3)',
        'total = thing.double() + make_000(1).double()',
        'print(total, not_defined_anywhere)',
      ]);
  return files;
}

/// The same project in TypeScript, with a tsconfig.json over src
/// (LanguageServerTest.typescriptProject).
Map<String, String> _typescriptProject() {
  final files = <String, String>{};
  final imports = StringBuffer();
  for (var index = 0; index < _modules; index++) {
    final n = _n(index);
    files['src/m$n.ts'] = _lines([
      'export class Thing$n {',
      '  constructor(public value: number) {}',
      '',
      '  double(): number {',
      '    return this.value * 2;',
      '  }',
      '',
      '  describe(): string {',
      '    return "thing $index: " + this.value;',
      '  }',
      '}',
      '',
      'export function make$n(value: number): Thing$n {',
      '  return new Thing$n(value);',
      '}',
    ]);
    imports.write('import { make$n } from "./m$n";\n');
  }
  final last = _n(_modules - 1);
  files['src/main.ts'] =
      imports.toString() +
      _lines([
        '',
        'const thing = make$last(3);',
        'const total: number = thing.double() + make000(1).double();',
        'const wrong: number = "x";',
        'export { total, wrong };',
      ]);
  files['tsconfig.json'] = _lines([
    '{"compilerOptions": {"strict": true, "target": "ES2022", '
        '"module": "ES2022", "moduleResolution": "Bundler", '
        '"noEmit": true}, "include": ["src"]}',
  ]);
  return files;
}

/// One server's measurement: its project, the file it is measured in, and
/// the edits made there.
final class _Case {
  const _Case({
    required this.server,
    required this.files,
    required this.main,
    required this.comment,
    required this.errorLine,
  });

  final LspServerId server;
  final Map<String, String> files;
  final String main;

  /// What comments a line out.
  final String comment;

  /// The error the [i]-th save adds: one error more, nothing else.
  final String Function(int i) errorLine;

  String get text => files[main]!;
}

double _round1(num value) => (value * 10).round() / 10;

double _max(List<double> values) =>
    values.isEmpty ? 0 : values.reduce(math.max);

List<Object?> _list(Object? value) =>
    value is List<Object?> ? value : const [];

int _int(Object? value) => value is num ? value.toInt() : 0;

/// The labels in an `lsp.complete` answer.
List<String> _labels(Object? result) => [
  if (result case {'items': final List<Object?> items})
    for (final item in items)
      if (item case {'label': final String label}) label,
];

/// The 1-based line and column of [offset] in [text], as `cmd.gotoLine`
/// takes them.
({int line, int column}) _lineColumnOf(String text, int offset) {
  final before = text.substring(0, offset);
  return (
    line: '\n'.allMatches(before).length + 1,
    column: offset - (before.lastIndexOf('\n') + 1) + 1,
  );
}

/// Waits for [condition] on plain timers, looking every few milliseconds:
/// what is timed must not wait for a frame.
Future<void> _waitFor(
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail('Timed out after ${timeout.inSeconds} s waiting for $what.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
}

/// A figure for tool/ci/gate_results.py, straight to the device log.
void _figure(String key, Object value) =>
    Zone.root.print('RUNTIME_GATE lsp_phone_$key=$value');

/// A line for the emulator gate's evidence (its lsp group keeps them).
void _line(String text) => debugPrint('LSP_GATE budget $text');

/// What was measured for one server.
final class _Figures {
  _Figures(this.server, {required this.files});

  final LspServerId server;
  final int files;
  int readyMs = 0;
  int firstDiagnosticsMs = 0;
  int baseErrors = 0;

  /// Each list's time in the page, from the request to the frame that drew
  /// it, and to the host's answer, in ms; its options.
  final List<double> completionMs = [];
  final List<double> answerMs = [];
  final List<int> items = [];
  int undrawn = 0;
  int empty = 0;
  int throttled = 0;

  /// Each save's time to the page's taking the diagnostics, in ms, and
  /// the save's own.
  final List<double> diagnosticsMs = [];
  final List<double> saveMs = [];

  /// The host's last reading of the server's process tree.
  LspServerInfo? info;

  void takeCompletions(Map<String, Object?> report) {
    for (final entry in _list(report['completions'])) {
      if (entry is! Map<String, Object?>) {
        continue;
      }
      completionMs.add((entry['ms']! as num).toDouble());
      answerMs.add((entry['answerMs']! as num).toDouble());
      items.add(_int(entry['items']));
    }
    undrawn = _int(report['undrawn']);
    empty = _int(report['empty']);
    throttled = _int(report['throttled']);
  }

  double get completionP50 => percentile(completionMs, 0.5);
  double get completionP95 => percentile(completionMs, 0.95);
  bool get completionUnderBudget =>
      completionMs.length >= _completions &&
      completionP95 <= completionBudgetMs;
  int get itemsMedian =>
      items.isEmpty ? 0 : ([...items]..sort())[items.length ~/ 2];

  double get diagnosticsP50 => percentile(diagnosticsMs, 0.5);
  double get diagnosticsP95 => percentile(diagnosticsMs, 0.95);
  bool get diagnosticsUnderBudget =>
      diagnosticsMs.length >= _saves &&
      diagnosticsP95 <= diagnosticsBudgetMs;

  int get pssKib => info?.pssKib ?? 0;
  double get pssMb => _round1(pssKib / 1024);
  double get rssMb => _round1((info?.rssKib ?? 0) / 1024);
  bool get memoryUnderBudget =>
      pssKib > 0 && pssKib / 1024 <= serverMemoryBudgetMb;

  /// The figures known once its own measurements are done.
  void reportTimes() {
    final id = server.id;
    _figure('${id}_files', files);
    _figure('${id}_ready_ms', readyMs);
    _figure('${id}_first_diagnostics_ms', firstDiagnosticsMs);
    _figure('${id}_completion_samples', completionMs.length);
    _figure('${id}_completion_p50_ms', completionP50);
    _figure('${id}_completion_p95_ms', completionP95);
    _figure('${id}_completion_max_ms', _max(completionMs));
    _figure('${id}_completion_answer_p95_ms', percentile(answerMs, 0.95));
    _figure('${id}_completion_items', itemsMedian);
    _figure('${id}_completion_undrawn', undrawn);
    _figure('${id}_completion_throttled', throttled);
    _figure('${id}_completion_under_budget', completionUnderBudget ? 1 : 0);
    _figure('${id}_diagnostics_samples', diagnosticsMs.length);
    _figure('${id}_diagnostics_p50_ms', diagnosticsP50);
    _figure('${id}_diagnostics_p95_ms', diagnosticsP95);
    _figure('${id}_diagnostics_max_ms', _max(diagnosticsMs));
    _figure('${id}_diagnostics_under_budget', diagnosticsUnderBudget ? 1 : 0);
    _line(
      '$id files=$files ready_ms=$readyMs '
      'first_diagnostics_ms=$firstDiagnosticsMs base_errors=$baseErrors',
    );
    _line(
      '$id completion samples=${completionMs.length} '
      'p50_ms=$completionP50 p95_ms=$completionP95 '
      'max_ms=${_max(completionMs)} '
      'answer_p95_ms=${percentile(answerMs, 0.95)} items=$itemsMedian '
      'undrawn=$undrawn empty=$empty throttled=$throttled '
      'under_budget=${completionUnderBudget ? 1 : 0}',
    );
    _line(
      '$id diagnostics samples=${diagnosticsMs.length} '
      'p50_ms=$diagnosticsP50 p95_ms=$diagnosticsP95 '
      'max_ms=${_max(diagnosticsMs)} '
      'save_p50_ms=${percentile(saveMs, 0.5)} '
      'under_budget=${diagnosticsUnderBudget ? 1 : 0}',
    );
  }

  void reportMemory() {
    final id = server.id;
    _figure('${id}_pss_mb', pssMb);
    _figure('${id}_rss_mb', rssMb);
    _figure('${id}_processes', info?.processes ?? 0);
    _figure('${id}_memory_under_budget', memoryUnderBudget ? 1 : 0);
    _line(
      '$id memory pss_mb=$pssMb rss_mb=$rssMb '
      'processes=${info?.processes ?? 0} '
      'under_budget=${memoryUnderBudget ? 1 : 0}',
    );
  }

  Map<String, Object?> toJson() => {
    'files': files,
    'readyMs': readyMs,
    'firstDiagnosticsMs': firstDiagnosticsMs,
    'baseErrors': baseErrors,
    'completion': {
      'samples': completionMs.length,
      'p50Ms': completionP50,
      'p95Ms': completionP95,
      'maxMs': _max(completionMs),
      'answerP50Ms': percentile(answerMs, 0.5),
      'answerP95Ms': percentile(answerMs, 0.95),
      'itemsMedian': itemsMedian,
      'undrawn': undrawn,
      'empty': empty,
      'throttled': throttled,
      'underBudget': completionUnderBudget,
      'ms': completionMs,
    },
    'diagnostics': {
      'samples': diagnosticsMs.length,
      'p50Ms': diagnosticsP50,
      'p95Ms': diagnosticsP95,
      'maxMs': _max(diagnosticsMs),
      'saveP50Ms': percentile(saveMs, 0.5),
      'underBudget': diagnosticsUnderBudget,
      'ms': diagnosticsMs,
    },
    'memory': {
      'pssMb': pssMb,
      'rssMb': rssMb,
      'processes': info?.processes ?? 0,
      'underBudget': memoryUnderBudget,
    },
  };
}

void phoneLspTests() {
  testWidgets(
    'lsp: the budgets on a 200-file project, Pyright and TypeScript (G6)',
    timeout: const Timeout(Duration(minutes: 20)),
    (tester) async {
      final gate = await FolderGate.start();
      final memory = memoryFrom(
        (request) => gate.ask(request, timeout: const Duration(seconds: 90)),
      );
      final projects = Directory(await projectsRootPath());
      if (projects.existsSync()) {
        projects.deleteSync(recursive: true);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await pumpRealApp(tester, prefs, languageServers: true);
      await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CodeForgeApp)),
        listen: false,
      );
      // The workbench starts the runtime, as it does for the user.
      await tester.ensureVisible(find.byKey(const ValueKey('explore_demo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('explore_demo')));
      await tester.pump();

      // Both languages' projects in one, written before it opens.
      final python = _Case(
        server: LspServerId.pyright,
        files: _pythonProject(),
        main: 'main.py',
        comment: '#',
        errorLine: (i) => 'wrong_$i = missing_$i',
      );
      final typescript = _Case(
        server: LspServerId.typescript,
        files: _typescriptProject(),
        main: 'src/main.ts',
        comment: '//',
        errorLine: (i) => 'export const wrong$i: number = "x$i";',
      );
      final switcher = container.read(workspaceSwitcherProvider);
      final created = await switcher.createProject(_project);
      final project = created.valueOrNull;
      expect(project, isNotNull, reason: 'create the project: $created');
      final root = '${projects.path}/${project!.folder}';
      for (final MapEntry(:key, :value) in {
        ...python.files,
        ...typescript.files,
      }.entries) {
        File('$root/$key')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(value);
      }
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

      final host = container.read(editorHostProvider);
      final documents = container.read(documentControllerProvider.notifier);
      String docIdOf(String path) =>
          container.read(documentControllerProvider).documents[path]!.docId;
      ProblemCounts countsOf(String path) =>
          container.read(lspFeaturesProvider).countsOf(path);
      LspStatus statusOf(LspServerId server) =>
          container.read(lspControllerProvider).statusOf(server);

      Future<void> ok(Future<Result<void>> command, String what) async {
        final result = await command;
        expect(result.isOk, isTrue, reason: '$what: $result');
      }

      Future<Map<String, Object?>> probe({bool clear = false}) async {
        final read = await host.readProbe(clear: clear);
        expect(read.isOk, isTrue, reason: 'probe.read: $read');
        return read.valueOrNull!;
      }

      Future<_Figures> measure(_Case c) async {
        final figures = _Figures(c.server, files: c.files.length);

        // ── Opened: the server starts (installed first if it must be) and
        // analyses the project.
        final started = Stopwatch()..start();
        final openedMain = await documents.open(c.main);
        expect(openedMain.isOk, isTrue, reason: '$openedMain');
        await tester.pump();
        final docId = docIdOf(c.main);
        await pumpUntil(
          tester,
          () => statusOf(c.server).running,
          what: '${c.server.title} to run (now ${statusOf(c.server)})',
          timeout: const Duration(minutes: 3),
        );
        figures.readyMs = started.elapsedMilliseconds;
        await pumpUntil(
          tester,
          () => countsOf(c.main).errors >= 1,
          what: "${c.server.title}'s first error in ${c.main}",
          timeout: const Duration(minutes: 3),
        );
        figures.firstDiagnosticsMs = started.elapsedMilliseconds;
        await tester.pump(const Duration(seconds: 2));
        await pumpUntil(
          tester,
          () => host.diagnosticsShown(docId) == countsOf(c.main).total,
          what: 'the page to show what is listed for ${c.main}',
        );
        final baseErrors = countsOf(c.main).errors;
        figures.baseErrors = baseErrors;

        // ── Completion after an edit, timed in the page.
        final text = c.text;
        final at = _lineColumnOf(
          text,
          text.indexOf('thing.double()') + 'thing.'.length,
        );
        // The test does not focus the editor, so no input method takes
        // part and the list is drawn over the whole editor, not above a
        // keyboard (W7's checklist has the owner try it with Gboard).
        var drawn = 0;
        Future<void> completeOnce(int i) async {
          await ok(host.gotoLine(_lastLine), 'to the end');
          await ok(host.insert('${c.comment} edit $i\n'), 'the edit');
          await ok(host.gotoLine(at.line, column: at.column), 'to thing.');
          final answered = host.pageAnswers('lsp.complete');
          await ok(host.exec('startCompletion'), 'startCompletion');
          await _waitFor(
            () => host.pageAnswers('lsp.complete') > answered,
            what: 'completion $i to be answered',
          );
          final labels = _labels(host.lastPageResult('lsp.complete'));
          expect(labels, contains('double'), reason: 'completion $i');
          drawn += 1;
          // The page times the frame that draws the list; then it counts.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final watch = Stopwatch()..start();
          while (_list((await probe())['completions']).length < drawn) {
            if (watch.elapsed > const Duration(seconds: 5)) {
              fail('Completion $i was answered, but its list never drawn.');
            }
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        }

        for (var i = 0; i < _completionWarmup; i++) {
          await completeOnce(i);
        }
        await probe(clear: true);
        drawn = 0;
        for (var i = 0; i < _completions; i++) {
          await completeOnce(_completionWarmup + i);
        }
        figures.takeCompletions(await probe(clear: true));

        // ── Diagnostics after a save: a line typed, the file saved at
        // once; every other save adds an error, the next comments it out.
        Future<({double ms, double saveMs})> saveOnce(int i) async {
          final add = i.isEven;
          if (add) {
            await ok(host.gotoLine(_lastLine), 'to the end');
            await ok(host.insert('${c.errorLine(i)}\n'), 'the error');
          } else {
            // The error is the last line before the final line break, and
            // the save before sent every edit: the host's text is current.
            final lines = host.textOf(docId)!.split('\n');
            await ok(host.gotoLine(lines.length - 1), 'to the error');
            await ok(host.insert('${c.comment} '), 'the error commented out');
          }
          final errors = add ? baseErrors + 1 : baseErrors;
          final watch = Stopwatch()..start();
          final saved = await documents.save(c.main);
          final saveMs = watch.elapsedMicroseconds / 1000;
          expect(saved.isOk, isTrue, reason: 'save $i: $saved');
          await _waitFor(
            () {
              final counts = countsOf(c.main);
              return counts.errors == errors &&
                  host.diagnosticsShown(docId) == counts.total;
            },
            what: 'the diagnostics after save $i ($errors errors)',
            timeout: const Duration(seconds: 30),
          );
          final ms = watch.elapsedMicroseconds / 1000;
          // A user's pace; the server's later messages about it land.
          await Future<void>.delayed(const Duration(milliseconds: 500));
          return (ms: _round1(ms), saveMs: _round1(saveMs));
        }

        for (var i = 0; i < _saveWarmup; i++) {
          await saveOnce(i);
        }
        for (var i = _saveWarmup; i < _saveWarmup + _saves; i++) {
          final timed = await saveOnce(i);
          figures.diagnosticsMs.add(timed.ms);
          figures.saveMs.add(timed.saveMs);
        }
        figures.reportTimes();
        return figures;
      }

      final measured = [await measure(python), await measure(typescript)];

      // ── Memory: each server's tree as the host reads it every 10 s (one
      // more reading first), then the app's and its renderers'.
      await tester.pump(const Duration(seconds: 12));
      final servers = await container.read(lspServiceProvider).servers();
      expect(servers.isOk, isTrue, reason: 'the servers: $servers');
      for (final info in servers.valueOrNull!) {
        for (final figures in measured) {
          if (info.server == figures.server.id) {
            figures.info = info;
          }
        }
      }
      final app = await memory('lsp');
      gate.done();
      for (final figures in measured) {
        figures.reportMemory();
      }
      final serversKb = measured.fold<int>(0, (sum, f) => sum + f.pssKib);
      final totalKb = app.totalKb + serversKb;
      _figure('build', buildMode);
      _figure('app_mb', app.megabytes(app.appKb));
      _figure('renderer_mb', app.megabytes(app.rendererKb));
      _figure('servers_mb', app.megabytes(serversKb));
      _figure('total_mb', app.megabytes(totalKb));
      _line(
        'memory app_mb=${app.megabytes(app.appKb)} '
        'renderer_mb=${app.megabytes(app.rendererKb)} '
        'renderers=${app.renderers} '
        'servers_mb=${app.megabytes(serversKb)} '
        'total_mb=${app.megabytes(totalKb)} build=$buildMode',
      );
      await printReport('CODEFORGE_LSP_JSON', {
        'test': 'phone_lsp',
        'build': buildMode,
        'budgets': {
          'completionP95Ms': completionBudgetMs,
          'diagnosticsP95Ms': diagnosticsBudgetMs,
          'serverPssMb': serverMemoryBudgetMb,
        },
        for (final figures in measured) figures.server.id: figures.toJson(),
        'memory': {
          ...app.toJson(),
          'serversMb': app.megabytes(serversKb),
          'withServersMb': app.megabytes(totalKb),
        },
      });
      for (final figures in measured) {
        expect(
          figures.completionMs.length,
          _completions,
          reason: '${figures.server.title}: every list timed',
        );
        expect(
          figures.info?.pssKib,
          isNotNull,
          reason: '${figures.server.title}: the host read its memory',
        );
      }
    },
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  phoneLspTests();
}
