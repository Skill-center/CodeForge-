/// Wiring for the engine benchmark (Phase 2 W3). Tests override the factory
/// with fake pages and surfaces.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/editor/bench/bench_pages.dart';
import '../../services/editor/bench/bench_surface.dart';
import 'editor_bench_runner.dart';

typedef EditorBenchRunnerFactory = EditorBenchRunner Function();

/// Creates the runner the benchmark screen owns (one per visit).
final editorBenchRunnerFactoryProvider = Provider<EditorBenchRunnerFactory>(
  (ref) =>
      () => EditorBenchRunner(
        loadManifest: () => loadBenchManifest(rootBundle),
        loadPage: (info) => loadBenchPage(rootBundle, info),
        createSurface: WebViewBenchSurface.new,
      ),
);
