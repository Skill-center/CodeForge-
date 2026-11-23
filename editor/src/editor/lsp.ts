/**
 * The editor's language features (Phase 6 W5, PHASE_6_PLAN W5), for the
 * languages a server analyses. The servers run behind the host; this layer
 * asks the host (`lsp.*`, requests.ts) and draws the answers.
 *
 * - **Completion:** CodeMirror's autocomplete with the server as an
 *   asynchronous source, as the user types and after the server's trigger
 *   characters. Each item shows its kind's icon; its documentation is
 *   fetched when it is selected; its text edit, and any edits that come with
 *   it (an import), are applied. While no server can answer (`unavailable`:
 *   starting, restarting, given up) the editor's own word completion
 *   stands in.
 * - **Diagnostics** come from the host (`diag.set`, controller.ts) as
 *   `@codemirror/lint` diagnostics: underlines and gutter marks. A tap on an
 *   underline shows its messages.
 * - **The symbol menu:** a long press (the WebView's `contextmenu`, which
 *   is not cancelled, so the word is still selected for copying) shows the
 *   diagnostics there, the server's hover text, and *Go to definition* and
 *   *Rename…*. With a mouse, hovering shows the hover text too.
 * - **Definition and rename** go to the host, which opens the definition or
 *   asks for the new name itself: F12 and F2, the symbol menu, and the
 *   host's commands (the symbol toolbar, the palette). A request that finds
 *   nothing, or fails, says so briefly at the cursor.
 * - **Timing** (Phase 6 W6): each list asked of a server is timed from the
 *   request to the frame that draws it (timings.ts); the host reads the
 *   times with `probe.read`.
 */
import {
  autocompletion,
  type Completion,
  type CompletionContext,
  type CompletionResult,
  completeAnyWord,
  pickedCompletion,
} from '@codemirror/autocomplete';
import { type Diagnostic, forEachDiagnostic, lintGutter, linter, nextDiagnostic, previousDiagnostic } from '@codemirror/lint';
import { EditorSelection, type EditorState, type Extension, Prec, StateEffect, StateField } from '@codemirror/state';
import { EditorView, hoverTooltip, keymap, showTooltip, type Tooltip } from '@codemirror/view';

import {
  type CompletionItemJson,
  type DiagnosticItem,
  type LanguageId,
  MAX_COMPLETION_ITEMS,
  type MarkupJson,
  type PageRequests,
  type PageResults,
  type TextEditJson,
} from '../protocol/types';
import type { Scheduler } from './batcher';
import { renderMarkup } from './markdown';
import { type PageRequester, REQUEST_TIMEOUT_MS, RequestError } from './requests';
import type { CompletionTimings } from './timings';

/** The languages a server analyses (app/lib/core/lsp/lsp_models.dart, LspServerId). */
export const ANALYZED_LANGUAGES: ReadonlySet<LanguageId> = new Set<LanguageId>([
  'python',
  'javascript',
  'jsx',
  'typescript',
  'tsx',
]);

/** How long a notice ("No definition found") stays. */
export const NOTICE_MS = 3000;

/** Identifier characters before the cursor: Python's, and JavaScript's `$`. */
const WORD_BEFORE = /[\w$]+/;
const WORD_TAIL = /^[\w$]*$/;

/** What the layer needs from the controller. */
export interface LanguageHost {
  readonly requests: PageRequester | null;
  readonly scheduler: Scheduler;
  /** The id of the document [state] belongs to, '' for none. */
  docIdOf(state: EditorState): string;
  /** Sends [docId]'s edits not sent yet; its version now, or null when it is not open. */
  syncedVersion(docId: string): number | null;
  /** Where each completion list's time goes (Phase 6 W6). */
  readonly timings: CompletionTimings;
}

/** A completion option with what applying and resolving it need. */
interface LspCompletion extends Completion {
  readonly item: CompletionItemJson;
  readonly docId: string;
  readonly resultId: string;
  readonly index: number;
  /** Where the typed word started, and the cursor, when the page asked. */
  readonly resultFrom: number;
  readonly requestPos: number;
  resolved?: PageResults['lsp.resolve'] | null;
  resolving?: Promise<PageResults['lsp.resolve'] | null>;
}

interface MenuState {
  readonly pos: number;
  /** The word pressed; the menu goes when the cursor leaves it. */
  readonly from: number;
  readonly to: number;
  /** The hover text: loading, none, or why there is none. */
  readonly hover: 'loading' | MarkupJson | null | { error: string };
  readonly diagnostics: readonly Diagnostic[];
}

interface TapState {
  readonly pos: number;
  readonly from: number;
  readonly to: number;
  readonly diagnostics: readonly Diagnostic[];
}

interface NoticeState {
  readonly pos: number;
  readonly message: string;
}

/** The diagnostics covering [pos], at their current positions. */
export function diagnosticsAt(state: EditorState, pos: number): Diagnostic[] {
  const found: Diagnostic[] = [];
  forEachDiagnostic(state, (d, from, to) => {
    if (from <= pos && pos <= to) found.push(d);
  });
  return found;
}

/** A host diagnostic as `@codemirror/lint` draws it, at [from]..[to]. */
export function toLintDiagnostic(item: DiagnosticItem, from: number, to: number): Diagnostic {
  const marks = (item.tags ?? []).map((tag) => `cm-cf-${tag}`);
  const source = item.source && item.code ? `${item.source}(${item.code})` : (item.source ?? item.code);
  return {
    from,
    to,
    severity: item.severity,
    message: item.message,
    ...(source ? { source } : {}),
    ...(marks.length > 0 ? { markClass: marks.join(' ') } : {}),
  };
}

const SEVERITY_LABEL: Record<Diagnostic['severity'], string> = {
  error: 'Error',
  warning: 'Warning',
  info: 'Info',
  hint: 'Hint',
};

function diagnosticRows(diagnostics: readonly Diagnostic[]): HTMLElement {
  const box = document.createElement('div');
  box.className = 'cm-cf-diagnostics';
  for (const d of diagnostics) {
    const row = document.createElement('div');
    row.className = `cm-cf-diagnostic cm-cf-diagnostic-${d.severity}`;
    const label = document.createElement('span');
    label.className = 'cm-cf-severity';
    label.textContent = SEVERITY_LABEL[d.severity];
    const message = document.createElement('span');
    message.className = 'cm-cf-message';
    message.textContent = d.source ? `${d.message} (${d.source})` : d.message;
    row.append(label, message);
    box.append(row);
  }
  return box;
}

/** Long details (TypeScript's signatures) are cut in the list; the documentation has them whole. */
function shortDetail(detail: string): string {
  const line = detail.split('\n', 1)[0] ?? '';
  return line.length > 60 ? `${line.slice(0, 59)}…` : line;
}

const theme = EditorView.baseTheme({
  '.cm-tooltip.cm-cf-tooltip': { maxWidth: 'min(36em, 90vw)', fontFamily: 'sans-serif', fontSize: '0.9em' },
  '.cm-cf-menu, .cm-cf-tap, .cm-cf-notice, .cm-cf-hover-box': { padding: '6px 8px', maxHeight: '45vh', overflowY: 'auto' },
  '.cm-cf-doc p': { margin: '0.3em 0' },
  '.cm-cf-doc hr': { border: 'none', borderTop: '1px solid currentColor', opacity: '0.25', margin: '0.4em 0' },
  '.cm-cf-doc pre, .cm-cf-info pre, .cm-cf-inline-code': {
    fontFamily: '"JetBrains Mono", monospace',
    fontVariantLigatures: 'none',
  },
  '.cm-cf-doc pre, .cm-cf-info pre': { margin: '0.3em 0', whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' },
  '.cm-cf-li': { margin: '0.15em 0' },
  '.cm-cf-muted': { opacity: '0.7' },
  '.cm-cf-diagnostic': { display: 'flex', gap: '0.5em', margin: '0.2em 0' },
  '.cm-cf-severity': { fontWeight: 'bold', flex: 'none' },
  '.cm-cf-diagnostic-error .cm-cf-severity': { color: '#E5484D' },
  '.cm-cf-diagnostic-warning .cm-cf-severity': { color: '#E5A00D' },
  '.cm-cf-diagnostic-info .cm-cf-severity, .cm-cf-diagnostic-hint .cm-cf-severity': { color: '#4C9AFF' },
  '.cm-cf-actions': { display: 'flex', flexWrap: 'wrap', gap: '6px', marginTop: '6px' },
  '.cm-cf-action': {
    minHeight: '40px',
    padding: '0 12px',
    font: 'inherit',
    color: 'inherit',
    background: 'transparent',
    border: '1px solid currentColor',
    borderRadius: '6px',
  },
  '.cm-cf-unnecessary': { opacity: '0.6' },
  '.cm-cf-deprecated': { textDecoration: 'line-through' },
  '.cm-completionDetail': { maxWidth: '40%', overflow: 'hidden', textOverflow: 'ellipsis', verticalAlign: 'bottom' },
  '.cm-tooltip.cm-completionInfo': { maxWidth: 'min(30em, 70vw)' },
});

export class LanguageLayer {
  /** Each document's trigger characters, once its server named them. */
  private readonly triggers = new Map<string, ReadonlySet<string>>();
  /** Where the last incomplete list was asked, to say so when asking again. */
  private incompleteAt: { docId: string; from: number } | null = null;
  private readonly hoverWithMouse: boolean;

  readonly openMenu = StateEffect.define<MenuState | null>();
  readonly showTap = StateEffect.define<TapState | null>();
  readonly showNotice = StateEffect.define<NoticeState | null>();

  readonly menuField: StateField<MenuState | null>;
  readonly tapField: StateField<TapState | null>;
  readonly noticeField: StateField<NoticeState | null>;

  constructor(private readonly host: LanguageHost) {
    this.hoverWithMouse =
      typeof window !== 'undefined' && typeof window.matchMedia === 'function' && window.matchMedia('(hover: hover)').matches;
    const openMenu = this.openMenu;
    this.menuField = StateField.define<MenuState | null>({
      create: () => null,
      update: (value, tr) => {
        for (const effect of tr.effects) if (effect.is(openMenu)) return effect.value;
        if (value === null || tr.docChanged) return null;
        const head = tr.state.selection.main.head;
        return tr.selection && (head < value.from || head > value.to) ? null : value;
      },
      provide: (field) => showTooltip.from(field, (menu) => (menu ? this.menuTooltip(menu) : null)),
    });
    const showTap = this.showTap;
    this.tapField = StateField.define<TapState | null>({
      create: () => null,
      update: (value, tr) => {
        for (const effect of tr.effects) if (effect.is(showTap)) return effect.value;
        if (value === null || tr.docChanged) return null;
        const head = tr.state.selection.main.head;
        return tr.selection && (head < value.from || head > value.to) ? null : value;
      },
      provide: (field) =>
        showTooltip.from(field, (tap) =>
          tap
            ? {
                pos: tap.pos,
                above: true,
                create: () => this.box('cm-cf-tap', diagnosticRows(tap.diagnostics)),
              }
            : null,
        ),
    });
    const showNotice = this.showNotice;
    this.noticeField = StateField.define<NoticeState | null>({
      create: () => null,
      update: (value, tr) => {
        for (const effect of tr.effects) if (effect.is(showNotice)) return effect.value;
        return tr.docChanged ? null : value;
      },
      provide: (field) =>
        showTooltip.from(field, (notice) => {
          if (!notice) return null;
          const text = document.createElement('div');
          text.textContent = notice.message;
          return { pos: notice.pos, above: true, create: () => this.box('cm-cf-notice', text) };
        }),
    });
  }

  /** The features for a document in [language]: none for a language no server analyses. */
  extensions(language: LanguageId): Extension {
    if (!ANALYZED_LANGUAGES.has(language)) return [];
    return [
      autocompletion({
        override: [this.complete],
        maxRenderedOptions: MAX_COMPLETION_ITEMS,
        icons: true,
        optionClass: (completion) => ((completion as Partial<LspCompletion>).item?.deprecated ? 'cm-cf-deprecated' : ''),
      }),
      // Underlines take their messages from a tap (tapField): lint's own
      // tooltip waits for a mouse to hover, which a finger never does.
      linter(null, { tooltipFilter: () => [] }),
      lintGutter(),
      this.menuField,
      this.tapField,
      this.noticeField,
      Prec.high(
        keymap.of([
          { key: 'F12', run: (view) => this.goToDefinition(view, view.state.selection.main.head) },
          { key: 'F2', run: (view) => this.renameSymbol(view, view.state.selection.main.head) },
          { key: 'F8', run: nextDiagnostic },
          { key: 'Shift-F8', run: previousDiagnostic },
          { key: 'Escape', run: (view) => this.closePopups(view) },
        ]),
      ),
      EditorView.domEventHandlers({
        contextmenu: (event, view) => {
          const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
          if (pos !== null) this.openMenuAt(view, pos);
          // Not cancelled: the WebView still selects the word.
          return false;
        },
        click: (event, view) => {
          const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
          if (pos !== null) this.tapAt(view, pos);
          return false;
        },
      }),
      this.hoverWithMouse ? hoverTooltip(this.hover, { hoverTime: 600 }) : [],
      // The frame that draws an answered list is timed (Phase 6 W6).
      EditorView.updateListener.of((update) => {
        if (this.host.timings.waiting) this.host.timings.update(update.state);
      }),
      theme,
    ];
  }

  // ------------------------------------------------------------ commands

  /** Asks the host to open the definition at [pos]; false where no server analyses the document. */
  goToDefinition(view: EditorView, pos: number): boolean {
    if (!this.analyzed(view.state)) return false;
    void this.ask(view, 'lsp.definition', pos).then((answer) => {
      if (answer instanceof RequestError) this.noticeFor(view, pos, answer);
      else if (answer.found === 0) this.notice(view, pos, 'No definition found');
    });
    return true;
  }

  /** Asks the host to rename the symbol at [pos]; it asks for the new name itself. */
  renameSymbol(view: EditorView, pos: number): boolean {
    if (!this.analyzed(view.state)) return false;
    void this.ask(view, 'lsp.prepareRename', pos).then((answer) => {
      if (answer instanceof RequestError) this.noticeFor(view, pos, answer);
    });
    return true;
  }

  /** Opens the symbol menu at [pos] (a long press, or the host's command at the cursor). */
  openMenuAt(view: EditorView, pos: number): boolean {
    const state = view.state;
    if (!this.analyzed(state)) return false;
    const word = state.wordAt(pos);
    const diagnostics = diagnosticsAt(state, pos);
    if (word === null && diagnostics.length === 0) return false;
    const menu: MenuState = {
      pos,
      from: word?.from ?? pos,
      to: word?.to ?? pos,
      hover: word === null ? null : 'loading',
      diagnostics,
    };
    view.dispatch({ effects: [this.openMenu.of(menu), this.showTap.of(null), this.showNotice.of(null)] });
    if (word !== null) {
      void this.ask(view, 'lsp.hover', pos).then((answer) => {
        if (view.state.field(this.menuField, false) !== menu) return;
        const hover =
          answer instanceof RequestError
            ? answer.code === 'cancelled'
              ? null
              : { error: answer.message }
            : answer.contents && answer.contents.value.trim() !== ''
              ? answer.contents
              : null;
        view.dispatch({ effects: this.openMenu.of({ ...menu, hover }) });
      });
    }
    return true;
  }

  /** Closes the symbol menu, a tap's messages and a notice; false when none was open. */
  closePopups(view: EditorView): boolean {
    const state = view.state;
    const open =
      (state.field(this.menuField, false) ?? null) !== null ||
      (state.field(this.tapField, false) ?? null) !== null ||
      (state.field(this.noticeField, false) ?? null) !== null;
    if (open) view.dispatch({ effects: [this.openMenu.of(null), this.showTap.of(null), this.showNotice.of(null)] });
    return open;
  }

  // ---------------------------------------------------------- completion

  private readonly complete = async (context: CompletionContext): Promise<CompletionResult | null> => {
    const docId = this.host.docIdOf(context.state);
    const word = context.matchBefore(WORD_BEFORE);
    const before = context.pos > 0 ? context.state.sliceDoc(context.pos - 1, context.pos) : '';
    // Typing a trigger character asks as `character`; asking explicitly
    // (Ctrl+Space) is `invoked` wherever the cursor is.
    const triggered = !context.explicit && word === null && (this.triggers.get(docId) ?? DEFAULT_TRIGGERS).has(before);
    if (!context.explicit && word === null && !triggered) return null;
    // A number, not a name.
    if (!context.explicit && word !== null && /^\d/.test(word.text)) return null;
    const requests = this.host.requests;
    // Timed from here (Phase 6 W6): the edits not sent yet go first.
    const started = this.host.timings.now();
    const version = docId === '' ? null : this.host.syncedVersion(docId);
    if (requests === null || version === null) return completeAnyWord(context);
    const from = word?.from ?? context.pos;
    const again = this.incompleteAt !== null && this.incompleteAt.docId === docId && this.incompleteAt.from === from;
    const payload: PageRequests['lsp.complete'] = {
      docId,
      version,
      pos: context.pos,
      trigger: triggered ? 'character' : again ? 'incomplete' : 'invoked',
    };
    if (triggered) payload.character = before;
    const pending = requests.request('lsp.complete', payload, REQUEST_TIMEOUT_MS['lsp.complete']);
    context.addEventListener('abort', () => requests.cancel(pending.id));
    let result: PageResults['lsp.complete'];
    try {
      result = await pending.result;
    } catch (error) {
      // No server can answer now: the editor's own words stand in.
      if (error instanceof RequestError && error.code === 'unavailable') return completeAnyWord(context);
      return null;
    }
    if (result.triggerCharacters !== undefined) this.triggers.set(docId, new Set(result.triggerCharacters));
    this.incompleteAt = result.incomplete ? { docId, from } : null;
    const options = result.items.length === 0 ? [] : this.options(result, docId, from, context.pos);
    this.host.timings.answered(started, options, payload.trigger);
    if (options.length === 0) return null;
    return result.incomplete ? { from, options } : { from, options, validFor: WORD_TAIL };
  };

  private options(result: PageResults['lsp.complete'], docId: string, from: number, pos: number): LspCompletion[] {
    const items = result.items;
    // The server's order (sortText) breaks ties between equally good matches.
    const order = items
      .map((item, index) => ({ key: item.sortText ?? item.label, index }))
      .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : a.index - b.index));
    const rank = new Array<number>(items.length).fill(0);
    order.forEach((entry, r) => {
      rank[entry.index] = r;
    });
    const n = items.length;
    return items.map((item, index) => {
      const completion: LspCompletion = {
        label: item.filterText ?? item.label,
        boost: item.preselect ? 99 : n <= 1 ? 0 : Math.round(99 - (198 * (rank[index] ?? 0)) / (n - 1)),
        apply: (view, picked, applyFrom, applyTo) => this.apply(view, picked as LspCompletion, applyFrom, applyTo),
        item,
        docId,
        resultId: result.resultId,
        index,
        resultFrom: from,
        requestPos: pos,
      };
      if (item.filterText !== undefined && item.filterText !== item.label) completion.displayLabel = item.label;
      if (item.kind !== undefined) completion.type = item.kind;
      if (item.detail) completion.detail = shortDetail(item.detail);
      if (item.resolvable || item.detail) completion.info = (picked) => this.info(picked as LspCompletion);
      return completion;
    });
  }

  private async info(completion: LspCompletion): Promise<Node | null> {
    const resolved = completion.item.resolvable ? await this.resolve(completion) : null;
    const detail = resolved?.detail ?? completion.item.detail;
    const documentation = resolved?.documentation;
    if (!detail && !documentation) return null;
    const box = document.createElement('div');
    box.className = 'cm-cf-info';
    if (detail) {
      const pre = document.createElement('pre');
      pre.textContent = detail;
      box.append(pre);
    }
    if (documentation && documentation.value.trim() !== '') box.append(renderMarkup(documentation));
    return box;
  }

  private resolve(completion: LspCompletion): Promise<PageResults['lsp.resolve'] | null> {
    if (completion.resolving) return completion.resolving;
    const requests = this.host.requests;
    if (requests === null) return Promise.resolve(null);
    const pending = requests.request(
      'lsp.resolve',
      { docId: completion.docId, resultId: completion.resultId, index: completion.index },
      REQUEST_TIMEOUT_MS['lsp.resolve'],
    );
    completion.resolving = pending.result.then(
      (resolved) => {
        completion.resolved = resolved;
        return resolved;
      },
      () => {
        completion.resolved = null;
        return null;
      },
    );
    return completion.resolving;
  }

  /**
   * Applies [completion] over [from]..[to], CodeMirror's range of the typed
   * word now. The server's edit was computed when the page asked: its start
   * keeps its place relative to the word, and its end moves with the
   * characters typed since. Edits that come with it (an import) apply when
   * they lie before the word, which typing since has not moved.
   */
  private apply(view: EditorView, completion: LspCompletion, from: number, to: number): void {
    const state = view.state;
    const length = state.doc.length;
    const clamp = (n: number) => Math.max(0, Math.min(length, n));
    const typed = to - completion.requestPos;
    const edit = completion.item.edit;
    const mainFrom = edit ? clamp(from + (edit.from - completion.resultFrom)) : from;
    const mainTo = edit ? clamp(Math.max(mainFrom, edit.to >= completion.requestPos ? edit.to + typed : edit.to)) : to;
    const insert = edit ? edit.insert : (completion.item.insert ?? completion.item.label);
    const limit = Math.min(mainFrom, completion.resultFrom);
    const known = completion.resolved?.additionalEdits ?? completion.item.additionalEdits;
    const extra = before(known ?? [], limit);
    let changes;
    try {
      changes = state.changes([...extra, { from: mainFrom, to: mainTo, insert }]);
    } catch {
      changes = state.changes({ from: mainFrom, to: mainTo, insert });
    }
    view.dispatch({
      changes,
      selection: EditorSelection.cursor(changes.mapPos(mainTo, 1)),
      annotations: pickedCompletion.of(completion),
      userEvent: 'input.complete',
      scrollIntoView: true,
    });
    if (!completion.item.resolvable || completion.resolved !== undefined || known !== undefined) return;
    // Picked before its documentation came: the edits that come with it
    // (TypeScript's imports) may still be on their way.
    const docAfter = view.state.doc;
    void this.resolve(completion).then((resolved) => {
      const late = resolved?.additionalEdits ?? [];
      if (late.length === 0 || view.state.doc !== docAfter) return;
      const safe = before(late, limit);
      if (safe.length !== late.length) return;
      try {
        view.dispatch({ changes: safe, userEvent: 'input.complete' });
      } catch {
        // Overlapping edits from a server: none is applied.
      }
    });
  }

  // --------------------------------------------------------------- hover

  private readonly hover = async (view: EditorView, pos: number): Promise<Tooltip | null> => {
    const answer = await this.ask(view, 'lsp.hover', pos);
    if (answer instanceof RequestError || !answer.contents || answer.contents.value.trim() === '') return null;
    const contents = answer.contents;
    const length = view.state.doc.length;
    return {
      pos: Math.min(answer.from ?? pos, length),
      end: Math.min(answer.to ?? pos, length),
      above: true,
      create: () => this.box('cm-cf-hover-box', renderMarkup(contents)),
    };
  };

  // ------------------------------------------------------------- helpers

  private analyzed(state: EditorState): boolean {
    return state.field(this.menuField, false) !== undefined;
  }

  private async ask<K extends 'lsp.hover' | 'lsp.definition' | 'lsp.prepareRename'>(
    view: EditorView,
    type: K,
    pos: number,
  ): Promise<PageResults[K] | RequestError> {
    const docId = this.host.docIdOf(view.state);
    const requests = this.host.requests;
    const version = docId === '' ? null : this.host.syncedVersion(docId);
    if (requests === null || version === null) {
      return new RequestError('unavailable', 'Language features are not available here');
    }
    try {
      const payload = { docId, version, pos } as PageRequests[K];
      return await requests.request(type, payload, REQUEST_TIMEOUT_MS[type]).result;
    } catch (error) {
      return error instanceof RequestError ? error : new RequestError('internal', String(error));
    }
  }

  private tapAt(view: EditorView, pos: number): void {
    const found = diagnosticsAt(view.state, pos);
    if (found.length === 0) {
      if (view.state.field(this.tapField, false)) view.dispatch({ effects: this.showTap.of(null) });
      return;
    }
    let from = pos;
    let to = pos;
    forEachDiagnostic(view.state, (_d, dFrom, dTo) => {
      if (dFrom <= pos && pos <= dTo) {
        from = Math.min(from, dFrom);
        to = Math.max(to, dTo);
      }
    });
    view.dispatch({ effects: this.showTap.of({ pos, from, to, diagnostics: found }) });
  }

  private noticeFor(view: EditorView, pos: number, error: RequestError): void {
    if (error.code !== 'cancelled') this.notice(view, pos, error.message);
  }

  /** Says [message] at [pos] for a moment, if the same document is still in view. */
  private notice(view: EditorView, pos: number, message: string): void {
    if (view.state.field(this.noticeField, false) === undefined) return;
    const notice: NoticeState = { pos: Math.min(pos, view.state.doc.length), message };
    view.dispatch({ effects: this.showNotice.of(notice) });
    this.host.scheduler.set(() => {
      if (view.state.field(this.noticeField, false) === notice) view.dispatch({ effects: this.showNotice.of(null) });
    }, NOTICE_MS);
  }

  private box(className: string, content: Node): { dom: HTMLElement } {
    const dom = document.createElement('div');
    dom.className = className;
    dom.append(content);
    return { dom };
  }

  private menuTooltip(menu: MenuState): Tooltip {
    return {
      pos: menu.pos,
      above: false,
      create: (view) => {
        const dom = document.createElement('div');
        dom.className = 'cm-cf-menu';
        dom.setAttribute('role', 'dialog');
        dom.setAttribute('aria-label', 'Symbol');
        if (menu.diagnostics.length > 0) dom.append(diagnosticRows(menu.diagnostics));
        if (menu.hover !== null || menu.diagnostics.length === 0) {
          const hover = document.createElement('div');
          hover.className = 'cm-cf-hover';
          if (menu.hover === 'loading') {
            hover.textContent = 'Loading…';
            hover.classList.add('cm-cf-muted');
          } else if (menu.hover === null) {
            hover.textContent = 'No information';
            hover.classList.add('cm-cf-muted');
          } else if ('error' in menu.hover) {
            hover.textContent = menu.hover.error;
            hover.classList.add('cm-cf-muted');
          } else {
            hover.append(renderMarkup(menu.hover));
          }
          dom.append(hover);
        }
        const actions = document.createElement('div');
        actions.className = 'cm-cf-actions';
        actions.append(
          this.action(view, 'Go to definition', 'definition', () => this.goToDefinition(view, menu.pos)),
          this.action(view, 'Rename…', 'rename', () => this.renameSymbol(view, menu.pos)),
        );
        dom.append(actions);
        return { dom };
      },
    };
  }

  private action(view: EditorView, label: string, name: string, run: () => void): HTMLButtonElement {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'cm-cf-action';
    button.dataset.action = name;
    button.textContent = label;
    // The editor keeps its focus and selection.
    button.addEventListener('mousedown', (event) => event.preventDefault());
    button.addEventListener('click', (event) => {
      event.preventDefault();
      view.dispatch({ effects: this.openMenu.of(null) });
      run();
    });
    return button;
  }
}

/** Until a server names its own, a member access asks it. */
const DEFAULT_TRIGGERS: ReadonlySet<string> = new Set(['.']);

/** The edits in [edits] that end at or before [limit], in a valid order. */
function before(edits: readonly TextEditJson[], limit: number): TextEditJson[] {
  return edits.filter((e) => e.from <= e.to && e.to <= limit).sort((a, b) => a.from - b.from);
}
