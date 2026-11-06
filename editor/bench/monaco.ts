/**
 * Monaco benchmark page entry, at the same scope as the CodeMirror page:
 * monarch highlighting for JS/TS/Python/HTML/CSS (plus a small monarch JSON
 * grammar, because Monaco's JSON support is a worker-based language service),
 * the find/replace widget, and the same stub completion source.
 *
 * No web workers: the page is one inline document under a CSP without
 * worker-src, so getWorker throws and Monaco falls back to running its editor
 * worker in-process (editorWorkerService: _createFallbackLocalWorker). The
 * TypeScript/JSON/CSS/HTML language services are not included at all.
 */
// First import: marks when the script started, before the engine evaluates.
import './timing';

import * as monaco from 'monaco-editor/editor/editor.api.js';
import 'monaco-editor/features/codicon/register.js';
import 'monaco-editor/features/find/register.js';
import 'monaco-editor/editor/contrib/suggest/browser/suggestController.js';
import 'monaco-editor/features/suggest/register.js';
import 'monaco-editor/features/folding/register.js';
import 'monaco-editor/features/bracketMatching/register.js';
import 'monaco-editor/features/comment/register.js';
import 'monaco-editor/features/linesOperations/register.js';
import 'monaco-editor/features/multicursor/register.js';
import 'monaco-editor/features/wordHighlighter/register.js';
import 'monaco-editor/features/wordOperations/register.js';
import 'monaco-editor/features/clipboard/register.js';
import 'monaco-editor/features/contextmenu/register.js';
import 'monaco-editor/features/cursorUndo/register.js';
import 'monaco-editor/features/indentation/register.js';
import 'monaco-editor/features/dnd/register.js';
import 'monaco-editor/languages/definitions/css/register.js';
import 'monaco-editor/languages/definitions/html/register.js';
import 'monaco-editor/languages/definitions/javascript/register.js';
import 'monaco-editor/languages/definitions/python/register.js';
import 'monaco-editor/languages/definitions/typescript/register.js';

import { DEFAULT_PALETTE } from '../src/editor/palette';
import { type BenchEngine, type BenchLanguage, STUB_COMPLETIONS } from './engine';
import { startBench } from './harness';

declare const __BENCH_ENGINE_VERSION__: string;

(globalThis as unknown as { MonacoEnvironment: unknown }).MonacoEnvironment = {
  getWorker(): never {
    throw new Error('CodeForge benchmark: web workers are disabled');
  },
};

const BENCH_IDS = ['javascript', 'typescript', 'python', 'json', 'html', 'css', 'plaintext'];

monaco.languages.register({ id: 'json', extensions: ['.json'] });
monaco.languages.setMonarchTokensProvider('json', {
  tokenizer: {
    root: [
      [/"(?:[^"\\]|\\.)*"(?=\s*:)/, 'type'],
      [/"(?:[^"\\]|\\.)*"/, 'string'],
      [/-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/, 'number'],
      [/\b(?:true|false|null)\b/, 'keyword'],
      [/[{}[\],:]/, 'delimiter'],
    ],
  },
});

monaco.languages.registerCompletionItemProvider(BENCH_IDS, {
  provideCompletionItems(model, position) {
    const word = model.getWordUntilPosition(position);
    const range = {
      startLineNumber: position.lineNumber,
      endLineNumber: position.lineNumber,
      startColumn: word.startColumn,
      endColumn: word.endColumn,
    };
    return {
      suggestions: STUB_COMPLETIONS.map((label) => ({
        label,
        kind: monaco.languages.CompletionItemKind.Keyword,
        insertText: label,
        range,
      })),
    };
  },
});

const hex = (color: string): string => color.replace('#', '').slice(0, 6);
const p = DEFAULT_PALETTE;
monaco.editor.defineTheme('codeforge', {
  base: 'vs-dark',
  inherit: true,
  rules: [
    { token: 'keyword', foreground: hex(p.syntax.keyword) },
    { token: 'string', foreground: hex(p.syntax.string) },
    { token: 'number', foreground: hex(p.syntax.number) },
    { token: 'type', foreground: hex(p.syntax.type) },
    { token: 'comment', foreground: hex(p.syntax.comment) },
    { token: 'delimiter', foreground: hex(p.syntax.operator) },
    { token: 'operator', foreground: hex(p.syntax.operator) },
    { token: 'tag', foreground: hex(p.syntax.keyword) },
    { token: 'attribute.name', foreground: hex(p.syntax.function) },
    { token: 'attribute.value', foreground: hex(p.syntax.string) },
  ],
  colors: {
    'editor.background': p.background,
    'editor.foreground': p.foreground,
    'editorLineNumber.foreground': p.gutterForeground,
    'editorLineNumber.activeForeground': p.foreground,
    'editor.lineHighlightBackground': p.activeLine,
    'editorCursor.foreground': p.cursor,
    'editor.selectionBackground': p.selection,
    'editorBracketMatch.background': p.matchingBracket,
    'editor.findMatchHighlightBackground': p.searchMatch,
    'editorWidget.background': p.panelBackground,
    'editorWidget.border': p.border,
  },
});

type FindControllerLike = {
  getState(): { change(state: { searchString: string; replaceString: string }, moveCursor: boolean): void };
  replaceAll(): boolean;
  closeFindWidget(): void;
};

class MonacoBench implements BenchEngine {
  readonly id = 'monaco' as const;
  readonly version = __BENCH_ENGINE_VERSION__;
  private editor: monaco.editor.IStandaloneCodeEditor | null = null;
  private host: HTMLElement | null = null;

  private get e(): monaco.editor.IStandaloneCodeEditor {
    if (!this.editor) throw new Error('the editor is not mounted');
    return this.editor;
  }

  private get model(): monaco.editor.ITextModel {
    const model = this.e.getModel();
    if (!model) throw new Error('the editor has no model');
    return model;
  }

  mount(parent: HTMLElement): void {
    this.host = parent;
    this.editor = monaco.editor.create(parent, {
      value: '',
      language: 'plaintext',
      theme: 'codeforge',
      fontFamily: '"JetBrains Mono", monospace',
      fontSize: 14,
      lineHeight: 21,
      fontLigatures: false,
      tabSize: 4,
      automaticLayout: true,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      glyphMargin: false,
      folding: true,
      renderLineHighlight: 'all',
      // Scope parity with the CodeMirror page: completion only on request,
      // no worker-backed extras.
      quickSuggestions: false,
      suggestOnTriggerCharacters: false,
      wordBasedSuggestions: 'off',
      links: false,
      colorDecorators: false,
      unicodeHighlight: { ambiguousCharacters: false, invisibleCharacters: false },
      stickyScroll: { enabled: false },
    });
  }

  setDocument(text: string, language: BenchLanguage): void {
    const old = this.e.getModel();
    this.e.setModel(monaco.editor.createModel(text, language));
    old?.dispose();
    this.e.setScrollTop(0);
  }

  text(): string {
    return this.model.getValue();
  }

  focus(): void {
    this.e.focus();
  }

  setCursor(offset: number): void {
    const position = this.model.getPositionAt(offset);
    this.e.setPosition(position);
    this.e.revealPositionInCenterIfOutsideViewport(position);
  }

  type(text: string): void {
    this.e.trigger('keyboard', 'type', { text });
  }

  scrollTop(): number {
    return this.e.getScrollTop();
  }

  setScrollTop(px: number): void {
    this.e.setScrollTop(px);
  }

  scrollMax(): number {
    return this.e.getScrollHeight() - this.e.getLayoutInfo().height;
  }

  highlightedSpans(): number {
    // Token spans carry mtk<N> classes; mtk1 is the default foreground.
    let count = 0;
    for (const span of Array.from(this.host?.querySelectorAll('.view-lines span[class*="mtk"]') ?? [])) {
      if (/\bmtk(?:[2-9]|\d{2,})\b/.test(span.className)) count += 1;
    }
    return count;
  }

  async replaceAll(search: string, replace: string): Promise<boolean> {
    const editor = this.e;
    await editor.getAction('editor.action.startFindReplaceAction')?.run();
    const controller = editor.getContribution('editor.contrib.findController') as unknown as FindControllerLike | null;
    if (!controller) return false;
    const before = this.text();
    controller.getState().change({ searchString: search, replaceString: replace }, false);
    controller.replaceAll();
    controller.closeFindWidget();
    editor.focus();
    return this.text() !== before;
  }

  async showCompletion(): Promise<boolean> {
    this.e.trigger('bench', 'editor.action.triggerSuggest', {});
    const start = performance.now();
    while (performance.now() - start < 1500) {
      const widget = this.host?.querySelector('.suggest-widget');
      if (widget && widget.classList.contains('visible') && widget.querySelector('.monaco-list-row')) return true;
      await new Promise((resolve) => requestAnimationFrame(resolve));
    }
    return false;
  }

  closeCompletion(): void {
    this.e.trigger('bench', 'hideSuggestWidget', {});
  }

  inputRoot(): HTMLElement {
    return this.host ?? document.body;
  }

  inputMode(): string {
    if (this.e.getOption(monaco.editor.EditorOption.effectiveEditContext)) return 'editcontext';
    return 'textarea';
  }
}

void startBench(new MonacoBench());
