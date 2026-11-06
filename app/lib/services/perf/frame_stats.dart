/// Frame timings for Settings → Developer → Frame timing: the G6
/// navigation-frame check on a real device that Phase 1 left open
/// (docs/phases/PHASE_1_REPORT.md §7). The engine reports FrameTiming in
/// batches; the recorder keeps the latest [FrameStatsRecorder.capacity]
/// frames. Numbers are only meaningful in profile builds (debug frames run
/// unoptimised code).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// One frame, in microseconds.
@immutable
final class FrameSample {
  const FrameSample({
    required this.buildMicros,
    required this.rasterMicros,
    required this.totalMicros,
  });

  final int buildMicros;
  final int rasterMicros;

  /// Vsync to raster finish: what the user waits for.
  final int totalMicros;
}

@immutable
final class FrameStatsSummary {
  const FrameStatsSummary({
    required this.frames,
    required this.p50TotalMs,
    required this.p90TotalMs,
    required this.p99TotalMs,
    required this.maxTotalMs,
    required this.p95BuildMs,
    required this.p95RasterMs,
    required this.over16Ms,
    required this.over32Ms,
    required this.since,
  });

  final int frames;
  final double p50TotalMs;
  final double p90TotalMs;
  final double p99TotalMs;
  final double maxTotalMs;
  final double p95BuildMs;
  final double p95RasterMs;

  /// Frames whose total span exceeded 16.7 ms (one 60 Hz vsync).
  final int over16Ms;

  /// Frames whose total span exceeded 32 ms: the G6 budget allows ≤ 5 %.
  final int over32Ms;
  final DateTime? since;

  double get over32Pct => frames == 0 ? 0 : over32Ms * 100 / frames;

  Map<String, Object?> toJson() => {
    'frames': frames,
    'p50TotalMs': p50TotalMs,
    'p90TotalMs': p90TotalMs,
    'p99TotalMs': p99TotalMs,
    'maxTotalMs': maxTotalMs,
    'p95BuildMs': p95BuildMs,
    'p95RasterMs': p95RasterMs,
    'over16Ms': over16Ms,
    'over32Ms': over32Ms,
    'over32Pct': double.parse(over32Pct.toStringAsFixed(1)),
    'budget': 'G6: frames over 32 ms <= 5 %',
    'since': since?.toUtc().toIso8601String(),
  };
}

final class FrameStatsRecorder {
  FrameStatsRecorder({this.capacity = 2000});

  final int capacity;
  final List<FrameSample> _samples = [];
  DateTime? _since;
  bool _listening = false;

  int get length => _samples.length;
  bool get isListening => _listening;

  /// Starts listening to the engine's frame timings (idempotent).
  void start() {
    if (_listening) {
      return;
    }
    _listening = true;
    _since ??= DateTime.now();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void stop() {
    if (!_listening) {
      return;
    }
    _listening = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      record(
        FrameSample(
          buildMicros: timing.buildDuration.inMicroseconds,
          rasterMicros: timing.rasterDuration.inMicroseconds,
          totalMicros: timing.totalSpan.inMicroseconds,
        ),
      );
    }
  }

  void record(FrameSample sample) {
    _samples.add(sample);
    if (_samples.length > capacity) {
      _samples.removeRange(0, _samples.length - capacity);
    }
  }

  void reset() {
    _samples.clear();
    _since = DateTime.now();
  }

  FrameStatsSummary summary() {
    double ms(int micros) => (micros / 100).round() / 10;
    final total = [for (final s in _samples) s.totalMicros]..sort();
    final build = [for (final s in _samples) s.buildMicros]..sort();
    final raster = [for (final s in _samples) s.rasterMicros]..sort();
    return FrameStatsSummary(
      frames: total.length,
      p50TotalMs: ms(nearestRank(total, 0.50)),
      p90TotalMs: ms(nearestRank(total, 0.90)),
      p99TotalMs: ms(nearestRank(total, 0.99)),
      maxTotalMs: ms(total.isEmpty ? 0 : total.last),
      p95BuildMs: ms(nearestRank(build, 0.95)),
      p95RasterMs: ms(nearestRank(raster, 0.95)),
      over16Ms: total.where((t) => t > 16700).length,
      over32Ms: total.where((t) => t > 32000).length,
      since: _since,
    );
  }
}

/// Nearest-rank percentile of an ascending list ([q] in 0..1).
int nearestRank(List<int> sorted, double q) {
  if (sorted.isEmpty) {
    return 0;
  }
  final rank = (q * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

/// The app-wide recorder; bootstrap starts it in non-release builds.
final FrameStatsRecorder frameStats = FrameStatsRecorder();
