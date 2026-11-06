/** Pure statistics for the benchmark (unit-tested in test/bench_stats.test.ts). */

export interface Summary {
  count: number;
  p50Ms: number;
  p95Ms: number;
  maxMs: number;
  meanMs: number;
}

const round1 = (n: number): number => Math.round(n * 10) / 10;

/** Nearest-rank percentile of an ascending array (q in 0..1). */
export function percentile(sorted: readonly number[], q: number): number {
  if (sorted.length === 0) return 0;
  const rank = Math.max(1, Math.ceil(q * sorted.length));
  return sorted[Math.min(rank, sorted.length) - 1]!;
}

export function summarize(samples: readonly number[]): Summary {
  const sorted = [...samples].sort((a, b) => a - b);
  const total = sorted.reduce((sum, n) => sum + n, 0);
  return {
    count: sorted.length,
    p50Ms: round1(percentile(sorted, 0.5)),
    p95Ms: round1(percentile(sorted, 0.95)),
    maxMs: round1(sorted.length === 0 ? 0 : sorted[sorted.length - 1]!),
    meanMs: round1(sorted.length === 0 ? 0 : total / sorted.length),
  };
}

export interface FrameSummary {
  frames: number;
  slowFrames: number;
  /** Share of frames slower than the threshold, in percent. */
  slowFramePct: number;
  p95FrameMs: number;
  maxFrameMs: number;
  thresholdMs: number;
}

/** Frame intervals (ms between consecutive frames) against a jank threshold. */
export function frameSummary(intervals: readonly number[], thresholdMs = 32): FrameSummary {
  const sorted = [...intervals].sort((a, b) => a - b);
  const slow = intervals.filter((ms) => ms > thresholdMs).length;
  return {
    frames: intervals.length,
    slowFrames: slow,
    slowFramePct: intervals.length === 0 ? 0 : round1((slow / intervals.length) * 100),
    p95FrameMs: round1(percentile(sorted, 0.95)),
    maxFrameMs: round1(sorted.length === 0 ? 0 : sorted[sorted.length - 1]!),
    thresholdMs,
  };
}

/** Index of the first UTF-16 code unit where two strings differ, or -1. */
export function firstDifference(a: string, b: string): number {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i += 1) if (a.charCodeAt(i) !== b.charCodeAt(i)) return i;
  return a.length === b.length ? -1 : n;
}

export const toMB = (bytes: number): number => Math.round((bytes / (1024 * 1024)) * 10) / 10;
export { round1 };
