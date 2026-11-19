import { describe, expect, it } from 'vitest';

import { LONG_PRESS_MS, type TouchPoint, type TouchTarget, TOUCH_SLOP, TouchGestures } from '../src/terminal/touch';
import { FakeScheduler } from './helpers';

class Recorder implements TouchTarget {
  readonly calls: string[] = [];
  alternate = false;
  cell: number | null = 20;

  cellHeight(): number | null {
    return this.cell;
  }
  inAlternateBuffer(): boolean {
    return this.alternate;
  }
  scrollLines(lines: number): void {
    this.calls.push(`scroll ${lines}`);
  }
  arrows(direction: 'up' | 'down', count: number): void {
    this.calls.push(`arrows ${direction} ${count}`);
  }
  selectWordAt(point: TouchPoint): void {
    this.calls.push(`word ${point.clientX},${point.clientY}`);
  }
  extendSelectionTo(point: TouchPoint): void {
    this.calls.push(`extend ${point.clientX},${point.clientY}`);
  }
  tap(point: TouchPoint): void {
    this.calls.push(`tap ${point.clientX},${point.clientY}`);
  }
}

const at = (x: number, y: number): TouchPoint[] => [{ clientX: x, clientY: y }];

function gestures(): { target: Recorder; timers: FakeScheduler; touch: TouchGestures } {
  const target = new Recorder();
  const timers = new FakeScheduler();
  return { target, timers, touch: new TouchGestures(target, timers) };
}

describe('terminal touch', () => {
  it('a tap focuses, and only a tap', () => {
    const { target, touch } = gestures();
    expect(touch.down(at(10, 10))).toBe(true);
    expect(touch.move(at(10 + TOUCH_SLOP - 1, 10))).toBe(true);
    expect(touch.up()).toBe(true);
    expect(target.calls).toEqual(['tap 10,10']);
    expect(touch.active).toBe(false);
  });

  it('a drag down scrolls back by whole lines and carries the rest', () => {
    const { target, touch } = gestures();
    touch.down(at(50, 100));
    touch.move(at(50, 115)); // past the slop: a drag, but under a cell
    touch.move(at(50, 125)); // 25 px from the start: one line
    touch.move(at(50, 165)); // 65 px: three lines in all
    touch.up();
    expect(target.calls).toEqual(['scroll -1', 'scroll -2']);
  });

  it('a drag up scrolls forward', () => {
    const { target, touch } = gestures();
    touch.down(at(50, 200));
    touch.move(at(50, 150));
    touch.up();
    expect(target.calls).toEqual(['scroll 2']);
  });

  it('in the alternate buffer a drag sends arrow keys instead', () => {
    const { target, touch } = gestures();
    target.alternate = true;
    touch.down(at(50, 100));
    touch.move(at(50, 145));
    touch.move(at(50, 85));
    touch.up();
    expect(target.calls).toEqual(['arrows up 2', 'arrows down 2']);
  });

  it('a long press selects the word, and moving on extends the selection', () => {
    const { target, timers, touch } = gestures();
    touch.down(at(30, 40));
    expect(timers.tasks.size).toBe(1);
    timers.run(); // LONG_PRESS_MS later
    touch.move(at(90, 40));
    touch.move(at(120, 60));
    touch.up();
    expect(target.calls).toEqual(['word 30,40', 'extend 90,40', 'extend 120,60']);
    expect(LONG_PRESS_MS).toBeGreaterThan(300);
  });

  it('a drag cancels the long press', () => {
    const { target, timers, touch } = gestures();
    touch.down(at(30, 40));
    touch.move(at(30, 80));
    expect(timers.tasks.size).toBe(0);
    touch.up();
    expect(target.calls).toEqual(['scroll -2']);
  });

  it('a second finger cancels the gesture and is left to the WebView', () => {
    const { target, timers, touch } = gestures();
    touch.down(at(30, 40));
    expect(touch.move([...at(30, 50), ...at(80, 90)])).toBe(false);
    expect(timers.tasks.size).toBe(0);
    expect(touch.up()).toBe(false);
    expect(touch.down([...at(1, 1), ...at(2, 2)])).toBe(false);
    expect(target.calls).toEqual([]);
  });

  it('does not scroll before the terminal has a cell size', () => {
    const { target, touch } = gestures();
    target.cell = null;
    touch.down(at(50, 100));
    touch.move(at(50, 200));
    touch.up();
    expect(target.calls).toEqual([]);
  });
});
