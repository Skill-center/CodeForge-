import { afterEach, describe, expect, it } from 'vitest';

import { bounce, messageType, probe } from '../bench/large_probe';

interface PageEntry {
  receive(raw: unknown): void;
}

const page = window as unknown as { codeforge?: PageEntry; codeforgeLargeProbe?: unknown };

const settle = (ms = 50) => new Promise((resolve) => setTimeout(resolve, ms));

describe('large-file probe (bench/large_probe.ts)', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('installs itself for the DevTools driver', () => {
    expect(page.codeforgeLargeProbe).toBe(probe);
  });

  it('bounces a scroll between the ends, from where the view was', () => {
    expect(bounce(0, 50, 100)).toBe(50);
    expect(bounce(0, 150, 100)).toBe(50);
    expect(bounce(0, 200, 100)).toBe(0);
    expect(bounce(80, 30, 100)).toBe(90);
    expect(bounce(80, 250, 100)).toBe(70);
  });

  it('reads the type from the start of a host message', () => {
    expect(messageType('{"v":1,"id":"h3","type":"doc.open","payload":{"text":"x"}}')).toBe('doc.open');
    expect(messageType('{"v":1,"id":"h4","payload":{}}')).toBe('?');
    expect(messageType('')).toBe('?');
  });

  it('times host messages at the page entry and still delivers every one', () => {
    expect(probe.watchMessages()).toBe(false);
    const received: unknown[] = [];
    let failing = false;
    page.codeforge = Object.freeze({
      receive(raw: unknown) {
        if (failing) throw new Error('rejected');
        received.push(raw);
      },
    });
    expect(probe.watchMessages()).toBe(true);
    expect(page.codeforge).not.toBeUndefined();

    const open = JSON.stringify({ v: 1, id: 'h1', type: 'doc.open', payload: { docId: 'd1', text: 'abc' } });
    page.codeforge?.receive(open);
    expect(received).toEqual([open]);
    failing = true;
    expect(() => page.codeforge?.receive('{"v":1,"id":"h2","type":"doc.close"}')).toThrow('rejected');

    const timings = probe.takeMessages();
    expect(timings.map((t) => [t.type, t.chars])).toEqual([
      ['doc.open', open.length],
      ['doc.close', 36],
    ]);
    for (const timing of timings) expect(timing.processMs).toBeGreaterThanOrEqual(0);
    expect(probe.takeMessages()).toEqual([]);
    // Watching again starts a fresh list on the same wrapper.
    failing = false;
    page.codeforge?.receive('{"type":"cmd.gotoLine"}');
    expect(probe.watchMessages()).toBe(true);
    expect(probe.takeMessages()).toEqual([]);
  });

  it('reports long tasks only where the browser observes them', () => {
    const supported =
      typeof PerformanceObserver !== 'undefined' &&
      (PerformanceObserver.supportedEntryTypes ?? []).includes('longtask');
    expect(probe.watchLongTasks()).toBe(supported);
    expect(probe.takeLongTasks()).toEqual({ supported, count: 0, totalMs: 0, maxMs: 0 });
  });

  it('names what is missing when the page has no editor', () => {
    expect(() => probe.dom()).toThrow('the page has no .cm-scroller');
    expect(() => probe.focusEditor()).toThrow('the page has no .cm-content');
    expect(() => probe.startTyping()).toThrow('the page has no .cm-editor');
  });

  it('counts the lines in the DOM and focuses the content', () => {
    document.body.innerHTML =
      '<div class="cm-editor"><div class="cm-scroller"><div class="cm-content" contenteditable="true">' +
      '<div class="cm-line">a</div><div class="cm-line">b</div><div class="cm-line">c</div></div></div></div>';
    expect(probe.dom().lines).toBe(3);
    expect(probe.focusEditor()).toBe(true);
    const heap = probe.heap();
    if (heap !== null) expect(heap.usedMB).toBeGreaterThan(0);
  });

  it('scrolls for the time asked and puts the view back', async () => {
    document.body.innerHTML = '<div class="cm-scroller"></div>';
    const scroller = document.querySelector<HTMLElement>('.cm-scroller');
    const stats = await probe.scroll(40, 6);
    expect(stats.frames).toBeGreaterThan(0);
    expect(stats.distancePx).toBeGreaterThanOrEqual(240);
    expect(stats.thresholdMs).toBe(32);
    expect(scroller?.scrollTop).toBe(0);
  });

  it('times key presses from the editor root until typing stops', async () => {
    document.body.innerHTML = '<div class="cm-editor"><div class="cm-content"></div></div>';
    probe.startTyping();
    const content = document.querySelector('.cm-content');
    content?.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true }));
    content?.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: 'a', bubbles: true }));
    await settle();
    const stats = probe.typingStats();
    expect(stats.count).toBe(1);
    expect(stats.events).toEqual({ keydown: 1, beforeinput: 1 });
    // Stopped: later keys are not counted.
    content?.dispatchEvent(new KeyboardEvent('keydown', { key: 'b', bubbles: true }));
    await settle();
    expect(probe.typingStats().count).toBe(1);
  });
});
