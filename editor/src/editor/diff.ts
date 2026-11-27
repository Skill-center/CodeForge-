/**
 * Diffs in the page (Phase 7 W5): `@codemirror/merge` over an open document.
 *
 * A diff never copies the document. In `inline` mode the document's own
 * state gains the unified merge extension, so the text being compared is the
 * one the user is editing: reverting a change is an ordinary edit, which
 * travels to the host as a change set and undoes with the rest of the undo
 * history. In `split` mode the page puts a second, read-only view beside the
 * document's — which is why only a read-only document may ask for it; a live
 * document is never moved out of its own editor.
 *
 * Only *Revert this change* is offered. `@codemirror/merge` can also accept a
 * chunk, which moves the *original* instead of the document; here the
 * original is a git blob the page cannot write, so that control is left out.
 */
import { MergeView, getChunks, unifiedMergeView } from '@codemirror/merge';
import { EditorState, type Extension } from '@codemirror/state';
import { EditorView } from '@codemirror/view';

import type { Palette } from '../protocol/types';

/** The label on each change's revert control. */
export const REVERT_LABEL = 'Revert this change';

/** Unchanged stretches longer than this collapse, with this much context. */
const COLLAPSE = { margin: 3, minSize: 4 };

/**
 * Renders a chunk's controls. `accept` would rewrite the older text, which
 * is a commit or the index here, so it is rendered as nothing at all.
 */
function chunkControl(type: 'accept' | 'reject', action: (event: MouseEvent) => void): HTMLElement {
  if (type === 'accept') {
    const none = document.createElement('span');
    none.style.display = 'none';
    return none;
  }
  const button = document.createElement('button');
  button.type = 'button';
  button.name = 'reject';
  button.className = 'cm-revertChunk';
  button.textContent = REVERT_LABEL;
  button.setAttribute('aria-label', REVERT_LABEL);
  let done = false;
  // Mouse down, as CodeMirror's own control does: a tap reverts without the
  // editor first moving the cursor into the widget.
  button.onmousedown = (event) => {
    if (done) return;
    done = true;
    action(event);
  };
  return button;
}

/**
 * The unified (one column) diff of the document against [original].
 *
 * [editable] decides whether each change gets its revert control: a
 * read-only document (a commit against its parent) has nothing to revert,
 * and `rejectChunk` would edit it anyway — CodeMirror's read-only facet
 * stops commands, not a transaction dispatched straight at the view.
 */
export function inlineDiff(original: string, editable: boolean): Extension {
  return unifiedMergeView({
    original,
    mergeControls: editable ? chunkControl : false,
    gutter: true,
    highlightChanges: true,
    collapseUnchanged: COLLAPSE,
  });
}

/** How many changed chunks [state] shows, 0 when it shows no diff. */
export function chunkCount(state: EditorState): number {
  return getChunks(state)?.chunks.length ?? 0;
}

/** The diff colours, from the app's own tokens (Palette.diffAdded/Removed). */
export function diffTheme(p: Palette): Extension {
  return EditorView.theme(
    {
      // Added or changed lines: the document's side in both modes.
      '&.cm-merge-b .cm-changedLine, .cm-inlineChangedLine, .cm-insertedLine': {
        backgroundColor: p.diffAdded,
      },
      // Removed lines: the older side, and the widget above an inline change.
      '&.cm-merge-a .cm-changedLine, .cm-deletedChunk, .cm-deletedLine': {
        backgroundColor: p.diffRemoved,
      },
      '.cm-deletedChunk del, .cm-deletedLine del': { textDecoration: 'none', color: p.foreground },
      '&.cm-merge-b .cm-changedText, .cm-inlineChangedText': {
        background: 'none',
        boxShadow: `inset 0 -2px 0 0 ${p.diffAdded}`,
      },
      '&.cm-merge-a .cm-changedText, .cm-deletedChunk .cm-deletedText': {
        background: 'none',
        boxShadow: `inset 0 -2px 0 0 ${p.diffRemoved}`,
      },
      '.cm-changeGutter': { width: '3px', paddingLeft: '1px' },
      '&.cm-merge-b .cm-changedLineGutter, .cm-inlineChangedLineGutter': { background: p.diffAdded },
      '&.cm-merge-a .cm-changedLineGutter, .cm-deletedLineGutter': { background: p.diffRemoved },
      // The controls sit on their own row at the top of a removed block, so
      // a touch-sized button never covers the text it belongs to.
      '.cm-deletedChunk': { paddingLeft: '6px' },
      '.cm-deletedChunk .cm-chunkButtons': {
        position: 'static',
        display: 'flex',
        justifyContent: 'flex-end',
        padding: '2px 0',
      },
      '.cm-revertChunk': {
        minHeight: '48px',
        padding: '0 12px',
        border: `1px solid ${p.border}`,
        borderRadius: '4px',
        margin: '0',
        background: p.panelBackground,
        color: p.foreground,
        font: 'inherit',
        fontSize: '0.85em',
        cursor: 'pointer',
      },
      // Collapsed stretches of unchanged text; tapping one opens it.
      '.cm-collapsedLines': {
        minHeight: '48px',
        display: 'flex',
        alignItems: 'center',
        padding: '0 10px',
        background: p.panelBackground,
        color: p.gutterForeground,
        cursor: 'pointer',
      },
      // Two columns: a divider, and each side scrolling with the other.
      '.cm-mergeView': { height: '100%', overflow: 'auto' },
      '.cm-mergeViewEditors': { alignItems: 'stretch' },
      '.cm-mergeViewEditor:first-child': { borderRight: `1px solid ${p.border}` },
    },
    { dark: p.dark },
  );
}

export interface SplitDiffOptions {
  parent: HTMLElement;
  /** The older text, shown on the left. */
  original: string;
  /** The document's text, shown on the right; read-only in this mode. */
  text: string;
  /** Theme, font, wrapping and language, from the controller's config. */
  extensions: Extension[];
}

/**
 * The two-column diff: the older text beside the document, lines aligned.
 * Both sides are read-only — the document itself stays in the controller's
 * own view, hidden while this one is up.
 */
export class SplitDiff {
  readonly view: MergeView;

  constructor(options: SplitDiffOptions) {
    const shared = [options.extensions, EditorState.readOnly.of(true), EditorView.editable.of(false)];
    this.view = new MergeView({
      a: { doc: options.original, extensions: shared },
      b: { doc: options.text, extensions: shared },
      parent: options.parent,
      orientation: 'a-b',
      highlightChanges: true,
      gutter: true,
      collapseUnchanged: COLLAPSE,
    });
  }

  get chunks(): number {
    return this.view.chunks.length;
  }

  destroy(): void {
    this.view.destroy();
  }
}
