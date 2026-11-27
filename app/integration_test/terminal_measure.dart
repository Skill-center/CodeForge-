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
///   instrumentation's shell), before the first terminal, with the terminal
///   open and idle, and after the flood; ADR-0006's delta within 80 MB once
///   the flood settled, and the open terminal's within 90 MB (the owner's
///   (a) of 2026-11-21, PHASE_5_PLAN §10 item 7).
/// - **The renderer:** each is measured with xterm.js's DOM renderer and
///   with WebGL (addon-webgl), then the DOM's again.
/// - **How the page is reached** (Phase 5 W6's memory work): how the app's
///   platform views are composed (Hybrid Composition++ where the engine
///   can, else Flutter's texture layer) and whether host messages reach the
///   page through its MessagePort; both recorded with the figures.
library;

import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:math' as math;
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
import 'package:flutter/services.dart' show HybridAndroidViewController;
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

/// The open terminal's budget: open and idle at its full stop, against
/// before any terminal (the owner's (a) of 2026-11-21, for what Phase 5
/// W6's memory work left over 80 MB; a flood's growth is recorded beside).
const double openMemoryBudgetMb = 90;

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

/// The build the figures come from: Test Lab's is a profile build since
/// Phase 5 W6 (its Dart compiled ahead of time, as the app ships), the
/// emulator gate's a debug build.
String get buildMode => kDebugMode
    ? 'debug'
    : kProfileMode
    ? 'profile'
    : 'release';

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

/// The App Summary rows the gate reports for the app (`dumpsys meminfo`).
const List<String> memoryRows = [
  'javaheap',
  'nativeheap',
  'code',
  'stack',
  'graphics',
  'privateother',
  'system',
  'unknown',
];

/// The app's and its renderers' PSS, in KiB (`dumpsys meminfo`).
final class MemorySample {
  const MemorySample({
    required this.label,
    required this.appKb,
    required this.rendererKb,
    required this.renderers,
    this.rows = const {},
    this.rendererGraphicsKb = 0,
  });

  /// From the gate's answer: `app:<kb>,renderer:<kb>,renderers:<n>,...`,
  /// then the app's App Summary rows and the renderers' graphics.
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
      rows: {
        for (final row in memoryRows)
          if ((fields[row] ?? -1) >= 0) row: fields[row]!,
      },
      rendererGraphicsKb: fields['rgraphics'] ?? 0,
    );
  }

  final String label;
  final int appKb;
  final int rendererKb;
  final int renderers;

  /// The app's App Summary, by row, in KiB: where its memory is.
  final Map<String, int> rows;
  final int rendererGraphicsKb;

  int get totalKb => appKb + rendererKb;

  double megabytes(int kb) => _round1(kb / 1024);

  Map<String, Object?> toJson() => {
    'appMb': megabytes(appKb),
    'rendererMb': megabytes(rendererKb),
    'renderers': renderers,
    'totalMb': megabytes(totalKb),
    'appRowsMb': {for (final e in rows.entries) e.key: megabytes(e.value)},
    'rendererGraphicsMb': megabytes(rendererGraphicsKb),
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
    this.dartBatches = 0,
    this.dartMs = 0,
  }) : chars = _integer(flood['chars']),
       hash = flood['hash'] is String ? flood['hash']! as String : '',
       writes = _integer(flood['writes']),
       maxWriteChars = _integer(flood['maxWriteChars']),
       ms = _number(flood['ms']),
       pageFrames = _object(flood['frames']),
       longTasks = _object(flood['longTasks']),
       whole =
           _integer(flood['chars']) == expected.chars &&
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

  /// The batches the app's controller handed to the page meanwhile, and
  /// the UI isolate's time on them (decoding, sending on).
  final int dartBatches;
  final double dartMs;

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
    'dart': {'batches': dartBatches, 'ms': dartMs},
  };

  String line() =>
      'renderer=$renderer whole=${whole ? 1 : 0} chars=$chars hash=$hash '
      'ms=$ms mib_s=$mibPerSecond writes=$writes max_write=$maxWriteChars '
      'ui_frames=${ui.frames} ui_slow=${ui.slow} ui_slow_pct=${ui.slowPct} '
      'ui_frozen=${ui.frozen} ui_p95_ms=${ui.p95TotalMs} '
      'ui_build_p95_ms=${ui.p95BuildMs} ui_raster_p95_ms=${ui.p95RasterMs} '
      'ui_max_ms=${ui.maxTotalMs} ui_gap_ms=${ui.longestGapMs} '
      'dart_batches=$dartBatches dart_ms=$dartMs wall_ms=$wallMs '
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
/// Flutter reported meanwhile, cut to the window [action] marks. [action]
/// answers its result and the window, as `Timeline.now` reads the clock
/// the frames are stamped with. Since Phase 7 W6 the Git group measures
/// its own operations with it (git_measure.dart).
Future<(T, UiFrames)> withFramesDrawn<T>(
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
  OutputStats Function()? outputStats,
}) async {
  final renderer = await rendererOf(view, id);
  expect(
    (await view.startFloodProbe(id, begin: floodBegin, end: floodEnd)).isOk,
    isTrue,
  );
  final startStats = outputStats?.call();
  final (report, ui) = await withFramesDrawn<(Map<String, Object?>, int)>(
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
  final endStats = outputStats?.call();
  final figures = FloodFigures(
    renderer: renderer,
    flood: _object(report.$1['flood']),
    ui: ui,
    wallMs: report.$2,
    expected: expected,
    dartBatches: startStats == null || endStats == null
        ? 0
        : endStats.batches - startStats.batches,
    dartMs: startStats == null || endStats == null
        ? 0
        : _round1((endStats.micros - startStats.micros) / 1000),
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

/// How the app's platform views are composed: `hcpp` where the engine
/// composes them with Hybrid Composition++ (the manifest's EnableHcpp, on
/// Android 14 and later with Vulkan), else `tlhc`, Flutter's texture layer.
Future<String> platformViewComposition() async {
  try {
    return await HybridAndroidViewController.checkIfSupported()
        ? 'hcpp'
        : 'tlhc';
  } on Object {
    return 'unknown';
  }
}

/// The renderer the app asks for (Phase 5 W6): WebGL. The page draws with
/// the DOM's where WebGL can't draw (no WebGL2, a software GPU such as the
/// emulator's): the budgets are judged on what it draws with.
const String shippedRenderer = 'webgl';

/// How long the terminal idles after a flood before its memory counts as
/// settled: the page's and the app's garbage collectors run when idle.
const Duration settleTime = Duration(seconds: 15);

/// The output the app's terminal controller handed to the page.
typedef OutputStats = ({int batches, int chars, int micros});

/// Everything [measureTerminal] took, for the report and the budgets.
final class TerminalMeasurements {
  TerminalMeasurements({
    required this.before,
    required this.opened,
    this.openedHalf,
  });

  final MemorySample before;

  /// The terminal open at its full stop, before any output, and at half.
  final MemorySample opened;
  final MemorySample? openedHalf;
  final Map<String, EchoFigures> echo = {};
  final Map<String, FloodFigures> flood = {};

  /// Two seconds after each flood, and once it settled ([settleTime]).
  final Map<String, MemorySample> afterFlood = {};
  final Map<String, MemorySample> settled = {};

  /// The page's JavaScript heap where DevTools can tell (the emulator):
  /// settled, then after a garbage collection DevTools forced, and the
  /// memory then. Attribution only, never judged.
  final Map<String, String> heap = {};
  MemorySample? afterCollection;

  /// What the page draws with when it is asked for [shippedRenderer].
  String shipped = 'unknown';

  /// How the platform views are composed ([platformViewComposition]), and
  /// whether host messages reached the page through its port.
  String composition = 'unknown';
  bool hostPort = false;

  /// What WebGL drew with when asked for, and why not when it could not.
  String webglRenderer = 'unknown';
  String? webglError;

  /// Why the other renderer's runs stopped, if they did (recorded, never
  /// judged: the budgets are the shipped renderer's).
  String? otherFailure;

  /// The shipped renderer's first runs: what the budgets judge.
  EchoFigures get shippedEcho => echo[shipped]!;
  FloodFigures get shippedFlood => flood[shipped]!;

  double _delta(MemorySample after) =>
      _round1((after.totalKb - before.totalKb) / 1024);

  /// The terminal's memory: once settled after its flood, against before
  /// any terminal.
  double get deltaMb => _delta(settled[shipped]!);

  /// The same two seconds after the flood, its garbage still there.
  double get peakDeltaMb => _delta(afterFlood[shipped]!);

  /// The terminal open, before any output: at its full stop and at half.
  double get openDeltaMb => _delta(opened);
  double? get openHalfDeltaMb {
    final half = openedHalf;
    return half == null ? null : _delta(half);
  }

  bool get memoryUnderBudget => deltaMb <= memoryBudgetMb;

  /// The terminal open and idle at its full stop, within its budget.
  bool get openUnderBudget => openDeltaMb <= openMemoryBudgetMb;

  Map<String, Object?> toJson() => {
    'askedRenderer': shippedRenderer,
    'shippedRenderer': shipped,
    'composition': composition,
    'hostPort': hostPort,
    'budgets': {
      'echoP95Ms': echoBudgetMs,
      'slowFrameMs': slowFrameMs,
      'slowFramePct': slowFrameBudgetPct,
      'frozenFrameMs': frozenFrameMs,
      'memoryDeltaMb': memoryBudgetMb,
      'openMemoryDeltaMb': openMemoryBudgetMb,
      'settleSeconds': settleTime.inSeconds,
    },
    'echo': {for (final e in echo.entries) e.key: e.value.toJson()},
    'flood': {for (final e in flood.entries) e.key: e.value.toJson()},
    'memory': {
      'before': before.toJson(),
      'opened': opened.toJson(),
      'openedHalf': openedHalf?.toJson(),
      for (final e in afterFlood.entries) 'after_${e.key}': e.value.toJson(),
      for (final e in settled.entries) 'settled_${e.key}': e.value.toJson(),
      'afterCollection': afterCollection?.toJson(),
      'heap': heap,
      'deltaMb': deltaMb,
      'peakDeltaMb': peakDeltaMb,
      'openDeltaMb': openDeltaMb,
      'openHalfDeltaMb': openHalfDeltaMb,
    },
    'webgl': {'renderer': webglRenderer, 'error': webglError},
    'otherFailure': otherFailure,
    'verdict': {
      'echo': shippedEcho.underBudget,
      'floodWhole': flood.values.every((f) => f.whole),
      'ui': shippedFlood.ui.underBudget,
      'memory': memoryUnderBudget,
      'memoryOpen': openUnderBudget,
    },
  };
}

/// The app's and its renderers' memory, from the gate: its host on the
/// emulator, the instrumentation on Test Lab (folder_gate.dart).
Future<MemorySample> Function(String label) memoryFrom(
  Future<String> Function(String request) ask,
) =>
    (label) async => MemorySample.parse(label, await ask('mem $label'));

/// Echo and the flood with what the page draws when asked for
/// [shippedRenderer], then with the other renderer, then the first again,
/// and the memory after each flood. Session [id] is at its prompt in
/// [folder]; [promptShown] waits until it is again. The other renderer's
/// runs are recorded whatever happens to them; a failure in the shipped
/// one's fails the test. [ask] reaches the gate for the page's heap.
Future<TerminalMeasurements> measureTerminal({
  required WidgetTester tester,
  required IntegrationTestWidgetsFlutterBinding binding,
  required TerminalView view,
  required int id,
  required String folder,
  required Future<void> Function(String text) write,
  required Future<void> Function(String what) promptShown,
  required Future<MemorySample> Function(String label) memory,
  required Future<String> Function(String request) ask,
  required MemorySample before,
  required MemorySample opened,
  required void Function(String line) report,
  MemorySample? openedHalf,
  OutputStats Function()? outputStats,
  int echoCount = 100,
}) async {
  File('$folder/$floodFile').writeAsStringSync(floodScript);
  final expected = floodExpected();
  final measured = TerminalMeasurements(
    before: before,
    opened: opened,
    openedHalf: openedHalf,
  );
  measured
    ..composition = await platformViewComposition()
    ..hostPort = view.throughPort;
  report(
    'reached composition=${measured.composition} '
    'host_port=${measured.hostPort ? 1 : 0}',
  );

  void reportMemory(String label, MemorySample sample) => report(
    'memory $label app_mb=${sample.megabytes(sample.appKb)} '
    'renderer_mb=${sample.megabytes(sample.rendererKb)} '
    'total_mb=${sample.megabytes(sample.totalKb)}',
  );

  // A fresh screen, then a pause: a renderer just switched to draws its
  // first frames (WebGL builds its glyph atlas) before anything is timed.
  Future<void> fresh(String key) async {
    await write('clear\r');
    await promptShown('a fresh prompt ($key)');
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  Future<void> run(String key, {required bool sample}) async {
    await fresh(key);
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
      outputStats: outputStats,
    );
    measured.flood[key] = flood;
    report('flood $key ${flood.line()}');
    await promptShown('the prompt after the flood ($key)');
    if (sample) {
      final settling = Stopwatch()..start();
      await Future<void>.delayed(const Duration(seconds: 2));
      final after = await memory('after-$key');
      measured.afterFlood[key] = after;
      reportMemory('after_$key', after);
      final rest = settleTime - settling.elapsed;
      if (rest > Duration.zero) {
        await Future<void>.delayed(rest);
      }
      final settled = await memory('settled-$key');
      measured.settled[key] = settled;
      reportMemory('settled_$key', settled);
    }
  }

  Future<({String renderer, String? error})> switchTo(String asked) async {
    final used = await useRenderer(view, id, asked);
    report(
      'renderer asked=$asked drawing=${used.renderer} error=${used.error}',
    );
    if (asked == 'webgl') {
      measured
        ..webglRenderer = used.renderer
        ..webglError = used.error;
    }
    return used;
  }

  // What the page draws with when asked for the app's renderer: judged.
  measured.shipped = (await switchTo(shippedRenderer)).renderer;
  await run(measured.shipped, sample: true);

  // Where DevTools can tell (the emulator), how much of the page's memory
  // after the flood is garbage: its heap, then a collection DevTools forces.
  final heap = await ask('heap read');
  if (heap != 'unavailable') {
    measured.heap['settled'] = heap;
    measured.heap['collected'] = await ask('heap gc');
    await Future<void>.delayed(const Duration(seconds: 2));
    final collected = await memory('collected-${measured.shipped}');
    measured.afterCollection = collected;
    report('heap settled=$heap collected=${measured.heap['collected']}');
    reportMemory('collected_${measured.shipped}', collected);
  }

  // The other renderer, recorded whatever happens.
  for (final other in terminalRenderers) {
    if (other == measured.shipped) {
      continue;
    }
    final used = await switchTo(other);
    if (used.renderer != other) {
      continue;
    }
    try {
      await run(other, sample: true);
    } on Object catch (error) {
      measured.otherFailure = '$error'.split('\n').first;
      report('renderer $other stopped: ${measured.otherFailure}');
      // The line is not known any more: Ctrl-C gives a fresh prompt.
      await write('\x03');
      await promptShown('the prompt after $other stopped');
    }
  }
  final again = await useRenderer(view, id, shippedRenderer);
  expect(again.renderer, measured.shipped, reason: again.error);
  await run('${measured.shipped}_again', sample: false);
  return measured;
}
