import { describe, expect, it } from 'vitest';

import { TerminalBridge } from '../src/terminal/bridge';
import { NO_RESPONSE, type TerminalController, TerminalPageError } from '../src/terminal/controller';

interface Message {
  v: number;
  id: string;
  type: string;
  payload: Record<string, unknown>;
}

function bridgeWith(handle: (type: string, payload: unknown) => unknown): { bridge: TerminalBridge; sent: Message[] } {
  const sent: Message[] = [];
  const bridge = new TerminalBridge((raw) => sent.push(JSON.parse(raw) as Message));
  bridge.attach({ handle } as unknown as TerminalController);
  return { bridge, sent };
}

const request = (id: string, type: string, payload: unknown) => JSON.stringify({ v: 1, id, type, payload });

describe('terminal bridge', () => {
  it('answers a request with its result, once', () => {
    const { bridge, sent } = bridgeWith(() => ({ cols: 80, rows: 24 }));
    bridge.receive(request('h1', 'session.open', { sessionId: 1 }));
    expect(sent).toEqual([{ v: 1, id: 't1', type: 'response', payload: { re: 'h1', ok: true, result: { cols: 80, rows: 24 } } }]);
  });

  it('answers a request without a result with ok alone', () => {
    const { bridge, sent } = bridgeWith(() => undefined);
    bridge.receive(request('h2', 'session.clear', { sessionId: 1 }));
    expect(sent[0]?.payload).toEqual({ re: 'h2', ok: true });
  });

  it('sends nothing for an accepted write: its ack comes from the controller', () => {
    const { bridge, sent } = bridgeWith(() => NO_RESPONSE);
    bridge.receive(request('h3', 'session.write', { sessionId: 1, seq: 0, data: 'x' }));
    expect(sent).toEqual([]);
  });

  it('answers a refusal with its code', () => {
    const { bridge, sent } = bridgeWith(() => {
      throw new TerminalPageError('unknown_session', 'no view for session 4');
    });
    bridge.receive(request('h4', 'session.write', { sessionId: 4, seq: 0, data: 'x' }));
    expect(sent[0]?.payload).toEqual({
      re: 'h4',
      ok: false,
      error: { code: 'unknown_session', message: 'no view for session 4' },
    });
  });

  it('answers an unexpected error as internal', () => {
    const { bridge, sent } = bridgeWith(() => {
      throw new Error('boom');
    });
    bridge.receive(request('h5', 'session.copy', { sessionId: 1 }));
    expect(sent[0]?.payload).toMatchObject({ re: 'h5', ok: false, error: { code: 'internal', message: 'boom' } });
  });

  it('refuses an invalid message before the controller sees it', () => {
    const seen: string[] = [];
    const { bridge, sent } = bridgeWith((type) => seen.push(type));
    bridge.receive(request('h6', 'session.key', { sessionId: 1, key: 'hyper' }));
    bridge.receive('{not json');
    bridge.receive(42);
    expect(seen).toEqual([]);
    expect(sent.map((m) => m.type)).toEqual(['response', 'terminal.log', 'terminal.log']);
    expect(sent[0]?.payload).toMatchObject({ re: 'h6', ok: false, error: { code: 'bad_payload' } });
    expect(sent[1]?.payload).toMatchObject({ level: 'error' });
  });

  it('refuses requests until a controller is attached', () => {
    const sent: Message[] = [];
    const bridge = new TerminalBridge((raw) => sent.push(JSON.parse(raw) as Message));
    bridge.receive(request('h7', 'session.copy', { sessionId: 1 }));
    expect(sent[0]?.payload).toMatchObject({ re: 'h7', ok: false, error: { code: 'internal' } });
  });
});
