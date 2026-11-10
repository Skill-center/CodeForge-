/// Drives the Phase 2 W3 engine benchmark (docs/phases/PHASE_2_PLAN.md, W3)
/// from the app: Settings → Developer → Editor benchmark on a phone, and the
/// phase gate's integration test on the CI emulator.
///
/// Every run gets a fresh WebView: load the verified page, wait for it to
/// announce itself, run its scripted suite, collect the result. Engines
/// alternate (A B B A …) so neither always runs first in a warm process.
/// Typing checks let a person type on the real keyboard (Gboard) and compare
/// the document with the phrase; driver phases hand a page to the gate's
/// DevTools driver (editor/tool/bench_cdp.mjs).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../core/errors/failure.dart';
import '../../services/editor/bench/bench_pages.dart';
import '../../services/editor/bench/bench_surface.dart';

typedef BenchManifestLoader = Future<Result<List<BenchPageInfo>>> Function();
typedef BenchPageLoader = Future<Result<BenchPage>> Function(BenchPageInfo);
typedef BenchSurfaceFactory = BenchSurface Function();

enum BenchPhase { loading, unavailable, idle, running, typing, driver }

/// A phrase for the manual typing check.
@immutable
final class BenchPhrase {
  const BenchPhrase(this.id, this.label, this.text);

  final String id;
  final String label;
  final String text;
}

const List<BenchPhrase> benchPhrases = [
  BenchPhrase(
    'code',
    'Code with symbols',
    'const total = items.map((x) => x * 2);',
  ),
  BenchPhrase(
    'words',
    'Words (swipe or suggestions)',
    'hello world from codeforge',
  ),
  BenchPhrase('emoji', 'Emoji', 'ok 👍🏽 done 😀'),
  BenchPhrase('cjk', 'Chinese (pinyin keyboard)', '你好，世界'),
];

/// Engine order for [runsPerEngine] runs each: A B B A A B …
List<String> alternatingOrder(List<String> engines, int runsPerEngine) {
  final order = <String>[];
  for (var round = 0; round < runsPerEngine; round += 1) {
    order.addAll(round.isEven ? engines : engines.reversed);
  }
  return order;
}

/// The value at [path] in nested JSON maps, if it is a number.
num? numAt(Map<String, Object?> json, List<String> path) {
  Object? node = json;
  for (final key in path) {
    if (node is! Map<String, Object?>) {
      return null;
    }
    node = node[key];
  }
  return node is num ? node : null;
}

/// Median (lower middle for even counts), or null for no values.
num? median(List<num> values) {
  if (values.isEmpty) {
    return null;
  }
  final sorted = [...values]..sort();
  return sorted[(sorted.length - 1) ~/ 2];
}

/// Metrics summarized per engine: name → path in a suite result.
const Map<String, List<String>> benchMetrics = {
  'readyMs': ['load', 'readyMs'],
  'typingP50Ms': ['typing', 'p50Ms'],
  'typingP95Ms': ['typing', 'p95Ms'],
  'largeOpenMs': ['largeFile', 'openMs'],
  'largeTypingP95Ms': ['largeFile', 'typing', 'p95Ms'],
  'scrollSlowFramePct': ['largeFile', 'scroll', 'slowFramePct'],
  // Phase 3 W1: the same text as plain text (record-only).
  'plainOpenMs': ['largePlain', 'openMs'],
  'plainTypingP95Ms': ['largePlain', 'typing', 'p95Ms'],
  'plainScrollSlowFramePct': ['largePlain', 'scroll', 'slowFramePct'],
};

/// A scope check passed: `true`, or a highlight entry with spans.
bool _passed(Object? value) => switch (value) {
  true => true,
  {'spans': final int spans} => spans > 0,
  _ => false,
};

bool _allPassed(Map<String, Object?> result, String key) =>
    switch (result[key]) {
      final Map<String, Object?> group => group.values.every(_passed),
      _ => false,
    };

final class EditorBenchRunner extends ChangeNotifier {
  EditorBenchRunner({
    required BenchManifestLoader loadManifest,
    required BenchPageLoader loadPage,
    required BenchSurfaceFactory createSurface,
    Future<void> Function()? settle,
    this.readyTimeout = const Duration(seconds: 60),
    this.runTimeout = const Duration(minutes: 3),
  }) : _loadManifest = loadManifest,
       _loadPage = loadPage,
       _createSurface = createSurface,
       _settle = settle ?? _settleFrames;

  final BenchManifestLoader _loadManifest;
  final BenchPageLoader _loadPage;
  final BenchSurfaceFactory _createSurface;
  final Future<void> Function() _settle;
  final Duration readyTimeout;
  final Duration runTimeout;

  BenchPhase _phase = BenchPhase.loading;
  String _message = 'Reading the benchmark manifest…';
  String? _step;
  List<BenchPageInfo> _pages = const [];
  BenchSurface? _surface;
  String? _surfaceEngine;
  int _generation = 0;
  bool _disposed = false;
  final List<Map<String, Object?>> _runs = [];
  final List<Map<String, Object?>> _typingChecks = [];
  final List<Map<String, Object?>> _driverPhases = [];
  final List<String> _errors = [];
  final List<String> _pageErrors = [];
  int? _lastHostReadyMs;

  BenchPhase get phase => _phase;
  String get message => _message;
  String? get step => _step;
  List<BenchPageInfo> get pages => _pages;
  List<String> get engines => [for (final page in _pages) page.engine];

  /// The page currently on screen, and a counter that changes with it (key
  /// the view with it so every run gets a fresh platform view).
  BenchSurface? get surface => _surface;
  String? get surfaceEngine => _surfaceEngine;
  int get generation => _generation;
  List<Map<String, Object?>> get runs => List.unmodifiable(_runs);
  List<Map<String, Object?>> get typingChecks =>
      List.unmodifiable(_typingChecks);
  List<Map<String, Object?>> get driverPhases =>
      List.unmodifiable(_driverPhases);
  List<String> get errors => List.unmodifiable(_errors);
  List<String> get pageErrors => List.unmodifiable(_pageErrors);

  static Future<void> _settleFrames() async {
    // The new platform view needs a frame to attach and a moment to get a
    // surface; rAF (which the page's timing relies on) waits for both.
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  Future<void> init() async {
    final manifest = await _loadManifest();
    switch (manifest) {
      case Ok(:final value) when value.isNotEmpty:
        _pages = value;
        _set(BenchPhase.idle, 'Ready: ${engines.join(' and ')}.');
      case Ok():
        _set(
          BenchPhase.unavailable,
          'This build has no benchmark pages. They ship in the phase-gate '
          'debug APK and the phone profile APK only.',
        );
      case Err(:final failure):
        _errors.add(failure.message);
        _set(BenchPhase.unavailable, failure.message);
    }
  }

  /// Runs the scripted suite [runsPerEngine] times per engine.
  Future<void> runAll({List<String>? only, int runsPerEngine = 3}) async {
    if (_phase != BenchPhase.idle) {
      return;
    }
    final selected = [
      for (final engine in engines)
        if (only == null || only.contains(engine)) engine,
    ];
    final order = alternatingOrder(selected, runsPerEngine);
    _runs.clear();
    _set(BenchPhase.running, 'Starting…');
    for (final (index, engine) in order.indexed) {
      if (_disposed) {
        return;
      }
      _message = 'Run ${index + 1} of ${order.length}: $engine';
      _step = null;
      _notify();
      await _runOnce(engine, index);
    }
    await _closeSurface();
    _step = null;
    _set(
      BenchPhase.idle,
      'Finished ${_runs.length} of ${order.length} runs.'
      '${_errors.isEmpty ? '' : ' ${_errors.length} problem(s) — see below.'}',
    );
  }

  Future<void> _runOnce(String engine, int index) async {
    final surface = await _openPage(engine);
    if (surface == null) {
      return;
    }
    final result = _waitFor(surface, 'result', runTimeout);
    await surface.execute('window.codeforgeBench.run();');
    final message = await result;
    if (message == null) {
      _errors.add(
        '$engine run ${index + 1}: no result within ${runTimeout.inSeconds} s',
      );
      return;
    }
    final suite = message['result'];
    if (suite is Map<String, Object?>) {
      _runs.add({
        'engine': engine,
        'run': index + 1,
        'hostReadyMs': _lastHostReadyMs,
        'result': suite,
      });
    }
  }

  /// Puts a fresh WebView with [engine]'s page on screen and waits until the
  /// page has started. Null (and an error recorded) when it does not.
  Future<BenchSurface?> _openPage(String engine) async {
    final info = _pages.where((page) => page.engine == engine).firstOrNull;
    if (info == null) {
      _errors.add('$engine: not in this build');
      return null;
    }
    final page = await _loadPage(info);
    if (page case Err(:final failure)) {
      _errors.add('$engine: ${failure.message}');
      return null;
    }
    final html = page.orThrow.html;
    await _closeSurface();
    final surface = _createSurface();
    _surface = surface;
    _surfaceEngine = engine;
    _generation += 1;
    _notify();
    await _settle();
    final watch = Stopwatch()..start();
    final ready = _waitFor(surface, 'ready', readyTimeout);
    try {
      await surface.load(html);
    } on Object catch (error) {
      _errors.add('$engine: the page did not load ($error)');
      await _closeSurface();
      return null;
    }
    if (await ready == null) {
      _errors.add(
        '$engine: the page did not start within ${readyTimeout.inSeconds} s',
      );
      await _closeSurface();
      return null;
    }
    _lastHostReadyMs = watch.elapsedMilliseconds;
    return surface;
  }

  Future<void> _closeSurface() async {
    final surface = _surface;
    if (surface == null) {
      return;
    }
    _surface = null;
    _surfaceEngine = null;
    _generation += 1;
    _notify();
    await surface.dispose();
  }

  /// The next message of [type] from [surface], or null after [timeout].
  /// Progress, page errors and console errors are recorded on the way.
  Future<Map<String, Object?>?> _waitFor(
    BenchSurface surface,
    String type,
    Duration timeout,
  ) {
    final completer = Completer<Map<String, Object?>?>();
    final engine = _surfaceEngine ?? '?';
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });
    final subscription = surface.messages.listen((message) {
      final kind = message['type'];
      if (kind == 'progress' && message['step'] is String) {
        _step = message['step'] as String?;
        _notify();
      } else if (kind == 'error' || kind == 'console') {
        if (_pageErrors.length < 50) {
          _pageErrors.add('$engine: ${message['message']}');
        }
      }
      if (kind == type && !completer.isCompleted) {
        completer.complete(message);
      }
    });
    return completer.future.whenComplete(() {
      timer.cancel();
      // Never await a cancel from here (TESTING.md §1.2, root-zone trap).
      unawaited(subscription.cancel());
    });
  }

  /// Opens [engine]'s page with an empty document for a person to type into.
  Future<void> openTyping(String engine) async {
    if (_phase != BenchPhase.idle && _phase != BenchPhase.typing) {
      return;
    }
    _set(BenchPhase.typing, 'Opening $engine…');
    final surface = await _openPage(engine);
    if (surface == null) {
      _set(BenchPhase.idle, 'Could not open $engine — see below.');
      return;
    }
    await surface.execute('window.codeforgeBench.startTyping();');
    _set(BenchPhase.typing, 'Tap the editor and type the phrase.');
  }

  /// Empties the document again (same engine, same page).
  Future<void> clearTyping() async {
    final surface = _surface;
    if (_phase == BenchPhase.typing && surface != null) {
      await surface.execute('window.codeforgeBench.startTyping();');
    }
  }

  /// Compares the document with [phrase]; the result is kept for the report.
  Future<Map<String, Object?>?> checkTyping(BenchPhrase phrase) async {
    final surface = _surface;
    if (_phase != BenchPhase.typing || surface == null) {
      return null;
    }
    final reply = _waitFor(surface, 'typing', readyTimeout);
    await surface.execute(
      'window.codeforgeBench.checkTyping(${jsonEncode(phrase.text)});',
    );
    final message = await reply;
    final result = message?['result'];
    if (result is! Map<String, Object?>) {
      _errors.add('typing check (${phrase.id}): no answer from the page');
      _notify();
      return null;
    }
    final check = {'phrase': phrase.id, ...result};
    _typingChecks.add(check);
    _message = result['match'] == true
        ? '${phrase.label}: match.'
        : '${phrase.label}: differs at ${result['firstDifference']}.';
    _notify();
    return check;
  }

  Future<void> closeTyping() async {
    if (_phase != BenchPhase.typing) {
      return;
    }
    await _closeSurface();
    _set(BenchPhase.idle, 'Typing check closed.');
  }

  /// Hands [engine]'s page to the gate's DevTools driver and waits until it
  /// is done. Returns whether the driver finished within [timeout].
  Future<bool> driverPhase(
    String engine, {
    Duration timeout = const Duration(minutes: 4),
  }) async {
    if (_phase != BenchPhase.idle) {
      return false;
    }
    _set(BenchPhase.driver, 'Waiting for the DevTools driver ($engine)…');
    final surface = await _openPage(engine);
    var completed = false;
    Object? summary;
    if (surface != null) {
      final done = _waitFor(surface, 'driver-done', timeout);
      await surface.execute('window.codeforgeBench.awaitDriver();');
      final message = await done;
      completed = message != null;
      summary = message?['summary'];
    }
    _driverPhases.add({
      'engine': engine,
      'completed': completed,
      'summary': summary,
    });
    await _closeSurface();
    _set(
      BenchPhase.idle,
      completed
          ? 'Driver finished ($engine).'
          : 'No driver attached ($engine).',
    );
    return completed;
  }

  /// Per-engine medians over the runs, plus scope checks.
  Map<String, Object?> summary() {
    final out = <String, Object?>{};
    for (final engine in engines) {
      final results = [
        for (final run in _runs)
          if (run['result'] case final Map<String, Object?> result
              when run['engine'] == engine)
            result,
      ];
      if (results.isEmpty) {
        continue;
      }
      final medians = <String, Object?>{
        for (final MapEntry(key: name, value: path) in benchMetrics.entries)
          name: median([for (final result in results) ?numAt(result, path)]),
      };
      final first = results.first;
      out[engine] = {
        'runs': results.length,
        'medians': medians,
        'featuresOk': results.every((r) => _allPassed(r, 'features')),
        'highlightOk': results.every((r) => _allPassed(r, 'highlight')),
        'inputMode': first['inputMode'],
        'engineVersion': first['engineVersion'],
        'userAgent': first['userAgent'],
      };
    }
    return out;
  }

  Map<String, Object?> report() => {
    'schema': 1,
    'kind': 'codeforge-editor-bench',
    'build': kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'pages': [for (final page in _pages) page.toJson()],
    'summary': summary(),
    'typingChecks': _typingChecks,
    'driverPhases': _driverPhases,
    'errors': _errors,
    'pageErrors': _pageErrors,
    'runs': _runs,
  };

  String reportJson() => jsonEncode(report());

  void _set(BenchPhase phase, String message) {
    _phase = phase;
    _message = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final surface = _surface;
    _surface = null;
    if (surface != null) {
      unawaited(surface.dispose());
    }
    super.dispose();
  }
}
