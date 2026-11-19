import { beforeEach, describe, expect, it } from 'vitest';

import {
  chunks,
  type CellLike,
  type LineLike,
  NO_RESPONSE,
  TerminalController,
  type TerminalLike,
  TerminalPageError,
  type TerminalSettings,
} from '../src/terminal/controller';
import type { TerminalMessageType, TerminalTheme, TerminalToHost } from '../src/terminal/protocol';

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
  /** xterm.js parses what was written. */
  parse(): void {
    for (const write of this.writes.splice(0)) write.callback?.();
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
