/**
 * The Tab key, for the symbol toolbar and hardware keyboards alike (W6):
 * selected lines are indented, and an empty cursor gets spaces up to the
 * next indent stop, as in VS Code. CodeMirror's own `insertTab` would type a
 * literal tab character, and `indentMore` would push the whole line from a
 * cursor in the middle of it.
 */
import { indentMore } from '@codemirror/commands';
import { getIndentUnit, indentUnit } from '@codemirror/language';
import { countColumn, EditorSelection } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';

export function insertIndent(view: EditorView): boolean {
  const { state } = view;
  if (state.readOnly) return false;
  if (state.selection.ranges.some((range) => !range.empty)) return indentMore(view);
  const tabs = state.facet(indentUnit).startsWith('\t');
  const width = getIndentUnit(state);
  view.dispatch(
    state.changeByRange((range) => {
      const line = state.doc.lineAt(range.head);
      const column = countColumn(line.text.slice(0, range.head - line.from), state.tabSize);
      const text = tabs ? '\t' : ' '.repeat(width - (column % width));
      return {
        changes: { from: range.head, insert: text },
        range: EditorSelection.cursor(range.head + text.length),
      };
    }),
    { userEvent: 'input.indent', scrollIntoView: true },
  );
  return true;
}
