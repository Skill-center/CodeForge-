/// The terminal's measurements (Phase 5 W6, gate G6: ADR-0006's budgets as
/// xterm.js's), shared by the emulator gate's terminal group
/// (terminal_test.dart) and Test Lab's phone (phone_terminal_test.dart).
///
/// - **Echo:** the page's probe (editor/src/terminal/probe.ts) types
///   characters into a session at its prompt the way an input method's
///   commit reaches the page, and times each from that input to the end of
///   the frame that draws its echo; within 50 ms at the 95th percentile.
/// - **The flood:** 10 MiB from python3 in the session (81,920 lines of 128
///   bytes, coloured), between two marks the page looks for. It arrives
///   whole when the page counted and hashed exactly what the test expects
///   (FNV-1a over the text as the terminal shows it, each line break as CR
///   LF). Meanwhile a progress bar laid over the app keeps Flutter drawing
///   every frame, as an animated UI would, and Flutter's own frame timings
///   are collected: frames over 32 ms, vsync to the end of raster, stay
///   under 5 %. The page's frames and long tasks are recorded beside them.
/// - **Memory:** the app's PSS and its WebView renderers' (`dumpsys
///   meminfo`, taken by the gate's host or, on Test Lab, by the
///   instrumentation's shell), before the first terminal and after the
///   flood; the terminal's delta within 80 MB.
/// - **The renderer:** each is measured with xterm.js's DOM renderer and
///   with WebGL (addon-webgl), then the DOM's again.
library;

import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FramePhase;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/terminal/terminal_view.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/terminal/terminal_protocol.dart'
    show terminalRenderers;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'smoke_test.dart' show pumpUntil;

/// ADR-0006's budgets.
const double echoBudgetMs = 50;
const double slowFrameMs = 32;
const double slowFrameBudgetPct = 5;
const double memoryBudgetMb = 80;

/// A frame this long is a frozen one (Android vitals: over 700 ms).
const double frozenFrameMs = 700;

/// The marks around the flood: operating-system commands xterm.js ignores,
/// with control characters no echoed command line holds.
const String floodBegin = '\x1b]777;cf-flood-begin\x07';
const String floodEnd = '\x1b]777;cf-flood-end\x07';

/// 81,920 lines of 128 bytes: 10 MiB.
const int floodLines = 81920;
const int floodBytes = floodLines * 128;

/// The flood's program, written into the session's folder as [floodFile].
const String floodFile = '.cf-flood.py';
const String floodScript = r'''
import sys
B = '\x1b]777;cf-flood-begin\x07'
E = '\x1b]777;cf-flood-end\x07'
A = 'abcdefghijklmnopqrstuvwxyz' * 6
out = [B]
for i in range(81920):
    out.append('\x1b[3%dm%07d\x1b[0m %s\n' % (i % 8, i, A[i % 26:i % 26 + 110]))
out.append(E)
sys.stdout.buffer.write(''.join(out).encode())
sys.stdout.buffer.flush()
''';

const String _alphabet = 'abcdefghijklmnopqrstuvwxyz';

/// Line [i] as the terminal shows it: the program's, its line break as CR LF.
String floodLine(int i) {
  final letters = _alphabet * 6;
  final start = i % 26;
  return '\x1b[3${i % 8}m${i.toString().padLeft(7, '0')}\x1b[0m '
      '${letters.substring(start, start + 110)}\r\n';
}

/// What the page must count between the marks: characters and FNV-1a.
({int chars, String hash}) floodExpected() {
  var hash = 0x811c9dc5;
  var chars = 0;
  for (var i = 0; i < floodLines; i++) {
    final line = floodLine(i);
    for (var j = 0; j < line.length; j++) {
      hash = ((hash ^ line.codeUnitAt(j)) * 0x01000193) & 0xffffffff;
    }
    chars += line.length;
  }
  return (chars: chars, hash: hash.toRadixString(16).padLeft(8, '0'));
}

double _round1(num value) => (value * 10).round() / 10;

/// Nearest-rank percentile of [values] (q in 0..1), as the page's stats.
double percentile(List<double> values, double q) {
  if (values.isEmpty) {
    return 0;
  }
  final sorted = [...values]..sort();
  final rank = math.max(1, (q * sorted.length).ceil());
  return sorted[math.min(rank, sorted.length) - 1];
}

double _number(Object? value) => value is num ? value.toDouble() : 0;
int _integer(Object? value) => value is num ? value.toInt() : 0;
Map<String, Object?> _object(Object? value) =>
    value is Map<String, Object?> ? value : const {};

/// The app's and its renderers' PSS, in KiB (`dumpsys meminfo`).
final class MemorySample {
  const MemorySample({
    required this.label,
    required this.appKb,
    required this.rendererKb,
    required this.renderers,
  });

  /// From the gate's answer: `app:<kb>,renderer:<kb>,renderers:<n>,...`.
  factory MemorySample.parse(String label, String answer) {
    final fields = <String, int>{};
    for (final part in answer.split(',')) {
      final at = part.indexOf(':');
      if (at > 0) {
        fields[part.substring(0, at)] =
            int.tryParse(part.substring(at + 1)) ?? -1;
      }
    }
    final app = fields['app'] ?? -1;
    final renderer = fields['renderer'] ?? -1;
    if (app <= 0 || renderer < 0) {
      fail('The memory sample "$label" came back as "$answer".');
    }
    return MemorySample(
      label: label,
      appKb: app,
      rendererKb: renderer,
      renderers: fields['renderers'] ?? 0,
    );
  }

  final String label;
  final int appKb;
  final int rendererKb;
  final int renderers;

  int get totalKb => appKb + rendererKb;

  double megabytes(int kb) => _round1(kb / 1024);

  Map<String, Object?> toJson() => {
    'appMb': megabytes(appKb),
    'rendererMb': megabytes(rendererKb),
    'renderers': renderers,
    'totalMb': megabytes(totalKb),
  };
}

/// The echo probe's figures (probe.ts's EchoFigures).
final class EchoFigures {
  EchoFigures(this.renderer, Map<String, Object?> echo)
    : count = _integer(echo['count']),
      typed = _integer(echo['typed']),
      lost = _integer(echo['lost']),
      p50Ms = _number(echo['p50Ms']),
      p95Ms = _number(echo['p95Ms']),
      maxMs = _number(echo['maxMs']),
      meanMs = _number(echo['meanMs']);

  final String renderer;
  final int count;
  final int typed;
  final int lost;
  final double p50Ms;
  final double p95Ms;
  final double maxMs;
  final double meanMs;

  bool get underBudget => lost == 0 && count > 0 && p95Ms <= echoBudgetMs;

  Map<String, Object?> toJson() => {
    'renderer': renderer,
    'typed': typed,
    'count': count,
    'lost': lost,
    'p50Ms': p50Ms,
    'p95Ms': p95Ms,
    'maxMs': maxMs,
    'meanMs': meanMs,
  };

  String line() =>
      'renderer=$renderer n=$count lost=$lost p50_ms=$p50Ms p95_ms=$p95Ms '
      'max_ms=$maxMs mean_ms=$meanMs';
}

/// Flutter's frames while the flood ran.
final class UiFrames {
  factory UiFrames(List<FrameTiming> timings, {required bool windowed}) {
    double ms(Duration duration) => duration.inMicroseconds / 1000;
    final totals = [for (final t in timings) ms(t.totalSpan)];
    final starts = [
      for (final t in timings) t.timestampInMicroseconds(FramePhase.vsyncStart),
    ]..sort();
    var longestGap = 0.0;
    for (var i = 1; i < starts.length; i++) {
      longestGap = math.max(longestGap, (starts[i] - starts[i - 1]) / 1000);
    }
    return UiFrames._(
      frames: timings.length,
      slow: totals.where((total) => total > slowFrameMs).length,
      frozen: totals.where((total) => total > frozenFrameMs).length,
      windowed: windowed,
      p95TotalMs: _round1(percentile(totals, 0.95)),
      maxTotalMs: _round1(totals.fold<double>(0, math.max)),
      p95BuildMs: _round1(
        percentile([for (final t in timings) ms(t.buildDuration)], 0.95),
      ),
      p95RasterMs: _round1(
        percentile([for (final t in timings) ms(t.rasterDuration)], 0.95),
      ),
      longestGapMs: _round1(longestGap),
    );
  }

  const UiFrames._({
    required this.frames,
    required this.slow,
    required this.frozen,
    required this.windowed,
    required this.p95TotalMs,
    required this.maxTotalMs,
    required this.p95BuildMs,
    required this.p95RasterMs,
    required this.longestGapMs,
  });

  final int frames;

  /// Frames over [slowFrameMs], vsync to the end of raster.
  final int slow;

  /// Frames over [frozenFrameMs].
  final int frozen;

  /// Whether the frames were cut to the flood's window (false: every frame
  /// reported meanwhile, when the clocks could not be matched).
  final bool windowed;
  final double p95TotalMs;
  final double maxTotalMs;
  final double p95BuildMs;
  final double p95RasterMs;

  /// The longest stretch between two frames' vsyncs.
  final double longestGapMs;

  double get slowPct => frames == 0 ? 0 : _round1(slow * 100 / frames);

  bool get underBudget =>
      frames > 0 && slowPct < slowFrameBudgetPct && frozen == 0;

  Map<String, Object?> toJson() => {
    'frames': frames,
    'slowFrames': slow,
    'slowFramePct': slowPct,
    'frozenFrames': frozen,
    'p95TotalMs': p95TotalMs,
    'maxTotalMs': maxTotalMs,
    'p95BuildMs': p95BuildMs,
    'p95RasterMs': p95RasterMs,
    'longestGapMs': longestGapMs,
    'windowed': windowed,
  };
}

/// The flood probe's figures (probe.ts's FloodFigures) and Flutter's frames.
final class FloodFigures {
  FloodFigures({
    required this.renderer,
    required Map<String, Object?> flood,
    required this.ui,
    required this.wallMs,
    required ({int chars, String hash}) expected,
  }) : chars = _integer(flood['chars']),
       hash = flood['hash'] is String ? flood['hash']! as String : '',
       writes = _integer(flood['writes']),
       maxWriteChars = _integer(flood['maxWriteChars']),
       ms = _number(flood['ms']),
       pageFrames = _object(flood['frames']),
       longTasks = _object(flood['longTasks']),
       whole = _integer(flood['chars']) == expected.chars &&
           flood['hash'] == expected.hash;

  final String renderer;
  final int chars;
  final String hash;
  final int writes;
  final int maxWriteChars;

  /// From the write with the first mark to the frame after the last.
  final double ms;

  /// From the command's Enter to the page's report, on the test's clock.
  final int wallMs;
  final Map<String, Object?> pageFrames;
  final Map<String, Object?> longTasks;
  final UiFrames ui;
  final bool whole;

  double get pageSlowPct => _number(pageFrames['slowFramePct']);

  /// Mebibytes a second, from the first mark to the last frame.
  double get mibPerSecond =>
      ms <= 0 ? 0 : _round1(floodBytes / (1024 * 1024) / (ms / 1000));

  Map<String, Object?> toJson() => {
    'renderer': renderer,
    'whole': whole,
    'chars': chars,
    'hash': hash,
    'writes': writes,
    'maxWriteChars': maxWriteChars,
    'ms': ms,
    'mibPerSecond': mibPerSecond,
    'wallMs': wallMs,
    'page': {'frames': pageFrames, 'longTasks': longTasks},
    'ui': ui.toJson(),
  };

  String line() =>
      'renderer=$renderer whole=${whole ? 1 : 0} chars=$chars hash=$hash '
      'ms=$ms mib_s=$mibPerSecond writes=$writes max_write=$maxWriteChars '
      'ui_frames=${ui.frames} ui_slow=${ui.slow} ui_slow_pct=${ui.slowPct} '
      'ui_frozen=${ui.frozen} ui_p95_ms=${ui.p95TotalMs} '
      'ui_max_ms=${ui.maxTotalMs} ui_gap_ms=${ui.longestGapMs} '
      'page_frames=${pageFrames['frames']} '
      'page_slow_pct=$pageSlowPct page_max_ms=${pageFrames['maxFrameMs']} '
      'long_tasks=${longTasks['count']} long_ms=${longTasks['totalMs']}';
}

/// The page's probe report once it is no longer running.
Future<Map<String, Object?>> _probeOutcome(
  TerminalView view, {
  required Duration timeout,
  required String what,
}) async {
  final watch = Stopwatch()..start();
  Map<String, Object?>? last;
  while (watch.elapsed < timeout) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final read = await view.readProbe();
    if (read case Ok(:final value)) {
      last = value;
      final state = value['state'];
      if (state == 'done') {
        return value;
      }
      if (state == 'failed') {
        fail('The $what failed in the page: ${value['message']}');
      }
    }
  }
  fail('The $what did not finish in ${timeout.inSeconds} s: $last');
}

/// Opens [path] in the editor and waits for its page: the app as it is used
/// beside a terminal, before the first terminal is measured against it.
Future<void> openInEditor(
  WidgetTester tester,
  ProviderContainer container,
  String path,
) async {
  final opened = await container
      .read(documentControllerProvider.notifier)
      .open(path);
  expect(opened.isOk, isTrue, reason: '$opened');
  final host = container.read(editorHostProvider);
  await pumpUntil(
    tester,
    () =>
        container.read(documentControllerProvider).activePath == path &&
        host.status.phase == EditorHostPhase.ready,
    what: 'the editor to show $path',
    timeout: const Duration(seconds: 60),
  );
}

/// The renderer [view]'s session [id] draws with now, as the page says.
Future<String> rendererOf(TerminalView view, int id) async {
  final report = (await view.readProbe()).orThrow;
  return _object(report['renderers'])['$id'] as String? ?? 'unknown';
}

/// Puts the page on [renderer] and answers what session [id] draws with:
/// WebGL that can't start leaves it on the DOM's, which the page says why.
Future<({String renderer, String? error})> useRenderer(
  TerminalView view,
  int id,
  String renderer,
) async {
  expect((await view.setRenderer(renderer)).isOk, isTrue);
  final report = (await view.readProbe()).orThrow;
  return (
    renderer: _object(report['renderers'])['$id'] as String? ?? 'unknown',
    error: report['webglError'] as String?,
  );
}

/// The echo probe on session [id], which must be at its prompt.
Future<EchoFigures> measureEcho(
  TerminalView view,
  int id, {
  int count = 100,
  int gapMs = 50,
}) async {
  final renderer = await rendererOf(view, id);
  expect(
    (await view.startEchoProbe(id, count: count, gapMs: gapMs)).isOk,
    isTrue,
  );
  final report = await _probeOutcome(
    view,
    timeout: Duration(milliseconds: count * (gapMs + 4500) + 10000),
    what: 'echo probe',
  );
  final figures = EchoFigures(renderer, _object(report['echo']));
  expect(figures.typed, count);
  return figures;
}

/// A thin progress bar laid over the app while [action] runs, so that
/// Flutter draws every frame (an animated UI), and the frame timings
/// Flutter reported meanwhile, cut to the window [action] marks.
Future<(T, UiFrames)> _withFramesDrawn<T>(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  Future<(T, int, int)> Function() action,
) async {
  final overlay = tester.state<OverlayState>(find.byType(Overlay).first);
  final entry = OverlayEntry(
    builder: (context) => const Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(child: LinearProgressIndicator(minHeight: 3)),
    ),
  );
  final timings = <FrameTiming>[];
  final policy = binding.framePolicy;
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  SchedulerBinding.instance.addTimingsCallback(timings.addAll);
  overlay.insert(entry);
  try {
    final (result, from, to) = await action();
    // Timings arrive in batches, every 100 ms outside release builds.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    bool inWindow(FrameTiming timing) {
      final start = timing.timestampInMicroseconds(FramePhase.vsyncStart);
      return start >= from && start <= to;
    }

    final window = timings.where(inWindow).toList();
    final frames = window.isNotEmpty
        ? UiFrames(window, windowed: true)
        : UiFrames(timings, windowed: false);
    return (result, frames);
  } finally {
    entry.remove();
    SchedulerBinding.instance.removeTimingsCallback(timings.addAll);
    binding.framePolicy = policy;
    await tester.pump();
  }
}

/// The flood through session [id], at its prompt in the folder [floodFile]
/// was written to; [write] sends the session text as typed.
Future<FloodFigures> measureFlood({
  required WidgetTester tester,
  required IntegrationTestWidgetsFlutterBinding binding,
  required TerminalView view,
  required int id,
  required Future<void> Function(String text) write,
  required ({int chars, String hash}) expected,
}) async {
  final renderer = await rendererOf(view, id);
  expect(
    (await view.startFloodProbe(id, begin: floodBegin, end: floodEnd)).isOk,
    isTrue,
  );
  final (report, ui) = await _withFramesDrawn<(Map<String, Object?>, int)>(
    tester,
    binding,
    () async {
    final wall = Stopwatch()..start();
    final from = Timeline.now;
    await write('python3 $floodFile\r');
    final report = await _probeOutcome(
      view,
      timeout: const Duration(minutes: 3),
      what: 'flood probe',
    );
    final to = Timeline.now;
    return ((report, wall.elapsedMilliseconds), from, to);
  },
  );
  final figures = FloodFigures(
    renderer: renderer,
    flood: _object(report.$1['flood']),
    ui: ui,
    wallMs: report.$2,
    expected: expected,
  );
  debugPrint('terminal measure: flood ${figures.line()}');
  return figures;
}

/// [text] as UTF-8, for a session write.
Uint8List typed(String text) => Uint8List.fromList(utf8.encode(text));

/// [report] printed as `<marker> <part>/<parts> <text>` lines, short enough
/// for any log (tool/ci/join_report.py, gate_results.py --document).
Future<void> printReport(String marker, Map<String, Object?> report) async {
  final json = jsonEncode(report);
  const size = 800;
  final parts = (json.length / size).ceil();
  for (var i = 0; i < parts; i++) {
    final end = math.min((i + 1) * size, json.length);
    debugPrint('$marker ${i + 1}/$parts ${json.substring(i * size, end)}');
  }
  // debugPrint is throttled: let the queue drain before the test goes on.
  await debugPrintDone;
}

/// The renderer the app ships (Phase 5 W6): the budgets are judged on it.
const String shippedRenderer = 'dom';

/// Everything [measureTerminal] took, for the report and the budgets.
final class TerminalMeasurements {
  TerminalMeasurements({required this.before, required this.opened});

  final MemorySample before;
  final MemorySample opened;
  final Map<String, EchoFigures> echo = {};
  final Map<String, FloodFigures> flood = {};
  final Map<String, MemorySample> memory = {};

  /// What WebGL drew with when asked for, and why not when it could not.
  String webglRenderer = 'unknown';
  String? webglError;

  /// The shipped renderer's first runs: what the budgets judge.
  EchoFigures get shippedEcho => echo[shippedRenderer]!;
  FloodFigures get shippedFlood => flood[shippedRenderer]!;
  MemorySample get shippedMemory => memory[shippedRenderer]!;

  /// The terminal's memory: after its flood, against before any terminal.
  double get deltaMb => _round1((shippedMemory.totalKb - before.totalKb) / 1024);

  bool get memoryUnderBudget => deltaMb <= memoryBudgetMb;

  Map<String, Object?> toJson() => {
    'shippedRenderer': shippedRenderer,
    'budgets': {
      'echoP95Ms': echoBudgetMs,
      'slowFrameMs': slowFrameMs,
      'slowFramePct': slowFrameBudgetPct,
      'frozenFrameMs': frozenFrameMs,
      'memoryDeltaMb': memoryBudgetMb,
    },
    'echo': {for (final e in echo.entries) e.key: e.value.toJson()},
    'flood': {for (final e in flood.entries) e.key: e.value.toJson()},
    'memory': {
      'before': before.toJson(),
      'opened': opened.toJson(),
      for (final e in memory.entries) 'after_${e.key}': e.value.toJson(),
      'deltaMb': deltaMb,
    },
    'webgl': {'renderer': webglRenderer, 'error': webglError},
    'verdict': {
      'echo': shippedEcho.underBudget,
      'floodWhole': flood.values.every((f) => f.whole),
      'ui': shippedFlood.ui.underBudget,
      'memory': memoryUnderBudget,
    },
  };
}

/// The app's and its renderers' memory, from the gate: its host on the
/// emulator, the instrumentation on Test Lab (folder_gate.dart).
Future<MemorySample> Function(String label) memoryFrom(
  Future<String> Function(String request) ask,
) =>
    (label) async => MemorySample.parse(label, await ask('mem $label'));

/// Echo and the flood with each renderer, the shipped one first and again
/// last, and the memory after each flood. Session [id] is at its prompt in
/// [folder]; [promptShown] waits until it is again.
Future<TerminalMeasurements> measureTerminal({
  required WidgetTester tester,
  required IntegrationTestWidgetsFlutterBinding binding,
  required TerminalView view,
  required int id,
  required String folder,
  required Future<void> Function(String text) write,
  required Future<void> Function(String what) promptShown,
  required Future<MemorySample> Function(String label) memory,
  required MemorySample before,
  required MemorySample opened,
  required void Function(String line) report,
  int echoCount = 100,
}) async {
  File('$folder/$floodFile').writeAsStringSync(floodScript);
  final expected = floodExpected();
  final measured = TerminalMeasurements(before: before, opened: opened);

  Future<void> run(String key, {bool sample = true}) async {
    await write('clear\r');
    await promptShown('the prompt before the echo ($key)');
    final echo = await measureEcho(view, id, count: echoCount);
    measured.echo[key] = echo;
    report('echo $key ${echo.line()}');
    await promptShown('the prompt after the echo ($key)');
    final flood = await measureFlood(
      tester: tester,
      binding: binding,
      view: view,
      id: id,
      write: write,
      expected: expected,
    );
    measured.flood[key] = flood;
    report('flood $key ${flood.line()}');
    await promptShown('the prompt after the flood ($key)');
    if (sample) {
      // Let the flood's garbage go before the sample.
      await Future<void>.delayed(const Duration(seconds: 2));
      final after = await memory('after-$key');
      measured.memory[key] = after;
      report(
        'memory after_$key app_mb=${after.megabytes(after.appKb)} '
        'renderer_mb=${after.megabytes(after.rendererKb)} '
        'total_mb=${after.megabytes(after.totalKb)}',
      );
    }
  }

  final others = [
    for (final renderer in terminalRenderers)
      if (renderer != shippedRenderer) renderer,
  ];
  for (final asked in [shippedRenderer, ...others]) {
    final used = await useRenderer(view, id, asked);
    report('renderer asked=$asked drawing=${used.renderer} error=${used.error}');
    if (asked == 'webgl') {
      measured
        ..webglRenderer = used.renderer
        ..webglError = used.error;
    }
    if (asked == shippedRenderer) {
      expect(used.renderer, shippedRenderer, reason: used.error);
    }
    if (used.renderer == asked) {
      await run(asked);
    }
  }
  final again = await useRenderer(view, id, shippedRenderer);
  expect(again.renderer, shippedRenderer, reason: again.error);
  await run('${shippedRenderer}_again', sample: false);
  return measured;
}
