import { describe, expect, it } from 'vitest';

import { ECHO_TIMEOUT_MS, type EchoTarget, FloodCounter, fnv1a, hex32, TerminalProbe } from '../src/terminal/probe';
import { FakeProbeClock as FakeClock, flushMicrotasks as flush } from './helpers';

/**
 * A shell at a prompt, as the echo probe sees its session: what is typed
 * comes back [echoMs] later as a write, which the probe sees before and
 * after it is "parsed"; DEL takes the last character back.
 */
class FakeShell implements EchoTarget {
  line = 'demo $ ';
  echoMs = 7;
  /** Characters typed that never come back (1-based). */
  readonly drop = new Set<number>();
  typed = 0;
  readonly inputs: string[] = [];

  constructor(
    private readonly clock: FakeClock,
    private readonly probe: () => TerminalProbe,
  ) {}

  beforeCursor(): string {
    return this.line.length > 0 ? this.line[this.line.length - 1]! : '';
  }
  cursorX(): number {
    return this.line.length;
  }
  type(text: string): void {
    this.typed += 1;
    this.inputs.push(text);
    if (this.drop.has(this.typed)) return;
    void this.clock.sleep(this.echoMs).then(() => this.output(text, () => (this.line += text)));
  }
  key(data: string): void {
    this.inputs.push(data);
    void this.clock.sleep(this.echoMs).then(() => this.output('\b \b', () => (this.line = this.line.slice(0, -1))));
  }
  private output(data: string, apply: () => void): void {
    const parsed = this.probe().write(1, data);
    apply();
    parsed?.();
  }
}

describe('FNV-1a', () => {
  it('matches the reference values and continues across pieces', () => {
    expect(hex32(fnv1a(''))).toBe('811c9dc5');
    expect(hex32(fnv1a('a'))).toBe('e40c292c');
    expect(hex32(fnv1a('foobar'))).toBe('bf9cf968');
    expect(fnv1a('bar', 0, 3, fnv1a('foo'))).toBe(fnv1a('foobar'));
    expect(fnv1a('xxfooyy', 2, 5)).toBe(fnv1a('foo'));
  });
});

describe('the flood counter', () => {
  const BEGIN = '\x1b]777;b\x07';
  const END = '\x1b]777;e\x07';

  it('counts and hashes exactly what lies between the marks, split anywhere', () => {
    const body = 'line one\r\nline two\r\n'.repeat(50);
    const stream = `$ python3 flood.py\r\n${BEGIN}${body}${END}demo $ `;
    for (const size of [1, 3, 7, 64, stream.length]) {
      const counter = new FloodCounter(BEGIN, END);
      let ended = 0;
      let at = 100;
      for (let i = 0; i < stream.length; i += size) {
        if (counter.feed(stream.slice(i, i + size), at)) ended += 1;
        at += 1;
      }
      expect(ended, `pieces of ${size}`).toBe(1);
      const figures = counter.figures();
      expect(figures.chars, `pieces of ${size}`).toBe(body.length);
      expect(figures.hash, `pieces of ${size}`).toBe(hex32(fnv1a(body)));
      expect(counter.beginAt).not.toBeNull();
    }
  });

  it('times from the first mark to the frame after the second, with the frames and long tasks between', () => {
    const counter = new FloodCounter('<b>', '<e>');
    counter.frame(5); // before the flood: not counted
    expect(counter.feed('noise<b>abc', 10)).toBe(false);
    counter.frame(16);
    counter.frame(32);
    counter.longTask(20, 60);
    counter.frame(90); // a 58 ms frame
    expect(counter.feed('defgh', 50)).toBe(false);
    expect(counter.feed('ij<e>tail', 95)).toBe(true);
    counter.frame(100);
    counter.finish(104);
    counter.frame(120); // after the flood: not counted
    counter.longTask(110, 70);
    const figures = counter.figures();
    expect(figures.chars).toBe('abcdefghij'.length);
    expect(figures.hash).toBe(hex32(fnv1a('abcdefghij')));
    expect(figures.writes).toBe(3);
    expect(figures.maxWriteChars).toBe('noise<b>abc'.length);
    expect(figures.ms).toBe(94);
    expect(figures.frames.frames).toBe(3);
    expect(figures.frames.slowFrames).toBe(1);
    expect(figures.frames.maxFrameMs).toBe(58);
    expect(figures.longTasks).toEqual({ count: 1, totalMs: 60, maxMs: 60 });
    expect(counter.finished).toBe(true);
    // Nothing after the end mark changes it.
    expect(counter.feed('<b>more<e>', 130)).toBe(false);
    expect(counter.figures().chars).toBe(10);
  });
});

describe('the echo probe', () => {
  it('types each character, times it to the frame that draws its echo, and erases it', async () => {
    const clock = new FakeClock();
    const probe = new TerminalProbe(clock);
    const shell = new FakeShell(clock, () => probe);
    probe.startEcho(1, shell, 3, 20);
    expect(probe.report({}).state).toBe('running');
    await clock.advance(200);
    const report = probe.report({ '1': 'dom' });
    expect(report.state).toBe('done');
    expect(report.kind).toBe('echo');
    expect(report.renderers).toEqual({ '1': 'dom' });
    // 7 ms to the echo, 4 more to the end of the frame that draws it.
    expect(report.echo?.samplesMs).toEqual([11, 11, 11]);
    expect(report.echo?.p95Ms).toBe(11);
    expect(report.echo?.lost).toBe(0);
    expect(report.echo?.typed).toBe(3);
    expect(shell.inputs).toEqual(['a', '\x7f', 'b', '\x7f', 'c', '\x7f']);
    expect(shell.line).toBe('demo $ ');
  });

  it('counts an echo that never comes as lost, and goes on', async () => {
    const clock = new FakeClock();
    const probe = new TerminalProbe(clock);
    const shell = new FakeShell(clock, () => probe);
    shell.drop.add(2);
    probe.startEcho(1, shell, 3, 10);
    await clock.advance(ECHO_TIMEOUT_MS + 200);
    const report = probe.report({});
    expect(report.state).toBe('done');
    expect(report.echo?.lost).toBe(1);
    expect(report.echo?.count).toBe(2);
    // The lost one needs no erasing.
    expect(shell.inputs).toEqual(['a', '\x7f', 'b', 'c', '\x7f']);
  });

  it('fails when the session closes, and a new probe replaces a running one', async () => {
    const clock = new FakeClock();
    const probe = new TerminalProbe(clock);
    const shell = new FakeShell(clock, () => probe);
    probe.startEcho(1, shell, 50, 10);
    await clock.advance(30);
    probe.closed(2);
    expect(probe.report({}).state).toBe('running');
    probe.closed(1);
    expect(probe.report({})).toMatchObject({ state: 'failed', message: 'session 1 closed' });
    probe.startEcho(1, shell, 50, 10);
    probe.armFlood(1, '<b>', '<e>');
    await clock.advance(500);
    // The echo run was given up: nothing more was typed after the flood probe began.
    const typed = shell.typed;
    await clock.advance(500);
    expect(shell.typed).toBe(typed);
    expect(probe.report({}).kind).toBe('flood');
  });

  it('runs a flood through the session writes, and stops recording frames once it ends', async () => {
    const clock = new FakeClock();
    const probe = new TerminalProbe(clock);
    probe.armFlood(4, '<b>', '<e>');
    expect(clock.frameListeners.size).toBe(1);
    expect(probe.write(3, '<b>other session<e>')).toBeNull();
    clock.time = 10;
    expect(probe.write(4, 'x<b>0123')).toBeNull();
    clock.frame(12);
    clock.time = 30;
    const parsed = probe.write(4, '4567<e>$ ');
    expect(parsed).not.toBeNull();
    clock.frame(28);
    parsed?.();
    await flush();
    const report = probe.report({ '4': 'webgl' });
    expect(report.state).toBe('done');
    expect(report.flood?.chars).toBe(8);
    expect(report.flood?.hash).toBe(hex32(fnv1a('01234567')));
    expect(report.flood?.ms).toBe(24);
    expect(report.flood?.frames.frames).toBe(1);
    expect(clock.frameListeners.size).toBe(0);
    expect(clock.taskListeners.size).toBe(0);
  });
});
