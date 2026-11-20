/**
 * The terminal's measurements, taken in the page (Phase 5 W6, gate G6:
 * ADR-0006's budgets as xterm.js's). The host starts one with `probe.echo`
 * or `probe.flood` and reads it with `probe.read`; the app's integration
 * tests do, on the emulator and on Test Lab's phone
 * (app/integration_test/terminal_measure.dart).
 *
 * **Echo.** The page types a character into a session the way an input
 * method's commit reaches it: the textarea's text and an `input` event,
 * through ime.ts and xterm.js's onData, so through the host to the session's
 * shell and back. Each is timed from that input to the end of the frame that
 * draws its echo, with the editor benchmark's instruments (bench/timing.ts:
 * a task posted from the next animation frame runs once that frame is
 * rendered; bench/stats.ts: nearest-rank percentiles). The echo is drawn
 * once a parsed write leaves the character before the cursor. Each is erased
 * again (DEL) before the next, so the line stays as it was.
 *
 * **Flood.** What a session writes between two marks is counted and hashed
 * (FNV-1a, 32 bits, over UTF-16 code units, as the test computes it), and
 * timed from the write that carries the first mark to the end of the frame
 * after the write with the second has been parsed. Meanwhile the page's
 * frames (the intervals between animation frames, slow over 32 ms) and its
 * long tasks are recorded: what the renderer comparison reads.
 *
 * DOM-free apart from [browserProbeClock], so test/terminal_probe.test.ts
 * drives it with a fake clock.
 */
import { type FrameSummary, frameSummary, round1, type Summary, summarize } from '../../bench/stats';
import { afterPaint } from '../../bench/timing';
import type { RendererKind } from './protocol';

/** Time, frames and long tasks: the browser's ([browserProbeClock]), or a test's. */
export interface ProbeClock {
  /** performance.now(). */
  now(): number;
  /** Resolves with the time the next frame has been rendered. */
  afterPaint(): Promise<number>;
  /** Resolves after [ms]. */
  sleep(ms: number): Promise<void>;
  /** Calls [callback] with every animation frame's time until the function it returns is called. */
  frames(callback: (time: number) => void): () => void;
  /** Calls [callback] with every long task until the function it returns is called. */
  longTasks(callback: (start: number, duration: number) => void): () => void;
}

/** One session, as the echo probe sees it. */
export interface EchoTarget {
  /** The character in the cell before the cursor, once the last write is parsed. */
  beforeCursor(): string;
  /** The cursor's column. */
  cursorX(): number;
  /** Types [text] as an input method's commit (ime.ts). */
  type(text: string): void;
  /** Sends [data] as a key would: the erase. */
  key(data: string): void;
}

export type ProbeState = 'idle' | 'running' | 'done' | 'failed';

export interface EchoFigures extends Summary {
  /** Characters whose echo never came within [ECHO_TIMEOUT_MS]. */
  lost: number;
  /** Characters typed. */
  typed: number;
  /** Every echo's time, in ms, in order. */
  samplesMs: number[];
}

export interface FloodFigures {
  /** UTF-16 code units between the marks. */
  chars: number;
  /** Their FNV-1a hash, 32 bits, as 8 hex digits. */
  hash: string;
  /** Writes from the one with the first mark to the one with the second. */
  writes: number;
  maxWriteChars: number;
  /** From the write with the first mark to the end of the frame after the second was parsed. */
  ms: number;
  /** The page's frames meanwhile. */
  frames: FrameSummary;
  longTasks: { count: number; totalMs: number; maxMs: number };
}

export interface ProbeReport {
  state: ProbeState;
  kind: 'echo' | 'flood' | null;
  sessionId: number | null;
  /** Why the probe failed. */
  message?: string;
  /** Each view's renderer now, by session id. */
  renderers: Record<string, RendererKind>;
  /** The last reason WebGL could not draw, if it ever failed. */
  webglError?: string;
  echo?: EchoFigures;
  flood?: FloodFigures;
}

/** How long a character's echo may take before it counts as lost (ms). */
export const ECHO_TIMEOUT_MS = 2000;
/** How long an erase may take before the probe gives up: the line is no longer known (ms). */
export const ERASE_TIMEOUT_MS = 10000;
/** The characters typed, in turn: lower-case letters, which no prompt redraw is made of. */
const ECHO_CHARACTERS = 'abcdefghijklmnopqrstuvwxyz';
/** The erase: what Backspace sends. */
const ERASE = '\x7f';
const FNV_OFFSET = 0x811c9dc5;
const FNV_PRIME = 0x01000193;
const SLOW_FRAME_MS = 32;

/** FNV-1a, 32 bits, of [text]'s UTF-16 code units from [from] to [to], continuing [hash]. */
export function fnv1a(text: string, from = 0, to = text.length, hash = FNV_OFFSET): number {
  let h = hash;
  for (let i = from; i < to; i += 1) h = Math.imul(h ^ text.charCodeAt(i), FNV_PRIME) >>> 0;
  return h >>> 0;
}

export const hex32 = (value: number): string => (value >>> 0).toString(16).padStart(8, '0');

/**
 * Where [mark] starts in [carry] followed by [data] from [from], or -1. The
 * carry is shorter than the mark, so a mark that starts in it ends within
 * the write's first characters.
 */
function locate(mark: string, carry: string, data: string, from: number): number {
  if (carry.length > 0) {
    const index = (carry + data.slice(from, from + mark.length - 1)).indexOf(mark);
    if (index >= 0 && index < carry.length) return index;
  }
  const index = data.indexOf(mark, from);
  return index < 0 ? -1 : carry.length + index - from;
}

/** The last [keep] characters of [carry] followed by [data] from [from]. */
function tail(carry: string, data: string, from: number, keep: number): string {
  if (keep <= 0) return '';
  if (data.length - from >= keep) return data.slice(data.length - keep);
  return (carry + data.slice(from)).slice(-keep);
}

/** A flood's count, hash and times, fed the session's writes in order. */
export class FloodCounter {
  private phase: 'waiting' | 'counting' | 'ending' | 'done' = 'waiting';
  /** Text held back: it may be the start of the mark looked for next. */
  private carry = '';
  private hash = FNV_OFFSET;
  chars = 0;
  writes = 0;
  maxWriteChars = 0;
  beginAt: number | null = null;
  endAt: number | null = null;
  private readonly frameTimes: number[] = [];
  private readonly tasks: Array<{ start: number; duration: number }> = [];

  constructor(
    private readonly begin: string,
    private readonly end: string,
  ) {}

  get finished(): boolean {
    return this.phase === 'done';
  }

  /**
   * Takes one write that arrived at [at]; true when it carries the end mark.
   * Only short strings are ever joined (the held-back text and a mark's
   * length of the write), so the probe adds no copy of the flood to the
   * page's heap.
   */
  feed(data: string, at: number): boolean {
    if (this.phase === 'ending' || this.phase === 'done') return false;
    let from = 0;
    if (this.phase === 'waiting') {
      const begin = locate(this.begin, this.carry, data, 0);
      if (begin < 0) {
        this.carry = tail(this.carry, data, 0, this.begin.length - 1);
        return false;
      }
      this.phase = 'counting';
      this.beginAt = at;
      // The held-back text is shorter than the mark, so the mark ends in this write.
      from = begin + this.begin.length - this.carry.length;
      this.carry = '';
    }
    this.writes += 1;
    this.maxWriteChars = Math.max(this.maxWriteChars, data.length);
    const end = locate(this.end, this.carry, data, from);
    if (end >= 0) {
      this.countFirst(data, from, end);
      this.carry = '';
      this.phase = 'ending';
      return true;
    }
    const total = this.carry.length + (data.length - from);
    const keep = Math.min(total, this.end.length - 1);
    const next = tail(this.carry, data, from, keep);
    this.countFirst(data, from, total - keep);
    this.carry = next;
    return false;
  }

  frame(time: number): void {
    if (this.phase === 'counting' || this.phase === 'ending') this.frameTimes.push(time);
  }

  longTask(start: number, duration: number): void {
    if (this.phase === 'counting' || this.phase === 'ending') this.tasks.push({ start, duration });
  }

  /** The frame after the end mark was parsed has been rendered, at [at]. */
  finish(at: number): void {
    if (this.phase !== 'ending') return;
    this.endAt = at;
    this.phase = 'done';
  }

  figures(): FloodFigures {
    const from = this.beginAt ?? 0;
    const to = this.endAt ?? from;
    const times = this.frameTimes.filter((t) => t >= from && t <= to);
    const intervals: number[] = [];
    for (let i = 1; i < times.length; i += 1) intervals.push(times[i]! - times[i - 1]!);
    const tasks = this.tasks.filter((task) => task.start >= from && task.start <= to);
    return {
      chars: this.chars,
      hash: hex32(this.hash),
      writes: this.writes,
      maxWriteChars: this.maxWriteChars,
      ms: round1(to - from),
      frames: frameSummary(intervals, SLOW_FRAME_MS),
      longTasks: {
        count: tasks.length,
        totalMs: round1(tasks.reduce((sum, task) => sum + task.duration, 0)),
        maxMs: round1(tasks.reduce((max, task) => Math.max(max, task.duration), 0)),
      },
    };
  }

  /** Counts the first [count] characters of the held-back text, then [data] from [from]. */
  private countFirst(data: string, from: number, count: number): void {
    const held = Math.min(count, this.carry.length);
    if (held > 0) this.count(this.carry, 0, held);
    if (count > held) this.count(data, from, from + count - held);
  }

  private count(text: string, from: number, to: number): void {
    this.hash = fnv1a(text, from, to, this.hash);
    this.chars += to - from;
  }
}

/** One probe at a time, for one session: a new one replaces the last. */
export class TerminalProbe {
  private state: ProbeState = 'idle';
  private kind: 'echo' | 'flood' | null = null;
  private sessionId: number | null = null;
  private message: string | undefined;
  private echo: EchoFigures | undefined;
  private flood: FloodCounter | null = null;
  /** Runs after each parsed write of the probed session, while an echo is awaited. */
  private onParsed: (() => void) | null = null;
  private stopFrames: (() => void) | null = null;
  private stopTasks: (() => void) | null = null;
  /** Bumped by every probe, so a stale run's steps change nothing. */
  private generation = 0;

  constructor(private readonly clock: ProbeClock) {}

  get running(): boolean {
    return this.state === 'running';
  }

  /** Starts typing [count] characters into [target] (session [sessionId]), [gapMs] apart. */
  startEcho(sessionId: number, target: EchoTarget, count: number, gapMs: number): void {
    const generation = this.begin(sessionId, 'echo');
    void this.runEcho(generation, target, count, gapMs).catch((error: unknown) =>
      this.fail(generation, error instanceof Error ? error.message : String(error)),
    );
  }

  /** Counts what session [sessionId] writes between [begin] and [end]. */
  armFlood(sessionId: number, begin: string, end: string): void {
    this.begin(sessionId, 'flood');
    const counter = new FloodCounter(begin, end);
    this.flood = counter;
    this.stopFrames = this.clock.frames((time) => counter.frame(time));
    this.stopTasks = this.clock.longTasks((start, duration) => counter.longTask(start, duration));
  }

  /**
   * A write for [sessionId] is about to be written: answers what to run once
   * xterm.js has parsed it, or null.
   */
  write(sessionId: number, data: string): (() => void) | null {
    if (this.state !== 'running' || sessionId !== this.sessionId) return null;
    const counter = this.flood;
    if (counter) {
      if (!counter.feed(data, this.clock.now())) return null;
      const generation = this.generation;
      return () => {
        void this.clock.afterPaint().then((at) => {
          if (generation !== this.generation) return;
          counter.finish(at);
          this.stopRecording();
          this.state = 'done';
        });
      };
    }
    const parsed = this.onParsed;
    return parsed ? () => this.onParsed?.() : null;
  }

  /** The session's view closed: a probe on it fails. */
  closed(sessionId: number): void {
    if (this.state === 'running' && sessionId === this.sessionId) {
      this.fail(this.generation, `session ${sessionId} closed`);
    }
  }

  report(renderers: Record<string, RendererKind>, webglError?: string): ProbeReport {
    const report: ProbeReport = {
      state: this.state,
      kind: this.kind,
      sessionId: this.sessionId,
      renderers,
    };
    if (this.message !== undefined) report.message = this.message;
    if (webglError !== undefined) report.webglError = webglError;
    if (this.echo) report.echo = this.echo;
    if (this.flood && this.flood.beginAt !== null) report.flood = this.flood.figures();
    return report;
  }

  /** A new probe; one still running is given up (its steps change nothing from now on). */
  private begin(sessionId: number, kind: 'echo' | 'flood'): number {
    this.stopRecording();
    this.generation += 1;
    this.state = 'running';
    this.kind = kind;
    this.sessionId = sessionId;
    this.message = undefined;
    this.echo = undefined;
    this.flood = null;
    this.onParsed = null;
    return this.generation;
  }

  private fail(generation: number, message: string): void {
    if (generation !== this.generation || this.state !== 'running') return;
    this.stopRecording();
    this.onParsed = null;
    this.message = message.slice(0, 500);
    this.state = 'failed';
  }

  private stopRecording(): void {
    this.stopFrames?.();
    this.stopTasks?.();
    this.stopFrames = null;
    this.stopTasks = null;
  }

  private async runEcho(generation: number, target: EchoTarget, count: number, gapMs: number): Promise<void> {
    const samples: number[] = [];
    let lost = 0;
    const home = target.cursorX();
    for (let i = 0; i < count; i += 1) {
      await this.clock.sleep(gapMs);
      if (generation !== this.generation) return;
      const ch = ECHO_CHARACTERS[i % ECHO_CHARACTERS.length]!;
      const echoed = this.until(() => target.beforeCursor() === ch);
      const start = this.clock.now();
      target.type(ch);
      if (!(await echoed)) {
        lost += 1;
      } else {
        const end = await this.clock.afterPaint();
        samples.push(round1(end - start));
      }
      if (generation !== this.generation) return;
      if (target.cursorX() !== home) {
        const erased = this.until(() => target.cursorX() === home, ERASE_TIMEOUT_MS);
        target.key(ERASE);
        if (!(await erased)) {
          throw new Error(`character ${i + 1} (${ch}) was not erased within ${ERASE_TIMEOUT_MS} ms`);
        }
      }
    }
    if (generation !== this.generation) return;
    this.echo = { ...summarize(samples), lost, typed: count, samplesMs: samples };
    this.onParsed = null;
    this.state = 'done';
  }

  /** Resolves true once [condition] holds after a parsed write, false after [timeoutMs]. */
  private until(condition: () => boolean, timeoutMs = ECHO_TIMEOUT_MS): Promise<boolean> {
    return new Promise((resolve) => {
      let settled = false;
      const settle = (value: boolean) => {
        if (settled) return;
        settled = true;
        this.onParsed = null;
        resolve(value);
      };
      this.onParsed = () => {
        if (condition()) settle(true);
      };
      void this.clock.sleep(timeoutMs).then(() => settle(false));
    });
  }
}

/** The browser's clock: performance.now, animation frames and the longtask observer. */
export function browserProbeClock(): ProbeClock {
  return {
    now: () => performance.now(),
    afterPaint: () => afterPaint(),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    frames: (callback) => {
      let stopped = false;
      const tick = (time: number) => {
        if (stopped) return;
        callback(time);
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      return () => {
        stopped = true;
      };
    },
    longTasks: (callback) => {
      if (typeof PerformanceObserver === 'undefined') return () => undefined;
      try {
        const observer = new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) callback(entry.startTime, entry.duration);
        });
        observer.observe({ type: 'longtask', buffered: false });
        return () => observer.disconnect();
      } catch {
        return () => undefined;
      }
    },
  };
}
