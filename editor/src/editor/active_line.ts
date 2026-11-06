/**
 * Active-line highlight for cursors only.
 *
 * The active line's background is opaque: the host sends a contrast-tested
 * design token. CodeMirror draws selections in a layer beneath the lines,
 * so highlighting a line that holds selected text would hide that text's
 * selection. A phone run found this in Phase 2 W3: a long-pressed word on
 * the cursor's line showed handles but no highlight. As in VS Code, the line
 * is therefore highlighted only around a plain cursor and never while any
 * text on it is selected.
 */
import type { EditorState, Extension, Line } from '@codemirror/state';
import { Decoration, type DecorationSet, type EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';

const lineDecoration = Decoration.line({ class: 'cm-activeLine' });

/** Whether any non-empty range draws a selection on [line]. */
function selectionTouches(state: EditorState, line: Line): boolean {
  // A range that ends exactly at the line's start draws nothing on it; one
  // that starts at its end covers its line break, which is drawn on it.
  return state.selection.ranges.some((r) => !r.empty && r.from <= line.to && r.to > line.from);
}

/** Line starts to highlight, ascending, for the current selection. */
export function activeLineStarts(state: EditorState): number[] {
  const starts: number[] = [];
  for (const range of state.selection.ranges) {
    if (!range.empty) continue;
    const line = state.doc.lineAt(range.head);
    if (starts[starts.length - 1] === line.from || selectionTouches(state, line)) continue;
    starts.push(line.from);
  }
  return starts;
}

function decorations(view: EditorView): DecorationSet {
  return Decoration.set(activeLineStarts(view.state).map((from) => lineDecoration.range(from)));
}

const plugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = decorations(view);
    }

    update(update: ViewUpdate): void {
      if (update.docChanged || update.selectionSet) this.decorations = decorations(update.view);
    }
  },
  { decorations: (v) => v.decorations },
);

/** Drop-in replacement for highlightActiveLine(): cursors only. */
export function cursorLineHighlight(): Extension {
  return plugin;
}
