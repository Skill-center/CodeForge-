import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { type Direction, MAX_MESSAGE_CHARS, PAGE_REQUEST_TYPES, type PageRequestType, PROTOCOL_VERSION } from '../src/protocol/types';
import { PAGE_RESULTS, parseMessage, validateMessage, validateResult } from '../src/protocol/validate';
import { FIXTURES, readFixtures } from './helpers';

/**
 * The message types the app accepts travelling in [direction]: the keys, two
 * spaces in, of `_hostToEditor` / `_editorToHost` in
 * app/lib/core/editor/protocol.dart, sorted.
 */
function appTypes(direction: Direction): string[] {
  const source = readFileSync(join(FIXTURES, '..', '..', '..', 'app', 'lib', 'core', 'editor', 'protocol.dart'), 'utf8');
  const name = direction === 'host-to-editor' ? '_hostToEditor' : '_editorToHost';
  const start = source.indexOf(`final Map<String, _Check> ${name} = {`);
  if (start < 0) throw new Error(`${name} not found in protocol.dart`);
  const block = source.slice(start, source.indexOf('\n};', start));
  return [...block.matchAll(/^ {2}'([A-Za-z.]+)':/gm)].map((match) => match[1] ?? '').sort();
}

interface Valid {
  description: string;
  /** The page request a `response` answers: its result is checked too (Phase 6 W5). */
  answers?: PageRequestType;
  message: unknown;
}
interface Invalid {
  description: string;
  direction: Direction;
  /** The envelope is valid; the result for this request is not. */
  answers?: PageRequestType;
  raw?: string;
  message?: unknown;
  error: string;
}

const resultOf = (message: unknown): unknown => (message as { payload: { result?: unknown } }).payload.result;

describe('protocol fixtures (shared with the Dart validator)', () => {
  const groups: Array<[string, Direction]> = [
    ['protocol/valid/host_to_editor', 'host-to-editor'],
    ['protocol/valid/editor_to_host', 'editor-to-host'],
  ];
  for (const [dir, direction] of groups) {
    for (const { name, data } of readFixtures<Valid>(dir)) {
      it(`accepts ${direction} ${name}: ${data.description}`, () => {
        const result = parseMessage(JSON.stringify(data.message), direction);
        expect(result).toMatchObject({ ok: true });
        if (data.answers !== undefined) expect(validateResult(data.answers, resultOf(data.message))).toBeNull();
      });
    }
  }

  for (const { name, data } of readFixtures<Invalid>('protocol/invalid')) {
    it(`rejects ${name} with ${data.error}: ${data.description}`, () => {
      const raw = data.raw ?? JSON.stringify(data.message);
      const result = parseMessage(raw, data.direction);
      if (data.answers !== undefined) {
        // The envelope passes; the page refuses the result as bad_payload.
        expect(result.ok).toBe(true);
        expect(data.error).toBe('bad_payload');
        expect(validateResult(data.answers, resultOf(data.message))).not.toBeNull();
        return;
      }
      expect(result.ok).toBe(false);
      if (!result.ok) expect(result.code).toBe(data.error);
    });
  }

  // The contract: the fixtures cover every type the app's validator knows and
  // this validator knows each of them; the Dart test (editor_protocol_test)
  // holds the app's tables equal to the ones in validate.ts.
  for (const [dir, direction] of groups) {
    it(`covers every ${direction} message type at least once`, () => {
      const types = new Set(readFixtures<Valid>(dir).map((f) => (f.data.message as { type: string }).type));
      expect([...types].sort()).toEqual(appTypes(direction));
    });

    it(`knows every ${direction} message type the app knows`, () => {
      const types = appTypes(direction);
      expect(types.length).toBeGreaterThan(0);
      const answer = (type: string) => {
        const result = validateMessage({ v: PROTOCOL_VERSION, id: 'contract', type, payload: {} }, direction);
        return result.ok ? 'ok' : result.code;
      };
      for (const type of types) expect(answer(type), type).not.toBe('unknown_type');
      expect(answer('no.such')).toBe('unknown_type');
    });
  }
});

describe('page requests (Phase 6 W5)', () => {
  it('every page request has a result check, and every check a request', () => {
    expect(Object.keys(PAGE_RESULTS).sort()).toEqual([...PAGE_REQUEST_TYPES].sort());
  });

  it('every page request and every result check has a fixture', () => {
    const sent = new Set(
      readFixtures<Valid>('protocol/valid/editor_to_host').map((f) => (f.data.message as { type: string }).type),
    );
    const answered = new Set(readFixtures<Valid>('protocol/valid/host_to_editor').map((f) => f.data.answers));
    for (const type of PAGE_REQUEST_TYPES) {
      expect(sent.has(type), type).toBe(true);
      expect(answered.has(type), type).toBe(true);
    }
  });

  it('caps a completion answer at 200 items', () => {
    const items = (n: number) => Array.from({ length: n }, (_, i) => ({ label: `item${i}` }));
    expect(validateResult('lsp.complete', { resultId: 'c1', incomplete: true, items: items(200) })).toBeNull();
    expect(validateResult('lsp.complete', { resultId: 'c1', incomplete: true, items: items(201) })).toContain('too many');
  });

  it('caps a document at 1000 diagnostics', () => {
    const items = (n: number) => Array.from({ length: n }, () => ({ from: 0, to: 1, severity: 'error', message: 'x' }));
    const msg = (n: number) => ({ v: 1, id: 'h1', type: 'diag.set', payload: { docId: 'd1', version: 1, items: items(n) } });
    expect(validateMessage(msg(1000), 'host-to-editor').ok).toBe(true);
    expect(validateMessage(msg(1001), 'host-to-editor')).toMatchObject({ ok: false, code: 'bad_payload' });
  });
});

describe('protocol details', () => {
  it('keeps the id of a rejected message so it can be answered', () => {
    const result = validateMessage({ v: 1, id: 'h9', type: 'doc.open', payload: {} }, 'host-to-editor');
    expect(result).toMatchObject({ ok: false, id: 'h9', code: 'bad_payload' });
  });

  it('names the offending field', () => {
    const result = validateMessage(
      { v: 1, id: 'h1', type: 'cmd.gotoLine', payload: { line: 0 } },
      'host-to-editor',
    );
    expect(result).toMatchObject({ ok: false, code: 'bad_payload' });
    if (!result.ok) expect(result.message).toContain('payload.line');
  });

  it('rejects oversized messages before parsing them', () => {
    const raw = 'x'.repeat(MAX_MESSAGE_CHARS + 1);
    expect(parseMessage(raw, 'host-to-editor')).toMatchObject({ ok: false, code: 'too_large', id: null });
  });

  it('rejects non-integer positions and inherited type names', () => {
    expect(validateMessage({ v: 1, id: 'h1', type: 'cmd.gotoLine', payload: { line: 1.5 } }, 'host-to-editor').ok).toBe(false);
    expect(validateMessage({ v: 1, id: 'h1', type: 'toString', payload: {} }, 'host-to-editor')).toMatchObject({ code: 'unknown_type' });
  });

  it('accepts a cursor offset only as a non-negative integer', () => {
    const msg = (cursorOffset: unknown) => ({ v: 1, id: 'h1', type: 'cmd.insert', payload: { text: '()', cursorOffset } });
    expect(validateMessage(msg(1), 'host-to-editor').ok).toBe(true);
    expect(validateMessage(msg(-1), 'host-to-editor').ok).toBe(false);
    expect(validateMessage(msg('1'), 'host-to-editor').ok).toBe(false);
  });
});
