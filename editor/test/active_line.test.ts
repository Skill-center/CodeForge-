import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { describe, expect, it } from 'vitest';

import { activeLineStarts, cursorLineHighlight } from '../src/editor/active_line';

// Lines start at 0 ("one"), 4 ("two") and 8 ("three").
const doc = 'one\ntwo\nthree';

const starts = (...ranges: ReturnType<typeof EditorSelection.range>[]): number[] =>
  activeLineStarts(
    EditorState.create({
      doc,
      selection: EditorSelection.create(ranges),
      extensions: EditorState.allowMultipleSelections.of(true),
    }),
  );

describe('cursor line highlight', () => {
  it('highlights the line of every cursor, once per line', () => {
    expect(starts(EditorSelection.cursor(5))).toEqual([4]);
    expect(starts(EditorSelection.cursor(1), EditorSelection.cursor(9))).toEqual([0, 8]);
    expect(starts(EditorSelection.cursor(4), EditorSelection.cursor(6))).toEqual([4]);
  });

  it('never highlights a line while text on it is selected', () => {
    // The phone case: a long-pressed word on the cursor's line.
    expect(starts(EditorSelection.range(4, 7))).toEqual([]);
    // A cursor sharing its line with a selection elsewhere on that line.
    expect(starts(EditorSelection.cursor(4), EditorSelection.range(6, 7))).toEqual([]);
    // A selected line break is drawn on its line.
    expect(starts(EditorSelection.cursor(1), EditorSelection.range(3, 4))).toEqual([]);
  });

  it('a selection that ends at a line start leaves that line alone', () => {
    expect(starts(EditorSelection.range(0, 4), EditorSelection.cursor(6))).toEqual([4]);
  });

  it('decorates the line in a view and follows the selection', () => {
    const parent = document.body.appendChild(document.createElement('div'));
    const view = new EditorView({
      parent,
      state: EditorState.create({ doc, selection: EditorSelection.single(5), extensions: cursorLineHighlight() }),
    });
    const active = (): string[] => [...parent.querySelectorAll('.cm-activeLine')].map((e) => e.textContent ?? '');
    expect(active()).toEqual(['two']);
    view.dispatch({ selection: EditorSelection.single(4, 7) });
    expect(active()).toEqual([]);
    view.dispatch({ selection: EditorSelection.single(10) });
    expect(active()).toEqual(['three']);
    view.destroy();
    parent.remove();
  });
});
