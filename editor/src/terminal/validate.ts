/**
 * Validation for the terminal protocol v1 (see protocol.ts), with the editor
 * protocol's checks (src/protocol/validate.ts). Mirrored one-to-one by the
 * Dart validator (app/lib/core/terminal/terminal_protocol.dart); the shared
 * fixtures in test/fixtures/terminal/ keep them equal.
 */
import {
  anyValue,
  bool,
  type Check,
  COLOR_PATTERN,
  ID_PATTERN,
  int,
  isObject,
  num,
  obj,
  oneOf,
  str,
} from '../protocol/validate';
import {
  KEY_NAMES,
  LOG_LEVELS,
  MAX_DIMENSION,
  MAX_INPUT_CHARS,
  MAX_PASTE_CHARS,
  MAX_SCROLLBACK,
  MAX_SNAPSHOT_SCROLLBACK,
  MAX_TERMINAL_MESSAGE_CHARS,
  MAX_WRITE_CHARS,
  TERMINAL_ERROR_CODES,
  TERMINAL_PROTOCOL_VERSION,
  type TerminalDirection,
  type TerminalErrorCode,
  THEME_COLORS,
} from './protocol';

const sessionId = int({ min: 1 });
const seq = int({ min: 0 });
const dimension = int({ min: 1, max: MAX_DIMENSION });
const color = str({ pattern: COLOR_PATTERN });

/** A key name, or one printable ASCII character. */
const key: Check = (v, path) => {
  if (typeof v !== 'string') return `${path} must be a string`;
  if ((KEY_NAMES as readonly string[]).includes(v)) return null;
  if (v.length === 1 && v >= ' ' && v <= '~') return null;
  return `${path} must be a key name or one printable ASCII character`;
};

const theme = obj({
  dark: bool,
  ...Object.fromEntries(THEME_COLORS.map((name) => [name, color])),
});

const HOST_TO_TERMINAL: Record<string, Check> = {
  'terminal.configure': obj(
    {},
    { theme, fontSize: num({ min: 8, max: 40 }), scrollback: int({ min: 0, max: MAX_SCROLLBACK }) },
  ),
  'terminal.focus': obj({ focused: bool }),
  'terminal.modifiers': obj({ ctrl: bool, alt: bool }),
  'session.open': obj({ sessionId }, { activate: bool }),
  'session.activate': obj({ sessionId }),
  'session.close': obj({ sessionId }),
  'session.write': obj({ sessionId, seq, data: str({ max: MAX_WRITE_CHARS }) }),
  'session.clear': obj({ sessionId }),
  'session.paste': obj({ sessionId, text: str({ max: MAX_PASTE_CHARS }) }),
  'session.key': obj({ sessionId, key }, { ctrl: bool, alt: bool, shift: bool }),
  'session.select': obj({ sessionId, action: oneOf(['all', 'none']) }),
  'session.copy': obj({ sessionId }),
  'session.snapshot': obj({ sessionId }, { scrollback: int({ min: 0, max: MAX_SNAPSHOT_SCROLLBACK }) }),
};

const responsePayload: Check = (v, path) => {
  if (!isObject(v)) return `${path} must be an object`;
  if (v.ok === true) return obj({ re: str({ pattern: ID_PATTERN }), ok: bool }, { result: anyValue })(v, path);
  if (v.ok === false) {
    return obj({
      re: str({ pattern: ID_PATTERN }),
      ok: bool,
      error: obj({ code: oneOf(TERMINAL_ERROR_CODES), message: str({ max: 2000 }) }),
    })(v, path);
  }
  return `${path}.ok must be a boolean`;
};

const TERMINAL_TO_HOST: Record<string, Check> = {
  'terminal.ready': obj({
    protocol: int({ min: 1 }),
    engine: str({ min: 1, max: 64 }),
    engineVersion: str({ min: 1, max: 64 }),
  }),
  'terminal.focus': obj({ focused: bool }),
  'terminal.modifiers': obj({ ctrl: bool, alt: bool }),
  'terminal.log': obj({ level: oneOf(LOG_LEVELS), message: str({ max: 4000 }) }),
  'session.input': obj({ sessionId, data: str({ min: 1, max: MAX_INPUT_CHARS }) }, { binary: bool }),
  'session.resized': obj({ sessionId, cols: dimension, rows: dimension }),
  'session.ack': obj({ sessionId, seq }),
  'session.title': obj({ sessionId, title: str({ max: 256 }) }),
  'session.bell': obj({ sessionId }),
  'session.link': obj({ sessionId, text: str({ min: 1, max: 4096 }) }),
  'session.selection': obj({ sessionId, active: bool }),
  response: responsePayload,
};

export interface TerminalEnvelope {
  v: typeof TERMINAL_PROTOCOL_VERSION;
  id: string;
  type: string;
  payload: Record<string, unknown>;
}

export type TerminalParseResult =
  | { ok: true; message: TerminalEnvelope }
  | { ok: false; id: string | null; code: TerminalErrorCode; message: string };

const fail = (code: TerminalErrorCode, message: string, id: string | null = null): TerminalParseResult => ({
  ok: false,
  id,
  code,
  message,
});

/** The message types travelling in [direction]. */
export function terminalMessageTypes(direction: TerminalDirection): string[] {
  return Object.keys(direction === 'host-to-terminal' ? HOST_TO_TERMINAL : TERMINAL_TO_HOST);
}

/** Validates an already-decoded value as a message travelling in [direction]. */
export function validateTerminalMessage(value: unknown, direction: TerminalDirection): TerminalParseResult {
  if (!isObject(value)) return fail('bad_envelope', 'message must be an object');
  // Recover the id early so a rejection can still be answered.
  const id = typeof value.id === 'string' && ID_PATTERN.test(value.id) ? value.id : null;
  for (const name of Object.keys(value)) {
    if (!['v', 'id', 'type', 'payload'].includes(name)) return fail('bad_envelope', `${name} is not allowed`, id);
  }
  if (id === null) return fail('bad_envelope', 'id must match [A-Za-z0-9_.:-]{1,64}');
  if (value.v !== TERMINAL_PROTOCOL_VERSION) {
    return fail('unsupported_version', `v must be ${TERMINAL_PROTOCOL_VERSION}`, id);
  }
  if (typeof value.type !== 'string') return fail('bad_envelope', 'type must be a string', id);
  const table = direction === 'host-to-terminal' ? HOST_TO_TERMINAL : TERMINAL_TO_HOST;
  const check = Object.prototype.hasOwnProperty.call(table, value.type) ? table[value.type] : undefined;
  if (!check) return fail('unknown_type', `unknown ${direction} type: ${value.type}`, id);
  if (!('payload' in value)) return fail('bad_envelope', 'payload is required', id);
  const err = check(value.payload, 'payload');
  if (err) return fail('bad_payload', err, id);
  return { ok: true, message: value as unknown as TerminalEnvelope };
}

/** Decodes and validates one serialized message travelling in [direction]. */
export function parseTerminalMessage(raw: string, direction: TerminalDirection): TerminalParseResult {
  if (raw.length > MAX_TERMINAL_MESSAGE_CHARS) {
    return fail('too_large', `message exceeds ${MAX_TERMINAL_MESSAGE_CHARS} characters`);
  }
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return fail('bad_json', 'message is not valid JSON');
  }
  return validateTerminalMessage(value, direction);
}
