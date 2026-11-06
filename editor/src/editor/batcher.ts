import type { ChangeSet } from '@codemirror/state';

/** Timer seam, so tests can drive time explicitly. */
export interface Scheduler {
  set(callback: () => void, ms: number): unknown;
  clear(handle: unknown): void;
}

export const browserScheduler: Scheduler = {
  set: (callback, ms) => setTimeout(callback, ms),
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/**
 * Groups edits into one change set per document, so the host receives at most
 * one message per `delayMs` while the user types (spec §6.3: no full-document
 * sync per keystroke). The first pending edit starts the timer, later edits
 * join the same batch, and callers flush early on blur, save, tab switch and
 * page hide.
 */
export class ChangeBatcher {
  private readonly pending = new Map<string, ChangeSet>();
  private timer: unknown = null;

  constructor(
    private readonly onFlush: (docId: string, changes: ChangeSet) => void,
    private readonly delayMs = 150,
    private readonly scheduler: Scheduler = browserScheduler,
  ) {}

  add(docId: string, changes: ChangeSet): void {
    const prev = this.pending.get(docId);
    this.pending.set(docId, prev ? prev.compose(changes) : changes);
    if (this.timer === null) {
      this.timer = this.scheduler.set(() => {
        this.timer = null;
        this.flushAll();
      }, this.delayMs);
    }
  }

  hasPending(docId: string): boolean {
    return this.pending.has(docId);
  }

  flush(docId: string): void {
    const changes = this.pending.get(docId);
    if (changes === undefined) return;
    this.pending.delete(docId);
    this.stopTimerIfIdle();
    // Edits that cancel out (type, then delete) compose to an empty set.
    if (!changes.empty) this.onFlush(docId, changes);
  }

  flushAll(): void {
    for (const docId of [...this.pending.keys()]) this.flush(docId);
  }

  /** Drops pending edits, for a document that is being replaced or closed. */
  discard(docId: string): void {
    this.pending.delete(docId);
    this.stopTimerIfIdle();
  }

  private stopTimerIfIdle(): void {
    if (this.pending.size === 0 && this.timer !== null) {
      this.scheduler.clear(this.timer);
      this.timer = null;
    }
  }
}
