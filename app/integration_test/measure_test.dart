/// The W6 measurements on the emulator (PHASE_3_PLAN W6, gate G7),
/// recorded as evidence and never judged here: as in Phase 2, frame-timed
/// numbers are judged on a phone. Each prints a `measure gate:` line, and
/// the test ends with the whole report as `MEASURE_JSON <part>/<parts>`
/// lines, which the gate script joins into measure.json.
/// 1. A project of 10,000 files (10 folders of 10 folders of 100 files):
///    opening it, which lists its root, and building Go to File's index of
///    every file.
/// 2. Writing and reading 1 and 10 MiB of text in that project, through
///    the file service the app saves and opens with (`dart:io`).
/// 3. The gate folder, picked in Android's real picker: listing its folder
///    `many`, which the gate script fills with 1,000 files, and writing and
///    reading 1 and 10 MiB through the storage broker (Android's storage
///    access framework).
/// 4. Frames while a 10 MiB text is digested: on the UI isolate, as before
///    W6, and on a background isolate (core/editor/journal.dart).
/// Times are medians of three runs, with every run kept.
library;

import 'dart:convert';
import 'dart:io';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/file_index.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/workspace_switcher.dart';
import 'package:codeforge/core/editor/journal.dart';
import 'package:codeforge/core/editor/large_samples.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/storage/drift_session_store.dart'
    show appDatabaseFileName;
import 'package:flutter/scheduler.dart';
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

/// The folder the gate script fills, and how many files it holds.
const String _many = 'many';
const int _manyFiles = 1000;

/// The project's shape: 10 × 10 folders of 100 files.
const int _top = 10;
const int _sub = 10;
const int _perFolder = 100;
const int _projectFiles = _top * _sub * _perFolder;

int _median(List<int> values) => ([...values]..sort())[values.length ~/ 2];

/// [once] timed [_runs] times, in milliseconds.
Future<List<int>> _timed(Future<void> Function(int run) once) async {
  final times = <int>[];
  for (var run = 0; run < _runs; run++) {
    final watch = Stopwatch()..start();
    await once(run);
    times.add(watch.elapsedMilliseconds);
  }
  return times;
}

Map<String, Object> _timing(List<int> times) => {
  'medianMs': _median(times),
  'runsMs': times,
};

void _say(String line) => debugPrint('measure gate: $line');

/// Writes and reads [text] as [path] through [files], [_runs] times each:
/// the app's save and open, byte for byte.
Future<Map<String, Object>> _readWrite(
  FileService files,
  String path,
  String text,
  String label,
) async {
  final writes = await _timed((_) async {
    final wrote = await files.writeText(path, text);
    expect(wrote.isOk, isTrue, reason: '$label: write $path: $wrote');
  });
  final reads = await _timed((_) async {
    final read = await files.readText(path);
    expect(
      read.valueOrNull?.text.length,
      text.length,
      reason: '$label: read $path: $read',
    );
  });
  _say(
    '$label ${text.length} chars: write ${_median(writes)} ms, '
    'read ${_median(reads)} ms (medians of $_runs)',
  );
  return {
    'chars': text.length,
    'write': _timing(writes),
    'read': _timing(reads),
  };
}

/// Frames the UI isolate drew while [work] ran, and the longest stretch
/// without one. Frames are asked for one after the other all along.
Future<Map<String, Object>> _framesWhile(
  WidgetTester tester,
  Future<void> Function() work,
) async {
  final binding = tester.binding as LiveTestWidgetsFlutterBinding;
  final policy = binding.framePolicy;
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final clock = Stopwatch()..start();
  final stamps = <Duration>[];
  var asking = true;
  void onFrame(Duration _) {
    stamps.add(clock.elapsed);
    if (asking) {
      SchedulerBinding.instance.scheduleFrameCallback(onFrame);
    }
  }

  SchedulerBinding.instance.scheduleFrameCallback(onFrame);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final start = clock.elapsed;
  await work();
  final end = clock.elapsed;
  asking = false;
  await Future<void>.delayed(const Duration(milliseconds: 200));
  binding.framePolicy = policy;
  final during = [
    for (final stamp in stamps)
      if (stamp >= start && stamp <= end) stamp,
  ];
  var longest = Duration.zero;
  var last = start;
  for (final stamp in [...during, end]) {
    if (stamp - last > longest) {
      longest = stamp - last;
    }
    last = stamp;
  }
  return {
    'ms': (end - start).inMilliseconds,
    'frames': during.length,
    'longestGapMs': longest.inMilliseconds,
  };
}

/// [report] as lines of at most 600 characters, for the gate to join.
void _printReport(Map<String, Object> report) {
  final json = jsonEncode(report);
  const size = 600;
  final parts = (json.length + size - 1) ~/ size;
  for (var part = 0; part < parts; part++) {
    final end = (part + 1) * size;
    debugPrint(
      'MEASURE_JSON ${part + 1}/$parts '
      '${json.substring(part * size, end > json.length ? json.length : end)}',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'measurements: 10,000-file project, 1 and 10 MiB, 1,000-entry folder, '
    'frames during a 10 MiB digest',
    timeout: const Timeout(Duration(minutes: 15)),
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
      final switcher = container.read(workspaceSwitcherProvider);
      final report = <String, Object>{
        'schema': 1,
        'kind': 'codeforge-measurements',
        'runs': _runs,
      };

      // ── 1. A project of 10,000 files ──────────────────────────────────
      final created = await switcher.createProject('perf10k');
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
              ).writeAsString('// m$m/s$s/f$f\n'),
          ]);
        }
      }
      _say(
        'project of $_projectFiles files written in ${fill.elapsedMilliseconds} ms (setup)',
      );

      final open = Stopwatch()..start();
      final opened = await switcher.open(project);
      final openMs = open.elapsedMilliseconds;
      expect(opened.isOk, isTrue, reason: 'open the project: $opened');
      expect(container.read(currentWorkspaceProvider), project);

      final index = container.read(fileIndexProvider.notifier);
      final indexTimes = <int>[];
      var indexed = 0;
      for (var run = 0; run < _runs; run++) {
        final watch = Stopwatch()..start();
        await index.rebuild();
        indexTimes.add(watch.elapsedMilliseconds);
        final state = container.read(fileIndexProvider);
        expect(state.status, FileIndexStatus.ready, reason: 'index run $run');
        indexed = state.files.length;
      }
      expect(indexed, _projectFiles);
      _say('project opened in $openMs ms (root listed)');
      _say(
        "Go to File's index of $indexed files in ${_median(indexTimes)} ms "
        '(median of $_runs: ${indexTimes.join(', ')})',
      );
      report['project'] = {
        'files': _projectFiles,
        'folders': 1 + _top + _top * _sub,
        'openMs': openMs,
        'index': {'files': indexed, ..._timing(indexTimes)},
      };

      // ── 2. 1 and 10 MiB through dart:io, in the project ───────────────
      final oneMiB = largeJavaScript(largeSampleChars(1));
      final tenMiB = largeJavaScript(largeSampleChars(10));
      final projectFiles = container.read(fileServiceProvider);
      report['projectIo'] = {
        '1MiB': await _readWrite(
          projectFiles,
          'io_1mib.txt',
          oneMiB,
          'dart:io',
        ),
        '10MiB': await _readWrite(
          projectFiles,
          'io_10mib.txt',
          tenMiB,
          'dart:io',
        ),
      };

      // ── 4. Frames while 10 MiB is digested ────────────────────────────
      // Here, before the picker: nothing else is going on.
      late final String inline;
      final before = await _framesWhile(tester, () async {
        inline = await digestTextInline(tenMiB);
      });
      late final String background;
      final after = await _framesWhile(tester, () async {
        background = await digestText(tenMiB);
      });
      expect(background, inline);
      _say(
        'digest of 10 MiB on the UI isolate: ${before['ms']} ms, '
        "${before['frames']} frames, longest without one "
        "${before['longestGapMs']} ms",
      );
      _say(
        'digest of 10 MiB on a background isolate: ${after['ms']} ms, '
        "${after['frames']} frames, longest without one "
        "${after['longestGapMs']} ms",
      );
      report['digest10MiB'] = {
        'chars': tenMiB.length,
        'uiIsolate': before,
        'background': after,
      };

      // ── 3. The gate folder, through Android's picker and provider ─────
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
      final folderFiles = container.read(fileServiceProvider);
      var listed = 0;
      final listTimes = await _timed((_) async {
        final listing = await folderFiles.listDirectory(_many);
        listed = listing.valueOrNull?.length ?? -1;
        expect(listed, _manyFiles, reason: 'list $_many: $listing');
      });
      _say(
        'listing $listed entries through the broker: '
        '${_median(listTimes)} ms (median of $_runs: ${listTimes.join(', ')})',
      );
      report['folderList'] = {'entries': listed, ..._timing(listTimes)};
      report['folderIo'] = {
        '1MiB': await _readWrite(folderFiles, 'io_1mib.txt', oneMiB, 'broker'),
        '10MiB': await _readWrite(
          folderFiles,
          'io_10mib.txt',
          tenMiB,
          'broker',
        ),
      };

      _printReport(report);
      gate.done();
    },
  );
}
