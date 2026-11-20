import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import type { Scheduler } from '../src/editor/batcher';
import type { ProbeClock } from '../src/terminal/probe';

// Resolve from the string: under happy-dom the global URL is happy-dom's,
// which node:url rejects.
export const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), 'fixtures');

export function readFixtures<T>(dir: string): Array<{ name: string; data: T }> {
  const path = join(FIXTURES, dir);
  return readdirSync(path)
    .filter((f) => f.endsWith('.json'))
    .sort()
    .map((f) => ({ name: f.replace(/\.json$/, ''), data: JSON.parse(readFileSync(join(path, f), 'utf8')) as T }));
}

/** A scheduler driven by the test: `run()` fires every due callback. */
export class FakeScheduler implements Scheduler {
  private next = 1;
  readonly tasks = new Map<number, () => void>();

  set(callback: () => void): unknown {
    const handle = this.next++;
    this.tasks.set(handle, callback);
    return handle;
  }

  clear(handle: unknown): void {
    this.tasks.delete(handle as number);
  }

  run(): void {
    const due = [...this.tasks.entries()];
    this.tasks.clear();
    for (const [, callback] of due) callback();
  }
}

/** Small deterministic PRNG (mulberry32) so property tests are reproducible. */
export function prng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Lets pending promise callbacks run. */
export async function flushMicrotasks(): Promise<void> {
  for (let i = 0; i < 10; i += 1) await Promise.resolve();
}

/**
 * The terminal probe's clock in the test's hands (src/terminal/probe.ts):
 * time moves only with advance(), which runs due timers; frames and long
 * tasks fire when the test says.
 */
export class FakeProbeClock implements ProbeClock {
  time = 0;
  /** How long after now the next frame is rendered. */
  paintDelay = 4;
  private timers: Array<{ at: number; resolve: () => void }> = [];
  readonly frameListeners = new Set<(time: number) => void>();
  readonly taskListeners = new Set<(start: number, duration: number) => void>();

  now(): number {
    return this.time;
  }
  afterPaint(): Promise<number> {
    return Promise.resolve(this.time + this.paintDelay);
  }
  sleep(ms: number): Promise<void> {
    return new Promise((resolve) => this.timers.push({ at: this.time + ms, resolve }));
  }
  frames(callback: (time: number) => void): () => void {
    this.frameListeners.add(callback);
    return () => this.frameListeners.delete(callback);
  }
  longTasks(callback: (start: number, duration: number) => void): () => void {
    this.taskListeners.add(callback);
    return () => this.taskListeners.delete(callback);
  }
  frame(time: number): void {
    for (const listener of [...this.frameListeners]) listener(time);
  }
  task(start: number, duration: number): void {
    for (const listener of [...this.taskListeners]) listener(start, duration);
  }
  /** Moves time on by [ms], 1 ms at a time, running due timers and what they start. */
  async advance(ms: number): Promise<void> {
    for (let step = 0; step < ms; step += 1) {
      this.time += 1;
      const due = this.timers.filter((timer) => timer.at <= this.time);
      this.timers = this.timers.filter((timer) => timer.at > this.time);
      for (const timer of due) timer.resolve();
      await flushMicrotasks();
    }
  }
}
