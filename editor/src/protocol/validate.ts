/**
 * Validation for protocol v1 (see types.ts). Hand-written on purpose: no
 * dependency, small bundle, and the rules are mirrored one-to-one by the Dart
 * validator. The shared fixtures in test/fixtures/protocol/ keep them equal.
 */
import {
  APP_SHORTCUTS,
  COMPLETION_KINDS,
  COMPLETION_TRIGGERS,
  DIAGNOSTIC_SEVERITIES,
  DIAGNOSTIC_TAGS,
  DIFF_MODES,
  type Direction,
  EDITOR_COMMANDS,
  type Envelope,
  ERROR_CODES,
  type ErrorCode,
  LANGUAGE_IDS,
  LOG_LEVELS,
  MARKUP_KINDS,
  MAX_COMPLETION_ITEMS,
  MAX_DIAGNOSTICS,
  MAX_DIFF_CHARS,
  MAX_DOCUMENT_EDITS,
  MAX_EDITED_DOCUMENTS,
  MAX_MESSAGE_CHARS,
  type PageRequestType,
  PROTOCOL_VERSION,
} from './types';

/** Returns null when valid, otherwise a short reason naming the bad path. */
export type Check = (value: unknown, path: string) => string | null;

export const ID_PATTERN = /^[A-Za-z0-9_.:-]{1,64}$/;
const DOC_ID_PATTERN = /^[A-Za-z0-9_.:-]{1,128}$/;
export const COLOR_PATTERN = /^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/;

export const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

export const str =
  (opts: { min?: number; max?: number; pattern?: RegExp; lfOnly?: boolean } = {}): Check =>
  (v, path) => {
    if (typeof v !== 'string') return `${path} must be a string`;
    if (opts.min !== undefined && v.length < opts.min) return `${path} is too short`;
    if (opts.max !== undefined && v.length > opts.max) return `${path} is too long`;
    if (opts.pattern && !opts.pattern.test(v)) return `${path} has an invalid format`;
    if (opts.lfOnly && v.includes('\r')) return `${path} must use \\n line breaks only`;
    return null;
  };

export const int =
  (opts: { min?: number; max?: number } = {}): Check =>
  (v, path) => {
    if (typeof v !== 'number' || !Number.isSafeInteger(v)) return `${path} must be an integer`;
    if (opts.min !== undefined && v < opts.min) return `${path} must be ≥ ${opts.min}`;
    if (opts.max !== undefined && v > opts.max) return `${path} must be ≤ ${opts.max}`;
    return null;
  };

export const num =
  (opts: { min?: number; max?: number } = {}): Check =>
  (v, path) => {
    if (typeof v !== 'number' || !Number.isFinite(v)) return `${path} must be a number`;
    if (opts.min !== undefined && v < opts.min) return `${path} must be ≥ ${opts.min}`;
    if (opts.max !== undefined && v > opts.max) return `${path} must be ≤ ${opts.max}`;
    return null;
  };

export const bool: Check = (v, path) => (typeof v === 'boolean' ? null : `${path} must be a boolean`);

export const oneOf =
  (values: readonly string[]): Check =>
  (v, path) =>
    typeof v === 'string' && values.includes(v) ? null : `${path} must be one of: ${values.join(', ')}`;

export const anyValue: Check = () => null;

/** Strict object: every required field present, optional fields typed, no others. */
export const obj =
  (required: Record<string, Check>, optional: Record<string, Check> = {}): Check =>
  (v, path) => {
    if (!isObject(v)) return `${path} must be an object`;
    for (const key of Object.keys(v)) {
      if (!(key in required) && !(key in optional)) return `${path}.${key} is not allowed`;
    }
    for (const [key, check] of Object.entries(required)) {
      if (!(key in v)) return `${path}.${key} is required`;
      const err = check(v[key], `${path}.${key}`);
      if (err) return err;
    }
    for (const [key, check] of Object.entries(optional)) {
      if (key in v) {
        const err = check(v[key], `${path}.${key}`);
        if (err) return err;
      }
    }
    return null;
  };

export const arrayOf =
  (item: Check, opts: { max?: number } = {}): Check =>
  (v, path) => {
    if (!Array.isArray(v)) return `${path} must be an array`;
    if (opts.max !== undefined && v.length > opts.max) return `${path} has too many items`;
    for (let i = 0; i < v.length; i++) {
      const err = item(v[i], `${path}[${i}]`);
      if (err) return err;
    }
    return null;
  };

const length = int({ min: 0 });

/** CodeMirror ChangeSet JSON (see ChangeSetJson in types.ts). */
const changeSet: Check = (v, path) => {
  if (!Array.isArray(v)) return `${path} must be an array`;
  for (let i = 0; i < v.length; i++) {
    const part: unknown = v[i];
    const at = `${path}[${i}]`;
    if (typeof part === 'number') {
      const err = length(part, at);
      if (err) return err;
      continue;
    }
    if (!Array.isArray(part) || part.length === 0) return `${at} must be a length or [length, ...lines]`;
    const err = length(part[0], `${at}[0]`);
    if (err) return err;
    for (let j = 1; j < part.length; j++) {
      const line: unknown = part[j];
      if (typeof line !== 'string') return `${at}[${j}] must be a string`;
      if (line.includes('\n') || line.includes('\r')) return `${at}[${j}] must not contain line breaks`;
    }
  }
  return null;
};

const docId = str({ pattern: DOC_ID_PATTERN });
const version = int({ min: 0 });
const text = str({ lfOnly: true });
const color = str({ pattern: COLOR_PATTERN });
const selection = obj({ anchor: length, head: length });

const palette = obj({
  dark: bool,
  background: color,
  foreground: color,
  gutterBackground: color,
  gutterForeground: color,
  activeLine: color,
  selection: color,
  cursor: color,
  matchingBracket: color,
  searchMatch: color,
  panelBackground: color,
  border: color,
  diffAdded: color,
  diffRemoved: color,
  syntax: obj({
    keyword: color,
    string: color,
    number: color,
    function: color,
    type: color,
    comment: color,
    operator: color,
  }),
});

// Language features (Phase 6 W5).
const requestId = str({ pattern: ID_PATTERN });
const textEdit = obj({ from: length, to: length, insert: str({ lfOnly: true, max: 1_000_000 }) });
const markup = obj({ kind: oneOf(MARKUP_KINDS), value: str({ max: 100_000 }) });
const diagnostic = obj(
  { from: length, to: length, severity: oneOf(DIAGNOSTIC_SEVERITIES), message: str({ max: 4000 }) },
  { source: str({ max: 100 }), code: str({ max: 100 }), tags: arrayOf(oneOf(DIAGNOSTIC_TAGS), { max: 2 }) },
);
const documentEdits = obj({ docId, baseVersion: version, edits: arrayOf(textEdit, { max: MAX_DOCUMENT_EDITS }) });
const positionRequest = obj({ docId, version, pos: length });
const triggerCharacter = str({ min: 1, max: 1 });
const completionItem = obj(
  { label: str({ min: 1, max: 500 }) },
  {
    kind: oneOf(COMPLETION_KINDS),
    detail: str({ max: 500 }),
    sortText: str({ max: 200 }),
    filterText: str({ max: 500 }),
    edit: textEdit,
    insert: str({ lfOnly: true, max: 100_000 }),
    additionalEdits: arrayOf(textEdit, { max: 100 }),
    resolvable: bool,
    deprecated: bool,
    preselect: bool,
  },
);

/** An answer, either way: the page's to the host's requests, and since W5 the host's to the page's. */
const responsePayload: Check = (v, path) => {
  if (!isObject(v)) return `${path} must be an object`;
  if (v.ok === true) return obj({ re: str({ pattern: ID_PATTERN }), ok: bool }, { result: anyValue })(v, path);
  if (v.ok === false) {
    return obj({
      re: str({ pattern: ID_PATTERN }),
      ok: bool,
      error: obj({ code: oneOf(ERROR_CODES), message: str({ max: 2000 }) }),
    })(v, path);
  }
  return `${path}.ok must be a boolean`;
};

const HOST_TO_EDITOR: Record<string, Check> = {
  'editor.configure': obj(
    {},
    { palette, fontSize: num({ min: 8, max: 40 }), lineWrapping: bool, tabSize: int({ min: 1, max: 8 }) },
  ),
  'doc.open': obj(
    { docId, text, language: oneOf(LANGUAGE_IDS), version },
    { readOnly: bool, selection, scrollTop: num({ min: 0 }), activate: bool },
  ),
  'doc.activate': obj({ docId }),
  'doc.close': obj({ docId }),
  'doc.replace': obj({ docId, text, version }, { baseVersion: version }),
  'doc.setLanguage': obj({ docId, language: oneOf(LANGUAGE_IDS) }),
  'doc.flush': obj({}, { docId }),
  'doc.snapshot': obj({ docId }),
  'cmd.insert': obj({ text: str({ min: 1, max: 4096, lfOnly: true }) }, { cursorOffset: length }),
  'cmd.exec': obj({ command: oneOf(EDITOR_COMMANDS) }),
  'cmd.gotoLine': obj({ line: int({ min: 1 }) }, { column: int({ min: 1 }) }),
  'search.set': obj(
    { query: str({ max: 10000 }) },
    { caseSensitive: bool, regexp: bool, wholeWord: bool, replace: str({ max: 10000 }) },
  ),
  'diag.set': obj({ docId, version, items: arrayOf(diagnostic, { max: MAX_DIAGNOSTICS }) }),
  'doc.applyEdits': obj({ documents: arrayOf(documentEdits, { max: MAX_EDITED_DOCUMENTS }) }),
  'probe.read': obj({}, { clear: bool }),
  // Phase 7 W5. The older text is capped at the line above which a document
  // opens as plain text: a larger file is offered, not diffed.
  'diff.open': obj({ docId, original: str({ lfOnly: true, max: MAX_DIFF_CHARS }), mode: oneOf(DIFF_MODES) }),
  'diff.close': obj({ docId }),
  response: responsePayload,
};

const EDITOR_TO_HOST: Record<string, Check> = {
  'editor.ready': obj({
    protocol: int({ min: 1 }),
    engine: str({ min: 1, max: 64 }),
    engineVersion: str({ min: 1, max: 64 }),
    languages: arrayOf(oneOf(LANGUAGE_IDS), { max: 64 }),
  }),
  'doc.changed': obj({ docId, baseVersion: version, version, lengthBefore: length, lengthAfter: length, changes: changeSet }),
  'doc.viewState': obj({ docId, selection, scrollTop: num({ min: 0 }) }),
  'editor.history': obj({ docId, canUndo: bool, canRedo: bool }),
  'editor.focus': obj({ focused: bool }),
  'ime.composition': obj({ docId, composing: bool }),
  'app.shortcut': obj({ shortcut: oneOf(APP_SHORTCUTS) }),
  'search.state': obj({ docId, open: bool, valid: bool, matches: length, current: length, capped: bool }),
  'editor.log': obj({ level: oneOf(LOG_LEVELS), message: str({ max: 4000 }) }),
  response: responsePayload,
  'lsp.complete': obj(
    { docId, version, pos: length, trigger: oneOf(COMPLETION_TRIGGERS) },
    { character: triggerCharacter },
  ),
  'lsp.resolve': obj({ docId, resultId: requestId, index: int({ min: 0, max: MAX_COMPLETION_ITEMS - 1 }) }),
  'lsp.hover': positionRequest,
  'lsp.definition': positionRequest,
  'lsp.prepareRename': positionRequest,
  'lsp.cancel': obj({ re: requestId }),
};

/**
 * What each of the page's requests answers: the `result` of an ok
 * `response` from the host. The page checks it against the request it sent
 * (the envelope alone cannot tell), and the host asserts its own answers.
 */
export const PAGE_RESULTS: Record<string, Check> = {
  'lsp.complete': obj(
    { resultId: requestId, items: arrayOf(completionItem, { max: MAX_COMPLETION_ITEMS }), incomplete: bool },
    { triggerCharacters: arrayOf(triggerCharacter, { max: 32 }) },
  ),
  'lsp.resolve': obj(
    {},
    { detail: str({ max: 2000 }), documentation: markup, additionalEdits: arrayOf(textEdit, { max: 100 }) },
  ),
  'lsp.hover': obj({}, { contents: markup, from: length, to: length }),
  'lsp.definition': obj({ found: length }),
  'lsp.prepareRename': obj({ from: length, to: length, placeholder: str({ max: 500 }) }),
};

/** Checks the result an ok `response` carries for a page request of [type]. */
export function validateResult(type: PageRequestType, result: unknown): string | null {
  const check = PAGE_RESULTS[type];
  if (check === undefined) return `no result check for ${type}`;
  return check(result, 'result');
}

export type ParseResult =
  | { ok: true; message: Envelope }
  | { ok: false; id: string | null; code: ErrorCode; message: string };

const fail = (code: ErrorCode, message: string, id: string | null = null): ParseResult => ({
  ok: false,
  id,
  code,
  message,
});

/** Validates an already-decoded value as a message travelling in [direction]. */
export function validateMessage(value: unknown, direction: Direction): ParseResult {
  if (!isObject(value)) return fail('bad_envelope', 'message must be an object');
  // Recover the id early so a rejection can still be answered.
  const id = typeof value.id === 'string' && ID_PATTERN.test(value.id) ? value.id : null;
  for (const key of Object.keys(value)) {
    if (!['v', 'id', 'type', 'payload'].includes(key)) return fail('bad_envelope', `${key} is not allowed`, id);
  }
  if (id === null) return fail('bad_envelope', 'id must match [A-Za-z0-9_.:-]{1,64}');
  if (value.v !== PROTOCOL_VERSION) return fail('unsupported_version', `v must be ${PROTOCOL_VERSION}`, id);
  if (typeof value.type !== 'string') return fail('bad_envelope', 'type must be a string', id);
  const table = direction === 'host-to-editor' ? HOST_TO_EDITOR : EDITOR_TO_HOST;
  const check = Object.prototype.hasOwnProperty.call(table, value.type) ? table[value.type] : undefined;
  if (!check) return fail('unknown_type', `unknown ${direction} type: ${value.type}`, id);
  if (!('payload' in value)) return fail('bad_envelope', 'payload is required', id);
  const err = check(value.payload, 'payload');
  if (err) return fail('bad_payload', err, id);
  return { ok: true, message: value as unknown as Envelope };
}

/** Decodes and validates one serialized message travelling in [direction]. */
export function parseMessage(raw: string, direction: Direction): ParseResult {
  if (raw.length > MAX_MESSAGE_CHARS) return fail('too_large', `message exceeds ${MAX_MESSAGE_CHARS} characters`);
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return fail('bad_json', 'message is not valid JSON');
  }
  return validateMessage(value, direction);
}
