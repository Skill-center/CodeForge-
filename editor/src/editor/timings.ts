/**
 * How long the page's completion lists take (Phase 6 W6, gate G6: the
 * completion budget, PERFORMANCE §2 — within 300 ms at the 95th percentile,
 * warm, from the request in the page to the list drawn).
 *
 * Each list the page asks a server for (lsp.ts) is timed from the request,
 * taken before the edits not sent yet go ahead of it, to the end of the
 * frame that draws it, with the editor benchmark's instrument
 * (bench/timing.ts: a task posted from the next animation frame runs once
 * that frame is rendered). The answer's arrival is noted on the way. A list
 * counts as drawn once CodeMirror's open list holds its options: the view
 * update that opens it builds the list's DOM, and the next frame positions
 * and paints it. A list that is never drawn, closed or replaced before it
 * opened, is counted, not timed.
 *
 * The host reads the times with `probe.read` (app/integration_test/
 * lsp_measure.dart does, on Test Lab's phone and on the emulator). The page
 * keeps the newest [MAX_TIMINGS].
 *
 * DOM-free apart from [browserTimingClock], so test/lsp.test.ts drives it
 * with a fake clock.
 */
import { type Completion, currentCompletions } from '@codemirror/autocomplete';
import type { EditorState } from '@codemirror/state';

import { afterPaint, throttledFrames } from '../../bench/timing';
import type { CompletionTiming, CompletionTrigger, ProbeReport } from '../protocol/types';

/** Time and frames: the browser's ([browserTimingClock]), or a test's. */
export interface TimingClock {
  /** performance.now(). */
  now(): number;
  /** Resolves with the time the next frame has been rendered. */
  afterPaint(): Promise<number>;
  /** How often [afterPaint] gave up waiting for a frame (a hidden page draws none). */
  throttled(): number;
}

export const browserTimingClock: TimingClock = {
  now: () => performance.now(),
  afterPaint: () => afterPaint(),
  throttled: () => throttledFrames,
};

/** The completion lists whose times the page keeps: the newest. */
export const MAX_TIMINGS = 500;

/** An answer whose list is not drawn yet. */
interface Awaited {
  readonly options: ReadonlySet<Completion>;
  readonly started: number;
  readonly answered: number;
  readonly trigger: CompletionTrigger;
}

const round1 = (ms: number): number => Math.round(ms * 10) / 10;

export class CompletionTimings {
  private readonly kept: CompletionTiming[] = [];
  private awaited: Awaited | null = null;
  private undrawn = 0;
  private empty = 0;
  private throttledBefore: number;

  constructor(private readonly clock: TimingClock) {
    this.throttledBefore = clock.throttled();
  }

  /** Whether an answer's list is still to be drawn. */
  get waiting(): boolean {
    return this.awaited !== null;
  }

  /** The time now: a request starts. */
  now(): number {
    return this.clock.now();
  }

  /**
   * The answer to the request that [started] came, with [options] to draw;
   * none means nothing is drawn. An answer still waiting for its list is
   * not drawn now.
   */
  answered(started: number, options: readonly Completion[], trigger: CompletionTrigger): void {
    if (this.awaited !== null) this.undrawn += 1;
    if (options.length === 0) {
      this.awaited = null;
      this.empty += 1;
      return;
    }
    this.awaited = { options: new Set(options), started, answered: this.clock.now(), trigger };
  }

  /** After each view update: once the awaited list is open, times the frame that draws it. */
  update(state: EditorState): void {
    const awaited = this.awaited;
    if (awaited === null) return;
    const open = currentCompletions(state);
    if (!open.some((option) => awaited.options.has(option))) return;
    this.awaited = null;
    void this.clock.afterPaint().then((painted) => {
      this.kept.push({
        ms: round1(painted - awaited.started),
        answerMs: round1(awaited.answered - awaited.started),
        items: awaited.options.size,
        trigger: awaited.trigger,
      });
      if (this.kept.length > MAX_TIMINGS) this.kept.splice(0, this.kept.length - MAX_TIMINGS);
    });
  }

  /** What was measured since the last time it was cleared; with [clear], counting starts again. */
  read(clear: boolean): ProbeReport {
    const throttled = this.clock.throttled();
    const report: ProbeReport = {
      completions: [...this.kept],
      undrawn: this.undrawn,
      empty: this.empty,
      throttled: throttled - this.throttledBefore,
    };
    if (clear) {
      this.kept.length = 0;
      this.undrawn = 0;
      this.empty = 0;
      this.throttledBefore = throttled;
    }
    return report;
  }
}
