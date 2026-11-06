/// The engine benchmark runner (Phase 2 W3) against scripted pages: run
/// order, results, failures that must surface, typing checks and the hand
/// over to the phase gate's DevTools driver.
library;

import 'dart:convert';

import 'package:codeforge/application/bench/editor_bench_runner.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/editor/bench/bench_pages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_bench_surface.dart';

void main() {
  group('helpers', () {
    test('engines alternate so neither always runs first', () {
      expect(alternatingOrder(['a', 'b'], 3), ['a', 'b', 'b', 'a', 'a', 'b']);
      expect(alternatingOrder(['a'], 2), ['a', 'a']);
      expect(alternatingOrder(['a', 'b'], 0), isEmpty);
    });

    test('median and nested numbers', () {
      expect(median([3, 1, 2]), 2);
      expect(median([4, 1, 3, 2]), 2); // lower middle
      expect(median([]), isNull);
      final json = <String, Object?>{
        'a': {'b': 1.5, 'c': 'x'},
      };
      expect(numAt(json, ['a', 'b']), 1.5);
      expect(numAt(json, ['a', 'c']), isNull);
      expect(numAt(json, ['a', 'b', 'c']), isNull);
    });
  });

  group('EditorBenchRunner', () {
    test('a build without pages is unavailable, and says why', () async {
      final runner = fakeBenchRunner();
      await runner.init();
      expect(runner.phase, BenchPhase.unavailable);
      expect(runner.message, contains('no benchmark pages'));
      runner.dispose();
    });

    test('a broken manifest is unavailable and recorded', () async {
      final runner = EditorBenchRunner(
        loadManifest: () async =>
            const Err(BridgeFailure('The benchmark manifest is malformed.')),
        loadPage: (info) async => Ok(BenchPage(info: info, html: '')),
        createSurface: FakeBenchSurface.new,
        settle: () async {},
      );
      await runner.init();
      expect(runner.phase, BenchPhase.unavailable);
      expect(runner.errors.single, contains('malformed'));
      runner.dispose();
    });

    test('runs every engine in fresh pages and summarizes', () async {
      final surfaces = <FakeBenchSurface>[];
      final runner = fakeBenchRunner(
        engines: ['codemirror', 'monaco'],
        onSurface: surfaces.add,
      );
      await runner.init();
      expect(runner.phase, BenchPhase.idle);
      await runner.runAll(runsPerEngine: 2);

      expect(runner.phase, BenchPhase.idle);
      expect(runner.errors, isEmpty);
      expect([for (final run in runner.runs) run['engine']], [
        'codemirror',
        'monaco',
        'monaco',
        'codemirror',
      ]);
      // One fresh page per run, each closed again.
      expect(surfaces, hasLength(4));
      expect(surfaces.every((s) => s.disposed), isTrue);
      expect(runner.surface, isNull);
      expect(runner.pageErrors, contains('codemirror: noted'));

      final summary = runner.summary();
      expect(summary.keys, ['codemirror', 'monaco']);
      final monaco = summary['monaco']! as Map<String, Object?>;
      expect(monaco['runs'], 2);
      expect(monaco['featuresOk'], isTrue);
      expect(monaco['highlightOk'], isTrue);
      expect((monaco['medians']! as Map<String, Object?>)['readyMs'], 300);

      final report = jsonDecode(runner.reportJson()) as Map<String, Object?>;
      expect(report['kind'], 'codeforge-editor-bench');
      expect(report['build'], 'debug');
      expect(report['runs'], hasLength(4));
      runner.dispose();
    });

    test('runs only the requested engine', () async {
      final runner = fakeBenchRunner(engines: ['codemirror', 'monaco']);
      await runner.init();
      await runner.runAll(only: ['monaco'], runsPerEngine: 2);
      expect([for (final run in runner.runs) run['engine']], [
        'monaco',
        'monaco',
      ]);
      runner.dispose();
    });

    test('a page that never starts is an error, not a hang', () async {
      final runner = fakeBenchRunner(
        engines: ['monaco'],
        surface: () => FakeBenchSurface(startPage: false),
        readyTimeout: const Duration(milliseconds: 50),
      );
      await runner.init();
      await runner.runAll(runsPerEngine: 1);
      expect(runner.runs, isEmpty);
      expect(runner.errors.single, contains('did not start'));
      expect(runner.phase, BenchPhase.idle);
      runner.dispose();
    });

    test('a page that fails verification is reported', () async {
      final runner = EditorBenchRunner(
        loadManifest: () async => Ok([fakeBenchPageInfo('monaco')]),
        loadPage: (info) async => const Err(
          BridgeFailure(
            'The monaco benchmark page does not match its manifest.',
          ),
        ),
        createSurface: FakeBenchSurface.new,
        settle: () async {},
      );
      await runner.init();
      await runner.runAll(runsPerEngine: 1);
      expect(runner.errors.single, contains('does not match'));
      expect(runner.runs, isEmpty);
      runner.dispose();
    });

    test('typing check compares the document with the phrase', () async {
      final surfaces = <FakeBenchSurface>[];
      final runner = fakeBenchRunner(
        engines: ['codemirror'],
        onSurface: surfaces.add,
      );
      await runner.init();
      await runner.openTyping('codemirror');
      expect(runner.phase, BenchPhase.typing);
      final page = surfaces.single;
      expect(page.scripts, contains('window.codeforgeBench.startTyping();'));

      final phrase = benchPhrases.firstWhere((p) => p.id == 'emoji');
      page.typed = phrase.text;
      final match = await runner.checkTyping(phrase);
      expect(match?['match'], isTrue);
      expect(match?['phrase'], 'emoji');

      page.typed = 'ok done';
      final differs = await runner.checkTyping(phrase);
      expect(differs?['match'], isFalse);
      expect(runner.typingChecks, hasLength(2));

      await runner.closeTyping();
      expect(runner.phase, BenchPhase.idle);
      expect(page.disposed, isTrue);
      runner.dispose();
    });

    test('hands the page to the driver and waits for it', () async {
      final runner = fakeBenchRunner(engines: ['monaco']);
      await runner.init();
      expect(await runner.driverPhase('monaco'), isTrue);
      expect(runner.driverPhases.single['completed'], isTrue);
      expect(runner.phase, BenchPhase.idle);
      runner.dispose();
    });

    test('no driver within the timeout is recorded, not fatal', () async {
      final runner = fakeBenchRunner(
        engines: ['monaco'],
        surface: () => FakeBenchSurface(answerDriver: false),
      );
      await runner.init();
      final done = await runner.driverPhase(
        'monaco',
        timeout: const Duration(milliseconds: 50),
      );
      expect(done, isFalse);
      expect(runner.driverPhases.single['completed'], isFalse);
      expect(runner.phase, BenchPhase.idle);
      runner.dispose();
    });
  });
}
