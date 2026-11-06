/// Settings → Developer → Frame timing (debug and profile builds only): the
/// G6 navigation-frame check on a real device that Phase 1 left open
/// (docs/phases/PHASE_1_REPORT.md §7). Reset, move around the app, come
/// back, copy. Only profile builds give meaningful numbers.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/typography.dart';
import '../../../services/perf/frame_stats.dart';

class FrameTimingScreen extends StatefulWidget {
  const FrameTimingScreen({super.key, this.recorder});

  /// Defaults to the app-wide recorder bootstrap starts.
  final FrameStatsRecorder? recorder;

  @override
  State<FrameTimingScreen> createState() => _FrameTimingScreenState();
}

class _FrameTimingScreenState extends State<FrameTimingScreen> {
  late final FrameStatsRecorder _recorder = widget.recorder ?? frameStats;
  late final Timer _refresh;

  @override
  void initState() {
    super.initState();
    // Timings arrive in batches about once a second; follow them.
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _refresh.cancel();
    super.dispose();
  }

  Future<void> _copy(FrameStatsSummary summary) async {
    final report = {
      'kind': 'codeforge-frame-timing',
      'build': kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      ...summary.toJson(),
    };
    await Clipboard.setData(ClipboardData(text: jsonEncode(report)));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Frame timing copied as JSON')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final summary = _recorder.summary();
    final rows = <(String, String)>[
      ('Frames', '${summary.frames}'),
      ('Total p50 / p90', '${summary.p50TotalMs} / ${summary.p90TotalMs} ms'),
      ('Total p99 / max', '${summary.p99TotalMs} / ${summary.maxTotalMs} ms'),
      ('Build p95', '${summary.p95BuildMs} ms'),
      ('Raster p95', '${summary.p95RasterMs} ms'),
      ('Over 16.7 ms', '${summary.over16Ms}'),
      (
        'Over 32 ms (G6 ≤ 5 %)',
        '${summary.over32Ms} (${summary.over32Pct.toStringAsFixed(1)} %)',
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        leading: CfIconButton(
          icon: Icons.arrow_back,
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: const Text('Frame timing'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(CfSpacing.lg),
          children: [
            if (!kProfileMode)
              const Padding(
                padding: EdgeInsets.only(bottom: CfSpacing.md),
                child: CfBanner(
                  message:
                      'Debug builds run unoptimised code: use the profile '
                      'APK for numbers that count.',
                  kind: CfBannerKind.warning,
                ),
              ),
            Text(
              'Tap Reset, then go back and move around the app for about '
              'half a minute: home, workspace, settings, open and close the '
              'terminal and the command palette. Come back here and tap Copy.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: CfSpacing.lg),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: CfSpacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Text(value, style: CfTypography.code(colors, fontSize: 13)),
                  ],
                ),
              ),
            const SizedBox(height: CfSpacing.lg),
            Wrap(
              spacing: CfSpacing.sm,
              runSpacing: CfSpacing.sm,
              children: [
                CfButton(
                  key: const ValueKey('frames_reset'),
                  label: 'Reset',
                  icon: Icons.restart_alt,
                  variant: CfButtonVariant.tonal,
                  onPressed: () => setState(_recorder.reset),
                ),
                CfButton(
                  key: const ValueKey('frames_copy'),
                  label: 'Copy',
                  icon: Icons.copy_all_outlined,
                  onPressed: () => unawaited(_copy(summary)),
                ),
              ],
            ),
            if (!_recorder.isListening)
              Padding(
                padding: const EdgeInsets.only(top: CfSpacing.md),
                child: Text(
                  'Not recording: frame timing starts with the app in debug '
                  'and profile builds.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
