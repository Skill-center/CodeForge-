/// Settings → Developer (Phase 2 W3), present in debug and profile builds:
/// the editor engine benchmark and the frame timing screen, driven over
/// scripted benchmark pages (test/support/fake_bench_surface.dart).
library;

import 'dart:convert';

import 'package:codeforge/application/bench/editor_bench_runner.dart';
import 'package:codeforge/application/bench/large_test_files.dart';
import 'package:codeforge/core/editor/large_samples.dart';
import 'package:codeforge/features/settings/developer/editor_benchmark_screen.dart';
import 'package:codeforge/features/settings/developer/frame_timing_screen.dart';
import 'package:codeforge/services/perf/frame_stats.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_bench_surface.dart';
import 'test_harness.dart';

/// Records clipboard writes instead of reaching the platform.
List<String> _clipboard(WidgetTester tester) {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      final arguments = call.arguments as Map<Object?, Object?>;
      copied.add(arguments['text']! as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return copied;
}

/// The benchmark screen's results text.
String _results(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('bench_results')),
        matching: find.byType(Text),
      ),
    )
    .data!;

Widget _benchScreen({
  List<String> engines = const ['codemirror', 'monaco'],
  void Function(FakeBenchSurface surface)? onSurface,
}) => TestHarness(
  benchRunnerFactory: fakeBenchRunnerFactory(
    engines: engines,
    onSurface: onSurface,
  ),
).wrap(const EditorBenchmarkScreen());

void main() {
  testWidgets('settings lists the developer tools in this build', (
    tester,
  ) async {
    setSurface(tester, 412, 1400);
    await tester.pumpWidget(
      TestHarness(shell: const ShellState(lastRoute: '/settings')).app(),
    );
    await tester.pumpAndSettle();
    expect(find.text('DEVELOPER'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings_frame_timing')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings_large_files')), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('settings_editor_benchmark')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings_editor_benchmark')));
    await tester.pumpAndSettle();
    expect(find.byType(EditorBenchmarkScreen), findsOneWidget);
    // The harness build carries no benchmark pages, like a plain debug run.
    expect(find.textContaining('no benchmark pages'), findsOneWidget);
    expect(find.byKey(const ValueKey('bench_run')), findsNothing);

    // Let the shell's debounced route persistence fire before teardown.
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets("Create large test files writes the gate's seven files", (
    tester,
  ) async {
    setSurface(tester, 412, 1400);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/settings'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('settings_large_files'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(
      find.textContaining("The large-file gate's 7 files"),
      findsOneWidget,
    );

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('Wrote 7 files to $largeTestFolder/'), findsOneWidget);
    expect(find.textContaining('Wrote 7 files ('), findsOneWidget);
    expect(harness.files.writes, [
      for (final sample in largeSamples) '$largeTestFolder/${sample.name}',
    ]);
    // Byte for byte what the generator makes, whose digests
    // test/core/large_samples_test.dart pins.
    final digests = <int, Digest>{};
    for (final sample in largeSamples) {
      final bytes = harness.files.bytesOf('$largeTestFolder/${sample.name}')!;
      final expected = digests.putIfAbsent(
        sample.chars,
        () => sha256.convert(utf8.encode(largeJavaScript(sample.chars))),
      );
      expect(sha256.convert(bytes), expected, reason: sample.name);
    }

    // Again: the files are replaced, not refused.
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(harness.files.writes, hasLength(14));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('benchmark runs both engines and shows the medians', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final copied = _clipboard(tester);
    final surfaces = <FakeBenchSurface>[];
    await tester.pumpWidget(_benchScreen(onSurface: surfaces.add));
    await tester.pumpAndSettle();
    expect(find.textContaining('codemirror and monaco'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bench_run')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Finished 6 of 6 runs'), findsOneWidget);
    expect(surfaces, hasLength(6));
    expect(surfaces.every((s) => s.disposed), isTrue);
    final results = _results(tester);
    expect(results, contains('CodeMirror (3 runs'));
    expect(results, contains('Monaco (3 runs'));
    expect(results, matches(RegExp(r'first frame +300\.0 ms')));
    expect(
      results,
      contains(
        'as plain text    40.0 ms open, typing p95 18.0 ms, '
        'scroll >32 ms 0.5 %',
      ),
    );

    await tester.tap(find.byKey(const ValueKey('bench_copy')));
    await tester.pump();
    expect(copied.single, contains('"kind":"codeforge-editor-bench"'));
  });

  testWidgets('typing check uses the engine page and the phrase', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final surfaces = <FakeBenchSurface>[];
    await tester.pumpWidget(_benchScreen(onSurface: surfaces.add));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Monaco'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bench_typing')));
    await tester.pumpAndSettle();
    final page = surfaces.single;
    expect(page.engine, 'monaco');
    expect(
      find.byKey(const ValueKey('fake_bench_view_monaco')),
      findsOneWidget,
    );
    final phrase = tester.widget<SelectableText>(
      find.byKey(const ValueKey('bench_phrase_text')),
    );
    expect(phrase.data, benchPhrases.first.text);
    // The person is told what to do, and nothing is judged yet.
    expect(find.byKey(const ValueKey('bench_typing_help')), findsOneWidget);
    expect(find.byKey(const ValueKey('bench_typing_result')), findsNothing);

    page.typed = 'const';
    await tester.tap(find.byKey(const ValueKey('bench_check')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('bench_typing_result')))
          .data,
      'Differs at character 0. The editor has: "const"',
    );

    page.typed = benchPhrases.first.text;
    await tester.tap(find.byKey(const ValueKey('bench_check')));
    await tester.pumpAndSettle();
    expect(find.textContaining('match.'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('bench_typing_result')))
          .data,
      'Match',
    );

    await tester.tap(find.byKey(const ValueKey('bench_typing_done')));
    await tester.pumpAndSettle();
    expect(page.disposed, isTrue);
    expect(
      _results(tester),
      contains(
        'typing monaco code: match (editcontext, input p95 14.5 ms over 26)',
      ),
    );
  });

  testWidgets('frame timing shows, copies and resets the recording', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final copied = _clipboard(tester);
    final recorder = FrameStatsRecorder();
    for (var i = 0; i < 9; i += 1) {
      recorder.record(
        const FrameSample(
          buildMicros: 4000,
          rasterMicros: 5000,
          totalMicros: 10000,
        ),
      );
    }
    recorder.record(
      const FrameSample(
        buildMicros: 30000,
        rasterMicros: 5000,
        totalMicros: 40000,
      ),
    );
    await tester.pumpWidget(
      TestHarness().wrap(FrameTimingScreen(recorder: recorder)),
    );
    await tester.pump();
    expect(find.text('10'), findsOneWidget);
    expect(find.text('1 (10.0 %)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('frames_copy')));
    await tester.pump();
    expect(copied.single, contains('"kind":"codeforge-frame-timing"'));
    expect(copied.single, contains('"over32Pct":10.0'));

    await tester.tap(find.byKey(const ValueKey('frames_reset')));
    await tester.pump();
    expect(recorder.length, 0);
    expect(find.text('0 (0.0 %)'), findsOneWidget);
  });
}
