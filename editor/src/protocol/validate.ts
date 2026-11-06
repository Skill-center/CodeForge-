/**
 * Validation for protocol v1 (see types.ts). Hand-written on purpose: no
 * dependency, small bundle, and the rules are mirrored one-to-one by the Dart
 * validator. The shared fixtures in test/fixtures/protocol/ keep them equal.
 */
import {
  APP_SHORTCUTS,
  type Direction,
  EDITOR_COMMANDS,
  type Envelope,
  ERROR_CODES,
  type ErrorCode,
  LANGUAGE_IDS,
  LOG_LEVELS,
  MAX_MESSAGE_CHARS,
  PROTOCOL_VERSION,
} from './types';

/** Returns null when valid, otherwise a short reason naming the bad path. */
type Check = (value: unknown, path: string) => string | null;

const ID_PATTERN = /^[A-Za-z0-9_.:-]{1,64}$/;
const DOC_ID_PATTERN = /^[A-Za-z0-9_.:-]{1,128}$/;
const COLOR_PATTERN = /^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/;

const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

const str =
  (opts: { min?: number; max?: number; pattern?: RegExp; lfOnly?: boolean } = {}): Check =>
  (v, path) => {
    if (typeof v !== 'string') return `${path} must be a string`;
    if (opts.min !== undefined && v.length < opts.min) return `${path} is too short`;
    if (opts.max !== undefined && v.length > opts.max) return `${path} is too long`;
    if (opts.pattern && !opts.pattern.test(v)) return `${path} has an invalid format`;
    if (opts.lfOnly && v.includes('\r')) return `${path} must use \\n line breaks only`;
    return null;
  };

const int =
  (opts: { min?: number; max?: number } = {}): Check =>
  (v, path) => {
    if (typeof v !== 'number' || !Number.isSafeInteger(v)) return `${path} must be an integer`;
    if (opts.min !== undefined && v < opts.min) return `${path} must be ≥ ${opts.min}`;
    if (opts.max !== undefined && v > opts.max) return `${path} must be ≤ ${opts.max}`;
    return null;
  };

const num =
  (opts: { min?: number; max?: number } = {}): Check =>
  (v, path) => {
    if (typeof v !== 'number' || !Number.isFinite(v)) return `${path} must be a number`;
    if (opts.min !== undefined && v < opts.min) return `${path} must be ≥ ${opts.min}`;
    if (opts.max !== undefined && v > opts.max) return `${path} must be ≤ ${opts.max}`;
    return null;
  };

const bool: Check = (v, path) => (typeof v === 'boolean' ? null : `${path} must be a boolean`);

const oneOf =
  (values: readonly string[]): Check =>
  (v, path) =>
    typeof v === 'string' && values.includes(v) ? null : `${path} must be one of: ${values.join(', ')}`;

const anyValue: Check = () => null;

/** Strict object: every required field present, optional fields typed, no others. */
const obj =
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

const arrayOf =
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
  'doc.replace': obj({ docId, text, version }),
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
};

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
  'editor.log': obj({ level: oneOf(LOG_LEVELS), message: str({ max: 4000 }) }),
  response: responsePayload,
};

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
