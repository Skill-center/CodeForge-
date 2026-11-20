import { beforeEach, describe, expect, it } from 'vitest';

import {
  chunks,
  type CellLike,
  type LineLike,
  type LinkProviderLike,
  NO_RESPONSE,
  TerminalController,
  type TerminalLike,
  TerminalPageError,
  type TerminalSettings,
} from '../src/terminal/controller';
import { fnv1a, hex32 } from '../src/terminal/probe';
import type { TerminalMessageType, TerminalTheme, TerminalToHost } from '../src/terminal/protocol';
import { FakeProbeClock, flushMicrotasks } from './helpers';

class Emitter<T> {
  private readonly listeners = new Set<(value: T) => void>();
  readonly event = (listener: (value: T) => void) => {
    this.listeners.add(listener);
    return { dispose: () => this.listeners.delete(listener) };
  };
  fire(value: T): void {
    for (const listener of [...this.listeners]) listener(value);
  }
  get size(): number {
    return this.listeners.size;
  }
}

class FakeLine implements LineLike {
  constructor(
    readonly text: string,
    readonly isWrapped = false,
  ) {}
  translateToString(trimRight?: boolean): string {
    return trimRight ? this.text.replace(/\s+$/, '') : this.text;
  }
  getCell(x: number): CellLike | undefined {
    if (x < 0 || x >= 80) return undefined;
    const ch = this.text[x] ?? '';
    return { getChars: () => ch, getWidth: () => 1 };
  }
}

const CELL_WIDTH = 10;
const CELL_HEIGHT = 20;

class FakeTerminal implements TerminalLike {
  cols = 80;
  rows = 4;
  element: HTMLElement | undefined;
  textarea: HTMLTextAreaElement | undefined;
  modes = { applicationCursorKeysMode: false, bracketedPasteMode: false };
  lines: FakeLine[] = [];
  bufferType: 'normal' | 'alternate' = 'normal';
  baseY = 0;
  viewportY = 0;
  cursorX = 0;
  cursorY = 0;
  options: TerminalLike['options'];
  readonly writes: Array<{ data: string; callback?: () => void }> = [];
  selection = '';
  readonly selected: Array<[number, number, number]> = [];
  readonly scrolled: number[] = [];
  focusCalls = 0;
  blurCalls = 0;
  clearCalls = 0;
  bottomCalls = 0;
  disposed = false;
  readonly data = new Emitter<string>();
  readonly binary = new Emitter<string>();
  readonly resized = new Emitter<{ cols: number; rows: number }>();
  readonly title = new Emitter<string>();
  readonly bell = new Emitter<void>();
  readonly selectionChange = new Emitter<void>();
  onData = this.data.event;
  onBinary = this.binary.event;
  onResize = this.resized.event;
  onTitleChange = this.title.event;
  onBell = this.bell.event;
  onSelectionChange = this.selectionChange.event;
  readonly linkProviders: LinkProviderLike[] = [];

  constructor(readonly settings: TerminalSettings) {
    this.options = { ...settings };
  }

  get buffer() {
    return {
      active: {
        type: this.bufferType,
        cursorX: this.cursorX,
        cursorY: this.cursorY,
        viewportY: this.viewportY,
        baseY: this.baseY,
        length: this.lines.length,
        getLine: (y: number) => this.lines[y],
      },
    };
  }

  open(parent: HTMLElement): void {
    this.element = parent;
    const screen = parent.ownerDocument.createElement('div');
    screen.className = 'xterm-screen';
    screen.getBoundingClientRect = () =>
      ({ left: 0, top: 0, width: this.cols * CELL_WIDTH, height: this.rows * CELL_HEIGHT }) as DOMRect;
    parent.appendChild(screen);
    const textarea = parent.ownerDocument.createElement('textarea');
    parent.appendChild(textarea);
    this.textarea = textarea;
  }
  write(data: string, callback?: () => void): void {
    this.writes.push({ data, callback });
  }
  registerLinkProvider(provider: LinkProviderLike) {
    this.linkProviders.push(provider);
    return { dispose: () => this.linkProviders.splice(this.linkProviders.indexOf(provider), 1) };
  }
  /** xterm.js parses what was written. */
  parse(): void {
    for (const write of this.writes.splice(0)) write.callback?.();
  }
  input(data: string): void {
    this.data.fire(data);
  }
  paste(data: string): void {
    let text = data.replace(/\r?\n/g, '\r');
    if (this.modes.bracketedPasteMode) text = `\x1b[200~${text}\x1b[201~`;
    this.data.fire(text);
  }
  focus(): void {
    this.focusCalls += 1;
    this.textarea?.focus();
  }
  blur(): void {
    this.blurCalls += 1;
    this.textarea?.blur();
  }
  clear(): void {
    this.clearCalls += 1;
  }
  hasSelection(): boolean {
    return this.selection !== '';
  }
  getSelection(): string {
    return this.selection;
  }
  selectAll(): void {
    this.selection = this.lines.map((line) => line.text).join('\n');
    this.selectionChange.fire();
  }
  clearSelection(): void {
    if (this.selection === '') return;
    this.selection = '';
    this.selectionChange.fire();
  }
  select(column: number, row: number, length: number): void {
    this.selected.push([column, row, length]);
    this.selection = 'selected';
    this.selectionChange.fire();
  }
  scrollLines(amount: number): void {
    this.scrolled.push(amount);
  }
  scrollToBottom(): void {
    this.bottomCalls += 1;
  }
  dispose(): void {
    this.disposed = true;
  }
  resizeTo(cols: number, rows: number): void {
    if (cols === this.cols && rows === this.rows) return;
    this.cols = cols;
    this.rows = rows;
    this.resized.fire({ cols, rows });
  }
}

type Sent = { type: TerminalMessageType; payload: unknown };

const theme: TerminalTheme = {
  dark: true,
  background: '#000000',
  foreground: '#FFFFFF',
  cursor: '#FF7A45',
  cursorAccent: '#000000',
  selection: '#FF7A4547',
  black: '#000001',
  red: '#000002',
  green: '#000003',
  yellow: '#000004',
  blue: '#000005',
  magenta: '#000006',
  cyan: '#000007',
  white: '#000008',
  brightBlack: '#000009',
  brightRed: '#00000A',
  brightGreen: '#00000B',
  brightYellow: '#00000C',
  brightBlue: '#00000D',
  brightMagenta: '#00000E',
  brightCyan: '#00000F',
  brightWhite: '#000010',
};

let parent: HTMLElement;
let sent: Sent[];
let terminals: FakeTerminal[];
let deferred: Array<() => void>;
let fitSize: { cols: number; rows: number };
let controller: TerminalController;

const of = <K extends TerminalMessageType>(type: K): Array<TerminalToHost[K]> =>
  sent.filter((m) => m.type === type).map((m) => m.payload as TerminalToHost[K]);

beforeEach(() => {
  document.body.innerHTML = '<div id="terminals"></div>';
  parent = document.getElementById('terminals') as HTMLElement;
  sent = [];
  terminals = [];
  deferred = [];
  fitSize = { cols: 50, rows: 20 };
  controller = new TerminalController({
    parent,
    emit: (type, payload) => sent.push({ type, payload }),
    createTerminal: (settings) => {
      const terminal = new FakeTerminal(settings);
      terminals.push(terminal);
      return { terminal, fit: () => terminal.resizeTo(fitSize.cols, fitSize.rows) };
    },
    defer: (callback) => deferred.push(callback),
  });
});

describe('sessions', () => {
  it('opens a view sized to the panel, shows it and answers its size', () => {
    const result = controller.handle('session.open', { sessionId: 3 });
    expect(result).toEqual({ cols: 50, rows: 20 });
    expect(of('session.resized')).toEqual([{ sessionId: 3, cols: 50, rows: 20 }]);
    const element = parent.querySelector<HTMLElement>('[data-session="3"]');
    expect(element?.style.display).toBe('');
    expect(controller.activeSession).toBe(3);
  });

  it('keeps a view opened in the background hidden until it is activated', () => {
    controller.handle('session.open', { sessionId: 1 });
    controller.handle('session.open', { sessionId: 2, activate: false });
    expect(controller.activeSession).toBe(1);
    expect(parent.querySelector<HTMLElement>('[data-session="2"]')?.style.display).toBe('none');
    controller.handle('session.activate', { sessionId: 2 });
    expect(parent.querySelector<HTMLElement>('[data-session="1"]')?.style.display).toBe('none');
    expect(parent.querySelector<HTMLElement>('[data-session="2"]')?.style.display).toBe('');
    expect(controller.activeSession).toBe(2);
  });

  it('refuses a second view for one session, and requests for unknown ones', () => {
    controller.handle('session.open', { sessionId: 1 });
    expect(() => controller.handle('session.open', { sessionId: 1 })).toThrow(TerminalPageError);
    const code = (fn: () => unknown) => {
      try {
        fn();
        return 'ok';
      } catch (error) {
        return (error as TerminalPageError).code;
      }
    };
    expect(code(() => controller.handle('session.open', { sessionId: 1 }))).toBe('session_exists');
    expect(code(() => controller.handle('session.activate', { sessionId: 9 }))).toBe('unknown_session');
    expect(code(() => controller.handle('session.write', { sessionId: 9, seq: 0, data: 'x' }))).toBe('unknown_session');
    expect(code(() => controller.handle('session.copy', { sessionId: 9 }))).toBe('unknown_session');
  });

  it('closing a view disposes its terminal, and its pending writes acknowledge nothing', () => {
    controller.handle('session.open', { sessionId: 1 });
    controller.handle('session.write', { sessionId: 1, seq: 4, data: 'late' });
    controller.handle('session.close', { sessionId: 1 });
    terminals[0].parse();
    expect(terminals[0].disposed).toBe(true);
    expect(terminals[0].data.size).toBe(0);
    expect(parent.querySelector('[data-session="1"]')).toBeNull();
    expect(controller.activeSession).toBeNull();
    expect(of('session.ack')).toEqual([]);
  });
});

describe('output and flow control', () => {
  it('writes in order and acknowledges each write once parsed, with its seq', () => {
    controller.handle('session.open', { sessionId: 1 });
    expect(controller.handle('session.write', { sessionId: 1, seq: 0, data: 'a' })).toBe(NO_RESPONSE);
    controller.handle('session.write', { sessionId: 1, seq: 1, data: 'b' });
    expect(of('session.ack')).toEqual([]);
    expect(terminals[0].writes.map((w) => w.data)).toEqual(['a', 'b']);
    terminals[0].parse();
    expect(of('session.ack')).toEqual([
      { sessionId: 1, seq: 0 },
      { sessionId: 1, seq: 1 },
    ]);
  });
});

describe('input', () => {
  beforeEach(() => {
    controller.handle('session.open', { sessionId: 1 });
  });

  it('sends what xterm.js sends, and mouse reports as binary', () => {
    terminals[0].data.fire('ls\r');
    terminals[0].binary.fire('\x1b[M !!');
    expect(of('session.input')).toEqual([
      { sessionId: 1, data: 'ls\r' },
      { sessionId: 1, data: '\x1b[M !!', binary: true },
    ]);
  });

  it('applies latched Ctrl to the next key only, and says it is released', () => {
    controller.handle('terminal.modifiers', { ctrl: true, alt: false });
    terminals[0].data.fire('c');
    terminals[0].data.fire('c');
    expect(of('session.input').map((p) => p.data)).toEqual(['\x03', 'c']);
    expect(of('terminal.modifiers')).toEqual([{ ctrl: false, alt: false }]);
  });

  it('applies latched Alt as a prefix', () => {
    controller.handle('terminal.modifiers', { ctrl: false, alt: true });
    terminals[0].data.fire('b');
    expect(of('session.input').map((p) => p.data)).toEqual(['\x1bb']);
  });

  it('sends extra keys in the cursor mode the program asked for', () => {
    terminals[0].modes.applicationCursorKeysMode = true;
    terminals[0].selection = 'old';
    controller.handle('session.key', { sessionId: 1, key: 'up' });
    controller.handle('session.key', { sessionId: 1, key: 'c', ctrl: true });
    expect(of('session.input').map((p) => p.data)).toEqual(['\x1bOA', '\x03']);
    expect(terminals[0].bottomCalls).toBe(2);
    expect(terminals[0].selection).toBe('');
  });

  it('pastes sanitized text, bracketed when the program asked, and leaves latched keys alone', () => {
    terminals[0].modes.bracketedPasteMode = true;
    controller.handle('terminal.modifiers', { ctrl: true, alt: false });
    controller.handle('session.paste', { sessionId: 1, text: 'echo hi\x1b[201~\r\nrm -rf x' });
    expect(of('session.input').map((p) => p.data)).toEqual(['\x1b[200~echo hi[201~\rrm -rf x\x1b[201~']);
    expect(of('terminal.modifiers')).toEqual([]);
    terminals[0].data.fire('d');
    expect(of('session.input').at(-1)?.data).toBe('\x04');
  });

  it('a paste of nothing but controls sends nothing', () => {
    controller.handle('session.paste', { sessionId: 1, text: '\x1b\x00' });
    controller.pasteIntoActive('\x07');
    expect(of('session.input')).toEqual([]);
  });

  it('sends the input method’s text once, as typed, and empties the textarea', () => {
    const textarea = terminals[0].textarea as HTMLTextAreaElement;
    expect(textarea.getAttribute('autocomplete')).toBe('off');
    controller.handle('terminal.modifiers', { ctrl: true, alt: false });
    const seenByXterm: string[] = [];
    textarea.addEventListener('input', () => seenByXterm.push('input'));
    textarea.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 229, bubbles: true }));
    textarea.value = 'c';
    textarea.dispatchEvent(new InputEvent('input', { data: 'c', inputType: 'insertText', bubbles: true }));
    textarea.value = 'at';
    textarea.dispatchEvent(new InputEvent('input', { data: 'at', inputType: 'insertText', bubbles: true }));
    expect(of('session.input').map((p) => p.data)).toEqual(['\x03', 'at']);
    expect(textarea.value).toBe('');
    expect(seenByXterm).toEqual([]);
  });

  it('shows a composition in xterm.js’s composition view until it ends', () => {
    const textarea = terminals[0].textarea as HTMLTextAreaElement;
    const box = document.createElement('div');
    box.className = 'composition-view';
    parent.querySelector('.xterm-screen')?.appendChild(box);
    terminals[0].cursorX = 3;
    terminals[0].cursorY = 2;
    // happy-dom's CompositionEvent keeps no data: it is given here.
    const composition = (type: string, data: string) => {
      const update = new CompositionEvent(type, { bubbles: true });
      Object.defineProperty(update, 'data', { value: data });
      return update;
    };
    textarea.dispatchEvent(composition('compositionstart', ''));
    textarea.dispatchEvent(composition('compositionupdate', 'かん'));
    textarea.value = 'かん';
    expect(box.classList.contains('active')).toBe(true);
    expect(box.textContent).toBe('かん');
    expect(box.style.left).toBe(`${3 * CELL_WIDTH}px`);
    expect(box.style.top).toBe(`${2 * CELL_HEIGHT}px`);
    textarea.value = '漢字';
    textarea.dispatchEvent(composition('compositionend', '漢字'));
    expect(box.classList.contains('active')).toBe(false);
    expect(of('session.input').map((p) => p.data)).toEqual(['漢字']);
  });

  it('splits long input without breaking a surrogate pair', () => {
    expect(chunks('abcdef', 4)).toEqual(['abcd', 'ef']);
    expect(chunks('ab😀cd', 3)).toEqual(['ab', '😀c', 'd']);
    expect(chunks('short', 10)).toEqual(['short']);
  });
});

describe('selection, copy and snapshot', () => {
  beforeEach(() => {
    controller.handle('session.open', { sessionId: 1 });
    terminals[0].lines = [
      new FakeLine('old line'),
      new FakeLine('$ ls src'),
      new FakeLine('main.js  util.js   '),
      new FakeLine('a very long line that'),
      new FakeLine(' wrapped', true),
    ];
    terminals[0].baseY = 1;
    terminals[0].rows = 4;
    terminals[0].cursorX = 2;
    terminals[0].cursorY = 3;
  });

  it('selects all, copies the text and drops the selection, reporting each change once', () => {
    controller.handle('session.select', { sessionId: 1, action: 'all' });
    expect(controller.handle('session.copy', { sessionId: 1 })).toEqual({ text: terminals[0].selection });
    controller.handle('session.select', { sessionId: 1, action: 'none' });
    controller.handle('session.select', { sessionId: 1, action: 'none' });
    expect(of('session.selection')).toEqual([
      { sessionId: 1, active: true },
      { sessionId: 1, active: false },
    ]);
  });

  it('a snapshot gives the screen, the scrollback asked for and the wrapped rows', () => {
    const snapshot = controller.handle('session.snapshot', { sessionId: 1, scrollback: 5 });
    expect(snapshot).toEqual({
      cols: 50,
      rows: 4,
      buffer: 'normal',
      cursorX: 2,
      cursorY: 3,
      screen: ['$ ls src', 'main.js  util.js', 'a very long line that', ' wrapped'],
      scrollback: ['old line'],
      wrapped: 1,
    });
  });

  it('a long press selects the word under the finger, and a drag extends it', () => {
    // Row 2 of the buffer is the screen's second row (baseY 1, viewportY 1).
    terminals[0].viewportY = 1;
    terminals[0].cols = 80;
    controller.gestures.down([{ clientX: 2 * CELL_WIDTH + 1, clientY: 1 * CELL_HEIGHT + 5 }]);
    (controller.gestures as unknown as { longPress(): void }).longPress();
    expect(terminals[0].selected.at(-1)).toEqual([0, 2, 7]); // "main.js"
    controller.gestures.move([{ clientX: 12 * CELL_WIDTH + 1, clientY: 1 * CELL_HEIGHT + 5 }]);
    expect(terminals[0].selected.at(-1)).toEqual([0, 2, 13]);
    controller.gestures.up();
  });

  it('a tap clears the selection and focuses the terminal', () => {
    terminals[0].selection = 'x';
    controller.gestures.down([{ clientX: 5, clientY: 5 }]);
    controller.gestures.up();
    expect(terminals[0].selection).toBe('');
    expect(terminals[0].focusCalls).toBe(1);
  });

  it('a tap on a file:line sends it, once, and leaves the keyboard down', () => {
    terminals[0].cols = 30;
    terminals[0].viewportY = 0;
    // Thirty columns: xterm.js wraps the frame after "main.".
    terminals[0].lines = [
      new FakeLine('    at main (/w/demo/src/main.'),
      new FakeLine('js:12:5)', true),
      new FakeLine('Done'),
    ];
    // The wrapped half of the path, on the screen's second row.
    controller.gestures.down([{ clientX: 3 * CELL_WIDTH + 1, clientY: 1 * CELL_HEIGHT + 5 }]);
    controller.gestures.up();
    expect(of('session.link')).toEqual([{ sessionId: 1, text: '/w/demo/src/main.js:12:5' }]);
    expect(terminals[0].focusCalls).toBe(0);
    // xterm.js's own link, from the mouse events the tap makes, is the same tap.
    let links: Parameters<Parameters<LinkProviderLike['provideLinks']>[1]>[0];
    terminals[0].linkProviders[0].provideLinks(2, (found) => {
      links = found;
    });
    expect(links!).toHaveLength(1);
    expect(links![0].range).toEqual({ start: { x: 14, y: 1 }, end: { x: 7, y: 2 } });
    links![0].activate(new MouseEvent('click'), links![0].text);
    expect(of('session.link')).toHaveLength(1);
    // A tap beside it focuses as before.
    controller.gestures.down([{ clientX: 1, clientY: 2 * CELL_HEIGHT + 5 }]);
    controller.gestures.up();
    expect(terminals[0].focusCalls).toBe(1);
    terminals[0].linkProviders[0].provideLinks(3, (found) => {
      links = found;
    });
    expect(links!).toBeUndefined();
  });

  it('clears the scrollback on request', () => {
    controller.handle('session.clear', { sessionId: 1 });
    expect(terminals[0].clearCalls).toBe(1);
  });
});

describe('appearance, focus and the program’s notices', () => {
  it('applies the theme and font size to every terminal, and to the ones opened later', () => {
    controller.handle('session.open', { sessionId: 1 });
    controller.handle('terminal.configure', { theme, fontSize: 16, scrollback: 500 });
    controller.handle('session.open', { sessionId: 2 });
    for (const terminal of terminals) {
      expect(terminal.options.theme?.selectionBackground).toBe('#FF7A4547');
      expect(terminal.options.theme?.brightWhite).toBe('#000010');
      expect(terminal.options.fontSize).toBe(16);
      expect(terminal.options.scrollback).toBe(500);
    }
    expect(terminals[1].settings.fontSize).toBe(16);
    expect(parent.style.background).not.toBe('');
  });

  it('focuses the active terminal on request and reports the focus once', () => {
    controller.handle('session.open', { sessionId: 1 });
    controller.handle('terminal.focus', { focused: true });
    expect(terminals[0].focusCalls).toBe(1);
    terminals[0].textarea?.dispatchEvent(new Event('focus'));
    terminals[0].textarea?.dispatchEvent(new Event('focus'));
    expect(of('terminal.focus')).toEqual([{ focused: true }]);
    controller.handle('terminal.focus', { focused: false });
    terminals[0].textarea?.dispatchEvent(new Event('blur'));
    for (const callback of deferred.splice(0)) callback();
    expect(of('terminal.focus')).toEqual([{ focused: true }, { focused: false }]);
  });

  it('forwards titles, clipped, and bells', () => {
    controller.handle('session.open', { sessionId: 5 });
    terminals[0].title.fire('t'.repeat(300));
    terminals[0].bell.fire();
    expect(of('session.title')).toEqual([{ sessionId: 5, title: 't'.repeat(256) }]);
    expect(of('session.bell')).toEqual([{ sessionId: 5 }]);
  });

  it('refits the shown terminal when the panel changes size', () => {
    controller.handle('session.open', { sessionId: 1 });
    fitSize = { cols: 90, rows: 12 };
    controller.layout();
    expect(of('session.resized').at(-1)).toEqual({ sessionId: 1, cols: 90, rows: 12 });
  });
});

describe('measurement (Phase 5 W6)', () => {
  /** A controller whose probe runs on the test's clock, with renderers the test controls. */
  function measured(options: { webgl?: 'ok' | 'fails' } = {}) {
    const clock = new FakeProbeClock();
    const views: Array<{ terminal: FakeTerminal; renderers: string[]; lose: (reason: string) => void }> = [];
    const probed = new TerminalController({
      parent,
      emit: (type, payload) => sent.push({ type, payload }),
      createTerminal: (settings) => {
        const terminal = new FakeTerminal(settings);
        terminals.push(terminal);
        const record = { terminal, renderers: [] as string[], lose: (_reason: string) => undefined as void };
        views.push(record);
        return {
          terminal,
          fit: () => terminal.resizeTo(fitSize.cols, fitSize.rows),
          setRenderer: (kind, lost) => {
            record.renderers.push(kind);
            record.lose = lost;
            if (kind === 'webgl' && options.webgl === 'fails') return { renderer: 'dom', error: 'WebGL2 not supported' };
            return { renderer: kind };
          },
        };
      },
      defer: (callback) => deferred.push(callback),
      probeClock: clock,
    });
    return { probed, clock, views };
  }

  it('puts every view on the configured renderer, new ones too, and reports them', () => {
    const { probed, views } = measured();
    probed.handle('session.open', { sessionId: 1 });
    expect(views[0]!.renderers).toEqual([]);
    probed.handle('terminal.configure', { renderer: 'webgl' });
    probed.handle('session.open', { sessionId: 2, activate: false });
    expect(views.map((v) => v.renderers)).toEqual([['webgl'], ['webgl']]);
    expect(probed.handle('probe.read', {})).toMatchObject({ state: 'idle', renderers: { '1': 'webgl', '2': 'webgl' } });
    // WebGL giving up leaves the view on the DOM's, and says why.
    views[0]!.lose('the WebGL context was lost');
    expect(probed.handle('probe.read', {})).toMatchObject({
      renderers: { '1': 'dom', '2': 'webgl' },
      webglError: 'the WebGL context was lost',
    });
    expect(of('terminal.log').at(-1)?.message).toContain('WebGL gave up');
    probed.handle('terminal.configure', { renderer: 'dom' });
    expect(views.map((v) => v.renderers.at(-1))).toEqual(['dom', 'dom']);
  });

  it('stays on the DOM renderer when WebGL cannot start, and says why', () => {
    const { probed } = measured({ webgl: 'fails' });
    probed.handle('session.open', { sessionId: 1 });
    probed.handle('terminal.configure', { renderer: 'webgl' });
    expect(probed.handle('probe.read', {})).toMatchObject({
      renderers: { '1': 'dom' },
      webglError: 'WebGL2 not supported',
    });
    expect(of('terminal.log').at(-1)?.message).toContain('WebGL could not start');
  });

  it('types through the input method path and times each echo from the buffer', async () => {
    const { probed, clock } = measured();
    probed.handle('session.open', { sessionId: 1 });
    const terminal = terminals[0]!;
    terminal.lines = [new FakeLine('demo $ ')];
    terminal.cursorX = 7;
    // The shell: 6 ms after each input its echo is written, then parsed.
    let seq = 0;
    let answered = 0;
    const shell = async () => {
      const inputs = of('session.input');
      while (answered < inputs.length) {
        const { data } = inputs[answered]!;
        answered += 1;
        await clock.sleep(6);
        const line = terminal.lines[0]!.text;
        const next = data === '\x7f' ? line.slice(0, -1) : line + data;
        probed.handle('session.write', { sessionId: 1, seq, data: data === '\x7f' ? '\b \b' : data });
        seq += 1;
        terminal.lines = [new FakeLine(next)];
        terminal.cursorX = next.length;
        terminal.parse();
      }
    };
    expect(probed.handle('probe.echo', { sessionId: 1, count: 2, gapMs: 10 })).toBeUndefined();
    for (let ms = 0; ms < 100; ms += 1) {
      void shell();
      await clock.advance(1);
    }
    expect(of('session.input').map((input) => input.data)).toEqual(['a', '\x7f', 'b', '\x7f']);
    // The textarea was emptied again, as for an input method's commit.
    expect(terminal.textarea?.value).toBe('');
    const report = probed.handle('probe.read', {}) as { state: string; echo: { samplesMs: number[]; lost: number } };
    expect(report.state).toBe('done');
    expect(report.echo.lost).toBe(0);
    // 6 ms to the echo, 4 more to the end of the frame that draws it.
    expect(report.echo.samplesMs).toEqual([10, 10]);
    expect(of('session.ack')).toHaveLength(4);
  });

  it('counts a flood in one session, still acknowledging every write', async () => {
    const { probed, clock } = measured();
    probed.handle('session.open', { sessionId: 1 });
    probed.handle('session.open', { sessionId: 2, activate: false });
    probed.handle('probe.flood', { sessionId: 1, begin: '<b>', end: '<e>' });
    probed.handle('session.write', { sessionId: 2, seq: 0, data: '<b>elsewhere<e>' });
    clock.time = 5;
    probed.handle('session.write', { sessionId: 1, seq: 0, data: '$ flood\r\n<b>abc' });
    clock.time = 9;
    probed.handle('session.write', { sessionId: 1, seq: 1, data: 'def<e>$ ' });
    for (const terminal of terminals) terminal.parse();
    await flushMicrotasks();
    const report = probed.handle('probe.read', {}) as {
      state: string;
      kind: string;
      flood: { chars: number; hash: string; ms: number; writes: number };
    };
    expect(report).toMatchObject({ state: 'done', kind: 'flood' });
    expect(report.flood).toMatchObject({ chars: 6, hash: hex32(fnv1a('abcdef')), ms: 8, writes: 2 });
    expect(of('session.ack')).toHaveLength(3);
  });

  it('refuses a probe for a session it has no view of, and fails one whose view closes', async () => {
    const { probed, clock } = measured();
    const code = (fn: () => unknown) => {
      try {
        fn();
        return null;
      } catch (error) {
        return (error as TerminalPageError).code;
      }
    };
    expect(code(() => probed.handle('probe.echo', { sessionId: 4, count: 3, gapMs: 0 }))).toBe('unknown_session');
    expect(code(() => probed.handle('probe.flood', { sessionId: 4, begin: 'b', end: 'e' }))).toBe('unknown_session');
    probed.handle('session.open', { sessionId: 4 });
    probed.handle('probe.echo', { sessionId: 4, count: 3, gapMs: 50 });
    await clock.advance(5);
    probed.handle('session.close', { sessionId: 4 });
    expect(probed.handle('probe.read', {})).toMatchObject({ state: 'failed', message: 'session 4 closed' });
  });
});
