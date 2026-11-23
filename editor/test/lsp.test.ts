/**
 * The page's language features (Phase 6 W5): the bridge's own requests and
 * the host's answers, the host's diagnostics (`diag.set`) and a rename's
 * edits (`doc.applyEdits`), the completion source with its fallback to the
 * document's words, definition, rename, the symbol menu, and the
 * documentation's Markdown.
 */
import { closeCompletion, type Completion, currentCompletions, startCompletion } from '@codemirror/autocomplete';
import { undo } from '@codemirror/commands';
import { diagnosticCount, forEachDiagnostic } from '@codemirror/lint';
import type { EditorView } from '@codemirror/view';
import { describe, expect, it, vi } from 'vitest';

import { Bridge } from '../src/bridge';
import { EditorController } from '../src/editor/controller';
import { renderMarkup } from '../src/editor/markdown';
import { type PageRequester, type PendingRequest, RequestError } from '../src/editor/requests';
import type {
  DiagnosticItem,
  EditorMessageType,
  EditorToHost,
  PageRequests,
  PageRequestType,
  PageResults,
} from '../src/protocol/types';
import { parseMessage } from '../src/protocol/validate';
import { FakeScheduler, flushMicrotasks } from './helpers';

// ------------------------------------------------------------------ kits

interface Asked {
  id: string;
  type: PageRequestType;
  payload: Record<string, unknown>;
  resolve: (result: unknown) => void;
  reject: (error: RequestError) => void;
}

/** The host's side of the page's requests, answered by the test. */
class FakeRequester implements PageRequester {
  readonly asked: Asked[] = [];
  readonly cancelled: string[] = [];
  private seq = 0;

  request<K extends PageRequestType>(type: K, payload: PageRequests[K]): PendingRequest<PageResults[K]> {
    this.seq += 1;
    const id = `r${this.seq}`;
    let resolve: (result: unknown) => void = () => {};
    let reject: (error: RequestError) => void = () => {};
    const result = new Promise<PageResults[K]>((res, rej) => {
      resolve = res as (result: unknown) => void;
      reject = rej;
    });
    this.asked.push({ id, type, payload: payload as unknown as Record<string, unknown>, resolve, reject });
    return { id, result };
  }

  cancel(id: string): void {
    this.cancelled.push(id);
    this.asked.find((a) => a.id === id)?.reject(new RequestError('cancelled', 'cancelled'));
  }

  last(type: PageRequestType): Asked {
    const found = [...this.asked].reverse().find((a) => a.type === type);
    if (!found) throw new Error(`no ${type} request`);
    return found;
  }
}

interface Sent {
  type: EditorMessageType;
  payload: unknown;
}

function setup(requests: PageRequester | null = new FakeRequester()) {
  document.body.innerHTML = '<div id="editor"></div>';
  const parent = document.getElementById('editor') as HTMLElement;
  const scheduler = new FakeScheduler();
  const sent: Sent[] = [];
  const ctl = new EditorController({ parent, scheduler, requests, emit: (type, payload) => void sent.push({ type, payload }) });
  const of = <K extends EditorMessageType>(type: K): Array<EditorToHost[K]> =>
    sent.filter((m) => m.type === type).map((m) => m.payload as EditorToHost[K]);
  return { ctl, scheduler, sent, of, requests: requests as FakeRequester, view: ctl.view };
}

function openDoc(ctl: EditorController, docId: string, text: string, language: 'python' | 'typescript' | 'plaintext' = 'python', version = 0) {
  ctl.handle('doc.open', { docId, text, language, version });
}

/** Types [text] at [at] as the user would, without sending it yet. */
function typeAt(view: EditorView, at: number, text: string): void {
  view.dispatch({ changes: { from: at, insert: text }, selection: { anchor: at + text.length }, userEvent: 'input.type' });
}

function diagnosticsOf(view: EditorView): Array<{ from: number; to: number; message: string }> {
  const found: Array<{ from: number; to: number; message: string }> = [];
  forEachDiagnostic(view.state, (d, from, to) => found.push({ from, to, message: d.message }));
  return found;
}

const error = (from: number, to: number, message = 'bad'): DiagnosticItem => ({ from, to, severity: 'error', message });

// ---------------------------------------------------------------- bridge

describe('the bridge asks the host (Phase 6 W5)', () => {
  function bridgeKit() {
    const out: string[] = [];
    const scheduler = new FakeScheduler();
    const bridge = new Bridge((raw) => void out.push(raw), scheduler);
    const messages = () => out.map((raw) => JSON.parse(raw) as { id: string; type: string; payload: Record<string, unknown> });
    const answer = (payload: unknown) => bridge.receive(JSON.stringify({ v: 1, id: 'h9', type: 'response', payload }));
    return { bridge, scheduler, out, messages, answer };
  }

  it('sends a valid request and resolves with the checked result', async () => {
    const { bridge, out, messages, answer } = bridgeKit();
    const pending = bridge.request('lsp.definition', { docId: 'd1', version: 2, pos: 5 }, 1000);
    expect(parseMessage(out[0] ?? '', 'editor-to-host')).toMatchObject({ ok: true });
    expect(messages()[0]).toMatchObject({ id: pending.id, type: 'lsp.definition', payload: { docId: 'd1', version: 2, pos: 5 } });
    answer({ re: pending.id, ok: true, result: { found: 1 } });
    await expect(pending.result).resolves.toEqual({ found: 1 });
    // The host's answer is never answered.
    expect(messages().filter((m) => m.type === 'response')).toEqual([]);
    expect(bridge.waiting).toBe(0);
  });

  it("rejects with the host's error code", async () => {
    const { bridge, answer } = bridgeKit();
    const pending = bridge.request('lsp.complete', { docId: 'd1', version: 0, pos: 0, trigger: 'invoked' }, 1000);
    answer({ re: pending.id, ok: false, error: { code: 'unavailable', message: 'Pyright is restarting.' } });
    await expect(pending.result).rejects.toMatchObject({ code: 'unavailable', message: 'Pyright is restarting.' });
  });

  it('times out, and drops the answer that comes late', async () => {
    const { bridge, scheduler, answer, messages } = bridgeKit();
    const pending = bridge.request('lsp.hover', { docId: 'd1', version: 0, pos: 0 }, 1000);
    scheduler.run();
    await expect(pending.result).rejects.toMatchObject({ code: 'timeout' });
    answer({ re: pending.id, ok: true, result: {} });
    expect(messages().map((m) => m.type)).toEqual(['lsp.hover']);
  });

  it('cancels at the host', async () => {
    const { bridge, messages } = bridgeKit();
    const pending = bridge.request('lsp.complete', { docId: 'd1', version: 0, pos: 0, trigger: 'invoked' }, 1000);
    bridge.cancel(pending.id);
    await expect(pending.result).rejects.toMatchObject({ code: 'cancelled' });
    expect(messages()[1]).toMatchObject({ type: 'lsp.cancel', payload: { re: pending.id } });
    bridge.cancel(pending.id);
    expect(messages()).toHaveLength(2);
  });

  it('refuses a result its request does not allow, and says why', async () => {
    const { bridge, answer, messages } = bridgeKit();
    const pending = bridge.request('lsp.definition', { docId: 'd1', version: 0, pos: 0 }, 1000);
    answer({ re: pending.id, ok: true, result: { found: -1 } });
    await expect(pending.result).rejects.toMatchObject({ code: 'bad_payload' });
    expect(messages()[1]).toMatchObject({ type: 'editor.log', payload: { level: 'error' } });
  });
});

// ----------------------------------------------------------- diagnostics

describe('diag.set', () => {
  it("shows a document's diagnostics, and an empty list clears them", () => {
    const { ctl, view } = setup();
    openDoc(ctl, 'd1', 'print(greet)\n');
    ctl.handle('diag.set', { docId: 'd1', version: 0, items: [error(6, 11, '"greet" is not defined')] });
    expect(diagnosticCount(view.state)).toBe(1);
    expect(diagnosticsOf(view)).toEqual([{ from: 6, to: 11, message: '"greet" is not defined' }]);
    ctl.handle('diag.set', { docId: 'd1', version: 0, items: [] });
    expect(diagnosticCount(view.state)).toBe(0);
  });

  it('maps them through edits not sent yet', () => {
    const { ctl, view } = setup();
    openDoc(ctl, 'd1', 'print(greet)\n');
    typeAt(view, 0, '# hi\n');
    ctl.handle('diag.set', { docId: 'd1', version: 0, items: [error(6, 11)] });
    expect(diagnosticsOf(view)).toMatchObject([{ from: 11, to: 16 }]);
  });

  it('maps them through batches sent since their version', () => {
    const { ctl, view, of } = setup();
    openDoc(ctl, 'd1', 'print(greet)\n');
    typeAt(view, 0, 'x = 1\n');
    ctl.flush('d1');
    typeAt(view, 0, 'y = 2\n');
    ctl.flush('d1');
    expect(of('doc.changed').map((c) => c.version)).toEqual([1, 2]);
    ctl.handle('diag.set', { docId: 'd1', version: 0, items: [error(6, 11)] });
    expect(diagnosticsOf(view)).toMatchObject([{ from: 18, to: 23 }]);
    ctl.handle('diag.set', { docId: 'd1', version: 1, items: [error(12, 17)] });
    expect(diagnosticsOf(view)).toMatchObject([{ from: 18, to: 23 }]);
  });

  it('refuses a version it cannot map from', () => {
    const { ctl } = setup();
    openDoc(ctl, 'd1', 'print(greet)\n', 'python', 3);
    expect(() => ctl.handle('diag.set', { docId: 'd1', version: 4, items: [] })).toThrow(/cannot map/);
    expect(() => ctl.handle('diag.set', { docId: 'd1', version: 1, items: [] })).toThrow(/cannot map/);
  });

  it('keeps a document in the background, and clamps what lies past its end', () => {
    const { ctl, view } = setup();
    openDoc(ctl, 'd1', 'abc');
    openDoc(ctl, 'd2', 'other');
    ctl.handle('diag.set', { docId: 'd1', version: 0, items: [error(1, 99, 'tail')] });
    expect(diagnosticCount(view.state)).toBe(0);
    ctl.handle('doc.activate', { docId: 'd1' });
    expect(diagnosticsOf(view)).toEqual([{ from: 1, to: 3, message: 'tail' }]);
  });

  it("marks LSP's tags: faded, struck through", () => {
    const { ctl, view } = setup();
    openDoc(ctl, 'd1', 'import os\n');
    ctl.handle('diag.set', {
      docId: 'd1',
      version: 0,
      items: [{ from: 7, to: 9, severity: 'hint', message: 'not accessed', tags: ['unnecessary'], source: 'Pyright', code: 'x' }],
    });
    let mark = '';
    let source = '';
    forEachDiagnostic(view.state, (d) => {
      mark = d.markClass ?? '';
      source = d.source ?? '';
    });
    expect(mark).toBe('cm-cf-unnecessary');
    expect(source).toBe('Pyright(x)');
  });

  it('shows the messages under a tapped underline', async () => {
    const { ctl, view } = setup();
    openDoc(ctl, 'd1', 'print(greet)\n');
    ctl.handle('diag.set', { docId: 'd1', version: 0, items: [error(6, 11, 'undefined')] });
    vi.spyOn(view, 'posAtCoords').mockReturnValue(8);
    view.contentDOM.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: 1, clientY: 1 }));
    await flushMicrotasks();
    expect(view.dom.querySelector('.cm-cf-tap')?.textContent).toContain('undefined');
    view.dispatch({ changes: { from: 0, insert: ' ' } });
    expect(view.dom.querySelector('.cm-cf-tap')).toBeNull();
  });
});

// ------------------------------------------------------------ applyEdits

describe('doc.applyEdits', () => {
  it("applies a rename's edits to open documents, each as one undo step, and sends them first", () => {
    const { ctl, view, of } = setup();
    openDoc(ctl, 'd1', 'def greet():\n    pass\ngreet()\n');
    openDoc(ctl, 'd2', 'from a import greet\ngreet()\n');
    ctl.handle('doc.applyEdits', {
      documents: [
        { docId: 'd1', baseVersion: 0, edits: [{ from: 4, to: 9, insert: 'welcome' }, { from: 22, to: 27, insert: 'welcome' }] },
        { docId: 'd2', baseVersion: 0, edits: [{ from: 14, to: 19, insert: 'welcome' }, { from: 20, to: 25, insert: 'welcome' }] },
      ],
    });
    expect(view.state.doc.toString()).toBe('from a import welcome\nwelcome()\n');
    expect(of('doc.changed').map((c) => [c.docId, c.version])).toEqual([
      ['d1', 1],
      ['d2', 1],
    ]);
    expect(ctl.snapshot('d1').text).toBe('def welcome():\n    pass\nwelcome()\n');
    // One undo takes the whole rename back in a document.
    expect(undo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe('from a import greet\ngreet()\n');
    ctl.handle('doc.activate', { docId: 'd1' });
    expect(undo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe('def greet():\n    pass\ngreet()\n');
  });

  it('changes nothing when any document moved on', () => {
    const { ctl, view } = setup();
    openDoc(ctl, 'd1', 'greet()\n');
    openDoc(ctl, 'd2', 'greet()\n');
    typeAt(view, 0, '#');
    const apply = () =>
      ctl.handle('doc.applyEdits', {
        documents: [
          { docId: 'd1', baseVersion: 0, edits: [{ from: 0, to: 5, insert: 'hello' }] },
          { docId: 'd2', baseVersion: 0, edits: [{ from: 0, to: 5, insert: 'hello' }] },
        ],
      });
    expect(apply).toThrow(/version/);
    expect(ctl.snapshot('d1').text).toBe('greet()\n');
    expect(ctl.snapshot('d2').text).toBe('#greet()\n');
  });

  it('refuses edits out of order, overlapping or past the end', () => {
    const { ctl } = setup();
    openDoc(ctl, 'd1', 'abcdef');
    for (const edits of [
      [
        { from: 3, to: 4, insert: 'x' },
        { from: 0, to: 1, insert: 'y' },
      ],
      [
        { from: 0, to: 3, insert: 'x' },
        { from: 2, to: 4, insert: 'y' },
      ],
      [{ from: 5, to: 9, insert: 'x' }],
    ]) {
      expect(() => ctl.handle('doc.applyEdits', { documents: [{ docId: 'd1', baseVersion: 0, edits }] })).toThrow(/sorted/);
    }
    expect(ctl.snapshot('d1').text).toBe('abcdef');
  });
});

// ------------------------------------------------------------ completion

async function completions(view: EditorView): Promise<readonly Completion[]> {
  await vi.waitFor(() => expect(currentCompletions(view.state).length).toBeGreaterThan(0), { timeout: 2000 });
  return currentCompletions(view.state);
}

describe('completion', () => {
  it('asks the host at the version it has, and lists the items in the server order', async () => {
    const { ctl, view, of, requests } = setup();
    openDoc(ctl, 'd1', 'import os\nos.pa');
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    typeAt(view, view.state.doc.length, 't');
    startCompletion(view);
    await vi.waitFor(() => expect(requests.asked.some((a) => a.type === 'lsp.complete')).toBe(true));
    const asked = requests.last('lsp.complete');
    // The edit went first, so the host has the text the request is about.
    expect(of('doc.changed').at(-1)?.version).toBe(1);
    expect(asked.payload).toEqual({ docId: 'd1', version: 1, pos: 16, trigger: 'invoked' });
    asked.resolve({
      resultId: 'c1',
      incomplete: false,
      items: [
        { label: 'pathsep', kind: 'variable', sortText: 'b' },
        { label: 'path', kind: 'namespace', detail: 'module', sortText: 'a' },
      ],
    });
    const options = await completions(view);
    expect(options.map((o) => o.label)).toEqual(['path', 'pathsep']);
    expect(options[0]).toMatchObject({ type: 'namespace', detail: 'module' });
  });

  it("falls back to the document's words while no server can answer", async () => {
    const { ctl, view, requests } = setup();
    openDoc(ctl, 'd1', 'greeting = 1\ngre');
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    startCompletion(view);
    await vi.waitFor(() => expect(requests.asked.length).toBe(1));
    requests.last('lsp.complete').reject(new RequestError('unavailable', 'Pyright is restarting.'));
    const options = await completions(view);
    expect(options.map((o) => o.label)).toContain('greeting');
  });

  it('asks after a trigger character, and learns the server ones', async () => {
    const { ctl, view, requests } = setup();
    openDoc(ctl, 'd1', 'obj');
    view.dispatch({ selection: { anchor: 3 } });
    typeAt(view, 3, '.');
    startCompletion(view);
    await vi.waitFor(() => expect(requests.asked.length).toBe(1));
    expect(requests.last('lsp.complete').payload).toMatchObject({ trigger: 'invoked', pos: 4 });
    requests.last('lsp.complete').resolve({ resultId: 'c1', incomplete: false, items: [{ label: 'x' }], triggerCharacters: ['.', '['] });
    await completions(view);
    // A session started explicitly stays explicit: close it, then type.
    closeCompletion(view);
    typeAt(view, view.state.doc.length, 'x[');
    await vi.waitFor(() => expect(requests.asked.length).toBe(2), { timeout: 2000 });
    expect(requests.last('lsp.complete').payload).toMatchObject({ trigger: 'character', character: '[' });
  });

  it('applies the edit, and the import that comes with it', async () => {
    const { ctl, view, requests } = setup();
    openDoc(ctl, 'd1', 'x = 1\nGre');
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    startCompletion(view);
    await vi.waitFor(() => expect(requests.asked.length).toBe(1));
    requests.last('lsp.complete').resolve({
      resultId: 'c1',
      incomplete: false,
      items: [
        {
          label: 'Greeter',
          kind: 'class',
          edit: { from: 6, to: 9, insert: 'Greeter' },
          additionalEdits: [{ from: 0, to: 0, insert: 'from people import Greeter\n' }],
        },
      ],
    });
    const [option] = await completions(view);
    // The user typed one more letter before picking it.
    typeAt(view, view.state.doc.length, 'e');
    const apply = option?.apply as (view: EditorView, c: Completion, from: number, to: number) => void;
    apply(view, option as Completion, 6, view.state.doc.length);
    expect(view.state.doc.toString()).toBe('from people import Greeter\nx = 1\nGreeter');
    expect(view.state.selection.main.head).toBe(view.state.doc.length);
  });

  it("fetches an item's documentation when it is selected", async () => {
    const { ctl, view, requests } = setup();
    openDoc(ctl, 'd1', 'gr');
    view.dispatch({ selection: { anchor: 2 } });
    startCompletion(view);
    await vi.waitFor(() => expect(requests.asked.length).toBe(1));
    requests.last('lsp.complete').resolve({
      resultId: 'c7',
      incomplete: false,
      items: [{ label: 'greet', kind: 'function', resolvable: true }],
    });
    const [option] = await completions(view);
    const info = (option?.info as (c: Completion) => Promise<Node | null>)(option as Completion);
    await vi.waitFor(() => expect(requests.asked.some((a) => a.type === 'lsp.resolve')).toBe(true));
    expect(requests.last('lsp.resolve').payload).toEqual({ docId: 'd1', resultId: 'c7', index: 0 });
    requests.last('lsp.resolve').resolve({
      detail: '(name: str) -> str',
      documentation: { kind: 'markdown', value: 'Says **hello**.' },
    });
    const node = (await info) as HTMLElement;
    expect(node.querySelector('pre')?.textContent).toBe('(name: str) -> str');
    expect(node.querySelector('strong')?.textContent).toBe('hello');
  });

  it('opens and takes the list on the host commands (the gate drives them)', async () => {
    const { ctl, view, requests } = setup();
    openDoc(ctl, 'd1', 'greeting = 1\ngre');
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    expect(ctl.handle('cmd.exec', { command: 'startCompletion' })).toEqual({ ran: true });
    await vi.waitFor(() => expect(requests.asked.length).toBe(1));
    requests.last('lsp.complete').resolve({
      resultId: 'c1',
      incomplete: false,
      items: [{ label: 'greeting', kind: 'variable', edit: { from: 13, to: 16, insert: 'greeting' } }],
    });
    await completions(view);
    await vi.waitFor(() => expect(ctl.handle('cmd.exec', { command: 'acceptCompletion' })).toEqual({ ran: true }));
    expect(view.state.doc.toString()).toBe('greeting = 1\ngreeting');
  });

  it('is not there for a language no server analyses', () => {
    const { ctl, view } = setup();
    openDoc(ctl, 'd1', 'plain words', 'plaintext');
    expect(startCompletion(view)).toBe(false);
  });
});

// ------------------------------------------- definition, rename, symbol menu

describe('definition, rename and the symbol menu', () => {
  it('asks for the definition at the cursor, and says when there is none', async () => {
    const { ctl, view, requests, scheduler } = setup();
    openDoc(ctl, 'd1', 'print(greet)\n');
    view.dispatch({ selection: { anchor: 8 } });
    expect(ctl.handle('cmd.exec', { command: 'goToDefinition' })).toEqual({ ran: true });
    expect(requests.last('lsp.definition').payload).toEqual({ docId: 'd1', version: 0, pos: 8 });
    requests.last('lsp.definition').resolve({ found: 0 });
    await vi.waitFor(() => expect(view.dom.querySelector('.cm-cf-notice')?.textContent).toBe('No definition found'));
    scheduler.run();
    await vi.waitFor(() => expect(view.dom.querySelector('.cm-cf-notice')).toBeNull());
  });

  it("asks to rename, and shows the server's refusal", async () => {
    const { ctl, view, requests } = setup();
    openDoc(ctl, 'd1', 'print(1)\n');
    expect(ctl.handle('cmd.exec', { command: 'renameSymbol' })).toEqual({ ran: true });
    requests.last('lsp.prepareRename').reject(new RequestError('server_error', 'This cannot be renamed.'));
    await vi.waitFor(() => expect(view.dom.querySelector('.cm-cf-notice')?.textContent).toBe('This cannot be renamed.'));
  });

  it('opens the symbol menu with the hover text, and its actions ask the host', async () => {
    const { ctl, view, requests } = setup();
    openDoc(ctl, 'd1', 'print(greet)\n');
    view.dispatch({ selection: { anchor: 8 } });
    expect(ctl.handle('cmd.exec', { command: 'showHover' })).toEqual({ ran: true });
    await vi.waitFor(() => expect(view.dom.querySelector('.cm-cf-menu')?.textContent).toContain('Loading'));
    requests.last('lsp.hover').resolve({ contents: { kind: 'markdown', value: '```python\ndef greet() -> str\n```' } });
    await vi.waitFor(() => expect(view.dom.querySelector('.cm-cf-menu pre')?.textContent).toBe('def greet() -> str'));
    const definition = view.dom.querySelector<HTMLButtonElement>('.cm-cf-action[data-action="definition"]');
    definition?.click();
    expect(requests.last('lsp.definition').payload).toMatchObject({ pos: 8 });
    await vi.waitFor(() => expect(view.dom.querySelector('.cm-cf-menu')).toBeNull());
  });

  it('opens the symbol menu on a long press, and leaves the selection to the WebView', () => {
    const { ctl, view, requests } = setup();
    openDoc(ctl, 'd1', 'print(greet)\n');
    vi.spyOn(view, 'posAtCoords').mockReturnValue(7);
    const press = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 1, clientY: 1 });
    view.contentDOM.dispatchEvent(press);
    expect(press.defaultPrevented).toBe(false);
    expect(requests.last('lsp.hover').payload).toEqual({ docId: 'd1', version: 0, pos: 7 });
  });

  it('does nothing in a language no server analyses', () => {
    const { ctl, requests } = setup();
    openDoc(ctl, 'd1', 'plain words', 'plaintext');
    expect(ctl.handle('cmd.exec', { command: 'goToDefinition' })).toEqual({ ran: false });
    expect(ctl.handle('cmd.exec', { command: 'showHover' })).toEqual({ ran: false });
    expect(requests.asked).toEqual([]);
  });

  it('forwards the Problems shortcut', () => {
    const { ctl, of } = setup();
    openDoc(ctl, 'd1', 'x');
    ctl.shortcut('problems');
    expect(of('app.shortcut')).toEqual([{ shortcut: 'problems' }]);
  });
});

// -------------------------------------------------------------- markdown

describe('documentation', () => {
  it('draws code blocks in the monospace font, and inline Markdown', () => {
    const node = renderMarkup({
      kind: 'markdown',
      value: '```python\ndef greet(name: str) -> str\n```\n---\nSays **hello** to `name`, see [docs](https://x).\n\n- one\n- two',
    });
    expect(node.querySelector('pre.cm-cf-code code')?.textContent).toBe('def greet(name: str) -> str');
    expect(node.querySelector('pre.cm-cf-code code')?.getAttribute('data-language')).toBe('python');
    expect(node.querySelector('hr')).not.toBeNull();
    expect(node.querySelector('strong')?.textContent).toBe('hello');
    expect(node.querySelector('code.cm-cf-inline-code')?.textContent).toBe('name');
    expect(node.querySelector('p')?.textContent).toBe('Says hello to name, see docs.');
    expect([...node.querySelectorAll('.cm-cf-li')].map((li) => li.textContent)).toEqual(['• one', '• two']);
  });

  it('never lets HTML through', () => {
    const node = renderMarkup({ kind: 'markdown', value: '<img src=x onerror=alert(1)> **<b>x</b>**' });
    expect(node.querySelector('img')).toBeNull();
    expect(node.querySelector('b')).toBeNull();
    expect(node.textContent).toContain('<img src=x onerror=alert(1)>');
  });

  it('keeps plain text as it is', () => {
    const node = renderMarkup({ kind: 'plaintext', value: '  a\n**b**' });
    expect(node.querySelector('pre.cm-cf-plain')?.textContent).toBe('  a\n**b**');
  });

  it('keeps snake_case names whole', () => {
    const node = renderMarkup({ kind: 'markdown', value: 'Use my_var_name and _private_ here.' });
    expect(node.querySelector('em')?.textContent).toBe('private');
    expect(node.textContent).toBe('Use my_var_name and private here.');
  });
});
