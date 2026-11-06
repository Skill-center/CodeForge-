/// Frame timing statistics behind Settings → Developer → Frame timing (G6
/// navigation frames on a device).
library;

import 'package:codeforge/services/perf/frame_stats.dart';
import 'package:flutter_test/flutter_test.dart';

FrameSample _frame(int totalMicros, {int build = 4000, int raster = 5000}) =>
    FrameSample(
      buildMicros: build,
      rasterMicros: raster,
      totalMicros: totalMicros,
    );

void main() {
  test('nearest-rank percentiles', () {
    final sorted = [for (var i = 1; i <= 20; i += 1) i];
    expect(nearestRank(sorted, 0.5), 10);
    expect(nearestRank(sorted, 0.95), 19);
    expect(nearestRank(sorted, 1), 20);
    expect(nearestRank([], 0.5), 0);
  });

  test('summarizes frames against the 16.7 and 32 ms lines', () {
    final recorder = FrameStatsRecorder();
    for (var i = 0; i < 95; i += 1) {
      recorder.record(_frame(10000));
    }
    recorder
      ..record(_frame(20000))
      ..record(_frame(32000)) // exactly 32 ms is within budget
      ..record(_frame(33000))
      ..record(_frame(40000, build: 30000))
      ..record(_frame(64000, raster: 50000));
    final summary = recorder.summary();
    expect(summary.frames, 100);
    expect(summary.p50TotalMs, 10);
    expect(summary.maxTotalMs, 64);
    expect(summary.over16Ms, 5);
    expect(summary.over32Ms, 3);
    expect(summary.over32Pct, 3);
    expect(summary.toJson()['over32Pct'], 3.0);
    expect(summary.p95BuildMs, 4);
  });

  test('keeps the latest frames and resets', () {
    final recorder = FrameStatsRecorder(capacity: 3);
    for (final total in [50000, 1000, 2000, 3000]) {
      recorder.record(_frame(total));
    }
    expect(recorder.length, 3);
    expect(recorder.summary().maxTotalMs, 3);
    recorder.reset();
    expect(recorder.summary().frames, 0);
    expect(recorder.summary().over32Pct, 0);
    expect(recorder.summary().since, isNotNull);
  });
}
