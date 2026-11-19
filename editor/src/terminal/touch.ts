/**
 * Touch for the terminal (Phase 5 W3). xterm.js 6 reads the mouse and the
 * wheel but no touch, so in Android's WebView a finger could neither scroll
 * nor select. This turns touches into what a terminal app on a phone does:
 *   - a drag scrolls: the scrollback in the normal buffer, arrow keys in the
 *     alternate buffer (less, man, nano, vim), as Termux does;
 *   - a long press selects the word under the finger, and moving on extends
 *     the selection; the app's toolbar then offers Copy;
 *   - a tap focuses the terminal, which brings up the keyboard.
 * The page cancels a drag's and a long press's touches, never a tap's
 * (main.ts): the WebView takes the app's focus only from a tap it sees,
 * and until it has the focus Chromium dispatches no focus event to the
 * page, so xterm.js's input would take the focus without the keyboard or
 * a word to the host (phase gate 44557551890).
 * The gesture logic is DOM-free apart from the event shapes, so
 * test/terminal_touch.test.ts drives it with plain objects.
 */

export interface TouchPoint {
  clientX: number;
  clientY: number;
}

/** What a gesture does to the active terminal. */
export interface TouchTarget {
  /** The size of one cell in CSS pixels, or null before the first render. */
  cellHeight(): number | null;
  inAlternateBuffer(): boolean;
  /** Scrolls the viewport by [lines]: negative towards older output. */
  scrollLines(lines: number): void;
  /** Sends [count] arrow keys, as the alternate buffer's programs expect. */
  arrows(direction: 'up' | 'down', count: number): void;
  selectWordAt(point: TouchPoint): void;
  extendSelectionTo(point: TouchPoint): void;
  tap(point: TouchPoint): void;
}

export interface Timers {
  set(callback: () => void, ms: number): unknown;
  clear(handle: unknown): void;
}

export const LONG_PRESS_MS = 450;
/** How far a finger may wander before a press becomes a drag (CSS pixels). */
export const TOUCH_SLOP = 8;

type State = 'idle' | 'pressed' | 'dragging' | 'selecting';

/** How a gesture ended: the page leaves a tap to the WebView and cancels a drag's or a selection's touches. */
export type GestureEnd = 'tap' | 'drag' | 'select' | null;

export class TouchGestures {
  private state: State = 'idle';
  private start: TouchPoint = { clientX: 0, clientY: 0 };
  private lastY = 0;
  private carry = 0;
  private timer: unknown = null;

  constructor(
    private readonly target: TouchTarget,
    private readonly timers: Timers = {
      set: (callback, ms) => setTimeout(callback, ms),
      clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
    },
  ) {}

  /** True while a gesture is in progress. */
  get active(): boolean {
    return this.state !== 'idle';
  }

  /**
   * True once the gesture is a drag or a selection: the page then keeps its
   * moves from the WebView. A finger still within the slop may yet be a tap.
   */
  get consuming(): boolean {
    return this.state === 'dragging' || this.state === 'selecting';
  }

  /** A finger down; a second finger cancels the gesture. Returns whether the page follows it. */
  down(points: readonly TouchPoint[]): boolean {
    if (points.length !== 1) {
      this.cancel();
      return false;
    }
    this.cancelTimer();
    this.state = 'pressed';
    this.start = { clientX: points[0].clientX, clientY: points[0].clientY };
    this.lastY = points[0].clientY;
    this.carry = 0;
    this.timer = this.timers.set(() => this.longPress(), LONG_PRESS_MS);
    return true;
  }

  move(points: readonly TouchPoint[]): boolean {
    if (this.state === 'idle') return false;
    if (points.length !== 1) {
      this.cancel();
      return false;
    }
    const point = points[0];
    if (this.state === 'pressed') {
      const dx = point.clientX - this.start.clientX;
      const dy = point.clientY - this.start.clientY;
      if (Math.hypot(dx, dy) <= TOUCH_SLOP) return true;
      this.cancelTimer();
      this.state = 'dragging';
    }
    if (this.state === 'selecting') {
      this.target.extendSelectionTo(point);
      return true;
    }
    this.scrollBy(point.clientY - this.lastY);
    this.lastY = point.clientY;
    return true;
  }

  /** The finger lifted: a press that never became a drag or a selection is a tap. */
  up(): GestureEnd {
    const state = this.state;
    this.cancelTimer();
    this.state = 'idle';
    switch (state) {
      case 'pressed':
        this.target.tap(this.start);
        return 'tap';
      case 'dragging':
        return 'drag';
      case 'selecting':
        return 'select';
      default:
        return null;
    }
  }

  cancel(): void {
    this.cancelTimer();
    this.state = 'idle';
  }

  private longPress(): void {
    this.timer = null;
    if (this.state !== 'pressed') return;
    this.state = 'selecting';
    this.target.selectWordAt(this.start);
  }

  /** A finger moving down [dy] pixels shows older lines: the scrollback moves up. */
  private scrollBy(dy: number): void {
    const cell = this.target.cellHeight();
    if (cell === null || cell <= 0) return;
    this.carry += dy;
    const lines = Math.trunc(this.carry / cell);
    if (lines === 0) return;
    this.carry -= lines * cell;
    if (this.target.inAlternateBuffer()) {
      this.target.arrows(lines > 0 ? 'up' : 'down', Math.abs(lines));
    } else {
      this.target.scrollLines(-lines);
    }
  }

  private cancelTimer(): void {
    if (this.timer !== null) {
      this.timers.clear(this.timer);
      this.timer = null;
    }
  }
}
