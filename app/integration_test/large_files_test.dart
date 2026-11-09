/// Large files on the real page in the emulator (Phase 2 W7, gate G7).
///
/// 1, 5 and 10 MiB of generated JavaScript (the W3 benchmark's
/// `largeJavaScript`, editor/bench/samples.ts), each opened through the app
/// as `.js` (highlighted) and as `.txt` (plain text). The cursor goes to the
/// middle line, and editor/tool/large_cdp.mjs, attached to the page through
/// the WebView's DevTools socket (debug builds only), measures what only
/// the page sees: the long tasks of the open, scrolling frames, real key
/// events typed at the cursor timed to the next frame, and the app's and
/// renderer's memory. The test asks for each step in the device log
/// (`LARGEGATE <run>.<n> prepare|measure|done …`, printed in the root zone,
/// which logs under the `flutter` tag) and waits for the driver's answer:
/// an empty `files/largegate/ack.<id>.ok` (or `.failed`) that the driver
/// writes through `run-as`. The typed text must then reach the app's copy
/// of the document: edits of a large document travel back.
///
/// The app side is timed here: the write, the open (read and decode, then
/// the page's own report of the document), the typed text's sync, the
/// journal catching up, the save; and the session store's snapshot and
/// change writes at each size with `synchronous = NORMAL` (the app's)
/// against `FULL` (ADR-0008), with the journal's first-edit digest. This is
/// a debug (JIT) build, so the app side is pessimistic; the page's numbers
/// do not depend on how the app was built.
///
/// The test ends with large_1mb.js open and stored as the active tab: the
/// gate then installs the release build over the same data, which restores
/// that session, and samples its memory (ADR-0004's release-like number).
/// The report is printed as CODEFORGE_LARGE_JSON lines, which
/// editor/tool/large_report.mjs merges into ci-results/gate/large_files.*.
/// The test fails when a step cannot run, never on a budget.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/editor/journal.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:codeforge/core/logging/logger.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/storage/app_database.dart';
import 'package:codeforge/services/storage/drift_session_store.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpRealApp, pumpUntil;

const int _mib = 1024 * 1024;
const List<int> _sizesMiB = [1, 5, 10];

/// What the driver types: the W3 driver's 60 keys (bench_cdp.mjs
/// KEY_TEXT), letters and spaces only.
const String _typed =
    'the quick brown fox jumps over the lazy dog and keeps runnin';

/// Left open for the gate's release-build memory sample.
const String _kept = 'large_1mb.js';

/// Events that mean the bridge or the documents went wrong.
const Set<String> _trouble = {
  'request_timeout',
  'request_failed',
  'page_restarted',
  'page_reload',
  'shadow_resync',
  'change_refused',
  'message_rejected',
  'open_failed',
  'reopen_failed',
  'save_failed',
  'editor_open_failed',
  'editor_close_failed',
  'editor_activate_failed',
};

/// editor/bench/samples.ts `largeJavaScript`, ported: at least [chars]
/// characters of ASCII JavaScript, cut at a line end. Blocks differ by
/// number, so no two lines of neighbouring blocks are identical.
String largeJavaScript(int chars) {
  final out = StringBuffer();
  var size = 0;
  for (var n = 0; size < chars; n += 1) {
    final block =
        '// Block $n: generated for the large-file benchmark.\n'
        'export function compute$n(items, factor = ${n % 97}) {\n'
        '  const result = [];\n'
        '  for (let i = 0; i < items.length; i += 1) {\n'
        '    const value = items[i] * factor + $n;\n'
        '    if (value % 2 === 0) {\n'
        "      result.push({ id: i, value, label: 'item-' + i + '-$n' });\n"
        '    } else {\n'
        '      result.push(null); // odd values are skipped\n'
        '    }\n'
        '  }\n'
        '  return result.filter(Boolean);\n'
        '}\n'
        '\n';
    out.write(block);
    size += block.length;
  }
  final text = out.toString();
  final cut = text.indexOf('\n', chars - 1);
  return cut < 0 ? text : text.substring(0, cut + 1);
}

int _lineCount(String text) {
  var lines = 0;
  for (var i = text.indexOf('\n'); i >= 0; i = text.indexOf('\n', i + 1)) {
    lines += 1;
  }
  return lines;
}

/// Writes [chars] of generated text to each of [names] through the app's
/// file service. The text is let go on return: from then on the app's
/// memory holds the app's own copies only.
Future<({int chars, int lines, Map<String, int> writeMs})> _writeFiles(
  FileService files,
  List<String> names,
  int chars,
) async {
  final text = largeJavaScript(chars);
  final writeMs = <String, int>{};
  for (final name in names) {
    final clock = Stopwatch()..start();
    final written = await files.writeText(name, text);
    writeMs[name] = clock.elapsedMilliseconds;
    expect(
      written.isOk,
      isTrue,
      reason: 'writing $name: ${written.failureOrNull?.message}',
    );
  }
  return (chars: text.length, lines: _lineCount(text), writeMs: writeMs);
}

String get _build {
  if (kDebugMode) {
    return 'debug';
  }
  return kProfileMode ? 'profile' : 'release';
}

void _expectNoTrouble(DateTime since, String what) {
  final trouble = [
    for (final record in appLogger.records)
      if (!record.time.isBefore(since) && _trouble.contains(record.event))
        '${record.tag} ${record.event} ${record.fields}',
  ];
  expect(trouble, isEmpty, reason: what);
}

void _deleteDatabase(String path) {
  for (final suffix in ['', '-wal', '-shm', '-journal']) {
    final part = File('$path$suffix');
    if (part.existsSync()) {
      part.deleteSync();
    }
  }
}

/// The session store's writes at each size, on a database of its own with
/// the app's settings (WAL, synchronous NORMAL) and then synchronous FULL
/// (ADR-0008); with the digest of the text that the journal computes on
/// the UI isolate at a document's first edit.
Future<Map<String, Object?>> _storeTimings(String folder) async {
  final path = '$folder/largegate.sqlite';
  _deleteDatabase(path);
  final db = AppDatabase(NativeDatabase.createInBackground(File(path)));
  final store = DriftSessionStore(db);
  final pragma = <String, Object?>{};
  final snapshots = <int, Map<String, Object?>>{};
  for (final mib in _sizesMiB) {
    snapshots[mib] = {'mib': mib};
  }
  final changes = <String, Object?>{'count': 20};
  try {
    for (final mode in ['NORMAL', 'FULL']) {
      await db.customStatement('PRAGMA synchronous = $mode');
      final row = await db.customSelect('PRAGMA synchronous').getSingle();
      pragma[mode] = row.data.values.first;
      for (final mib in _sizesMiB) {
        final entry = snapshots[mib]!;
        final text = largeJavaScript(mib * _mib);
        entry['chars'] = text.length;
        if (mode == 'NORMAL') {
          final digest = Stopwatch()..start();
          textDigest(text);
          entry['digestMs'] = digest.elapsedMilliseconds;
        }
        final times = <int>[];
        for (var version = 1; version <= 3; version += 1) {
          final clock = Stopwatch()..start();
          final written = await store.writeSnapshot(
            JournalSnapshot(
              workspaceId: 'largegate',
              path: 'large_${mib}mb.js',
              text: text,
              version: version,
              baseDigest: null,
              format: TextFormat.standard,
              language: 'javascript',
            ),
            restart: true,
          );
          times.add(clock.elapsedMilliseconds);
          expect(written.isOk, isTrue, reason: 'a $mib MiB snapshot ($mode)');
        }
        entry['${mode.toLowerCase()}Ms'] = times;
      }
      // One typed character at a time, as the journal appends them.
      const base = 1000;
      final times = <double>[];
      for (var i = 0; i < 20; i += 1) {
        final clock = Stopwatch()..start();
        final appended = await store.appendChange(
          'largegate',
          'large_1mb.js',
          JournalChange(
            baseVersion: 3 + i,
            version: 4 + i,
            lengthBefore: base + i,
            lengthAfter: base + i + 1,
            changes: [
              base + i,
              [0, 'x'],
            ],
          ),
        );
        times.add(clock.elapsedMicroseconds / 1000);
        expect(appended.isOk, isTrue, reason: 'a change ($mode)');
      }
      changes['${mode.toLowerCase()}Ms'] = times;
    }
  } finally {
    await store.close();
    _deleteDatabase(path);
  }
  return {
    'pragma': pragma,
    'snapshots': snapshots.values.toList(),
    'changes': changes,
  };
}

/// Prints [report] in numbered chunks: long lines are not safe in every log
/// path between the device and the gate's output file.
Future<void> _printReport(Map<String, Object?> report) async {
  final json = jsonEncode(report);
  const size = 800;
  final parts = (json.length / size).ceil();
  for (var i = 0; i < parts; i += 1) {
    final chunk = json.substring(
      i * size,
      math.min((i + 1) * size, json.length),
    );
    debugPrint('CODEFORGE_LARGE_JSON ${i + 1}/$parts $chunk');
  }
  // debugPrint is throttled: let the queue drain before the test ends.
  await debugPrintDone;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('large files: open, scroll, typing and memory', (tester) async {
    // A clean slate, a retried attempt included: no stored tabs (the app
    // database opens lazily, so it is not open yet), no files left behind.
    final filesDir = await applicationFilesPath();
    final workspace = await demoWorkspacePath();
    _deleteDatabase('$filesDir/$appDatabaseFileName');
    final gate = Directory('$filesDir/largegate');
    if (gate.existsSync()) {
      gate.deleteSync(recursive: true);
    }
    gate.createSync(recursive: true);
    final folder = Directory(workspace);
    if (folder.existsSync()) {
      for (final entity in folder.listSync()) {
        final name = entity.uri.pathSegments.last;
        if (entity is File && name.startsWith('large_')) {
          entity.deleteSync();
        }
      }
    }

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

    final files = container.read(fileServiceProvider);
    final documents = container.read(documentControllerProvider.notifier);
    final started = DateTime.now();
    final clock = Stopwatch()..start();
    // The page reports a document's undo history as soon as it has opened
    // and shown it (before it answers doc.open): the page side of an open.
    final shown = <String, int>{};
    final events = host.events.listen((event) {
      if (event is HistoryChanged) {
        shown.putIfAbsent(event.docId, () => clock.elapsedMilliseconds);
      }
    });
    addTearDown(events.cancel);

    final run = DateTime.now().millisecondsSinceEpoch;
    var step = 0;
    Future<void> ask(
      String request,
      String what, {
      Duration timeout = const Duration(minutes: 2),
    }) async {
      step += 1;
      final id = '$run.$step';
      Zone.root.print('LARGEGATE $id $request');
      final ok = File('${gate.path}/ack.$id.ok');
      final failed = File('${gate.path}/ack.$id.failed');
      await pumpUntil(
        tester,
        () => ok.existsSync() || failed.existsSync(),
        what: 'the DevTools driver to $what',
        timeout: timeout,
      );
      if (failed.existsSync()) {
        fail(
          'The DevTools driver could not $what '
          '(ci-results/gate/large_files_cdp.txt says why).',
        );
      }
    }

    final results = <Map<String, Object?>>[];
    var baselineAsked = false;
    for (final mib in _sizesMiB) {
      final names = ['large_${mib}mb.js', 'large_${mib}mb.txt'];
      final written = await _writeFiles(files, names, mib * _mib);
      for (final name in names) {
        await ask(
          'prepare $name${baselineAsked ? '' : ' memory'}',
          'prepare for $name',
        );
        baselineAsked = true;
        final since = DateTime.now();
        final openStart = clock.elapsedMilliseconds;
        final opened = await documents.open(name);
        final openReturned = clock.elapsedMilliseconds;
        expect(
          opened.isOk,
          isTrue,
          reason: 'opening $name: ${opened.failureOrNull?.message}',
        );
        final doc = container.read(documentControllerProvider).documents[name]!;
        await pumpUntil(
          tester,
          () => shown.containsKey(doc.docId),
          what: 'the page to show $name',
          timeout: const Duration(seconds: 90),
        );
        final pageShown = shown[doc.docId]!;
        final going = Stopwatch()..start();
        final went = await host.gotoLine(written.lines ~/ 2);
        final gotoMs = going.elapsedMilliseconds;
        expect(went.isOk, isTrue, reason: 'going to the middle of $name');
        _expectNoTrouble(since, 'opening $name');
        await tester.pump(const Duration(milliseconds: 500));

        await ask(
          'measure $name ${written.chars} ${written.lines} $_typed',
          'measure $name',
          timeout: const Duration(minutes: 4),
        );
        final syncing = Stopwatch()..start();
        await pumpUntil(
          tester,
          () =>
              (host.textOf(doc.docId)?.length ?? 0) >=
              written.chars + _typed.length,
          what: 'the typed text to reach the app',
        );
        final syncMs = syncing.elapsedMilliseconds;
        final typedArrived = host.textOf(doc.docId)!.contains(_typed);
        expect(typedArrived, isTrue, reason: 'the typed text in $name');
        final persisting = Stopwatch()..start();
        await documents.persisted;
        final persistMs = persisting.elapsedMilliseconds;
        final saving = Stopwatch()..start();
        final saved = await documents.save(name);
        final saveMs = saving.elapsedMilliseconds;
        expect(
          saved.isOk,
          isTrue,
          reason: 'saving $name: ${saved.failureOrNull?.message}',
        );
        documents.close(name);
        await pumpUntil(
          tester,
          () => host.textOf(doc.docId) == null,
          what: 'closing $name',
        );
        _expectNoTrouble(since, 'typing into, saving and closing $name');
        File('$workspace/$name').deleteSync();
        results.add({
          'file': name,
          'language': doc.language,
          'chars': written.chars,
          'lines': written.lines,
          'writeMs': written.writeMs[name],
          'openReturnMs': openReturned - openStart,
          'pageAnswerMs': pageShown - openReturned,
          'openMs': pageShown - openStart,
          'gotoMs': gotoMs,
          'typedArrived': typedArrived,
          'syncMs': syncMs,
          'persistMs': persistMs,
          'saveMs': saveMs,
        });
        debugPrint(
          'large-files: $name opened in ${pageShown - openStart} ms '
          '(app ${openReturned - openStart}, page ${pageShown - openReturned})'
          ', saved in $saveMs ms',
        );
      }
    }

    final store = await _storeTimings(filesDir);

    // The session the gate's release build restores: the demo with the
    // 1 MiB file open, stored as the active tab.
    await _writeFiles(files, const [_kept], _mib);
    final keptOpened = await documents.open(_kept);
    expect(keptOpened.isOk, isTrue, reason: 'opening $_kept again');
    final kept = container.read(documentControllerProvider).documents[_kept]!;
    await pumpUntil(
      tester,
      () => shown.containsKey(kept.docId),
      what: 'the page to show $_kept again',
      timeout: const Duration(seconds: 90),
    );
    await documents.persisted;
    final tabs =
        (await container.read(sessionStoreProvider).loadTabs('demo'))
            .valueOrNull ??
        const <SavedTab>[];
    expect(
      [
        for (final tab in tabs)
          if (tab.active) tab.path,
      ],
      [_kept],
      reason: 'the stored session',
    );

    step += 1;
    Zone.root.print('LARGEGATE $run.$step done');
    bool afterStart(LogRecord record) => !record.time.isBefore(started);
    final warnings = [
      for (final record in appLogger.records)
        if (afterStart(record) && record.level.index >= LogLevel.warn.index)
          '${record.tag} ${record.event} ${record.fields}',
    ];
    await _printReport({
      'schema': 1,
      'build': _build,
      'typed': _typed,
      'method': {
        'open':
            'documents.open (read, decode, doc.open built and sent) until '
            'the page reports the document shown (editor.history on '
            'activation); then cmd.gotoLine to the middle line',
        'sync':
            "from the driver's answer until the app's copy of the "
            'document has the typed text',
        'persist': 'the journal catching up after the typing',
        'save': 'documents.save: edits flushed, encoded, written atomically',
        'store':
            "a database of its own beside the app's: 3 snapshots per size "
            'and 20 one-character changes, synchronous NORMAL then FULL; '
            "digest: the journal's first-edit textDigest on the UI isolate",
      },
      'files': results,
      'store': store,
      'warnings': warnings,
      'leftOpen': _kept,
    });
  }, timeout: const Timeout(Duration(minutes: 14)));
}
