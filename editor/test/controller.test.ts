import { indentUnit, language } from '@codemirror/language';
import { EditorSelection } from '@codemirror/state';
import { runScopeHandlers } from '@codemirror/view';
import { describe, expect, it } from 'vitest';

import { EditorController, EditorError } from '../src/editor/controller';
import { DEFAULT_PALETTE } from '../src/editor/theme';
import { applyChanges } from '../src/protocol/changes';
import type { EditorMessageType, EditorToHost } from '../src/protocol/types';
import { FakeScheduler } from './helpers';

interface Sent {
  type: EditorMessageType;
  payload: unknown;
}

function setup() {
  document.body.innerHTML = '<div id="editor"></div>';
  const parent = document.getElementById('editor') as HTMLElement;
  const scheduler = new FakeScheduler();
  const sent: Sent[] = [];
  const ctl = new EditorController({ parent, scheduler, emit: (type, payload) => void sent.push({ type, payload }) });
  const of = <K extends EditorMessageType>(type: K): Array<EditorToHost[K]> =>
    sent.filter((m) => m.type === type).map((m) => m.payload as EditorToHost[K]);
  return { ctl, scheduler, sent, of };
}

/** Types [text] at the cursor the way user input arrives. */
function typeText(ctl: EditorController, text: string): void {
  const view = ctl.view;
  const at = view.state.selection.main.head;
  view.dispatch({ changes: { from: at, insert: text }, selection: { anchor: at + text.length }, userEvent: 'input.type' });
}

function errorCode(fn: () => unknown): string | undefined {
  try {
    fn();
  } catch (e) {
    return e instanceof EditorError ? e.code : 'not-an-EditorError';
  }
  return undefined;
}

describe('EditorController', () => {
  it('reports batched edits that replay exactly on the host copy', () => {
    const { ctl, scheduler, of } = setup();
    ctl.open({ docId: 'd1', text: 'hello', language: 'javascript', version: 0, selection: { anchor: 5, head: 5 } });
    typeText(ctl, ' ');
    typeText(ctl, 'world');
    expect(of('doc.changed')).toHaveLength(0);
    scheduler.run();
    const [changed] = of('doc.changed');
    expect(changed).toMatchObject({ docId: 'd1', baseVersion: 0, version: 1, lengthBefore: 5, lengthAfter: 11 });
    expect(applyChanges('hello', changed!.changes)).toBe('hello world');
  });

  it('keeps cursor, text and undo history per document across switches', () => {
    const { ctl, of } = setup();
    ctl.open({ docId: 'a', text: 'aaa', language: 'plaintext', version: 0 });
    ctl.view.dispatch({ selection: { anchor: 1 } });
    typeText(ctl, 'X');
    ctl.open({ docId: 'b', text: 'bbb', language: 'python', version: 0 });
    // Switching away flushed a's pending edit immediately.
    expect(of('doc.changed').map((c) => c.docId)).toEqual(['a']);
    expect(ctl.activeDocId).toBe('b');
    expect(ctl.view.state.doc.toString()).toBe('bbb');
    ctl.activate('a');
    expect(ctl.view.state.doc.toString()).toBe('aXaa');
    expect(ctl.view.state.selection.main.head).toBe(2);
    expect(ctl.exec('undo')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('aaa');
    ctl.activate('b');
    expect(ctl.exec('undo')).toBe(false);
  });

  it('switches a document to another language, keeping text, cursor and undo', () => {
    const { ctl } = setup();
    ctl.open({ docId: 'a', text: 'x = 1', language: 'plaintext', version: 0, selection: { anchor: 5, head: 5 } });
    typeText(ctl, '\n');
    expect(ctl.view.state.facet(language)).toBeNull();
    ctl.setLanguage('a', 'python');
    expect(ctl.view.state.facet(language)?.name).toBe('python');
    expect(ctl.view.state.facet(indentUnit)).toBe('    ');
    expect(ctl.view.state.doc.toString()).toBe('x = 1\n');
    expect(ctl.view.state.selection.main.head).toBe(6);
    expect(ctl.exec('undo')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('x = 1');

    // An inactive document takes the new language with it when it comes back.
    ctl.open({ docId: 'b', text: '{}', language: 'plaintext', version: 0 });
    ctl.setLanguage('a', 'javascript');
    expect(ctl.view.state.facet(language)).toBeNull();
    ctl.activate('a');
    expect(ctl.view.state.facet(language)?.name).toBe('javascript');
    expect(ctl.view.state.doc.toString()).toBe('x = 1');
    expect(ctl.exec('redo')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('x = 1\n');
    expect(errorCode(() => ctl.setLanguage('nope', 'css'))).toBe('unknown_doc');
  });

  it('reports the scroll offset in snapshots of the active document only', () => {
    const { ctl } = setup();
    ctl.open({ docId: 'a', text: 'aaa', language: 'plaintext', version: 0 });
    ctl.open({ docId: 'b', text: 'bbb', language: 'plaintext', version: 0 });
    expect(ctl.snapshot('b').scrollTop).toBe(0);
    expect(ctl.snapshot('a').scrollTop).toBeUndefined();
  });

  it('inserts toolbar text at every cursor, with the cursor inside a pair', () => {
    const { ctl } = setup();
    ctl.open({ docId: 'd1', text: 'f\ng', language: 'javascript', version: 0 });
    ctl.view.dispatch({
      selection: EditorSelection.create([EditorSelection.cursor(1), EditorSelection.cursor(3)]),
    });
    expect(ctl.insert('()', 1)).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('f()\ng()');
    expect(ctl.view.state.selection.ranges.map((r) => r.head)).toEqual([2, 6]);
  });

  it('replaces a selection with toolbar text and refuses read-only documents', () => {
    const { ctl } = setup();
    ctl.open({ docId: 'rw', text: 'abc', language: 'plaintext', version: 0, selection: { anchor: 0, head: 3 } });
    ctl.insert('=> ');
    expect(ctl.view.state.doc.toString()).toBe('=> ');
    ctl.open({ docId: 'ro', text: 'x', language: 'plaintext', version: 0, readOnly: true });
    expect(ctl.insert(';')).toBe(false);
    expect(ctl.view.state.doc.toString()).toBe('x');
  });

  it('does not echo a host replace, and continues versions from it', () => {
    const { ctl, scheduler, of } = setup();
    ctl.open({ docId: 'd1', text: 'old', language: 'plaintext', version: 3 });
    typeText(ctl, '!');
    ctl.replace('d1', 'new text', 9);
    scheduler.run();
    expect(of('doc.changed')).toHaveLength(0);
    expect(ctl.snapshot('d1')).toMatchObject({ text: 'new text', version: 9 });
    ctl.view.dispatch({ selection: { anchor: 8 } });
    typeText(ctl, '?');
    scheduler.run();
    expect(of('doc.changed')[0]).toMatchObject({ baseVersion: 9, version: 10 });
    expect(of('editor.history').at(-1)).toMatchObject({ canUndo: true });
  });

  it('flushes pending edits before answering a snapshot', () => {
    const { ctl, of } = setup();
    ctl.open({ docId: 'd1', text: '', language: 'plaintext', version: 0 });
    typeText(ctl, 'abc');
    const snap = ctl.snapshot('d1');
    expect(of('doc.changed')).toHaveLength(1);
    expect(snap).toEqual({ docId: 'd1', text: 'abc', version: 1, selection: { anchor: 3, head: 3 }, scrollTop: 0 });
  });

  it('reports undo and redo availability as it changes', () => {
    const { ctl, of } = setup();
    ctl.open({ docId: 'd1', text: '', language: 'plaintext', version: 0 });
    expect(of('editor.history').at(-1)).toEqual({ docId: 'd1', canUndo: false, canRedo: false });
    typeText(ctl, 'x');
    expect(of('editor.history').at(-1)).toEqual({ docId: 'd1', canUndo: true, canRedo: false });
    ctl.exec('undo');
    expect(of('editor.history').at(-1)).toEqual({ docId: 'd1', canUndo: false, canRedo: true });
  });

  it('rejects unknown documents, duplicates and commands with no document', () => {
    const { ctl } = setup();
    expect(errorCode(() => ctl.exec('undo'))).toBe('no_active_doc');
    expect(errorCode(() => ctl.activate('nope'))).toBe('unknown_doc');
    ctl.open({ docId: 'd1', text: '', language: 'plaintext', version: 0 });
    expect(errorCode(() => ctl.open({ docId: 'd1', text: '', language: 'plaintext', version: 0 }))).toBe('doc_exists');
  });

  it('leaves an empty, read-only view after closing the active document', () => {
    const { ctl, of } = setup();
    ctl.open({ docId: 'd1', text: 'abc', language: 'plaintext', version: 0 });
    typeText(ctl, 'd');
    ctl.close('d1');
    expect(of('doc.changed')).toHaveLength(1);
    expect(ctl.activeDocId).toBeNull();
    expect(ctl.hasDoc('d1')).toBe(false);
    expect(ctl.view.state.doc.length).toBe(0);
    expect(ctl.view.state.readOnly).toBe(true);
  });

  it('forwards app shortcuts after flushing pending edits', () => {
    const { ctl, sent } = setup();
    ctl.open({ docId: 'd1', text: '', language: 'plaintext', version: 0 });
    typeText(ctl, 'x');
    const handled = runScopeHandlers(ctl.view, new KeyboardEvent('keydown', { key: 's', ctrlKey: true }), 'editor');
    expect(handled).toBe(true);
    const order = sent.filter((m) => m.type === 'doc.changed' || m.type === 'app.shortcut').map((m) => m.type);
    expect(order).toEqual(['doc.changed', 'app.shortcut']);
    expect(sent.at(-1)).toEqual({ type: 'app.shortcut', payload: { shortcut: 'save' } });
  });

  it('goes to a line and column, clamping out-of-range targets', () => {
    const { ctl } = setup();
    ctl.open({ docId: 'd1', text: 'a\nbb\nccc', language: 'plaintext', version: 0 });
    expect(ctl.gotoLine(2, 2)).toEqual({ line: 2, position: 3 });
    expect(ctl.view.state.selection.main.head).toBe(3);
    expect(ctl.gotoLine(99, 50)).toEqual({ line: 3, position: 8 });
  });

  it('sets the search query and reports invalid regular expressions', () => {
    const { ctl } = setup();
    ctl.open({ docId: 'd1', text: 'one two one', language: 'plaintext', version: 0 });
    expect(ctl.setSearch({ query: '(', regexp: true })).toEqual({ valid: false });
    expect(ctl.setSearch({ query: 'one' })).toEqual({ valid: true });
    ctl.view.dispatch({ selection: { anchor: 1 } });
    expect(ctl.exec('findNext')).toBe(true);
    const { from, to } = ctl.view.state.selection.main;
    expect([from, to]).toEqual([8, 11]);
  });

  it('applies configuration to the active and to later documents', () => {
    const { ctl } = setup();
    ctl.open({ docId: 'a', text: 'x', language: 'plaintext', version: 0 });
    ctl.configure({ fontSize: 18, lineWrapping: true, palette: { ...DEFAULT_PALETTE, dark: false } });
    expect(ctl.view.dom.classList.contains('cm-lineWrapping') || ctl.view.contentDOM.classList.contains('cm-lineWrapping')).toBe(true);
    ctl.open({ docId: 'b', text: 'y', language: 'plaintext', version: 0 });
    expect(ctl.view.contentDOM.classList.contains('cm-lineWrapping')).toBe(true);
    ctl.activate('a');
    expect(ctl.view.contentDOM.classList.contains('cm-lineWrapping')).toBe(true);
  });

  it('reports the cursor position, throttled', () => {
    const { ctl, scheduler, of } = setup();
    ctl.open({ docId: 'd1', text: 'abc', language: 'plaintext', version: 0 });
    ctl.view.dispatch({ selection: { anchor: 1 } });
    ctl.view.dispatch({ selection: { anchor: 2 } });
    expect(of('doc.viewState')).toHaveLength(0);
    scheduler.run();
    expect(of('doc.viewState')).toEqual([{ docId: 'd1', selection: { anchor: 2, head: 2 }, scrollTop: 0 }]);
  });
});
