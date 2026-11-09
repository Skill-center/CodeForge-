/**
 * The large-file gate's probe in the real editor page (Phase 2 W7, gate G7).
 *
 * tool/large_cdp.mjs bundles this module and evaluates it in the app's
 * editor page through the WebView's DevTools socket, which only debug builds
 * open: nothing here ships in the app, and the page has no test hooks. It
 * measures what only the page can see, with the W3 benchmark's instruments
 * (input_recorder.ts, stats.ts), so the numbers compare with
 * editor_bench.json:
 *   - scrolling: scrollTop stepped every frame at a constant speed from where
 *     the view is, bouncing at the ends, timing each frame interval;
 *   - typing: real key events (the driver's Input.dispatchKeyEvent) timed
 *     from each input event to the end of the next frame;
 *   - each host message's handling: window.codeforge.receive is wrapped
 *     (it still does exactly what it did) to time how long the page spent
 *     on the message and when the next frame was painted, e.g. a doc.open;
 *   - long tasks (over 50 ms) on the page's main thread;
 *   - the JS heap, and how many lines the editor keeps in the DOM.
 */
import { InputRecorder, type InputStats } from './input_recorder';
import { frameSummary, type FrameSummary } from './stats';
import { afterPaint } from './timing';

export interface ScrollStats extends FrameSummary {
  distancePx: number;
  scrollMaxPx: number;
}

export interface LongTaskStats {
  supported: boolean;
  count: number;
  totalMs: number;
  maxMs: number;
}

export interface MessageTiming {
  type: string;
  chars: number;
  /** The page's synchronous work on the message. */
  processMs: number;
  /** From the message's arrival to the end of the next frame painted. */
  paintedMs: number | null;
}

export interface HeapStats {
  usedMB: number;
  totalMB: number;
}

export interface DomStats {
  lines: number;
  scrollHeightPx: number;
}

const round1 = (n: number): number => Math.round(n * 10) / 10;

/**
 * Where a scroll that bounces between 0 and `max` is after travelling
 * `travelled` px from `start` (the W3 harness bounces from 0).
 */
export function bounce(start: number, travelled: number, max: number): number {
  const at = (start + travelled) % (2 * max);
  return at > max ? 2 * max - at : at;
}

function element(selector: string): HTMLElement {
  const found = document.querySelector<HTMLElement>(selector);
  if (!found) throw new Error(`the page has no ${selector}`);
  return found;
}

function scroll(ms: number, pxPerMs: number): Promise<ScrollStats> {
  const scroller = element('.cm-scroller');
  const max = Math.max(1, scroller.scrollHeight - scroller.clientHeight);
  const from = scroller.scrollTop;
  const intervals: number[] = [];
  return new Promise((resolve) => {
    let start = -1;
    let previous = -1;
    const step = (now: number) => {
      if (start < 0) {
        start = now;
      } else {
        intervals.push(now - previous);
      }
      previous = now;
      const elapsed = now - start;
      if (elapsed >= ms) {
        // Back where it was, so typing starts at the cursor's view.
        scroller.scrollTop = from;
        resolve({ ...frameSummary(intervals), distancePx: Math.round(elapsed * pxPerMs), scrollMaxPx: max });
        return;
      }
      scroller.scrollTop = bounce(from, elapsed * pxPerMs, max);
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
}

interface PageEntry {
  receive(raw: unknown): void;
}

const messages: MessageTiming[] = [];
let wrapped = false;

/** The message type from the start of a host message (v, id, type, payload). */
export function messageType(raw: string): string {
  return /"type":"([^"]+)"/.exec(raw.slice(0, 200))?.[1] ?? '?';
}

function wrapReceive(): boolean {
  if (wrapped) return true;
  const page = window as unknown as { codeforge?: PageEntry };
  const original = page.codeforge;
  if (!original) return false;
  page.codeforge = Object.freeze({
    receive(raw: unknown): void {
      const start = performance.now();
      try {
        original.receive(raw);
      } finally {
        const text = typeof raw === 'string' ? raw : '';
        const timing: MessageTiming = {
          type: messageType(text),
          chars: text.length,
          processMs: round1(performance.now() - start),
          paintedMs: null,
        };
        messages.push(timing);
        void afterPaint(10000).then((end) => {
          timing.paintedMs = round1(end - start);
        });
      }
    },
  });
  wrapped = true;
  return true;
}

const recorder = new InputRecorder();
const longTasks: number[] = [];
let observer: PerformanceObserver | null = null;
const longTasksSupported =
  typeof PerformanceObserver !== 'undefined' && (PerformanceObserver.supportedEntryTypes ?? []).includes('longtask');

function collect(entries: PerformanceEntryList): void {
  for (const entry of entries) longTasks.push(entry.duration);
}

export const probe = {
  version: 1,

  /** Starts a fresh window of long tasks; false where they are not reported. */
  watchLongTasks(): boolean {
    if (!longTasksSupported) return false;
    if (observer) {
      collect(observer.takeRecords());
    } else {
      observer = new PerformanceObserver((list) => collect(list.getEntries()));
      observer.observe({ type: 'longtask' });
    }
    longTasks.length = 0;
    return true;
  },

  /** Starts a fresh list of host-message timings; false without a page entry. */
  watchMessages(): boolean {
    const ok = wrapReceive();
    messages.length = 0;
    return ok;
  },

  /** The host messages since watchMessages or the last take. */
  takeMessages(): MessageTiming[] {
    return messages.splice(0);
  },

  /** The long tasks since watchLongTasks or the last take. */
  takeLongTasks(): LongTaskStats {
    if (observer) collect(observer.takeRecords());
    const durations = longTasks.splice(0);
    return {
      supported: longTasksSupported,
      count: durations.length,
      totalMs: round1(durations.reduce((sum, ms) => sum + ms, 0)),
      maxMs: round1(durations.length === 0 ? 0 : Math.max(...durations)),
    };
  },

  scroll,

  /** Gives the editor the keyboard focus; true when it has it. */
  focusEditor(): boolean {
    const content = element('.cm-content');
    content.focus();
    return document.activeElement === content;
  },

  startTyping(): void {
    recorder.attach(element('.cm-editor'));
    recorder.reset();
  },

  typingStats(): InputStats {
    const stats = recorder.stats();
    recorder.dispose();
    return stats;
  },

  heap(): HeapStats | null {
    const memory = (performance as Performance & { memory?: { usedJSHeapSize: number; totalJSHeapSize: number } })
      .memory;
    if (!memory) return null;
    const mb = (bytes: number) => round1(bytes / (1024 * 1024));
    return { usedMB: mb(memory.usedJSHeapSize), totalMB: mb(memory.totalJSHeapSize) };
  },

  dom(): DomStats {
    return {
      lines: document.querySelectorAll('.cm-line').length,
      scrollHeightPx: element('.cm-scroller').scrollHeight,
    };
  },
};

(window as unknown as { codeforgeLargeProbe?: typeof probe }).codeforgeLargeProbe = probe;
