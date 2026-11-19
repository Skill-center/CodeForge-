import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  KEY_NAMES,
  MAX_TERMINAL_MESSAGE_CHARS,
  TERMINAL_PROTOCOL_VERSION,
  type TerminalDirection,
} from '../src/terminal/protocol';
import { parseTerminalMessage, terminalMessageTypes, validateTerminalMessage } from '../src/terminal/validate';
import { FIXTURES, readFixtures } from './helpers';

/**
 * The message types the app accepts travelling in [direction]: the keys, two
 * spaces in, of `_hostToTerminal` / `_terminalToHost` in
 * app/lib/core/terminal/terminal_protocol.dart, sorted.
 */
function appTypes(direction: TerminalDirection): string[] {
  const source = readFileSync(
    join(FIXTURES, '..', '..', '..', 'app', 'lib', 'core', 'terminal', 'terminal_protocol.dart'),
    'utf8',
  );
  const name = direction === 'host-to-terminal' ? '_hostToTerminal' : '_terminalToHost';
  const start = source.indexOf(`final Map<String, Check> ${name} = {`);
  if (start < 0) throw new Error(`${name} not found in terminal_protocol.dart`);
  const block = source.slice(start, source.indexOf('\n};', start));
  return [...block.matchAll(/^ {2}'([A-Za-z.]+)':/gm)].map((match) => match[1] ?? '').sort();
}

/** KEY_NAMES as the app lists them (`terminalKeyNames` in terminal_protocol.dart). */
function appKeyNames(): string[] {
  const source = readFileSync(
    join(FIXTURES, '..', '..', '..', 'app', 'lib', 'core', 'terminal', 'terminal_protocol.dart'),
    'utf8',
  );
  const start = source.indexOf('const List<String> terminalKeyNames = [');
  if (start < 0) throw new Error('terminalKeyNames not found in terminal_protocol.dart');
  const block = source.slice(start, source.indexOf('];', start));
  return [...block.matchAll(/'([A-Za-z]+)'/g)].map((match) => match[1] ?? '');
}

interface Valid {
  description: string;
  message: unknown;
}
interface Invalid {
  description: string;
  direction: TerminalDirection;
  raw?: string;
  message?: unknown;
  error: string;
}

describe('terminal protocol fixtures (shared with the Dart validator)', () => {
  const groups: Array<[string, TerminalDirection]> = [
    ['terminal/valid/host_to_terminal', 'host-to-terminal'],
    ['terminal/valid/terminal_to_host', 'terminal-to-host'],
  ];
  for (const [dir, direction] of groups) {
    for (const { name, data } of readFixtures<Valid>(dir)) {
      it(`accepts ${direction} ${name}: ${data.description}`, () => {
        const result = parseTerminalMessage(JSON.stringify(data.message), direction);
        expect(result).toMatchObject({ ok: true });
      });
    }
  }

  for (const { name, data } of readFixtures<Invalid>('terminal/invalid')) {
    it(`rejects ${name} with ${data.error}: ${data.description}`, () => {
      const raw = data.raw ?? JSON.stringify(data.message);
      const result = parseTerminalMessage(raw, data.direction);
      expect(result.ok).toBe(false);
      if (!result.ok) expect(result.code).toBe(data.error);
    });
  }

  for (const [dir, direction] of groups) {
    it(`covers every ${direction} message type at least once`, () => {
      const types = new Set(readFixtures<Valid>(dir).map((f) => (f.data.message as { type: string }).type));
      expect([...types].sort()).toEqual(terminalMessageTypes(direction).sort());
    });

    it(`knows exactly the ${direction} message types the app knows`, () => {
      expect(terminalMessageTypes(direction).sort()).toEqual(appTypes(direction));
      const answer = (type: string) => {
        const result = validateTerminalMessage({ v: TERMINAL_PROTOCOL_VERSION, id: 'contract', type, payload: {} }, direction);
        return result.ok ? 'ok' : result.code;
      };
      expect(answer('no.such')).toBe('unknown_type');
    });
  }

  it('names the same keys as the app', () => {
    expect(appKeyNames()).toEqual([...KEY_NAMES]);
  });

  it('keeps the id of a refused message, so the refusal can be answered', () => {
    const result = parseTerminalMessage(JSON.stringify({ v: 1, id: 'h42', type: 'session.open', payload: {} }), 'host-to-terminal');
    expect(result).toMatchObject({ ok: false, id: 'h42', code: 'bad_payload' });
  });

  it('refuses a message over the size limit before parsing it', () => {
    const result = parseTerminalMessage(' '.repeat(MAX_TERMINAL_MESSAGE_CHARS + 1), 'host-to-terminal');
    expect(result).toMatchObject({ ok: false, code: 'too_large' });
  });
});
