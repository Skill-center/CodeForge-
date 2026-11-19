/**
 * The terminal page's controller (Phase 5 W3): one xterm.js instance per
 * session, one of them shown, in one WebView. It turns host messages into
 * calls on those terminals and their events into page messages:
 *   - output is written in order, and each write is acknowledged once
 *     xterm.js has parsed it (`session.ack`), which is the host's credit;
 *   - what xterm.js sends (keys, the input method, mouse reports) goes out
 *     as `session.input`, with the latched Ctrl and Alt applied once;
 *   - the extra-keys row's keys become the sequences the terminal's modes
 *     expect (keys.ts); pasted text is sanitized first;
 *   - sizes come from the panel (addon-fit), touches scroll and select
 *     (touch.ts).
 * xterm.js is reached through [TerminalLike], so test/terminal_controller
 * drives this with a fake terminal; main.ts passes the real one.
 */
import { IME_EVENTS, type ImeEvent, ImeInput } from './ime';
import { applyModifiers, keySequence, sanitizePaste } from './keys';
import {
  type ConfigurePayload,
  DEFAULT_SCROLLBACK,
  type HostTerminalType,
  type HostToTerminal,
  type KeyName,
  MAX_INPUT_CHARS,
  MAX_SNAPSHOT_SCROLLBACK,
  type SnapshotResult,
  type TerminalErrorCode,
  type TerminalMessageType,
  type TerminalTheme,
  type TerminalToHost,
} from './protocol';
import { type TouchPoint, type TouchTarget, TouchGestures } from './touch';

export class TerminalPageError extends Error {
  constructor(
    readonly code: TerminalErrorCode,
    message: string,
  ) {
    super(message);
  }
}

/** What [TerminalController.handle] returns for a message answered later (`session.write`). */
export const NO_RESPONSE: unique symbol = Symbol('no response');

export interface Disposable {
  dispose(): void;
}
type TerminalEvent<T> = (listener: (value: T) => void) => Disposable;

export interface CellLike {
  getChars(): string;
  getWidth(): number;
}
export interface LineLike {
  readonly isWrapped: boolean;
  translateToString(trimRight?: boolean): string;
  getCell(x: number): CellLike | undefined;
}
export interface BufferLike {
  readonly type: 'normal' | 'alternate';
  readonly cursorX: number;
  readonly cursorY: number;
  readonly viewportY: number;
  readonly baseY: number;
  readonly length: number;
  getLine(y: number): LineLike | undefined;
}

/** The part of xterm.js's Terminal the page uses. */
export interface TerminalLike {
  readonly cols: number;
  readonly rows: number;
  readonly element: HTMLElement | undefined;
  readonly textarea: HTMLTextAreaElement | undefined;
  readonly modes: { readonly applicationCursorKeysMode: boolean };
  readonly buffer: { readonly active: BufferLike };
  options: { theme?: Record<string, string>; fontSize?: number; scrollback?: number };
  open(parent: HTMLElement): void;
  write(data: string, callback?: () => void): void;
  /** Data as typed: what onData then fires. */
  input(data: string, wasUserInput?: boolean): void;
  paste(data: string): void;
  focus(): void;
  blur(): void;
  clear(): void;
  hasSelection(): boolean;
  getSelection(): string;
  selectAll(): void;
  clearSelection(): void;
  select(column: number, row: number, length: number): void;
  scrollLines(amount: number): void;
  scrollToBottom(): void;
  dispose(): void;
  onData: TerminalEvent<string>;
  onBinary: TerminalEvent<string>;
  onResize: TerminalEvent<{ cols: number; rows: number }>;
  onTitleChange: TerminalEvent<string>;
  onBell: TerminalEvent<void>;
  onSelectionChange: TerminalEvent<void>;
}

export interface TerminalSettings {
  fontSize: number;
  scrollback: number;
  theme?: Record<string, string>;
}

export interface CreatedTerminal {
  terminal: TerminalLike;
  /** Sizes the terminal to its element (addon-fit). */
  fit(): void;
}

export type TerminalFactory = (settings: TerminalSettings) => CreatedTerminal;

export type Emit = <K extends TerminalMessageType>(type: K, payload: TerminalToHost[K]) => void;

export interface TerminalControllerOptions {
  /** The element the sessions' views go in. */
  parent: HTMLElement;
  emit: Emit;
  createTerminal: TerminalFactory;
  /** Runs [callback] after the current event (a blur's focus moves on first). */
  defer?: (callback: () => void) => void;
}

interface SessionView {
  readonly sessionId: number;
  readonly terminal: TerminalLike;
  readonly fit: () => void;
  readonly element: HTMLElement;
  readonly disposables: Disposable[];
  selection: boolean;
}

interface SelectionAnchor {
  readonly view: SessionView;
  readonly startCol: number;
  readonly endCol: number;
  readonly row: number;
}

/** xterm's default word separators: a long press selects the run between them. */
const WORD_SEPARATORS = ' ()[]{}\',"`';

/** The most arrow keys one drag step sends. */
const MAX_DRAG_KEYS = 100;

export const DEFAULT_FONT_SIZE = 14;

/** The app's theme as xterm.js's ITheme. */
export function xtermTheme(theme: TerminalTheme): Record<string, string> {
  return {
    background: theme.background,
    foreground: theme.foreground,
    cursor: theme.cursor,
    cursorAccent: theme.cursorAccent,
    selectionBackground: theme.selection,
    black: theme.black,
    red: theme.red,
    green: theme.green,
    yellow: theme.yellow,
    blue: theme.blue,
    magenta: theme.magenta,
    cyan: theme.cyan,
    white: theme.white,
    brightBlack: theme.brightBlack,
    brightRed: theme.brightRed,
    brightGreen: theme.brightGreen,
    brightYellow: theme.brightYellow,
    brightBlue: theme.brightBlue,
    brightMagenta: theme.brightMagenta,
    brightCyan: theme.brightCyan,
    brightWhite: theme.brightWhite,
  };
}

/** [data] in pieces of at most [max] characters, never splitting a surrogate pair. */
export function chunks(data: string, max: number): string[] {
  if (data.length <= max) return [data];
  const out: string[] = [];
  let start = 0;
  while (start < data.length) {
    let end = Math.min(start + max, data.length);
    const last = data.charCodeAt(end - 1);
    if (end < data.length && last >= 0xd800 && last <= 0xdbff) end -= 1;
    out.push(data.slice(start, end));
    start = end;
  }
  return out;
}

export class TerminalController {
  private readonly views = new Map<number, SessionView>();
  private activeId: number | null = null;
  private fontSize = DEFAULT_FONT_SIZE;
  private scrollback = DEFAULT_SCROLLBACK;
  private theme: Record<string, string> | undefined;
  private modifiers = { ctrl: false, alt: false };
  private pasting = false;
  private focused = false;
  private anchor: SelectionAnchor | null = null;
  readonly gestures: TouchGestures;

  constructor(private readonly options: TerminalControllerOptions) {
    this.gestures = new TouchGestures(this.touchTarget());
  }

  /** The session shown, if any. */
  get activeSession(): number | null {
    return this.activeId;
  }

  get sessionIds(): number[] {
    return [...this.views.keys()];
  }

  /**
   * Runs one validated host message. Returns the response's result
   * (undefined: ok without one), or [NO_RESPONSE] for `session.write`.
   * Throws [TerminalPageError] for a request it refuses.
   */
  handle(type: HostTerminalType, payload: unknown): unknown {
    switch (type) {
      case 'terminal.configure':
        return this.configure(payload as ConfigurePayload);
      case 'terminal.focus':
        return this.focus((payload as HostToTerminal['terminal.focus']).focused);
      case 'terminal.modifiers': {
        const { ctrl, alt } = payload as HostToTerminal['terminal.modifiers'];
        this.modifiers = { ctrl, alt };
        return undefined;
      }
      case 'session.open': {
        const { sessionId, activate } = payload as HostToTerminal['session.open'];
        return this.open(sessionId, activate !== false);
      }
      case 'session.activate':
        return this.activate((payload as HostToTerminal['session.activate']).sessionId);
      case 'session.close':
        return this.close((payload as HostToTerminal['session.close']).sessionId);
      case 'session.write': {
        const { sessionId, seq, data } = payload as HostToTerminal['session.write'];
        return this.write(sessionId, seq, data);
      }
      case 'session.clear':
        this.view((payload as HostToTerminal['session.clear']).sessionId).terminal.clear();
        return undefined;
      case 'session.paste': {
        const { sessionId, text } = payload as HostToTerminal['session.paste'];
        return this.paste(sessionId, text);
      }
      case 'session.key':
        return this.key(payload as HostToTerminal['session.key']);
      case 'session.select': {
        const { sessionId, action } = payload as HostToTerminal['session.select'];
        const terminal = this.view(sessionId).terminal;
        if (action === 'all') terminal.selectAll();
        else terminal.clearSelection();
        return undefined;
      }
      case 'session.copy':
        return { text: this.view((payload as HostToTerminal['session.copy']).sessionId).terminal.getSelection() };
      case 'session.snapshot': {
        const { sessionId, scrollback } = payload as HostToTerminal['session.snapshot'];
        return this.snapshot(sessionId, scrollback ?? 0);
      }
      default:
        throw new TerminalPageError('internal', `no handler for ${String(type)}`);
    }
  }

  /** The panel changed size: the shown terminal follows it. */
  layout(): void {
    const view = this.activeView();
    if (view) this.fitView(view);
  }

  /** Text pasted by the WebView itself (its own menu, a keyboard's paste): sanitized like the app's. */
  pasteIntoActive(text: string): void {
    if (this.activeId !== null) this.paste(this.activeId, text);
  }

  // ------------------------------------------------------------ sessions

  private open(sessionId: number, activate: boolean): { cols: number; rows: number } {
    if (this.views.has(sessionId)) {
      throw new TerminalPageError('session_exists', `session ${sessionId} already has a view`);
    }
    const element = this.options.parent.ownerDocument.createElement('div');
    element.className = 'session';
    element.dataset.session = String(sessionId);
    element.style.display = 'none';
    this.options.parent.appendChild(element);
    const { terminal, fit } = this.options.createTerminal({
      fontSize: this.fontSize,
      scrollback: this.scrollback,
      theme: this.theme,
    });
    const view: SessionView = { sessionId, terminal, fit, element, disposables: [], selection: false };
    this.views.set(sessionId, view);
    view.disposables.push(
      terminal.onData((data) => this.input(view, data)),
      terminal.onBinary((data) => this.emitInput(view, data, true)),
      terminal.onResize(({ cols, rows }) => this.emit('session.resized', { sessionId, cols, rows })),
      terminal.onTitleChange((title) => this.emit('session.title', { sessionId, title: title.slice(0, 256) })),
      terminal.onBell(() => this.emit('session.bell', { sessionId })),
      terminal.onSelectionChange(() => this.selectionChanged(view)),
    );
    terminal.open(element);
    const textarea = terminal.textarea;
    if (textarea) {
      const onFocus = () => this.setFocused(true);
      const onBlur = () => this.defer(() => this.setFocused(this.anyFocused()));
      textarea.addEventListener('focus', onFocus);
      textarea.addEventListener('blur', onBlur);
      // No suggestions (Android's TYPE_TEXT_FLAG_NO_SUGGESTIONS): input
      // methods then commit what is typed rather than compose words.
      textarea.setAttribute('autocomplete', 'off');
      // The input method's text, before xterm.js sees it (ime.ts).
      const ime = new ImeInput(textarea, {
        type: (data) => terminal.input(data, true),
        paste: (text) => this.paste(sessionId, text),
        compose: (text) => this.compose(view, text),
      });
      const onIme = (event: Event) => ime.handle(event as unknown as ImeEvent);
      for (const type of IME_EVENTS) element.addEventListener(type, onIme, true);
      view.disposables.push({
        dispose: () => {
          textarea.removeEventListener('focus', onFocus);
          textarea.removeEventListener('blur', onBlur);
          for (const type of IME_EVENTS) element.removeEventListener(type, onIme, true);
        },
      });
    }
    if (activate) this.activate(sessionId);
    return { cols: terminal.cols, rows: terminal.rows };
  }

  private activate(sessionId: number): undefined {
    const view = this.view(sessionId);
    for (const other of this.views.values()) other.element.style.display = other === view ? '' : 'none';
    this.activeId = sessionId;
    this.fitView(view);
    if (this.focused) view.terminal.focus();
    return undefined;
  }

  private close(sessionId: number): undefined {
    const view = this.view(sessionId);
    for (const disposable of view.disposables) disposable.dispose();
    view.terminal.dispose();
    view.element.remove();
    this.views.delete(sessionId);
    if (this.anchor?.view === view) this.anchor = null;
    if (this.activeId === sessionId) this.activeId = null;
    return undefined;
  }

  private write(sessionId: number, seq: number, data: string): typeof NO_RESPONSE {
    const view = this.view(sessionId);
    view.terminal.write(data, () => {
      // A view closed meanwhile acknowledges nothing: its session is gone.
      if (this.views.get(sessionId) === view) this.emit('session.ack', { sessionId, seq });
    });
    return NO_RESPONSE;
  }

  private snapshot(sessionId: number, scrollback: number): SnapshotResult {
    const terminal = this.view(sessionId).terminal;
    const buffer = terminal.buffer.active;
    const screen: string[] = [];
    let wrapped = 0;
    for (let y = buffer.baseY; y < buffer.baseY + terminal.rows; y += 1) {
      const line = buffer.getLine(y);
      screen.push(line ? line.translateToString(true) : '');
      if (line?.isWrapped) wrapped += 1;
    }
    const from = Math.max(0, buffer.baseY - Math.min(scrollback, MAX_SNAPSHOT_SCROLLBACK));
    const back: string[] = [];
    for (let y = from; y < buffer.baseY; y += 1) back.push(buffer.getLine(y)?.translateToString(true) ?? '');
    return {
      cols: terminal.cols,
      rows: terminal.rows,
      buffer: buffer.type,
      cursorX: buffer.cursorX,
      cursorY: buffer.cursorY,
      screen,
      scrollback: back,
      wrapped,
    };
  }

  // ------------------------------------------------------------ appearance and focus

  private configure(payload: ConfigurePayload): undefined {
    if (payload.theme) {
      this.theme = xtermTheme(payload.theme);
      this.options.parent.style.background = payload.theme.background;
    }
    if (payload.fontSize !== undefined) this.fontSize = payload.fontSize;
    if (payload.scrollback !== undefined) this.scrollback = payload.scrollback;
    for (const view of this.views.values()) {
      if (payload.theme) view.terminal.options.theme = this.theme;
      if (payload.fontSize !== undefined) view.terminal.options.fontSize = this.fontSize;
      if (payload.scrollback !== undefined) view.terminal.options.scrollback = this.scrollback;
    }
    this.layout();
    return undefined;
  }

  private focus(focused: boolean): undefined {
    if (focused) {
      this.activeView()?.terminal.focus();
    } else {
      for (const view of this.views.values()) view.terminal.blur();
    }
    return undefined;
  }

  private setFocused(focused: boolean): void {
    if (focused === this.focused) return;
    this.focused = focused;
    this.emit('terminal.focus', { focused });
  }

  private anyFocused(): boolean {
    const active = this.options.parent.ownerDocument.activeElement;
    for (const view of this.views.values()) if (view.terminal.textarea === active) return true;
    return false;
  }

  // ------------------------------------------------------------ input

  private input(view: SessionView, data: string): void {
    let out = data;
    if (!this.pasting && (this.modifiers.ctrl || this.modifiers.alt)) {
      out = applyModifiers(data, this.modifiers);
      // Latched for one key: the row shows them released again.
      this.modifiers = { ctrl: false, alt: false };
      this.emit('terminal.modifiers', { ctrl: false, alt: false });
    }
    this.emitInput(view, out, false);
  }

  private emitInput(view: SessionView, data: string, binary: boolean): void {
    if (data.length === 0) return;
    for (const piece of chunks(data, MAX_INPUT_CHARS)) {
      this.emit(
        'session.input',
        binary ? { sessionId: view.sessionId, data: piece, binary: true } : { sessionId: view.sessionId, data: piece },
      );
    }
  }

  private key(payload: HostToTerminal['session.key']): undefined {
    const view = this.view(payload.sessionId);
    const sequence = keySequence(
      payload.key as KeyName,
      { ctrl: payload.ctrl, alt: payload.alt, shift: payload.shift },
      view.terminal.modes.applicationCursorKeysMode,
    );
    view.terminal.clearSelection();
    view.terminal.scrollToBottom();
    this.emitInput(view, sequence, false);
    return undefined;
  }

  private paste(sessionId: number, text: string): undefined {
    const view = this.view(sessionId);
    const clean = sanitizePaste(text);
    if (clean.length === 0) return undefined;
    this.pasting = true;
    try {
      view.terminal.paste(clean);
    } finally {
      this.pasting = false;
    }
    return undefined;
  }

  /**
   * Shows the input method's composition at the cursor, in xterm.js's own
   * composition view (its helper no longer sees compositions: ime.ts).
   */
  private compose(view: SessionView, text: string | null): void {
    const box = view.element.querySelector<HTMLElement>('.composition-view');
    if (!box) return;
    if (!text) {
      box.classList.remove('active');
      box.textContent = '';
      return;
    }
    const cell = this.metrics(view);
    const buffer = view.terminal.buffer.active;
    if (cell) {
      box.style.left = `${Math.min(buffer.cursorX, view.terminal.cols - 1) * cell.width}px`;
      box.style.top = `${buffer.cursorY * cell.height}px`;
      box.style.height = `${cell.height}px`;
      box.style.lineHeight = `${cell.height}px`;
    }
    box.style.fontSize = `${this.fontSize}px`;
    box.textContent = text;
    box.classList.add('active');
  }

  // ------------------------------------------------------------ selection and touch

  private selectionChanged(view: SessionView): void {
    const active = view.terminal.hasSelection();
    if (active === view.selection) return;
    view.selection = active;
    this.emit('session.selection', { sessionId: view.sessionId, active });
  }

  /** One cell's size and the screen's corner, from the rendered screen; null before it has a size. */
  private metrics(view: SessionView): { width: number; height: number; left: number; top: number } | null {
    const screen = view.element.querySelector<HTMLElement>('.xterm-screen') ?? view.element;
    const rect = screen.getBoundingClientRect();
    if (!rect.width || !rect.height || !view.terminal.cols || !view.terminal.rows) return null;
    return {
      width: rect.width / view.terminal.cols,
      height: rect.height / view.terminal.rows,
      left: rect.left,
      top: rect.top,
    };
  }

  private cellAt(view: SessionView, point: TouchPoint): { col: number; row: number } | null {
    const m = this.metrics(view);
    if (!m) return null;
    const terminal = view.terminal;
    const col = Math.min(terminal.cols - 1, Math.max(0, Math.floor((point.clientX - m.left) / m.width)));
    const screenRow = Math.min(terminal.rows - 1, Math.max(0, Math.floor((point.clientY - m.top) / m.height)));
    return { col, row: screenRow + terminal.buffer.active.viewportY };
  }

  private selectWordAt(point: TouchPoint): void {
    const view = this.activeView();
    if (!view) return;
    const cell = this.cellAt(view, point);
    if (!cell) return;
    const terminal = view.terminal;
    const line = terminal.buffer.active.getLine(cell.row);
    if (!line) return;
    const inWord = (x: number): boolean => {
      const c = line.getCell(x);
      if (!c) return false;
      // The second cell of a wide character belongs to the first.
      if (c.getWidth() === 0) return x > 0 && inWord(x - 1);
      const chars = c.getChars();
      return chars !== '' && !WORD_SEPARATORS.includes(chars);
    };
    let start = cell.col;
    let end = cell.col;
    if (inWord(cell.col)) {
      while (start > 0 && inWord(start - 1)) start -= 1;
      while (end < terminal.cols - 1 && inWord(end + 1)) end += 1;
    }
    terminal.select(start, cell.row, end - start + 1);
    this.anchor = { view, startCol: start, endCol: end, row: cell.row };
  }

  private extendSelectionTo(point: TouchPoint): void {
    const view = this.activeView();
    const anchor = this.anchor;
    if (!view || !anchor || anchor.view !== view) return;
    const cell = this.cellAt(view, point);
    if (!cell) return;
    const cols = view.terminal.cols;
    const from = anchor.row * cols + anchor.startCol;
    const to = anchor.row * cols + anchor.endCol;
    const at = cell.row * cols + cell.col;
    if (at >= from) {
      view.terminal.select(anchor.startCol, anchor.row, Math.max(to, at) - from + 1);
    } else {
      view.terminal.select(cell.col, cell.row, to - at + 1);
    }
  }

  private touchTarget(): TouchTarget {
    return {
      cellHeight: () => {
        const view = this.activeView();
        return view ? (this.metrics(view)?.height ?? null) : null;
      },
      inAlternateBuffer: () => this.activeView()?.terminal.buffer.active.type === 'alternate',
      scrollLines: (lines) => this.activeView()?.terminal.scrollLines(lines),
      arrows: (direction, count) => {
        const view = this.activeView();
        if (!view) return;
        const sequence = keySequence(direction, {}, view.terminal.modes.applicationCursorKeysMode);
        this.emitInput(view, sequence.repeat(Math.min(count, MAX_DRAG_KEYS)), false);
      },
      selectWordAt: (point) => this.selectWordAt(point),
      extendSelectionTo: (point) => this.extendSelectionTo(point),
      tap: () => {
        const view = this.activeView();
        if (!view) return;
        view.terminal.clearSelection();
        view.terminal.focus();
      },
    };
  }

  // ------------------------------------------------------------ helpers

  private view(sessionId: number): SessionView {
    const view = this.views.get(sessionId);
    if (!view) throw new TerminalPageError('unknown_session', `no view for session ${sessionId}`);
    return view;
  }

  private activeView(): SessionView | undefined {
    return this.activeId === null ? undefined : this.views.get(this.activeId);
  }

  private fitView(view: SessionView): void {
    try {
      view.fit();
    } catch (error) {
      this.emit('terminal.log', { level: 'warn', message: `fit failed: ${String(error)}`.slice(0, 4000) });
    }
  }

  private defer(callback: () => void): void {
    (this.options.defer ?? ((cb: () => void) => setTimeout(cb, 0)))(callback);
  }

  private emit<K extends TerminalMessageType>(type: K, payload: TerminalToHost[K]): void {
    this.options.emit(type, payload);
  }
}
