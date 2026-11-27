import { getChunks, getOriginalDoc } from '@codemirror/merge';
import { describe, expect, it } from 'vitest';

import { EditorError } from '../src/editor/controller';
import { REVERT_LABEL } from '../src/editor/diff';
import { applyChanges } from '../src/protocol/changes';
import { setupController } from './controller_kit';

/** The working tree's text, and the same file as the index has it. */
const WORKING = 'one\ntwo changed\nthree\nfour\n';
const ORIGINAL = 'one\ntwo\nthree\nfour\n';

function errorCode(fn: () => unknown): string | undefined {
  try {
    fn();
  } catch (e) {
    return e instanceof EditorError ? e.code : 'not-an-EditorError';
  }
  return undefined;
}

/** Each revert control the page drew, in document order. */
function revertButtons(): HTMLButtonElement[] {
  return [...document.querySelectorAll<HTMLButtonElement>('button.cm-revertChunk')];
}

function tap(button: HTMLButtonElement): void {
  button.dispatchEvent(new window.MouseEvent('mousedown', { bubbles: true, cancelable: true }));
}

describe('inline diffs (Phase 7 W5)', () => {
  it('shows the working tree against the older text, and counts the changes', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: WORKING, language: 'plaintext', version: 0 });
    const result = ctl.openDiff({ docId: 'd1', original: ORIGINAL, mode: 'inline' });
    expect(result).toEqual({ mode: 'inline', chunks: 1 });
    expect(ctl.diffMode('d1')).toBe('inline');
    expect(getOriginalDoc(ctl.view.state).toString()).toBe(ORIGINAL);
    // The document itself is untouched: a diff is a way of showing it.
    expect(ctl.view.state.doc.toString()).toBe(WORKING);
  });

  it('counts a chunk per change, and none when the two texts agree', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'a\nB\nc\nD\n', language: 'plaintext', version: 0 });
    expect(ctl.openDiff({ docId: 'd1', original: 'a\nb\nc\nd\n', mode: 'inline' }).chunks).toBe(2);
    expect(ctl.openDiff({ docId: 'd1', original: 'a\nB\nc\nD\n', mode: 'inline' }).chunks).toBe(0);
  });

  it('offers only *Revert this change*, never one that rewrites the older text', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: WORKING, language: 'plaintext', version: 0 });
    ctl.openDiff({ docId: 'd1', original: ORIGINAL, mode: 'inline' });
    const buttons = revertButtons();
    expect(buttons).toHaveLength(1);
    expect(buttons[0]?.textContent).toBe(REVERT_LABEL);
    expect(document.querySelectorAll('button[name=accept]')).toHaveLength(0);
  });

  it('reverting a change edits the document: the host hears it and it undoes', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: WORKING, language: 'plaintext', version: 0 });
    ctl.openDiff({ docId: 'd1', original: ORIGINAL, mode: 'inline' });

    tap(revertButtons()[0]!);

    expect(ctl.view.state.doc.toString()).toBe(ORIGINAL);
    scheduler.run();
    const [changed] = of('doc.changed');
    expect(changed).toMatchObject({ docId: 'd1', baseVersion: 0, version: 1 });
    expect(applyChanges(WORKING, changed!.changes)).toBe(ORIGINAL);
    // Nothing is left to revert, and the undo history has the edit.
    expect(getChunks(ctl.view.state)?.chunks).toHaveLength(0);
    expect(ctl.exec('undo')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe(WORKING);
    scheduler.run();
    expect(applyChanges(ORIGINAL, of('doc.changed')[1]!.changes)).toBe(WORKING);
  });

  it('reverts at the cursor as a command, which the host and a key can run', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: 'a\nB\nc\nD\n', language: 'plaintext', version: 0 });
    ctl.openDiff({ docId: 'd1', original: 'a\nb\nc\nd\n', mode: 'inline' });

    // The cursor in the second change: that one goes, the first stays.
    const second = ctl.view.state.doc.line(4).from;
    ctl.view.dispatch({ selection: { anchor: second } });
    expect(ctl.exec('revertChunk')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('a\nB\nc\nd\n');
    expect(getChunks(ctl.view.state)?.chunks).toHaveLength(1);
    scheduler.run();
    expect(applyChanges('a\nB\nc\nD\n', of('doc.changed')[0]!.changes)).toBe('a\nB\nc\nd\n');

    // It is the button's edit, so one undo takes it back.
    expect(ctl.exec('undo')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('a\nB\nc\nD\n');
  });

  it('the revert command reverts nothing where there is no diff', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: WORKING, language: 'plaintext', version: 0 });
    expect(ctl.exec('revertChunk')).toBe(false);
    ctl.openDiff({ docId: 'd1', original: WORKING, mode: 'inline' });
    expect(ctl.exec('revertChunk')).toBe(false);
    expect(ctl.view.state.doc.toString()).toBe(WORKING);
  });

  it('reverts one change at a time, leaving the others', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'a\nB\nc\nD\n', language: 'plaintext', version: 0 });
    expect(ctl.openDiff({ docId: 'd1', original: 'a\nb\nc\nd\n', mode: 'inline' }).chunks).toBe(2);
    tap(revertButtons()[0]!);
    expect(ctl.view.state.doc.toString()).toBe('a\nb\nc\nD\n');
    expect(getChunks(ctl.view.state)?.chunks).toHaveLength(1);
  });

  it('reverts an added line and a removed one', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'a\nnew\nb\n', language: 'plaintext', version: 0 });
    ctl.openDiff({ docId: 'd1', original: 'a\nb\n', mode: 'inline' });
    tap(revertButtons()[0]!);
    expect(ctl.view.state.doc.toString()).toBe('a\nb\n');

    const second = setupController();
    second.ctl.open({ docId: 'd1', text: 'a\n', language: 'plaintext', version: 0 });
    second.ctl.openDiff({ docId: 'd1', original: 'a\ngone\n', mode: 'inline' });
    tap(revertButtons()[0]!);
    expect(second.ctl.view.state.doc.toString()).toBe('a\ngone\n');
  });

  it('typing on reverts to nothing left to revert, and the diff follows the text', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: WORKING, language: 'plaintext', version: 0 });
    ctl.openDiff({ docId: 'd1', original: ORIGINAL, mode: 'inline' });
    ctl.view.dispatch({ changes: { from: 0, insert: 'zero\n' }, userEvent: 'input.type' });
    expect(getChunks(ctl.view.state)?.chunks).toHaveLength(2);
  });

  it('closing the diff leaves the document and its text alone', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: WORKING, language: 'plaintext', version: 0 });
    ctl.openDiff({ docId: 'd1', original: ORIGINAL, mode: 'inline' });
    ctl.closeDiff('d1');
    expect(ctl.diffMode('d1')).toBeNull();
    expect(getChunks(ctl.view.state)).toBeNull();
    expect(revertButtons()).toHaveLength(0);
    expect(ctl.view.state.doc.toString()).toBe(WORKING);
    scheduler.run();
    expect(of('doc.changed')).toHaveLength(0);
    // Closing a diff twice, or one that was never open, is not an error.
    expect(errorCode(() => ctl.closeDiff('d1'))).toBeUndefined();
  });

  it('keeps a diff while the document is not the active one', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: WORKING, language: 'plaintext', version: 0 });
    ctl.openDiff({ docId: 'd1', original: ORIGINAL, mode: 'inline' });
    ctl.open({ docId: 'd2', text: 'other', language: 'plaintext', version: 0 });
    expect(getChunks(ctl.view.state)).toBeNull();
    ctl.activate('d1');
    expect(ctl.diffMode('d1')).toBe('inline');
    expect(getChunks(ctl.view.state)?.chunks).toHaveLength(1);
  });

  it('survives a replace and a language change, and goes with the document', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: WORKING, language: 'plaintext', version: 0 });
    ctl.openDiff({ docId: 'd1', original: ORIGINAL, mode: 'inline' });
    ctl.replace('d1', 'one\ntwo changed again\nthree\nfour\n', 7);
    expect(getChunks(ctl.view.state)?.chunks).toHaveLength(1);
    ctl.setLanguage('d1', 'javascript');
    expect(getChunks(ctl.view.state)?.chunks).toHaveLength(1);
    ctl.close('d1');
    expect(errorCode(() => ctl.closeDiff('d1'))).toBe('unknown_doc');
  });

  it('refuses a diff on a document that is not open', () => {
    const { ctl } = setupController();
    expect(errorCode(() => ctl.openDiff({ docId: 'nope', original: '', mode: 'inline' }))).toBe('unknown_doc');
  });

  it('diffs a read-only document in one column, with nothing to revert', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'g1', text: WORKING, language: 'plaintext', version: 0, readOnly: true });
    expect(ctl.openDiff({ docId: 'g1', original: ORIGINAL, mode: 'inline' })).toEqual({ mode: 'inline', chunks: 1 });
    // A commit's file has nothing to revert, and the control would edit it:
    // the read-only facet stops commands, not a dispatch at the view.
    expect(revertButtons()).toHaveLength(0);
    scheduler.run();
    expect(of('doc.changed')).toHaveLength(0);
    expect(ctl.view.state.doc.toString()).toBe(WORKING);
  });
});

describe('split diffs (Phase 7 W5)', () => {
  const splitDom = () => document.querySelector('.cm-mergeView');

  it('puts the older text beside a read-only document, and takes it away again', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'g1', text: WORKING, language: 'plaintext', version: 0, readOnly: true });
    const result = ctl.openDiff({ docId: 'g1', original: ORIGINAL, mode: 'split' });
    expect(result).toEqual({ mode: 'split', chunks: 1 });
    expect(ctl.diffMode('g1')).toBe('split');
    expect(splitDom()).not.toBeNull();
    // The document stays in its own view, hidden under the diff.
    expect(ctl.view.dom.style.display).toBe('none');
    expect(ctl.view.state.doc.toString()).toBe(WORKING);

    ctl.closeDiff('g1');
    expect(splitDom()).toBeNull();
    expect(ctl.view.dom.style.display).toBe('');
    expect(ctl.diffMode('g1')).toBeNull();
  });

  it('refuses to move a document the user can edit out of its own editor', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: WORKING, language: 'plaintext', version: 0 });
    expect(errorCode(() => ctl.openDiff({ docId: 'd1', original: ORIGINAL, mode: 'split' }))).toBe('bad_payload');
    expect(ctl.diffMode('d1')).toBeNull();
    expect(splitDom()).toBeNull();
  });

  it('shows the document the diff is about, whichever was active', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'working file', language: 'plaintext', version: 0 });
    ctl.open({ docId: 'g1', text: WORKING, language: 'plaintext', version: 0, readOnly: true, activate: false });
    ctl.openDiff({ docId: 'g1', original: ORIGINAL, mode: 'split' });
    expect(ctl.activeDocId).toBe('g1');
  });

  it('ends when another document comes into the editor', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'working file', language: 'plaintext', version: 0 });
    ctl.open({ docId: 'g1', text: WORKING, language: 'plaintext', version: 0, readOnly: true });
    ctl.openDiff({ docId: 'g1', original: ORIGINAL, mode: 'split' });
    ctl.activate('d1');
    expect(splitDom()).toBeNull();
    expect(ctl.diffMode('g1')).toBeNull();
    expect(ctl.view.dom.style.display).toBe('');
  });

  it('ends when its document is closed', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'g1', text: WORKING, language: 'plaintext', version: 0, readOnly: true });
    ctl.openDiff({ docId: 'g1', original: ORIGINAL, mode: 'split' });
    ctl.close('g1');
    expect(splitDom()).toBeNull();
    expect(ctl.view.dom.style.display).toBe('');
  });

  it('is rebuilt when the appearance changes', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'g1', text: WORKING, language: 'plaintext', version: 0, readOnly: true });
    ctl.openDiff({ docId: 'g1', original: ORIGINAL, mode: 'split' });
    ctl.configure({ fontSize: 20 });
    expect(document.querySelectorAll('.cm-mergeView')).toHaveLength(1);
    expect(ctl.diffMode('g1')).toBe('split');
  });

  it('switches between the two modes', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'g1', text: WORKING, language: 'plaintext', version: 0, readOnly: true });
    ctl.openDiff({ docId: 'g1', original: ORIGINAL, mode: 'split' });
    expect(ctl.openDiff({ docId: 'g1', original: ORIGINAL, mode: 'inline' })).toEqual({ mode: 'inline', chunks: 1 });
    expect(splitDom()).toBeNull();
    expect(ctl.view.dom.style.display).toBe('');
    expect(ctl.openDiff({ docId: 'g1', original: ORIGINAL, mode: 'split' }).mode).toBe('split');
    expect(getChunks(ctl.view.state)).toBeNull();
    expect(document.querySelectorAll('.cm-mergeView')).toHaveLength(1);
  });

  it('is gone after the controller is destroyed', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'g1', text: WORKING, language: 'plaintext', version: 0, readOnly: true });
    ctl.openDiff({ docId: 'g1', original: ORIGINAL, mode: 'split' });
    ctl.destroy();
    expect(splitDom()).toBeNull();
  });
});
