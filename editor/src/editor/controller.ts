import { closeBrackets, closeBracketsKeymap } from '@codemirror/autocomplete';
import {
  cursorCharLeft,
  cursorCharRight,
  cursorLineBoundaryBackward,
  cursorLineBoundaryForward,
  cursorLineDown,
  cursorLineUp,
  defaultKeymap,
  history,
  historyKeymap,
  indentLess,
  indentMore,
  indentWithTab,
  redo,
  redoDepth,
  selectAll,
  toggleComment,
  undo,
  undoDepth,
} from '@codemirror/commands';
import { bracketMatching, foldGutter, foldKeymap, indentOnInput } from '@codemirror/language';
import {
  closeSearchPanel,
  findNext,
  findPrevious,
  highlightSelectionMatches,
  openSearchPanel,
  replaceAll,
  replaceNext,
  search,
  SearchQuery,
  searchKeymap,
  selectNextOccurrence,
  setSearchQuery,
} from '@codemirror/search';
import {
  type ChangeSet,
  Compartment,
  EditorSelection,
  EditorState,
  type Extension,
  Facet,
  type StateEffect,
} from '@codemirror/state';
import {
  drawSelection,
  dropCursor,
  EditorView,
  highlightActiveLineGutter,
  highlightSpecialChars,
  type KeyBinding,
  keymap,
  lineNumbers,
  rectangularSelection,
  type ViewUpdate,
} from '@codemirror/view';

import type {
  AppShortcut,
  ChangeSetJson,
  ConfigurePayload,
  DocOpenPayload,
  EditorCommand,
  EditorMessageType,
  EditorToHost,
  ErrorCode,
  HostMessageType,
  HostToEditor,
  LanguageId,
  Palette,
  SearchPayload,
  Selection,
  SnapshotResult,
} from '../protocol/types';
import { cursorLineHighlight } from './active_line';
import { browserScheduler, ChangeBatcher, type Scheduler } from './batcher';
import { languageExtension } from './languages';
import { DEFAULT_PALETTE, fontSizeTheme, forgeTheme } from './theme';

/** A rejected host command; the bridge turns it into an error response. */
export class EditorError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
  ) {
    super(message);
  }
}

export type Emit = <K extends EditorMessageType>(type: K, payload: EditorToHost[K]) => void;

export interface ControllerOptions {
  parent: HTMLElement;
  emit: Emit;
  scheduler?: Scheduler;
  /** Change-set batching window (EDITOR_ARCHITECTURE §2: ~150 ms). */
  batchDelayMs?: number;
  /** Cursor/scroll reports are throttled to one per window. */
  viewStateDelayMs?: number;
}

interface Config {
  palette: Palette;
  fontSize: number;
  lineWrapping: boolean;
  tabSize: number;
}

interface DocEntry {
  readonly id: string;
  state: EditorState;
  version: number;
  language: LanguageId;
  readOnly: boolean;
  configGen: number;
  /** Scroll position captured when the document was last swapped out. */
  scroll: StateEffect<unknown> | null;
  /** Scroll position requested by doc.open, applied on first activation. */
  pendingScrollTop: number | null;
  history: { canUndo: boolean; canRedo: boolean } | null;
}

/** Tags each document's state with its id, so updates can be attributed. */
const docIdFacet = Facet.define<string, string>({ combine: (values) => values[0] ?? '' });

const COMMANDS: Record<EditorCommand, (view: EditorView) => boolean> = {
  undo,
  redo,
  indentMore,
  indentLess,
  selectAll,
  cursorCharLeft,
  cursorCharRight,
  cursorLineUp,
  cursorLineDown,
  cursorLineStart: cursorLineBoundaryBackward,
  cursorLineEnd: cursorLineBoundaryForward,
  toggleComment,
  selectNextOccurrence,
  openSearch: openSearchPanel,
  closeSearch: closeSearchPanel,
  findNext,
  findPrevious,
  replaceNext,
  replaceAll,
  focus: (view) => {
    view.focus();
    return true;
  },
  blur: (view) => {
    view.contentDOM.blur();
    return true;
  },
};

function clampSelection(selection: Selection | undefined, length: number): EditorSelection | undefined {
  if (selection === undefined) return undefined;
  return EditorSelection.single(Math.min(selection.anchor, length), Math.min(selection.head, length));
}

function editableExtension(readOnly: boolean): Extension {
  return [EditorState.readOnly.of(readOnly), EditorView.editable.of(!readOnly)];
}

/**
 * One EditorView, one EditorState per open document (EDITOR_ARCHITECTURE §2).
 * Switching documents swaps states into the view, which keeps each
 * document's undo history, selection and scroll position, and avoids one
 * WebView per tab.
 */
export class EditorController {
  readonly view: EditorView;

  private readonly docs = new Map<string, DocEntry>();
  private activeId: string | null = null;
  private config: Config = { palette: DEFAULT_PALETTE, fontSize: 14, lineWrapping: false, tabSize: 4 };
  private configGen = 0;
  private readonly batcher: ChangeBatcher;
  private readonly scheduler: Scheduler;
  private readonly viewStateDelayMs: number;
  private viewStateTimer: unknown = null;
  private composing = false;

  private readonly themeSlot = new Compartment();
  private readonly fontSlot = new Compartment();
  private readonly wrapSlot = new Compartment();
  private readonly tabSlot = new Compartment();
  private readonly languageSlot = new Compartment();
  private readonly editableSlot = new Compartment();

  constructor(private readonly options: ControllerOptions) {
    this.scheduler = options.scheduler ?? browserScheduler;
    this.viewStateDelayMs = options.viewStateDelayMs ?? 400;
    this.batcher = new ChangeBatcher(
      (docId, changes) => this.emitChanges(docId, changes),
      options.batchDelayMs ?? 150,
      this.scheduler,
    );
    this.view = new EditorView({ parent: options.parent, state: this.idleState() });
    this.view.scrollDOM.addEventListener('scroll', () => this.scheduleViewState(), { passive: true });
  }

  get activeDocId(): string | null {
    return this.activeId;
  }

  hasDoc(docId: string): boolean {
    return this.docs.has(docId);
  }

  /** Routes one validated host message; the return value becomes the response result. */
  handle(type: HostMessageType, payload: unknown): unknown {
    switch (type) {
      case 'editor.configure':
        return this.configure(payload as ConfigurePayload);
      case 'doc.open':
        return this.open(payload as DocOpenPayload);
      case 'doc.activate':
        return this.activate((payload as HostToEditor['doc.activate']).docId);
      case 'doc.close':
        return this.close((payload as HostToEditor['doc.close']).docId);
      case 'doc.replace': {
        const p = payload as HostToEditor['doc.replace'];
        return this.replace(p.docId, p.text, p.version);
      }
      case 'doc.setLanguage': {
        const p = payload as HostToEditor['doc.setLanguage'];
        return this.setLanguage(p.docId, p.language);
      }
      case 'doc.flush':
        return this.flush((payload as HostToEditor['doc.flush']).docId);
      case 'doc.snapshot':
        return this.snapshot((payload as HostToEditor['doc.snapshot']).docId);
      case 'cmd.insert': {
        const p = payload as HostToEditor['cmd.insert'];
        return { inserted: this.insert(p.text, p.cursorOffset) };
      }
      case 'cmd.exec':
        return { ran: this.exec((payload as HostToEditor['cmd.exec']).command) };
      case 'cmd.gotoLine': {
        const p = payload as HostToEditor['cmd.gotoLine'];
        return this.gotoLine(p.line, p.column);
      }
      case 'search.set':
        return this.setSearch(payload as SearchPayload);
      default: {
        const unreachable: never = type;
        throw new EditorError('unknown_type', `unhandled type ${String(unreachable)}`);
      }
    }
  }

  // ------------------------------------------------------------ host commands

  configure(p: ConfigurePayload): void {
    this.config = {
      palette: p.palette ?? this.config.palette,
      fontSize: p.fontSize ?? this.config.fontSize,
      lineWrapping: p.lineWrapping ?? this.config.lineWrapping,
      tabSize: p.tabSize ?? this.config.tabSize,
    };
    this.configGen += 1;
    const entry = this.active();
    if (entry) {
      this.reconfigure(entry);
    } else {
      this.view.setState(this.idleState());
    }
  }

  open(p: DocOpenPayload): void {
    if (this.docs.has(p.docId)) throw new EditorError('doc_exists', `document ${p.docId} is already open`);
    const entry: DocEntry = {
      id: p.docId,
      state: EditorState.create(),
      version: p.version,
      language: p.language,
      readOnly: p.readOnly ?? false,
      configGen: this.configGen,
      scroll: null,
      pendingScrollTop: p.scrollTop ?? null,
      history: null,
    };
    entry.state = EditorState.create({
      doc: p.text,
      selection: clampSelection(p.selection, p.text.length),
      extensions: this.docExtensions(entry),
    });
    this.docs.set(p.docId, entry);
    if (p.activate ?? true) this.activate(p.docId);
  }

  activate(docId: string): void {
    const entry = this.require(docId);
    if (this.activeId === docId) return;
    this.deactivateCurrent();
    this.activeId = docId;
    this.view.setState(entry.state);
    if (entry.configGen !== this.configGen) this.reconfigure(entry);
    if (entry.scroll) {
      this.view.dispatch({ effects: entry.scroll });
      entry.scroll = null;
    } else if (entry.pendingScrollTop !== null) {
      const top = entry.pendingScrollTop;
      entry.pendingScrollTop = null;
      this.view.requestMeasure({
        read: () => null,
        write: () => {
          this.view.scrollDOM.scrollTop = top;
        },
      });
    }
    this.emitHistory(entry, true);
  }

  close(docId: string): void {
    this.require(docId);
    this.batcher.flush(docId);
    if (this.activeId === docId) {
      this.flushViewState();
      this.activeId = null;
      this.view.setState(this.idleState());
    }
    this.docs.delete(docId);
  }

  /**
   * Replaces a document's text with the host's (recovery, external change).
   * Unsent edits are discarded and the undo history restarts; the host
   * flushes first when it wants them.
   */
  replace(docId: string, text: string, version: number): void {
    const entry = this.require(docId);
    this.batcher.discard(docId);
    const isActive = this.activeId === docId;
    const current = isActive ? this.view.state : entry.state;
    const { anchor, head } = current.selection.main;
    entry.version = version;
    entry.history = null;
    entry.configGen = this.configGen;
    entry.state = EditorState.create({
      doc: text,
      selection: clampSelection({ anchor, head }, text.length),
      extensions: this.docExtensions(entry),
    });
    if (isActive) {
      const scroll = this.view.scrollSnapshot();
      this.view.setState(entry.state);
      this.view.dispatch({ effects: scroll });
      this.emitHistory(entry, true);
    }
  }

  /**
   * Highlights a document as [language] from now on. Text, selection and
   * undo history stay: only the language extension is swapped.
   */
  setLanguage(docId: string, language: LanguageId): void {
    const entry = this.require(docId);
    if (entry.language === language) return;
    entry.language = language;
    const effects = this.languageSlot.reconfigure(languageExtension(language));
    if (this.activeId === docId) {
      this.view.dispatch({ effects });
    } else {
      entry.state = entry.state.update({ effects }).state;
    }
  }

  /** Sends pending edits now (all documents when [docId] is omitted). */
  flush(docId?: string): void {
    if (docId === undefined) {
      this.batcher.flushAll();
    } else {
      this.require(docId);
      this.batcher.flush(docId);
    }
    this.flushViewState();
  }

  snapshot(docId: string): SnapshotResult {
    const entry = this.require(docId);
    this.batcher.flush(docId);
    const active = this.activeId === docId;
    const state = active ? this.view.state : entry.state;
    const { anchor, head } = state.selection.main;
    const result: SnapshotResult = { docId, text: state.doc.toString(), version: entry.version, selection: { anchor, head } };
    if (active) result.scrollTop = Math.max(0, this.view.scrollDOM.scrollTop);
    return result;
  }

  /** Inserts [text] at every cursor, replacing selections (symbol toolbar). */
  insert(text: string, cursorOffset?: number): boolean {
    this.requireActive();
    const state = this.view.state;
    if (state.readOnly) return false;
    const offset = Math.min(cursorOffset ?? text.length, text.length);
    this.view.dispatch(
      state.changeByRange((range) => ({
        changes: { from: range.from, to: range.to, insert: text },
        range: EditorSelection.cursor(range.from + offset),
      })),
      { userEvent: 'input.toolbar', scrollIntoView: true },
    );
    return true;
  }

  exec(command: EditorCommand): boolean {
    this.requireActive();
    return COMMANDS[command](this.view);
  }

  gotoLine(line: number, column?: number): { line: number; position: number } {
    this.requireActive();
    const doc = this.view.state.doc;
    const target = doc.line(Math.min(Math.max(1, line), doc.lines));
    const position = Math.min(target.from + (column ?? 1) - 1, target.to);
    this.view.dispatch({
      selection: { anchor: position },
      effects: EditorView.scrollIntoView(position, { y: 'center' }),
      userEvent: 'select',
    });
    return { line: target.number, position };
  }

  setSearch(p: SearchPayload): { valid: boolean } {
    this.requireActive();
    const query = new SearchQuery({
      search: p.query,
      caseSensitive: p.caseSensitive ?? false,
      regexp: p.regexp ?? false,
      wholeWord: p.wholeWord ?? false,
      replace: p.replace ?? '',
    });
    this.view.dispatch({ effects: setSearchQuery.of(query) });
    return { valid: query.valid };
  }

  /** Flushes pending edits, then tells the host about an app shortcut. */
  shortcut(shortcut: AppShortcut): void {
    this.flush();
    this.options.emit('app.shortcut', { shortcut });
  }

  destroy(): void {
    this.flush();
    this.view.destroy();
  }

  // ---------------------------------------------------------------- internals

  private active(): DocEntry | null {
    return this.activeId === null ? null : (this.docs.get(this.activeId) ?? null);
  }

  private require(docId: string): DocEntry {
    const entry = this.docs.get(docId);
    if (!entry) throw new EditorError('unknown_doc', `no open document ${docId}`);
    return entry;
  }

  private requireActive(): DocEntry {
    const entry = this.active();
    if (!entry) throw new EditorError('no_active_doc', 'no document is active');
    return entry;
  }

  private deactivateCurrent(): void {
    const prev = this.active();
    if (!prev) return;
    this.batcher.flush(prev.id);
    this.flushViewState();
    prev.state = this.view.state;
    prev.scroll = this.view.scrollSnapshot();
  }

  private reconfigure(entry: DocEntry): void {
    entry.configGen = this.configGen;
    const c = this.config;
    this.view.dispatch({
      effects: [
        this.themeSlot.reconfigure(forgeTheme(c.palette)),
        this.fontSlot.reconfigure(fontSizeTheme(c.fontSize)),
        this.wrapSlot.reconfigure(c.lineWrapping ? EditorView.lineWrapping : []),
        this.tabSlot.reconfigure(EditorState.tabSize.of(c.tabSize)),
      ],
    });
  }

  private configExtensions(): Extension[] {
    const c = this.config;
    return [
      this.themeSlot.of(forgeTheme(c.palette)),
      this.fontSlot.of(fontSizeTheme(c.fontSize)),
      this.wrapSlot.of(c.lineWrapping ? EditorView.lineWrapping : []),
      this.tabSlot.of(EditorState.tabSize.of(c.tabSize)),
    ];
  }

  /** Shown while no document is open: empty and not editable. */
  private idleState(): EditorState {
    return EditorState.create({ doc: '', extensions: [...this.configExtensions(), editableExtension(true)] });
  }

  private docExtensions(entry: DocEntry): Extension[] {
    return [
      docIdFacet.of(entry.id),
      lineNumbers(),
      highlightActiveLineGutter(),
      highlightSpecialChars(),
      history(),
      foldGutter(),
      drawSelection(),
      dropCursor(),
      EditorState.allowMultipleSelections.of(true),
      indentOnInput(),
      bracketMatching(),
      closeBrackets(),
      rectangularSelection(),
      cursorLineHighlight(),
      highlightSelectionMatches(),
      search({ top: true }),
      keymap.of([
        ...this.appKeymap(),
        ...closeBracketsKeymap,
        ...defaultKeymap,
        ...searchKeymap,
        ...historyKeymap,
        ...foldKeymap,
        indentWithTab,
      ]),
      this.languageSlot.of(languageExtension(entry.language)),
      this.editableSlot.of(editableExtension(entry.readOnly)),
      ...this.configExtensions(),
      // Code is not prose: keep the IME from autocorrecting or capitalising.
      EditorView.contentAttributes.of({
        autocorrect: 'off',
        autocapitalize: 'off',
        spellcheck: 'false',
        autocomplete: 'off',
        'aria-label': 'Code editor',
      }),
      EditorView.updateListener.of((update) => this.onUpdate(update)),
      EditorView.domEventHandlers({
        compositionstart: () => {
          this.setComposing(true);
          return false;
        },
        compositionend: () => {
          this.setComposing(false);
          return false;
        },
      }),
    ];
  }

  private appKeymap(): KeyBinding[] {
    const fire = (shortcut: AppShortcut) => () => {
      this.shortcut(shortcut);
      return true;
    };
    return [
      { key: 'Mod-s', run: fire('save'), preventDefault: true },
      { key: 'Mod-Shift-s', run: fire('saveAs'), preventDefault: true },
      { key: 'Mod-Shift-p', run: fire('palette'), preventDefault: true },
      { key: 'F1', run: fire('palette'), preventDefault: true },
      { key: 'Mod-w', run: fire('closeTab'), preventDefault: true },
      { key: 'Ctrl-Tab', run: fire('nextTab'), preventDefault: true },
      { key: 'Ctrl-Shift-Tab', run: fire('previousTab'), preventDefault: true },
      { key: 'Mod-n', run: fire('newFile'), preventDefault: true },
    ];
  }

  private onUpdate(update: ViewUpdate): void {
    const docId = update.state.facet(docIdFacet);
    if (docId === '' || docId !== this.activeId) return;
    const entry = this.docs.get(docId);
    if (!entry) return;
    if (update.docChanged) this.batcher.add(docId, update.changes);
    this.emitHistory(entry, false);
    if (update.docChanged || update.selectionSet) this.scheduleViewState();
    if (update.focusChanged) {
      const focused = update.view.hasFocus;
      this.options.emit('editor.focus', { focused });
      if (!focused) {
        this.batcher.flush(docId);
        this.flushViewState();
      }
    }
  }

  private emitChanges(docId: string, changes: ChangeSet): void {
    const entry = this.docs.get(docId);
    if (!entry) return;
    const baseVersion = entry.version;
    entry.version += 1;
    this.options.emit('doc.changed', {
      docId,
      baseVersion,
      version: entry.version,
      lengthBefore: changes.length,
      lengthAfter: changes.newLength,
      changes: changes.toJSON() as ChangeSetJson,
    });
  }

  private emitHistory(entry: DocEntry, force: boolean): void {
    const state = this.view.state;
    const canUndo = undoDepth(state) > 0;
    const canRedo = redoDepth(state) > 0;
    const last = entry.history;
    if (!force && last && last.canUndo === canUndo && last.canRedo === canRedo) return;
    entry.history = { canUndo, canRedo };
    this.options.emit('editor.history', { docId: entry.id, canUndo, canRedo });
  }

  private scheduleViewState(): void {
    if (this.viewStateTimer !== null || this.activeId === null) return;
    this.viewStateTimer = this.scheduler.set(() => {
      this.viewStateTimer = null;
      this.emitViewState();
    }, this.viewStateDelayMs);
  }

  private flushViewState(): void {
    if (this.viewStateTimer === null) return;
    this.scheduler.clear(this.viewStateTimer);
    this.viewStateTimer = null;
    this.emitViewState();
  }

  private emitViewState(): void {
    const entry = this.active();
    if (!entry) return;
    const { anchor, head } = this.view.state.selection.main;
    this.options.emit('doc.viewState', {
      docId: entry.id,
      selection: { anchor, head },
      scrollTop: Math.max(0, this.view.scrollDOM.scrollTop),
    });
  }

  private setComposing(composing: boolean): void {
    if (this.composing === composing) return;
    this.composing = composing;
    if (this.activeId !== null) this.options.emit('ime.composition', { docId: this.activeId, composing });
  }
}
