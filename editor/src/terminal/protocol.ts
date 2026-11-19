/**
 * CodeForge terminal protocol, version 1 (Phase 5 W3).
 *
 * The contract between the Flutter host (app/lib/application/terminal/) and
 * the terminal page: xterm.js, one instance per session, in one WebView
 * (docs/TERMINAL_ARCHITECTURE.md §2). Both sides validate every message
 * against the same rules, and the shared JSON fixtures in
 * test/fixtures/terminal/ prove they agree.
 *
 * The envelope is the editor protocol's (src/protocol/types.ts): `{v: 1, id,
 * type, payload}`, unknown versions, types and fields rejected, ids
 * `[A-Za-z0-9_.:-]{1,64}`. Every host request gets exactly one `response`,
 * with one exception: `session.write` is answered by `session.ack` once
 * xterm.js has parsed the data (flow control), or by an error `response`
 * when the page refuses it.
 *
 * Text, not bytes: the host decodes each session's output as UTF-8 (a
 * sequence split between two batches is held back until it is whole) and
 * sends it as a string; the page sends input as the string xterm.js produced
 * (`binary: true` marks mouse reports whose characters are bytes).
 */

export const TERMINAL_PROTOCOL_VERSION = 1;

/** Upper bound for one serialized message, in UTF-16 code units. */
export const MAX_TERMINAL_MESSAGE_CHARS = 8 * 1024 * 1024;

/** The most a `session.write` may carry: the host's window is 256 KiB. */
export const MAX_WRITE_CHARS = 1024 * 1024;

/** The most a pasted text may hold. Its UTF-8 fits the host's input queue (1 MiB). */
export const MAX_PASTE_CHARS = 256 * 1024;

/** The most one `session.input` may carry: a paste, bracketed. */
export const MAX_INPUT_CHARS = MAX_PASTE_CHARS + 64;

/** Rows and columns, as the host's sessions allow them. */
export const MAX_DIMENSION = 999;

/** The most scrollback lines a snapshot returns. */
export const MAX_SNAPSHOT_SCROLLBACK = 1000;

/** The scrollback a terminal keeps unless the host configures another. */
export const DEFAULT_SCROLLBACK = 2000;
export const MAX_SCROLLBACK = 50000;

/** Keys the extra-keys row sends by name; the page turns them into the sequence the terminal's modes expect. */
export const KEY_NAMES = [
  'escape',
  'tab',
  'enter',
  'backspace',
  'up',
  'down',
  'left',
  'right',
  'home',
  'end',
  'pageUp',
  'pageDown',
  'insert',
  'delete',
] as const;
export type KeyName = (typeof KEY_NAMES)[number];

export const LOG_LEVELS = ['debug', 'info', 'warn', 'error'] as const;
export type LogLevel = (typeof LOG_LEVELS)[number];

export const TERMINAL_ERROR_CODES = [
  'bad_json',
  'bad_envelope',
  'unsupported_version',
  'unknown_type',
  'bad_payload',
  'too_large',
  'unknown_session',
  'session_exists',
  'internal',
] as const;
export type TerminalErrorCode = (typeof TERMINAL_ERROR_CODES)[number];

/** Colours as `#RRGGBB` or `#RRGGBBAA`, derived from the app's CfColors tokens. */
export interface TerminalTheme {
  dark: boolean;
  background: string;
  foreground: string;
  cursor: string;
  cursorAccent: string;
  selection: string;
  black: string;
  red: string;
  green: string;
  yellow: string;
  blue: string;
  magenta: string;
  cyan: string;
  white: string;
  brightBlack: string;
  brightRed: string;
  brightGreen: string;
  brightYellow: string;
  brightBlue: string;
  brightMagenta: string;
  brightCyan: string;
  brightWhite: string;
}

export const THEME_COLORS = [
  'background',
  'foreground',
  'cursor',
  'cursorAccent',
  'selection',
  'black',
  'red',
  'green',
  'yellow',
  'blue',
  'magenta',
  'cyan',
  'white',
  'brightBlack',
  'brightRed',
  'brightGreen',
  'brightYellow',
  'brightBlue',
  'brightMagenta',
  'brightCyan',
  'brightWhite',
] as const;

// ---------------------------------------------------------------- host → page

export interface ConfigurePayload {
  theme?: TerminalTheme;
  /** CSS pixels, the user's text scale included. */
  fontSize?: number;
  scrollback?: number;
}

export interface KeyPayload {
  sessionId: number;
  /** A name from KEY_NAMES, or one printable ASCII character. */
  key: string;
  ctrl?: boolean;
  alt?: boolean;
  shift?: boolean;
}

export interface SnapshotResult {
  cols: number;
  rows: number;
  buffer: 'normal' | 'alternate';
  cursorX: number;
  cursorY: number;
  /** The screen's rows, top to bottom, trailing spaces trimmed. */
  screen: string[];
  /** Up to the requested number of lines above the screen, oldest first. */
  scrollback: string[];
  /** Screen rows that continue the row above (a line longer than the width). */
  wrapped: number;
}

export interface HostToTerminal {
  'terminal.configure': ConfigurePayload;
  /** Gives the active terminal the focus (the soft keyboard follows), or takes it away. */
  'terminal.focus': { focused: boolean };
  /** Ctrl and Alt latched on the extra-keys row: they apply to the next key typed on the keyboard. */
  'terminal.modifiers': { ctrl: boolean; alt: boolean };
  /** A view for a session; answered with its size. */
  'session.open': { sessionId: number; activate?: boolean };
  'session.activate': { sessionId: number };
  'session.close': { sessionId: number };
  /** Output, in order; answered by `session.ack` with the same seq once parsed. */
  'session.write': { sessionId: number; seq: number; data: string };
  'session.clear': { sessionId: number };
  'session.paste': { sessionId: number; text: string };
  'session.key': KeyPayload;
  'session.select': { sessionId: number; action: 'all' | 'none' };
  /** Answered with `{text}`: the selection, '' when there is none. */
  'session.copy': { sessionId: number };
  /** Answered with a SnapshotResult. */
  'session.snapshot': { sessionId: number; scrollback?: number };
}

// ---------------------------------------------------------------- page → host

export type ResponsePayload =
  | { re: string; ok: true; result?: unknown }
  | { re: string; ok: false; error: { code: TerminalErrorCode; message: string } };

export interface TerminalToHost {
  'terminal.ready': { protocol: number; engine: string; engineVersion: string };
  'terminal.focus': { focused: boolean };
  'terminal.modifiers': { ctrl: boolean; alt: boolean };
  'terminal.log': { level: LogLevel; message: string };
  'session.input': { sessionId: number; data: string; binary?: boolean };
  'session.resized': { sessionId: number; cols: number; rows: number };
  'session.ack': { sessionId: number; seq: number };
  'session.title': { sessionId: number; title: string };
  'session.bell': { sessionId: number };
  'session.link': { sessionId: number; text: string };
  'session.selection': { sessionId: number; active: boolean };
  response: ResponsePayload;
}

export type HostTerminalType = keyof HostToTerminal;
export type TerminalMessageType = keyof TerminalToHost;
export type TerminalDirection = 'host-to-terminal' | 'terminal-to-host';
