/// A scripted stand-in for an engine benchmark page (Phase 2 W3): it answers
/// the page API (codeforgeBench.run / startTyping / checkTyping /
/// awaitDriver) the way editor/bench/harness.ts does, without a WebView.
library;

import 'dart:async';
import 'dart:convert';

import 'package:codeforge/application/bench/editor_bench_providers.dart';
import 'package:codeforge/application/bench/editor_bench_runner.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/editor/bench/bench_pages.dart';
import 'package:codeforge/services/editor/bench/bench_surface.dart';
import 'package:flutter/widgets.dart';

BenchPageInfo fakeBenchPageInfo(String engine) => BenchPageInfo(
  engine: engine,
  engineVersion: engine == 'monaco' ? '0.57.0' : '6.43.15',
  file: '$engine.html',
  bytes: 1000,
  gzipBytes: engine == 'monaco' ? 1054049 : 300737,
  sha256: 'fake-$engine',
);

/// One scripted suite result, shaped like harness.ts SuiteResult.
Map<String, Object?> fakeSuiteResult(
  String engine, {
  num readyMs = 300,
  num typingP95Ms = 12,
  bool replaceAll = true,
}) => {
  'schema': 1,
  'engine': engine,
  'engineVersion': engine == 'monaco' ? '0.57.0' : '6.43.15',
  'inputMode': 'editcontext',
  'userAgent': 'fake',
  'load': {'readyMs': readyMs},
  'highlight': {
    'javascript': {'spans': 12, 'ms': 1},
    'json': {'spans': 4, 'ms': 1},
  },
  'features': {'replaceAll': replaceAll, 'completion': true},
  'typing': {'count': 60, 'p50Ms': 5, 'p95Ms': typingP95Ms, 'maxMs': 20},
  'largeFile': {
    'bytes': 1048576,
    'openMs': 80,
    'typing': {'p95Ms': 30},
    'scroll': {'slowFramePct': 1.5},
  },
  'errors': <Object?>[],
};

final class FakeBenchSurface implements BenchSurface {
  FakeBenchSurface({
    this.startPage = true,
    this.answerRuns = true,
    this.answerDriver = true,
  });

  /// Post `ready` once loaded (false: a page that never starts).
  final bool startPage;
  final bool answerRuns;
  final bool answerDriver;

  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>.broadcast();
  final List<String> scripts = [];
  String? loadedHtml;
  bool disposed = false;

  /// What the "person" typed into the page's document.
  String typed = '';

  /// The engine whose page was loaded (from the fake page HTML).
  String get engine => loadedHtml ?? '?';

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  void post(Map<String, Object?> message) {
    if (!_messages.isClosed) {
      _messages.add(message);
    }
  }

  @override
  Future<void> load(String html) async {
    loadedHtml = html;
    if (startPage) {
      scheduleMicrotask(() => post({'type': 'ready', 'engine': html}));
    }
  }

  @override
  Future<void> execute(String script) async {
    scripts.add(script);
    if (script.contains('codeforgeBench.run()') && answerRuns) {
      scheduleMicrotask(() {
        post({'type': 'progress', 'step': 'typing'});
        post({'type': 'console', 'level': 'warning', 'message': 'noted'});
        post({'type': 'result', 'result': fakeSuiteResult(engine)});
      });
    } else if (script.contains('codeforgeBench.startTyping()')) {
      typed = '';
    } else if (script.contains('codeforgeBench.checkTyping(')) {
      final argument = script.substring(
        script.indexOf('(') + 1,
        script.lastIndexOf(')'),
      );
      final expected = jsonDecode(argument) as String;
      scheduleMicrotask(
        () => post({
          'type': 'typing',
          'result': {
            'engine': engine,
            'inputMode': 'editcontext',
            'expected': expected,
            'actual': typed,
            'match': typed == expected,
            'firstDifference': typed == expected ? -1 : 0,
            'input': {
              'count': 26,
              'p50Ms': 8,
              'p95Ms': 14.5,
              'maxMs': 20,
              'meanMs': 9,
            },
          },
        }),
      );
    } else if (script.contains('codeforgeBench.awaitDriver()') &&
        answerDriver) {
      scheduleMicrotask(
        () => post({
          'type': 'driver-done',
          'summary': {'ok': true},
        }),
      );
    }
  }

  @override
  Widget buildView(BuildContext context) =>
      SizedBox.expand(key: ValueKey('fake_bench_view_$engine'));

  @override
  Future<void> dispose() async {
    disposed = true;
    await _messages.close();
  }
}

/// A runner over fake pages: [engines] are "in the build" (none: a build
/// without benchmark pages). Created surfaces are reported to [onSurface].
EditorBenchRunner fakeBenchRunner({
  List<String> engines = const [],
  void Function(FakeBenchSurface surface)? onSurface,
  FakeBenchSurface Function()? surface,
  Duration readyTimeout = const Duration(seconds: 5),
  Duration runTimeout = const Duration(seconds: 5),
}) {
  return EditorBenchRunner(
    loadManifest: () async => Ok([for (final e in engines) fakeBenchPageInfo(e)]),
    // The fake page's HTML is its engine id: the surface answers as it.
    loadPage: (info) async => Ok(BenchPage(info: info, html: info.engine)),
    createSurface: () {
      final created = surface?.call() ?? FakeBenchSurface();
      onSurface?.call(created);
      return created;
    },
    settle: () async {},
    readyTimeout: readyTimeout,
    runTimeout: runTimeout,
  );
}

EditorBenchRunnerFactory fakeBenchRunnerFactory({
  List<String> engines = const [],
  void Function(FakeBenchSurface surface)? onSurface,
}) =>
    () => fakeBenchRunner(engines: engines, onSurface: onSurface);
