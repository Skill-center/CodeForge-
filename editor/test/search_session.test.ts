import { describe, expect, it } from 'vitest';

import { MAX_COUNTED_MATCHES } from '../src/protocol/types';
import { pressKey, setupController, typeText } from './controller_kit';

/** The main selection as [from, to]. */
function selected(view: { state: { selection: { main: { from: number; to: number } } } }): number[] {
  const { from, to } = view.state.selection.main;
  return [from, to];
}

function marks(root: HTMLElement): { all: number; current: number } {
  return {
    all: root.querySelectorAll('.cm-searchMatch').length,
    current: root.querySelectorAll('.cm-searchMatch-selected').length,
  };
}

describe('search session', () => {
  it('counts matches and follows the current one through next and previous', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: 'one two one\none', language: 'plaintext', version: 0 });
    expect(ctl.setSearch({ query: 'one' })).toEqual({ valid: true });
    scheduler.run();
    expect(of('search.state').at(-1)).toEqual({ docId: 'd1', open: true, valid: true, matches: 3, current: 0, capped: false });

    const currents: number[] = [];
    for (const command of ['findNext', 'findNext', 'findNext', 'findNext', 'findPrevious'] as const) {
      expect(ctl.exec(command)).toBe(true);
      scheduler.run();
      currents.push(of('search.state').at(-1)!.current);
    }
    // Both directions wrap around the ends of the document.
    expect(currents).toEqual([1, 2, 3, 1, 3]);
    expect(selected(ctl.view)).toEqual([12, 15]);
  });

  it('coalesces reports and counts when the report goes out', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: 'aaa', language: 'plaintext', version: 0 });
    ctl.setSearch({ query: 'a' });
    typeText(ctl.view, 'aa');
    expect(of('search.state')).toHaveLength(0);
    scheduler.run();
    expect(of('search.state')).toEqual([{ docId: 'd1', open: true, valid: true, matches: 5, current: 0, capped: false }]);
  });

  it('stops counting at the cap', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: 'x'.repeat(MAX_COUNTED_MATCHES + 500), language: 'plaintext', version: 0 });
    ctl.setSearch({ query: 'x' });
    scheduler.run();
    expect(of('search.state').at(-1)).toMatchObject({ matches: MAX_COUNTED_MATCHES, capped: true });
  });

  it('honours case, whole word and regular expressions', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: 'Cat cat concat CAT', language: 'plaintext', version: 0 });
    const count = (spec: Parameters<typeof ctl.setSearch>[0]) => {
      ctl.setSearch(spec);
      scheduler.run();
      return of('search.state').at(-1)!.matches;
    };
    expect(count({ query: 'cat' })).toBe(4);
    expect(count({ query: 'cat', caseSensitive: true })).toBe(2);
    expect(count({ query: 'cat', wholeWord: true })).toBe(3);
    expect(count({ query: 'cat', wholeWord: true, caseSensitive: true })).toBe(1);
    expect(count({ query: '^c\\w+', regexp: true })).toBe(1);
    expect(count({ query: 'c[ao]n?', regexp: true, caseSensitive: true })).toBe(3);
  });

  it('highlights matches only while the session is open', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'one two one', language: 'plaintext', version: 0 });
    expect(marks(ctl.view.contentDOM)).toEqual({ all: 0, current: 0 });
    ctl.setSearch({ query: 'one' });
    expect(marks(ctl.view.contentDOM)).toEqual({ all: 2, current: 0 });
    ctl.exec('findNext');
    expect(marks(ctl.view.contentDOM)).toEqual({ all: 2, current: 1 });
    expect(ctl.exec('closeSearch')).toBe(true);
    expect(marks(ctl.view.contentDOM)).toEqual({ all: 0, current: 0 });
  });

  it('reports an unusable query and never opens CodeMirror’s own panel', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: 'a(b', language: 'plaintext', version: 0 });
    expect(ctl.setSearch({ query: '(', regexp: true })).toEqual({ valid: false });
    scheduler.run();
    expect(of('search.state').at(-1)).toEqual({ docId: 'd1', open: true, valid: false, matches: 0, current: 0, capped: false });
    for (const command of ['findNext', 'findPrevious', 'replaceNext', 'replaceAll'] as const) {
      expect(ctl.exec(command)).toBe(false);
    }
    // F3 is swallowed (preventDefault, as in CodeMirror's keymap) but does nothing.
    pressKey(ctl.view, 'F3');
    expect(selected(ctl.view)).toEqual([0, 0]);
    ctl.setSearch({ query: '' });
    expect(ctl.exec('findNext')).toBe(false);
    expect(ctl.view.dom.querySelector('.cm-search')).toBeNull();
    expect(ctl.view.dom.querySelector('.cm-panels')).toBeNull();
  });

  it('carries the session across documents, closing it quietly in the one put away', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'a', text: 'x one', language: 'plaintext', version: 0 });
    ctl.setSearch({ query: 'one' });
    scheduler.run();
    ctl.open({ docId: 'b', text: 'one one', language: 'plaintext', version: 0 });
    scheduler.run();
    ctl.activate('a');
    scheduler.run();
    expect(of('search.state').map((s) => [s.docId, s.open, s.matches])).toEqual([
      ['a', true, 1],
      ['b', true, 2],
      ['a', true, 1],
    ]);

    ctl.exec('closeSearch');
    scheduler.run();
    expect(of('search.state').at(-1)).toMatchObject({ docId: 'a', open: false });
    ctl.activate('b');
    scheduler.run();
    // b was put away while the session was open; it must not come back with it.
    expect(of('search.state').at(-1)).toMatchObject({ docId: 'a', open: false });
    expect(marks(ctl.view.contentDOM).all).toBe(0);
  });

  it('keeps the session when the host replaces the active text', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: 'x', language: 'plaintext', version: 0 });
    ctl.setSearch({ query: 'x' });
    ctl.replace('d1', 'x x x', 4);
    scheduler.run();
    expect(of('search.state').at(-1)).toMatchObject({ open: true, matches: 3 });
  });

  it('replaces the current match, then every match, each one undo step', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'cat cat cat', language: 'plaintext', version: 0 });
    ctl.setSearch({ query: 'cat', replace: 'dog' });
    // The first press selects a match; the next replaces it and moves on.
    expect(ctl.exec('replaceNext')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('cat cat cat');
    expect(selected(ctl.view)).toEqual([0, 3]);
    ctl.exec('replaceNext');
    expect(ctl.view.state.doc.toString()).toBe('dog cat cat');
    expect(selected(ctl.view)).toEqual([4, 7]);
    expect(ctl.exec('replaceAll')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('dog dog dog');
    ctl.exec('undo');
    expect(ctl.view.state.doc.toString()).toBe('dog cat cat');
  });

  it('replaces with regular expression groups', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'me@home you@work', language: 'plaintext', version: 0 });
    ctl.setSearch({ query: '(\\w+)@(\\w+)', regexp: true, replace: '$2:$1' });
    ctl.exec('replaceAll');
    expect(ctl.view.state.doc.toString()).toBe('home:me work:you');
  });

  it('reports edits made by replacing, so the host copy follows', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: 'a a', language: 'plaintext', version: 0 });
    ctl.setSearch({ query: 'a', replace: 'bb' });
    ctl.exec('replaceAll');
    scheduler.run();
    expect(of('doc.changed').at(-1)).toMatchObject({ docId: 'd1', lengthBefore: 3, lengthAfter: 5 });
    expect(of('search.state').at(-1)).toMatchObject({ matches: 0 });
  });

  it('refuses to replace in a read-only document', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'a a', language: 'plaintext', version: 0, readOnly: true });
    ctl.setSearch({ query: 'a', replace: 'b' });
    expect(ctl.exec('replaceAll')).toBe(false);
    expect(ctl.view.state.doc.toString()).toBe('a a');
  });

  it('ends the session on Escape; with none open, Escape is CodeMirror’s', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: 'abc abc', language: 'plaintext', version: 0 });
    ctl.setSearch({ query: 'abc' });
    expect(pressKey(ctl.view, 'Escape')).toBe(true);
    scheduler.run();
    expect(of('search.state').at(-1)).toMatchObject({ open: false, matches: 0 });
    expect(marks(ctl.view.contentDOM).all).toBe(0);
    expect(pressKey(ctl.view, 'Escape')).toBe(false);
  });

  it('finds with F3 and Shift+F3 while the query is usable', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'ab ab ab', language: 'plaintext', version: 0 });
    ctl.setSearch({ query: 'ab' });
    expect(pressKey(ctl.view, 'F3')).toBe(true);
    expect(pressKey(ctl.view, 'F3')).toBe(true);
    expect(selected(ctl.view)).toEqual([3, 5]);
    expect(pressKey(ctl.view, 'F3', { shift: true })).toBe(true);
    expect(selected(ctl.view)).toEqual([0, 2]);
  });

  it('forwards find, replace and go to line to the app', () => {
    const { ctl, of } = setupController();
    ctl.open({ docId: 'd1', text: '', language: 'plaintext', version: 0 });
    expect(pressKey(ctl.view, 'f', { ctrl: true })).toBe(true);
    expect(pressKey(ctl.view, 'h', { ctrl: true })).toBe(true);
    expect(pressKey(ctl.view, 'g', { ctrl: true })).toBe(true);
    expect(of('app.shortcut').map((s) => s.shortcut)).toEqual(['find', 'replace', 'gotoLine']);
    expect(ctl.view.dom.querySelector('.cm-panels')).toBeNull();
  });

  it('forwards Go to File to the app', () => {
    const { ctl, of } = setupController();
    ctl.open({ docId: 'd1', text: '', language: 'plaintext', version: 0 });
    expect(pressKey(ctl.view, 'p', { ctrl: true })).toBe(true);
    expect(of('app.shortcut').map((s) => s.shortcut)).toEqual(['goToFile']);
  });

  it('opens the session with the current query on openSearch', () => {
    const { ctl, scheduler, of } = setupController();
    ctl.open({ docId: 'd1', text: 'q q', language: 'plaintext', version: 0 });
    ctl.setSearch({ query: 'q' });
    ctl.exec('closeSearch');
    expect(ctl.exec('openSearch')).toBe(true);
    scheduler.run();
    expect(of('search.state').at(-1)).toMatchObject({ open: true, matches: 2 });
  });
});
