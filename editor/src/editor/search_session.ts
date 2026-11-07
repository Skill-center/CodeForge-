/**
 * The search session behind the app's find bar (EDITOR_ARCHITECTURE §8).
 *
 * The app owns the find UI. The page keeps CodeMirror's query state and its
 * find and replace commands, highlights the matches in view while the
 * session is open, and counts them for the bar. CodeMirror's own search
 * panel is never shown: nothing here opens it, and should anything else,
 * it renders nothing.
 */
import { getSearchQuery, search } from '@codemirror/search';
import {
  Annotation,
  type EditorState,
  type Extension,
  RangeSetBuilder,
  StateEffect,
  StateField,
} from '@codemirror/state';
import {
  type Command,
  Decoration,
  type DecorationSet,
  type EditorView,
  type Panel,
  ViewPlugin,
  type ViewUpdate,
} from '@codemirror/view';

import { MAX_COUNTED_MATCHES } from '../protocol/types';

/** Opens or closes the session in one document's state. */
export const setSearchOpen = StateEffect.define<boolean>();

/**
 * Marks a transaction whose session change the host must not hear about:
 * closing the session in a document that is being swapped out.
 */
export const quietSearch = Annotation.define<boolean>();

export const searchOpen = StateField.define<boolean>({
  create: () => false,
  update(open, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setSearchOpen)) open = effect.value;
    }
    return open;
  },
});

export function isSearchOpen(state: EditorState): boolean {
  return state.field(searchOpen, false) ?? false;
}

export interface MatchCount {
  matches: number;
  /** 1-based index of the match the main selection covers; 0 when none. */
  current: number;
  /** True when counting stopped at the cap and there are more. */
  capped: boolean;
}

/** Counts the query's matches in [state], stopping after [cap]. */
export function countMatches(state: EditorState, cap = MAX_COUNTED_MATCHES): MatchCount {
  const query = getSearchQuery(state);
  if (!query.valid) return { matches: 0, current: 0, capped: false };
  const { from, to } = state.selection.main;
  const cursor = query.getCursor(state);
  let matches = 0;
  let current = 0;
  for (let next = cursor.next(); !next.done; next = cursor.next()) {
    if (matches === cap) return { matches, current, capped: true };
    matches += 1;
    if (next.value.from === from && next.value.to === to) current = matches;
  }
  return { matches, current, capped: false };
}

/** Whether [update] opened or closed the session or changed its query. */
export function sessionChanged(update: ViewUpdate): boolean {
  return (
    isSearchOpen(update.state) !== isSearchOpen(update.startState) ||
    !getSearchQuery(update.state).eq(getSearchQuery(update.startState))
  );
}

/**
 * Runs a find or replace command only when the query is usable. Given an
 * empty or broken query, CodeMirror's commands would open its own panel.
 */
export function withValidQuery(command: Command): Command {
  return (view) => getSearchQuery(view.state).valid && command(view);
}

const matchMark = Decoration.mark({ class: 'cm-searchMatch' });
const currentMark = Decoration.mark({ class: 'cm-searchMatch cm-searchMatch-selected' });

/** Matches this close to the viewport are highlighted too, as CodeMirror does. */
const MARGIN = 250;

function highlight(view: EditorView): DecorationSet {
  const { state } = view;
  const query = getSearchQuery(state);
  if (!isSearchOpen(state) || !query.valid) return Decoration.none;
  const builder = new RangeSetBuilder<Decoration>();
  const ranges = view.visibleRanges;
  // Everything before this position has been searched.
  let searched = 0;
  for (let i = 0; i < ranges.length; i++) {
    let { from, to } = ranges[i];
    // Nearby visible ranges are searched as one, so no match is cut in two.
    while (i < ranges.length - 1 && to > ranges[i + 1].from - 2 * MARGIN) to = ranges[++i].to;
    from = Math.max(searched, from - MARGIN);
    to = Math.min(state.doc.length, to + MARGIN);
    if (from > to) continue;
    const cursor = query.getCursor(state, from, to);
    for (let next = cursor.next(); !next.done; next = cursor.next()) {
      const match = next.value;
      // Empty matches (a regexp like ^) count, but there is nothing to paint.
      if (match.from === match.to) continue;
      const current = state.selection.ranges.some((r) => r.from === match.from && r.to === match.to);
      builder.add(match.from, match.to, current ? currentMark : matchMark);
    }
    searched = to;
  }
  return builder.finish();
}

const highlighter = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = highlight(view);
    }

    update(update: ViewUpdate): void {
      if (update.docChanged || update.selectionSet || update.viewportChanged || sessionChanged(update)) {
        this.decorations = highlight(update.view);
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

/** Should anything open CodeMirror's own search panel, it shows nothing. */
function hiddenPanel(): Panel {
  const dom = document.createElement('div');
  dom.hidden = true;
  return { dom, top: true };
}

/** Query state, the open flag and match highlighting, for each document. */
export function searchSession(): Extension {
  return [search({ createPanel: hiddenPanel }), searchOpen, highlighter];
}
