/// Phase 2 W3 on the CI emulator: one engine's benchmark page in the real
/// Android System WebView, driven through the real Settings → Developer →
/// Editor benchmark screen.
///
/// The phase gate runs this file once per engine (a fresh app process each,
/// so the memory numbers belong to one engine):
///   --dart-define=BENCH_ENGINE=codemirror|monaco
///   --dart-define=BENCH_RUNS=3            scripted runs (default 3)
///   --dart-define=BENCH_DRIVER=true       then hand the page to the DevTools
///                                         driver (editor/tool/bench_cdp.mjs)
/// The report is printed as CODEFORGE_BENCH_JSON lines that
/// editor/tool/bench_report.mjs reassembles into
/// ci-results/gate/editor_bench.json. Budget misses are information for
/// ADR-0004; the test fails only when the benchmark itself cannot run.
library;

import 'dart:math' as math;

import 'package:codeforge/application/bench/editor_bench_providers.dart';
import 'package:codeforge/application/bench/editor_bench_runner.dart';
import 'package:codeforge/design_system/theme/theme.dart';
import 'package:codeforge/features/settings/developer/editor_benchmark_screen.dart';
import 'package:codeforge/services/editor/bench/bench_pages.dart';
import 'package:codeforge/services/editor/bench/bench_surface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'smoke_test.dart' show pumpUntil;

const String _engine = String.fromEnvironment(
  'BENCH_ENGINE',
  defaultValue: 'codemirror',
);
const int _runs = int.fromEnvironment('BENCH_RUNS', defaultValue: 3);
const bool _driver = bool.fromEnvironment('BENCH_DRIVER');

/// Prints [json] in numbered chunks: long lines are not safe in every log
/// path between the device and the gate's output file.
Future<void> printReport(String engine, String json) async {
  const size = 800;
  final parts = (json.length / size).ceil();
  for (var i = 0; i < parts; i += 1) {
    final chunk = json.substring(
      i * size,
      math.min((i + 1) * size, json.length),
    );
    debugPrint('CODEFORGE_BENCH_JSON $engine ${i + 1}/$parts $chunk');
  }
  // debugPrint is throttled: let the queue drain before the test ends.
  await debugPrintDone;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('editor benchmark: $_engine', (tester) async {
    EditorBenchRunner? captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          editorBenchRunnerFactoryProvider.overrideWithValue(() {
            final runner = EditorBenchRunner(
              loadManifest: () => loadBenchManifest(rootBundle),
              loadPage: (info) => loadBenchPage(rootBundle, info),
              createSurface: WebViewBenchSurface.new,
            );
            captured = runner;
            return runner;
          }),
        ],
        child: MaterialApp(
          theme: CfTheme.dark(),
          home: const EditorBenchmarkScreen(),
        ),
      ),
    );
    final runner = captured!;
    await pumpUntil(
      tester,
      () => runner.phase != BenchPhase.loading,
      what: 'the benchmark manifest',
    );
    expect(runner.phase, BenchPhase.idle, reason: runner.message);
    expect(runner.engines, contains(_engine));

    var finished = false;
    final watch = Stopwatch()..start();
    runner.runAll(only: [_engine], runsPerEngine: _runs).whenComplete(() {
      finished = true;
    }).ignore();
    await pumpUntil(
      tester,
      () => finished,
      what: 'the $_engine benchmark runs',
      timeout: const Duration(minutes: 12),
    );
    debugPrint(
      'editor-bench: $_engine ${runner.runs.length}/$_runs runs in '
      '${watch.elapsed.inSeconds} s',
    );

    if (_driver) {
      var driven = false;
      runner
          .driverPhase(_engine, timeout: const Duration(minutes: 4))
          .whenComplete(() {
            driven = true;
          })
          .ignore();
      await pumpUntil(
        tester,
        () => driven,
        what: 'the DevTools driver phase',
        timeout: const Duration(minutes: 5),
      );
    }

    await printReport(_engine, runner.reportJson());

    expect(runner.errors, isEmpty, reason: runner.errors.join('\n'));
    expect(runner.runs, hasLength(_runs));
    final summary = runner.summary()[_engine];
    if (summary is! Map<String, Object?>) {
      fail('no summary for $_engine');
    }
    expect(summary['featuresOk'], isTrue, reason: 'scope checks');
    expect(summary['highlightOk'], isTrue, reason: 'highlighting');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
