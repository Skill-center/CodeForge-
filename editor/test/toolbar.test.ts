import { indentUnit } from '@codemirror/language';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { describe, expect, it } from 'vitest';

import { insertIndent } from '../src/editor/indent';
import { pressKey, setupController } from './controller_kit';

/** What the symbol toolbar's keys and Tab do on the page (W6, G6). */
describe('symbol toolbar commands', () => {
  it('Tab at a cursor inserts spaces up to the next indent stop', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'ab\nc', language: 'javascript', version: 0, selection: { anchor: 1, head: 1 } });
    expect(ctl.exec('insertIndent')).toBe(true);
    // Column 1 → 2 (the default unit is two spaces).
    expect(ctl.view.state.doc.toString()).toBe('a b\nc');
    expect(ctl.view.state.selection.main.head).toBe(2);
    expect(ctl.exec('insertIndent')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('a   b\nc');
    expect(ctl.view.state.selection.main.head).toBe(4);
  });

  it('Tab indents every selected line and Shift+Tab takes it back', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'one\ntwo\nthree', language: 'javascript', version: 0, selection: { anchor: 1, head: 6 } });
    expect(ctl.exec('insertIndent')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('  one\n  two\nthree');
    expect(ctl.exec('indentLess')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('one\ntwo\nthree');
  });

  it('gives each cursor its own stop', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'x\nabc', language: 'javascript', version: 0 });
    ctl.view.dispatch({
      selection: EditorSelection.create([EditorSelection.cursor(0), EditorSelection.cursor(5)]),
    });
    expect(ctl.exec('insertIndent')).toBe(true);
    // Column 0 → 2 on line 1, column 3 → 4 on line 2.
    expect(ctl.view.state.doc.toString()).toBe('  x\nabc ');
  });

  it('is the hardware Tab key too, with Shift+Tab outdenting', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'if (a) {\nb\n}', language: 'javascript', version: 0, selection: { anchor: 9, head: 9 } });
    expect(pressKey(ctl.view, 'Tab')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('if (a) {\n  b\n}');
    expect(pressKey(ctl.view, 'Tab', { shift: true })).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('if (a) {\nb\n}');
  });

  it('leaves a read-only document alone', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'ab', language: 'javascript', version: 0, readOnly: true });
    expect(ctl.exec('insertIndent')).toBe(false);
    expect(ctl.insert('()', 1)).toBe(false);
    expect(ctl.view.state.doc.toString()).toBe('ab');
  });

  it('types a tab character when the indent unit is a tab', () => {
    const view = new EditorView({
      state: EditorState.create({ doc: 'a', selection: { anchor: 1 }, extensions: [indentUnit.of('\t')] }),
      parent: document.body,
    });
    expect(insertIndent(view)).toBe(true);
    expect(view.state.doc.toString()).toBe('a\t');
    view.destroy();
  });

  it('paired keys put the cursor between the pair, at every cursor', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'f\ng', language: 'javascript', version: 0 });
    ctl.view.dispatch({
      selection: EditorSelection.create([EditorSelection.cursor(1), EditorSelection.cursor(3)]),
    });
    expect(ctl.insert('()', 1)).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('f()\ng()');
    expect(ctl.view.state.selection.ranges.map((r) => r.head)).toEqual([2, 6]);
  });

  it('a key replaces the selection, and its cursor offset is clamped', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'value', language: 'javascript', version: 0, selection: { anchor: 0, head: 5 } });
    expect(ctl.insert('${}', 2)).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('${}');
    expect(ctl.view.state.selection.main.head).toBe(2);
    expect(ctl.insert(';', 9)).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('${;}');
    expect(ctl.view.state.selection.main.head).toBe(3);
  });
});
