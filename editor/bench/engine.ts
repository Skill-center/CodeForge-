/**
 * Phase 2 W3 engine benchmark (docs/phases/PHASE_2_PLAN.md, W3).
 *
 * Each engine (CodeMirror 6, Monaco) gets an adapter with this shape, built
 * at the same scope: highlighting for JS/TS/Python/JSON/HTML/CSS,
 * find/replace, and a stub completion popup. The harness (harness.ts) only
 * talks to adapters, so both engines run exactly the same scenarios.
 */

export const BENCH_LANGUAGES = ['javascript', 'typescript', 'python', 'json', 'html', 'css'] as const;
export type BenchLanguage = (typeof BENCH_LANGUAGES)[number] | 'plaintext';

export type EngineId = 'codemirror' | 'monaco';

/** Words offered by both engines' stub completion source. */
export const STUB_COMPLETIONS = ['console', 'const', 'constructor', 'context', 'continue', 'compute'] as const;

export interface BenchEngine {
  readonly id: EngineId;
  readonly version: string;
  /** Creates the editor inside `parent`, with an empty plain-text document. */
  mount(parent: HTMLElement): void;
  /** Replaces the document and its language; undo restarts, scroll goes to the top. */
  setDocument(text: string, language: BenchLanguage): void;
  text(): string;
  focus(): void;
  /** Collapsed cursor at a UTF-16 offset. */
  setCursor(offset: number): void;
  /** Inserts text at the cursor through the engine's own typing path. */
  type(text: string): void;
  scrollTop(): number;
  setScrollTop(px: number): void;
  /** Largest useful scrollTop for the current document. */
  scrollMax(): number;
  /** Rendered spans that carry a syntax-highlighting style (0 = none). */
  highlightedSpans(): number;
  /**
   * Opens the engine's find/replace UI, replaces every `search` with
   * `replace`, and closes it again. Resolves true when the text changed.
   */
  replaceAll(search: string, replace: string): Promise<boolean>;
  /** Opens the completion popup; resolves true once it is on screen. */
  showCompletion(): Promise<boolean>;
  closeCompletion(): void;
  /** The element that receives input; the harness records input events on it. */
  inputRoot(): HTMLElement;
  /**
   * How text input reaches the engine on this browser: 'editcontext' (the
   * EditContext API), 'contenteditable' or 'textarea'.
   */
  inputMode(): string;
}
