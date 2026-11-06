import { describe, expect, it } from 'vitest';

import { type Direction, MAX_MESSAGE_CHARS } from '../src/protocol/types';
import { parseMessage, validateMessage } from '../src/protocol/validate';
import { readFixtures } from './helpers';

interface Valid {
  description: string;
  message: unknown;
}
interface Invalid {
  description: string;
  direction: Direction;
  raw?: string;
  message?: unknown;
  error: string;
}

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
      });
    }
  }

  for (const { name, data } of readFixtures<Invalid>('protocol/invalid')) {
    it(`rejects ${name} with ${data.error}: ${data.description}`, () => {
      const raw = data.raw ?? JSON.stringify(data.message);
      const result = parseMessage(raw, data.direction);
      expect(result.ok).toBe(false);
      if (!result.ok) expect(result.code).toBe(data.error);
    });
  }

  it('covers every host message type at least once', () => {
    const types = new Set(readFixtures<Valid>('protocol/valid/host_to_editor').map((f) => (f.data.message as { type: string }).type));
    expect([...types].sort()).toEqual(
      ['cmd.exec', 'cmd.gotoLine', 'cmd.insert', 'doc.activate', 'doc.close', 'doc.flush', 'doc.open', 'doc.replace', 'doc.snapshot', 'editor.configure', 'search.set'].sort(),
    );
  });

  it('covers every editor message type at least once', () => {
    const types = new Set(readFixtures<Valid>('protocol/valid/editor_to_host').map((f) => (f.data.message as { type: string }).type));
    expect([...types].sort()).toEqual(
      ['app.shortcut', 'doc.changed', 'doc.viewState', 'editor.focus', 'editor.history', 'editor.log', 'editor.ready', 'ime.composition', 'response'].sort(),
    );
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
