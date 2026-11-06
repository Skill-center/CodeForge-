import { describe, expect, it } from 'vitest';

import { Bridge } from '../src/bridge';
import { EditorController } from '../src/editor/controller';
import { parseMessage } from '../src/protocol/validate';
import { FakeScheduler } from './helpers';

function setup() {
  document.body.innerHTML = '<div id="editor"></div>';
  const out: string[] = [];
  const bridge = new Bridge((raw) => void out.push(raw));
  const scheduler = new FakeScheduler();
  const ctl = new EditorController({
    parent: document.getElementById('editor') as HTMLElement,
    scheduler,
    emit: (type, payload) => bridge.emit(type, payload),
  });
  bridge.attach(ctl);
  const send = (id: string, type: string, payload: unknown) => bridge.receive(JSON.stringify({ v: 1, id, type, payload }));
  const messages = () => out.map((raw) => JSON.parse(raw) as { type: string; payload: Record<string, unknown> });
  const responses = () => messages().filter((m) => m.type === 'response').map((m) => m.payload);
  return { bridge, ctl, scheduler, out, send, messages, responses };
}

describe('Bridge', () => {
  it('answers each request with exactly one matching response', () => {
    const { send, responses } = setup();
    send('h1', 'doc.open', { docId: 'd1', text: 'hi', language: 'plaintext', version: 0 });
    send('h2', 'doc.snapshot', { docId: 'd1' });
    expect(responses()).toEqual([
      { re: 'h1', ok: true },
      { re: 'h2', ok: true, result: { docId: 'd1', text: 'hi', version: 0, selection: { anchor: 0, head: 0 } } },
    ]);
  });

  it('answers rejected requests with their error code', () => {
    const { send, bridge, responses, messages } = setup();
    send('h1', 'doc.activate', { docId: 'zz' });
    send('h2', 'doc.activate', { docId: 'bad id' });
    bridge.receive('{"v":1,"id":"h3","type":"doc.flush","payload":{},"x":1}');
    bridge.receive('not json');
    bridge.receive(42);
    expect(responses()).toEqual([
      { re: 'h1', ok: false, error: { code: 'unknown_doc', message: 'no open document zz' } },
      { re: 'h2', ok: false, error: { code: 'bad_payload', message: 'payload.docId has an invalid format' } },
      { re: 'h3', ok: false, error: { code: 'bad_envelope', message: 'x is not allowed' } },
    ]);
    const logs = messages().filter((m) => m.type === 'editor.log');
    expect(logs).toHaveLength(2);
  });

  it('emits only messages that pass the host-side validation', () => {
    const { send, scheduler, ctl, out } = setup();
    send('h1', 'editor.configure', { fontSize: 16 });
    send('h2', 'doc.open', { docId: 'd1', text: 'let a = 1;\n', language: 'typescript', version: 0 });
    ctl.view.dispatch({ changes: { from: 0, insert: '// 😀\n' } });
    scheduler.run();
    send('h3', 'cmd.insert', { text: '{}', cursorOffset: 1 });
    send('h4', 'cmd.exec', { command: 'undo' });
    send('h5', 'search.set', { query: 'a' });
    send('h6', 'cmd.gotoLine', { line: 2 });
    send('h7', 'doc.flush', {});
    ctl.shortcut('palette');
    send('h8', 'doc.close', { docId: 'd1' });
    send('h9', 'doc.close', { docId: 'd1' });
    expect(out.length).toBeGreaterThan(10);
    for (const raw of out) {
      const result = parseMessage(raw, 'editor-to-host');
      expect(result, raw).toMatchObject({ ok: true });
    }
  });
});
