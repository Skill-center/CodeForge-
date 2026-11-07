import { insertNewlineAndIndent } from '@codemirror/commands';
import { foldCode, foldedRanges, unfoldAll } from '@codemirror/language';
import { describe, expect, it } from 'vitest';

import { pressKey, setupController, typeText } from './controller_kit';

/** The editing behaviour Phase 2's G5 asks for, through the real controller. */
describe('editing', () => {
  it('highlights the bracket matching the one at the cursor', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'f(a[0])', language: 'javascript', version: 0, selection: { anchor: 2, head: 2 } });
    const matched = [...ctl.view.contentDOM.querySelectorAll('.cm-matchingBracket')].map((e) => e.textContent);
    expect(matched).toEqual(['(', ')']);
    ctl.view.dispatch({ selection: { anchor: 0 } });
    expect(ctl.view.contentDOM.querySelectorAll('.cm-matchingBracket')).toHaveLength(0);
  });

  it('closes brackets and quotes as they are typed, and steps over the closer', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: '', language: 'javascript', version: 0 });
    typeText(ctl.view, '(');
    expect(ctl.view.state.doc.toString()).toBe('()');
    expect(ctl.view.state.selection.main.head).toBe(1);
    typeText(ctl.view, '"');
    expect(ctl.view.state.doc.toString()).toBe('("")');
    typeText(ctl.view, 'x');
    typeText(ctl.view, '"');
    typeText(ctl.view, ')');
    expect(ctl.view.state.doc.toString()).toBe('("x")');
    expect(ctl.view.state.selection.main.head).toBe(5);
  });

  it('deletes an empty pair with one backspace', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: '', language: 'javascript', version: 0 });
    typeText(ctl.view, '[');
    expect(pressKey(ctl.view, 'Backspace')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('');
  });

  it('indents a new line inside a block, by each language’s unit', () => {
    const cases = [
      { language: 'javascript', text: 'function f() {}', at: 14, expected: 'function f() {\n  \n}' },
      { language: 'python', text: 'def f():', at: 8, expected: 'def f():\n    ' },
      { language: 'css', text: 'a {}', at: 3, expected: 'a {\n  \n}' },
      { language: 'json', text: '{"a": []}', at: 7, expected: '{"a": [\n  \n]}' },
    ] as const;
    for (const { language, text, at, expected } of cases) {
      const { ctl } = setupController();
      ctl.open({ docId: 'd1', text, language, version: 0, selection: { anchor: at, head: at } });
      expect(insertNewlineAndIndent(ctl.view)).toBe(true);
      expect(ctl.view.state.doc.toString(), language).toBe(expected);
    }
  });

  it('re-indents a closing brace as it is typed', () => {
    const { ctl } = setupController();
    const text = 'if (x) {\n  y();\n  ';
    ctl.open({ docId: 'd1', text, language: 'javascript', version: 0, selection: { anchor: text.length, head: text.length } });
    typeText(ctl.view, '}');
    expect(ctl.view.state.doc.toString()).toBe('if (x) {\n  y();\n}');
  });

  it('folds and unfolds a block, with a gutter to do it by touch', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'function f() {\n  return 1;\n}\n', language: 'javascript', version: 0 });
    expect(ctl.view.dom.querySelector('.cm-foldGutter')).not.toBeNull();
    expect(foldCode(ctl.view)).toBe(true);
    expect(foldedRanges(ctl.view.state).size).toBe(1);
    expect(ctl.view.contentDOM.querySelector('.cm-foldPlaceholder')).not.toBeNull();
    expect(unfoldAll(ctl.view)).toBe(true);
    expect(foldedRanges(ctl.view.state).size).toBe(0);
  });

  it('toggles line comments in the document’s language', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'py', text: 'x = 1', language: 'python', version: 0 });
    expect(ctl.exec('toggleComment')).toBe(true);
    expect(ctl.view.state.doc.toString()).toBe('# x = 1');
    ctl.open({ docId: 'js', text: 'x = 1', language: 'javascript', version: 0 });
    ctl.exec('toggleComment');
    expect(ctl.view.state.doc.toString()).toBe('// x = 1');
    ctl.exec('toggleComment');
    expect(ctl.view.state.doc.toString()).toBe('x = 1');
  });

  it('adds the next occurrence of the selected word as another cursor', () => {
    const { ctl } = setupController();
    ctl.open({ docId: 'd1', text: 'ab ab ab', language: 'plaintext', version: 0, selection: { anchor: 0, head: 2 } });
    expect(pressKey(ctl.view, 'd', { ctrl: true })).toBe(true);
    expect(ctl.view.state.selection.ranges.map((r) => [r.from, r.to])).toEqual([
      [0, 2],
      [3, 5],
    ]);
  });
});
