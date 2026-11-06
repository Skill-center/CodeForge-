/// Settings → Developer → Editor benchmark (Phase 2 W3; debug and profile
/// builds only). Runs the CodeMirror 6 and Monaco benchmark pages in the
/// app's own WebView, lets a person check typing with the real keyboard
/// (Gboard: predictions, swipe, emoji, CJK), and copies everything as JSON.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../application/bench/editor_bench_providers.dart';
import '../../../application/bench/editor_bench_runner.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/typography.dart';

class EditorBenchmarkScreen extends ConsumerStatefulWidget {
  const EditorBenchmarkScreen({super.key});

  @override
  ConsumerState<EditorBenchmarkScreen> createState() =>
      _EditorBenchmarkScreenState();
}

class _EditorBenchmarkScreenState extends ConsumerState<EditorBenchmarkScreen> {
  late final EditorBenchRunner _runner;
  String? _typingEngine;
  BenchPhrase _phrase = benchPhrases.first;

  @override
  void initState() {
    super.initState();
    _runner = ref.read(editorBenchRunnerFactoryProvider)();
    unawaited(_runner.init());
  }

  @override
  void dispose() {
    _runner.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _runner.reportJson()));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Results copied as JSON')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _runner,
      builder: (context, _) {
        final runner = _runner;
        final surface = runner.surface;
        final busy =
            runner.phase == BenchPhase.loading ||
            runner.phase == BenchPhase.running ||
            runner.phase == BenchPhase.driver;
        return Scaffold(
          appBar: AppBar(
            leading: CfIconButton(
              icon: Icons.arrow_back,
              tooltip: 'Back',
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/settings'),
            ),
            title: const Text('Editor benchmark'),
            actions: [
              CfIconButton(
                key: const ValueKey('bench_copy'),
                icon: Icons.copy_all_outlined,
                tooltip: 'Copy results',
                onPressed: busy ? null : _copy,
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatusLine(runner: runner),
                Expanded(
                  child: surface == null
                      ? _ResultsView(runner: runner)
                      : KeyedSubtree(
                          key: ValueKey('bench_view_${runner.generation}'),
                          child: surface.buildView(context),
                        ),
                ),
                const Divider(height: CfSpacing.hairline),
                Padding(
                  padding: const EdgeInsets.all(CfSpacing.sm),
                  child: runner.phase == BenchPhase.typing
                      ? _typingControls(runner)
                      : _mainControls(runner),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _mainControls(EditorBenchRunner runner) {
    final idle = runner.phase == BenchPhase.idle;
    final engines = runner.engines;
    final typingEngine = _typingEngine ?? engines.firstOrNull;
    return Wrap(
      spacing: CfSpacing.sm,
      runSpacing: CfSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        CfButton(
          key: const ValueKey('bench_run'),
          label: 'Run benchmark',
          icon: Icons.speed,
          onPressed: idle ? () => unawaited(runner.runAll()) : null,
        ),
        if (engines.isNotEmpty)
          SegmentedButton<String>(
            segments: [
              for (final engine in engines)
                ButtonSegment(value: engine, label: Text(_engineLabel(engine))),
            ],
            selected: {?typingEngine},
            showSelectedIcon: false,
            onSelectionChanged: idle
                ? (selection) => setState(() => _typingEngine = selection.first)
                : null,
          ),
        CfButton(
          key: const ValueKey('bench_typing'),
          label: 'Typing check',
          icon: Icons.keyboard_outlined,
          variant: CfButtonVariant.tonal,
          onPressed: idle && typingEngine != null
              ? () => unawaited(runner.openTyping(typingEngine))
              : null,
        ),
      ],
    );
  }

  Widget _typingControls(EditorBenchRunner runner) {
    final colors = CfColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButton<BenchPhrase>(
          key: const ValueKey('bench_phrase'),
          value: _phrase,
          isExpanded: true,
          items: [
            for (final phrase in benchPhrases)
              DropdownMenuItem(value: phrase, child: Text(phrase.label)),
          ],
          onChanged: (phrase) {
            if (phrase != null) {
              setState(() => _phrase = phrase);
              unawaited(runner.clearTyping());
            }
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: CfSpacing.xs),
          child: SelectableText(
            _phrase.text,
            key: const ValueKey('bench_phrase_text'),
            style: CfTypography.code(colors, fontSize: 16),
          ),
        ),
        Wrap(
          spacing: CfSpacing.sm,
          runSpacing: CfSpacing.sm,
          children: [
            CfButton(
              key: const ValueKey('bench_check'),
              label: 'Check',
              icon: Icons.check,
              onPressed: () => unawaited(runner.checkTyping(_phrase)),
            ),
            CfButton(
              label: 'Clear',
              icon: Icons.backspace_outlined,
              variant: CfButtonVariant.ghost,
              onPressed: () => unawaited(runner.clearTyping()),
            ),
            CfButton(
              key: const ValueKey('bench_typing_done'),
              label: 'Done',
              variant: CfButtonVariant.ghost,
              onPressed: () => unawaited(runner.closeTyping()),
            ),
          ],
        ),
      ],
    );
  }
}

String _engineLabel(String engine) => switch (engine) {
  'codemirror' => 'CodeMirror',
  'monaco' => 'Monaco',
  _ => engine,
};

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.runner});

  final EditorBenchRunner runner;

  @override
  Widget build(BuildContext context) {
    final step = runner.step;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CfSpacing.lg,
        CfSpacing.sm,
        CfSpacing.lg,
        CfSpacing.sm,
      ),
      child: Text(
        step == null ? runner.message : '${runner.message} — $step',
        key: const ValueKey('bench_status'),
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

/// What has been measured so far, readable on a phone.
class _ResultsView extends StatelessWidget {
  const _ResultsView({required this.runner});

  final EditorBenchRunner runner;

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final style = CfTypography.code(colors, fontSize: 12);
    if (runner.phase == BenchPhase.unavailable) {
      return Padding(
        padding: const EdgeInsets.all(CfSpacing.lg),
        child: CfBanner(message: runner.message, kind: CfBannerKind.warning),
      );
    }
    final lines = <String>[
      for (final page in runner.pages)
        '${_engineLabel(page.engine)} ${page.engineVersion}: '
            '${(page.gzipBytes / 1024).toStringAsFixed(0)} KiB gzipped',
      '',
      ...benchSummaryLines(runner.summary()),
      if (runner.typingChecks.isNotEmpty) '',
      for (final check in runner.typingChecks) _typingLine(check),
      if (runner.errors.isNotEmpty) '',
      for (final error in runner.errors) 'problem: $error',
      if (runner.pageErrors.isNotEmpty) '',
      for (final error in runner.pageErrors.take(10)) 'page: $error',
    ];
    return SingleChildScrollView(
      key: const ValueKey('bench_results'),
      padding: const EdgeInsets.all(CfSpacing.lg),
      child: Text(lines.join('\n'), style: style),
    );
  }
}

/// One typing check: the verdict, plus the real keyboard's input → frame
/// latency on this device when the page saw input events.
String _typingLine(Map<String, Object?> check) {
  final verdict = check['match'] == true ? 'match' : 'DIFFERS';
  final input = check['input'];
  final count = input is Map<String, Object?> ? input['count'] : null;
  final p95 = input is Map<String, Object?> ? input['p95Ms'] : null;
  final latency = count is num && count > 0 && p95 is num
      ? ', input p95 ${p95.toStringAsFixed(1)} ms over $count'
      : '';
  return 'typing ${check['engine']} ${check['phrase']}: $verdict '
      '(${check['inputMode']}$latency)';
}

/// One line per engine and metric: the medians over the runs.
List<String> benchSummaryLines(Map<String, Object?> summary) {
  String fmt(Object? value, String unit) =>
      value is num ? '${value.toStringAsFixed(1)} $unit' : '—';
  final lines = <String>[];
  for (final MapEntry(key: engine, value: entry) in summary.entries) {
    if (entry is! Map<String, Object?>) {
      continue;
    }
    final medians = entry['medians'];
    final m = medians is Map<String, Object?> ? medians : <String, Object?>{};
    lines
      ..add(
        '${_engineLabel(engine)} (${entry['runs']} runs, '
        'input ${entry['inputMode']}):',
      )
      ..add('  first frame      ${fmt(m['readyMs'], 'ms')}')
      ..add(
        '  typing p50/p95   ${fmt(m['typingP50Ms'], 'ms')} / '
        '${fmt(m['typingP95Ms'], 'ms')}',
      )
      ..add('  1 MiB open       ${fmt(m['largeOpenMs'], 'ms')}')
      ..add('  1 MiB typing p95 ${fmt(m['largeTypingP95Ms'], 'ms')}')
      ..add('  scroll >32 ms    ${fmt(m['scrollSlowFramePct'], '%')}')
      ..add(
        '  features ${entry['featuresOk'] == true ? 'ok' : 'FAILED'}, '
        'highlighting ${entry['highlightOk'] == true ? 'ok' : 'FAILED'}',
      );
  }
  if (lines.isEmpty) {
    lines.add('No runs yet. Tap "Run benchmark" (about 2 minutes).');
  }
  return lines;
}
