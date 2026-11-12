/**
 * CodeForge bridge protocol, version 1.
 *
 * The contract between the Flutter host (app/lib/services/editor/) and this
 * editor page. Both sides validate every message against the same rules,
 * and the shared JSON fixtures in test/fixtures/protocol/ prove they agree.
 *
 * Rules that keep the two sides in step:
 * - Every message is an envelope `{v: 1, id, type, payload}`. Unknown
 *   versions, types or payload fields are rejected: both sides ship in the
 *   same APK, so an unknown field is a bug, not a newer peer.
 * - Text crossing the bridge uses "\n" line breaks only. CodeMirror counts a
 *   line break as one position, and so does the host's shadow buffer only if
 *   no "\r" is ever present. Line endings are converted at file I/O instead.
 * - Positions and lengths are UTF-16 code units (JavaScript and Dart agree).
 * - Edits travel as CodeMirror change-set JSON, batched, never full text.
 *   Full text moves only on open, replace (recovery) and snapshot.
 */

export const PROTOCOL_VERSION = 1;

/** Upper bound for one serialized message, in UTF-16 code units. */
export const MAX_MESSAGE_CHARS = 32 * 1024 * 1024;

export const LANGUAGE_IDS = [
  'plaintext',
  'javascript',
  'jsx',
  'typescript',
  'tsx',
  'python',
  'json',
  'html',
  'css',
  'markdown',
] as const;
export type LanguageId = (typeof LANGUAGE_IDS)[number];

/** Editor commands the host can run (toolbar buttons, palette entries). */
export const EDITOR_COMMANDS = [
  'undo',
  'redo',
  'indentMore',
  'indentLess',
  /** The Tab key: indents selected lines, or spaces to the next stop. */
  'insertIndent',
  'selectAll',
  'cursorCharLeft',
  'cursorCharRight',
  'cursorLineUp',
  'cursorLineDown',
  'cursorLineStart',
  'cursorLineEnd',
  'toggleComment',
  'selectNextOccurrence',
  'openSearch',
  'closeSearch',
  'findNext',
  'findPrevious',
  'replaceNext',
  'replaceAll',
  'focus',
  'blur',
] as const;
export type EditorCommand = (typeof EDITOR_COMMANDS)[number];

/**
 * App-level shortcuts. While the WebView has focus, hardware key events never
 * reach Flutter, so the editor catches these and forwards them.
 */
export const APP_SHORTCUTS = [
  'save',
  'saveAs',
  'palette',
  'closeTab',
  'nextTab',
  'previousTab',
  'newFile',
  'find',
  'replace',
  'gotoLine',
  'goToFile',
] as const;
export type AppShortcut = (typeof APP_SHORTCUTS)[number];

export const LOG_LEVELS = ['debug', 'info', 'warn', 'error'] as const;
export type LogLevel = (typeof LOG_LEVELS)[number];

export const ERROR_CODES = [
  'bad_json',
  'bad_envelope',
  'unsupported_version',
  'unknown_type',
  'bad_payload',
  'too_large',
  'unknown_doc',
  'doc_exists',
  'no_active_doc',
  'stale',
  'internal',
] as const;
export type ErrorCode = (typeof ERROR_CODES)[number];

export interface Selection {
  anchor: number;
  head: number;
}

/** Colours as `#RRGGBB` or `#RRGGBBAA`, taken from the app's CfColors tokens. */
export interface SyntaxPalette {
  keyword: string;
  string: string;
  number: string;
  function: string;
  type: string;
  comment: string;
  operator: string;
}

export interface Palette {
  dark: boolean;
  background: string;
  foreground: string;
  gutterBackground: string;
  gutterForeground: string;
  activeLine: string;
  selection: string;
  cursor: string;
  matchingBracket: string;
  searchMatch: string;
  panelBackground: string;
  border: string;
  syntax: SyntaxPalette;
}

/**
 * CodeMirror ChangeSet JSON: a number keeps that many characters, `[n]`
 * deletes n characters, `[n, ...lines]` replaces n characters with the lines
 * joined by "\n".
 */
export type ChangeSetJson = Array<number | [number, ...string[]]>;

// ---------------------------------------------------------------- host → editor

export interface ConfigurePayload {
  palette?: Palette;
  fontSize?: number;
  lineWrapping?: boolean;
  tabSize?: number;
}

export interface DocOpenPayload {
  docId: string;
  text: string;
  language: LanguageId;
  version: number;
  readOnly?: boolean;
  selection?: Selection;
  scrollTop?: number;
  /** Defaults to true. */
  activate?: boolean;
}

export interface SearchPayload {
  query: string;
  caseSensitive?: boolean;
  regexp?: boolean;
  wholeWord?: boolean;
  replace?: string;
}

/**
 * The search session behind the app's find bar, reported while it changes:
 * whether it is open, whether the query is usable, how many matches there
 * are (counting stops at [MAX_COUNTED_MATCHES], then [capped] is true) and
 * which one the main selection covers (1-based; 0 when none).
 */
export interface SearchStatePayload {
  docId: string;
  open: boolean;
  valid: boolean;
  matches: number;
  current: number;
  capped: boolean;
}

export const MAX_COUNTED_MATCHES = 1000;

export interface HostToEditor {
  'editor.configure': ConfigurePayload;
  'doc.open': DocOpenPayload;
  'doc.activate': { docId: string };
  'doc.close': { docId: string };
  /**
   * Replaces a document's text. With `baseVersion` (Phase 3 W5: a file that
   * changed outside the app) the page refuses with `stale` unless its
   * document is still at that version with no edits waiting to be sent, so
   * nothing typed is ever replaced.
   */
  'doc.replace': { docId: string; text: string; version: number; baseVersion?: number };
  /** Re-highlights a document under another language (Save As to a new extension). */
  'doc.setLanguage': { docId: string; language: LanguageId };
  'doc.flush': { docId?: string };
  'doc.snapshot': { docId: string };
  'cmd.insert': { text: string; cursorOffset?: number };
  'cmd.exec': { command: EditorCommand };
  'cmd.gotoLine': { line: number; column?: number };
  'search.set': SearchPayload;
}

// ---------------------------------------------------------------- editor → host

export interface DocChangedPayload {
  docId: string;
  baseVersion: number;
  version: number;
  lengthBefore: number;
  lengthAfter: number;
  changes: ChangeSetJson;
}

export interface SnapshotResult {
  docId: string;
  text: string;
  version: number;
  selection: Selection;
  /** The vertical scroll offset, reported for the active document only. */
  scrollTop?: number;
}

export type ResponsePayload =
  | { re: string; ok: true; result?: unknown }
  | { re: string; ok: false; error: { code: ErrorCode; message: string } };

export interface EditorToHost {
  'editor.ready': {
    protocol: number;
    engine: string;
    engineVersion: string;
    languages: LanguageId[];
  };
  'doc.changed': DocChangedPayload;
  'doc.viewState': { docId: string; selection: Selection; scrollTop: number };
  'editor.history': { docId: string; canUndo: boolean; canRedo: boolean };
  'editor.focus': { focused: boolean };
  'ime.composition': { docId: string; composing: boolean };
  'app.shortcut': { shortcut: AppShortcut };
  'search.state': SearchStatePayload;
  'editor.log': { level: LogLevel; message: string };
  response: ResponsePayload;
}

export type HostMessageType = keyof HostToEditor;
export type EditorMessageType = keyof EditorToHost;

export interface Envelope<T extends string = string, P = unknown> {
  v: typeof PROTOCOL_VERSION;
  id: string;
  type: T;
  payload: P;
}

export type Direction = 'host-to-editor' | 'editor-to-host';
