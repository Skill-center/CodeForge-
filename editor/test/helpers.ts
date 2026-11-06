import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import type { Scheduler } from '../src/editor/batcher';

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
