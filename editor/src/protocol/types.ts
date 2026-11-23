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
  /**
   * Language features (Phase 6 W5), at the main cursor: the page asks the
   * host (`lsp.definition`, `lsp.prepareRename`, `lsp.hover`) as F12, F2 and
   * a long press do.
   */
  'goToDefinition',
  'renameSymbol',
  'showHover',
  /** Opens the completion list at the cursor, and takes its selected item. */
  'startCompletion',
  'acceptCompletion',
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
  /** The Problems sheet (Phase 6 W5). */
  'problems',
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
  /**
   * A language request (Phase 6 W5) no server can answer now: none runs for
   * the document, or it is starting, restarting or gave up. Completion falls
   * back to the words of the document.
   */
  'unavailable',
  'timeout',
  'cancelled',
  /** The server failed the request, or refused it (nothing to rename there). */
  'server_error',
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

// ------------------------------------------------- language features (W5)
//
// Phase 6 W5 (PHASE_6_PLAN): the language servers run behind the host
// (app/lib/application/lsp/), never in the page. The host sends a
// document's diagnostics (`diag.set`) and edits from a rename
// (`doc.applyEdits`); the page asks for completion, its documentation,
// hover, definition and rename (`lsp.*`), each answered through `response`.
// Positions are offsets into the document at the request's `version`, which
// the page sends only after the edits before it.

export const DIAGNOSTIC_SEVERITIES = ['error', 'warning', 'info', 'hint'] as const;
export type DiagnosticSeverity = (typeof DIAGNOSTIC_SEVERITIES)[number];

/** LSP's diagnostic tags: faded (unused) and struck through (deprecated). */
export const DIAGNOSTIC_TAGS = ['unnecessary', 'deprecated'] as const;
export type DiagnosticTag = (typeof DIAGNOSTIC_TAGS)[number];

/** CodeMirror's completion icons, which the host maps LSP's kinds onto. */
export const COMPLETION_KINDS = [
  'class',
  'constant',
  'enum',
  'function',
  'interface',
  'keyword',
  'method',
  'namespace',
  'property',
  'text',
  'type',
  'variable',
] as const;
export type CompletionKind = (typeof COMPLETION_KINDS)[number];

/** LSP's CompletionTriggerKind, by name. */
export const COMPLETION_TRIGGERS = ['invoked', 'character', 'incomplete'] as const;
export type CompletionTrigger = (typeof COMPLETION_TRIGGERS)[number];

export const MARKUP_KINDS = ['markdown', 'plaintext'] as const;
export type MarkupKind = (typeof MARKUP_KINDS)[number];

/**
 * The bridge's caps, checked against what the servers gave in W1-W4
 * (PHASE_6_PLAN W5; the runtime legs' lsp-report.txt): the largest
 * completion list had 26 items (Pyright, the 200-file project) and the most
 * diagnostics were TypeScript's 199 in that project, its largest message
 * 37,991 bytes.
 *
 * The most diagnostics one document shows.
 */
export const MAX_DIAGNOSTICS = 1000;

/**
 * The most completion items one answer carries, which is also the most the
 * list draws (PHASE_6_PLAN W5: at most 200 shown, trimmed in Dart). The host
 * keeps the items that match the typed word, in the server's order, and marks
 * a trimmed answer incomplete, so the page asks again as the word grows.
 */
export const MAX_COMPLETION_ITEMS = 200;

/** The most documents one `doc.applyEdits` changes. */
export const MAX_EDITED_DOCUMENTS = 64;

/** The most edits one document takes in one `doc.applyEdits`. */
export const MAX_DOCUMENT_EDITS = 10000;

export interface DiagnosticItem {
  from: number;
  to: number;
  severity: DiagnosticSeverity;
  message: string;
  source?: string;
  code?: string;
  tags?: DiagnosticTag[];
}

/** Replaces `from`..`to` with `insert`. */
export interface TextEditJson {
  from: number;
  to: number;
  insert: string;
}

export interface MarkupJson {
  kind: MarkupKind;
  value: string;
}

export interface DocumentEdits {
  docId: string;
  /** Refused (`stale`) unless the document is still at this version. */
  baseVersion: number;
  /** Sorted, not overlapping, at `baseVersion`. */
  edits: TextEditJson[];
}

export interface PositionRequest {
  docId: string;
  version: number;
  pos: number;
}

export interface CompletionItemJson {
  label: string;
  kind?: CompletionKind;
  detail?: string;
  sortText?: string;
  filterText?: string;
  /** The server's text edit, at the request's version. */
  edit?: TextEditJson;
  /** Inserted over the typed word when there is no `edit`. */
  insert?: string;
  /** Applied with it (an import added at the top). */
  additionalEdits?: TextEditJson[];
  /** `lsp.resolve` has more: documentation, detail, edits. */
  resolvable?: boolean;
  deprecated?: boolean;
  preselect?: boolean;
}

/** The page's requests and what each answers. */
export interface PageRequests {
  'lsp.complete': PositionRequest & { trigger: CompletionTrigger; character?: string };
  'lsp.resolve': { docId: string; resultId: string; index: number };
  'lsp.hover': PositionRequest;
  /** The host opens the definition itself. */
  'lsp.definition': PositionRequest;
  /** The host asks for the new name itself, then renames. */
  'lsp.prepareRename': PositionRequest;
}

export interface PageResults {
  'lsp.complete': {
    resultId: string;
    items: CompletionItemJson[];
    incomplete: boolean;
    triggerCharacters?: string[];
  };
  'lsp.resolve': { detail?: string; documentation?: MarkupJson; additionalEdits?: TextEditJson[] };
  'lsp.hover': { contents?: MarkupJson; from?: number; to?: number };
  'lsp.definition': { found: number };
  'lsp.prepareRename': { from: number; to: number; placeholder: string };
}

export type PageRequestType = keyof PageRequests;

export const PAGE_REQUEST_TYPES: readonly PageRequestType[] = [
  'lsp.complete',
  'lsp.resolve',
  'lsp.hover',
  'lsp.definition',
  'lsp.prepareRename',
];

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
  /**
   * A document's diagnostics at `version` (Phase 6 W5), replacing the ones
   * before; an empty list clears them. The page maps them through its edits
   * since, and refuses (`stale`) a version it can no longer map.
   */
  'diag.set': { docId: string; version: number; items: DiagnosticItem[] };
  /**
   * Edits to open documents (Phase 6 W5, a rename), each document's as one
   * undoable change. All or nothing: refused (`stale`) if any document moved
   * past its base version or has edits not sent yet.
   */
  'doc.applyEdits': { documents: DocumentEdits[] };
  /** The answer to one of the page's requests (`lsp.*`). */
  response: ResponsePayload;
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
  'lsp.complete': PageRequests['lsp.complete'];
  'lsp.resolve': PageRequests['lsp.resolve'];
  'lsp.hover': PageRequests['lsp.hover'];
  'lsp.definition': PageRequests['lsp.definition'];
  'lsp.prepareRename': PageRequests['lsp.prepareRename'];
  /** The page no longer wants the answer to request `re`; nothing answers this. */
  'lsp.cancel': { re: string };
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
