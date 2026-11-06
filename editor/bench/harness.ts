/**
 * The benchmark harness: identical scenarios for every engine adapter.
 *
 * Runs inside the app's WebView (Settings → Developer → Editor benchmark, and
 * the phase gate's integration test). It reports to the host through the
 * `CodeForgeBench` JavaScript channel and exposes `window.codeforgeBench`
 * for the host (runJavaScript) and the gate's DevTools driver
 * (tool/bench_cdp.mjs).
 *
 * Metrics (ADR-0004 / EDITOR_ARCHITECTURE §1 gate):
 * - load: script start → editor mounted → first frame with the editor;
 * - typing: 60 characters through the engine's own typing path, each timed
 *   to the end of the next frame (no OS or IME in the loop; the DevTools
 *   driver and the manual check cover real input events);
 * - large file: open time, typing in the middle, scroll frame intervals;
 * - memory: performance.memory after the session, kept raw only (Chromium
 *   quantizes it and caches it per renderer process; the gate measures
 *   process PSS with dumpsys instead);
 * - scope checks: highlighting per language, replace-all, completion popup.
 */
import { BENCH_LANGUAGES, type BenchEngine, type BenchLanguage } from './engine';
import { InputRecorder, type InputStats } from './input_recorder';
import { largeJavaScript, SAMPLES, TYPING_TEXT } from './samples';
import { firstDifference, frameSummary, round1, summarize, toMB, type FrameSummary, type Summary } from './stats';
import { afterPaint, SCRIPT_START_MS, sleep, throttledFrames } from './timing';

export interface SuiteOptions {
  keys: number;
  keyGapMs: number;
  largeBytes: number;
  largeKeys: number;
  scrollMs: number;
  scrollPxPerMs: number;
}

export const DEFAULT_OPTIONS: SuiteOptions = {
  keys: 60,
  keyGapMs: 30,
  largeBytes: 1024 * 1024,
  largeKeys: 30,
  scrollMs: 3000,
  scrollPxPerMs: 6,
};

interface LoadTimes {
  scriptStartMs: number;
  modulesReadyMs: number;
  mountedMs: number;
  /** First frame with the editor on screen: the G1 "cold load → first paint". */
  readyMs: number;
  firstPaintMs: number | null;
  firstContentfulPaintMs: number | null;
}

export interface SuiteResult {
  schema: 1;
  engine: string;
  engineVersion: string;
  inputMode: string;
  userAgent: string;
  options: SuiteOptions;
  load: LoadTimes;
  highlight: Record<string, { spans: number; ms: number }>;
  features: { replaceAll: boolean; completion: boolean };
  typing: Summary;
  largeFile: {
    bytes: number;
    lines: number;
    openMs: number;
    typing: Summary;
    scroll: FrameSummary & { distancePx: number };
  };
  memory: { usedJSHeapMB: number; totalJSHeapMB: number } | null;
  domNodes: number;
  throttledFrames: number;
  errors: string[];
  durationMs: number;
}

export interface TypingCheck {
  engine: string;
  inputMode: string;
  expected: string;
  actual: string;
  match: boolean;
  firstDifference: number;
  input: InputStats;
}

type HostChannel = { postMessage(message: string): void };

function post(message: Record<string, unknown>): void {
  const channel = (window as unknown as { CodeForgeBench?: HostChannel }).CodeForgeBench;
  const text = JSON.stringify(message);
  if (channel && typeof channel.postMessage === 'function') channel.postMessage(text);
  else console.log(`[codeforge-bench] ${text}`);
}

function paintTime(name: string): number | null {
  const entry = performance.getEntriesByName(name)[0];
  return entry ? round1(entry.startTime) : null;
}

async function typeTimed(engine: BenchEngine, text: string, gapMs: number): Promise<Summary> {
  const samples: number[] = [];
  for (const ch of text) {
    const start = performance.now();
    engine.type(ch);
    samples.push((await afterPaint()) - start);
    await sleep(gapMs);
  }
  return summarize(samples);
}

function scrollTimed(engine: BenchEngine, ms: number, pxPerMs: number): Promise<FrameSummary & { distancePx: number }> {
  const max = Math.max(1, engine.scrollMax());
  const intervals: number[] = [];
  return new Promise((resolve) => {
    let start = -1;
    let previous = -1;
    const step = (now: number) => {
      if (start < 0) {
        start = now;
      } else {
        intervals.push(now - previous);
      }
      previous = now;
      const elapsed = now - start;
      if (elapsed >= ms) {
        resolve({ ...frameSummary(intervals), distancePx: Math.round(elapsed * pxPerMs) });
        return;
      }
      // Bounce between the top and the bottom at a constant speed.
      const travelled = (elapsed * pxPerMs) % (2 * max);
      engine.setScrollTop(travelled > max ? 2 * max - travelled : travelled);
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
}

async function waitFor(check: () => boolean, timeoutMs: number): Promise<boolean> {
  const start = performance.now();
  while (performance.now() - start < timeoutMs) {
    if (check()) return true;
    await afterPaint();
  }
  return check();
}

export async function startBench(engine: BenchEngine): Promise<void> {
  const inputMode = (): string => engine.inputMode();
  const modulesReadyMs = performance.now();
  const errors: string[] = [];
  const recordError = (message: string) => {
    errors.push(message);
    post({ type: 'error', message });
  };
  window.addEventListener('error', (e) => recordError(`${e.message} (${e.filename}:${e.lineno})`));
  window.addEventListener('unhandledrejection', (e) => recordError(`unhandled rejection: ${String(e.reason)}`));

  // Both engines measure glyphs at creation; mount once the embedded font is in.
  try {
    await Promise.race([document.fonts.load('14px "JetBrains Mono"'), sleep(2000)]);
  } catch {
    // An unavailable font only affects metrics; the run goes on.
  }
  const parent = document.getElementById('editor');
  if (!parent) throw new Error('the page has no #editor element');
  engine.mount(parent);
  const mountedMs = performance.now();
  const readyMs = await afterPaint();
  const load: LoadTimes = {
    scriptStartMs: round1(SCRIPT_START_MS),
    modulesReadyMs: round1(modulesReadyMs),
    mountedMs: round1(mountedMs),
    readyMs: round1(readyMs),
    firstPaintMs: paintTime('first-paint'),
    firstContentfulPaintMs: paintTime('first-contentful-paint'),
  };

  const recorder = new InputRecorder();
  recorder.attach(engine.inputRoot());
  let running = false;

  async function run(overrides: Partial<SuiteOptions> = {}): Promise<SuiteResult> {
    if (running) throw new Error('a run is already in progress');
    running = true;
    const options = { ...DEFAULT_OPTIONS, ...overrides };
    const started = performance.now();
    try {
      post({ type: 'progress', step: 'highlight' });
      const highlight: SuiteResult['highlight'] = {};
      for (const language of BENCH_LANGUAGES) {
        engine.setDocument(SAMPLES[language], language);
        const t0 = performance.now();
        await waitFor(() => engine.highlightedSpans() > 0, 2000);
        highlight[language] = { spans: engine.highlightedSpans(), ms: round1(performance.now() - t0) };
      }

      post({ type: 'progress', step: 'features' });
      engine.setDocument(SAMPLES.javascript, 'javascript');
      await afterPaint();
      const replaced = await engine.replaceAll('total', 'sum');
      const replaceAll = replaced && !engine.text().includes('total') && engine.text().includes('sum');
      engine.setDocument('co', 'javascript');
      engine.setCursor(2);
      engine.focus();
      const completion = await engine.showCompletion();
      engine.closeCompletion();

      post({ type: 'progress', step: 'typing' });
      engine.setDocument('', 'javascript');
      engine.focus();
      await afterPaint();
      const typing = await typeTimed(engine, TYPING_TEXT.slice(0, options.keys), options.keyGapMs);

      post({ type: 'progress', step: 'large-file' });
      const big = largeJavaScript(options.largeBytes);
      await afterPaint();
      const openStart = performance.now();
      engine.setDocument(big, 'javascript');
      const openMs = round1((await afterPaint()) - openStart);
      const middle = big.indexOf('\n', Math.floor(big.length / 2)) + 1;
      engine.setCursor(middle);
      await afterPaint();
      const largeTyping = await typeTimed(engine, TYPING_TEXT.slice(0, options.largeKeys), options.keyGapMs);

      post({ type: 'progress', step: 'scroll' });
      const scroll = await scrollTimed(engine, options.scrollMs, options.scrollPxPerMs);

      const memoryInfo = (performance as unknown as { memory?: { usedJSHeapSize: number; totalJSHeapSize: number } })
        .memory;
      const result: SuiteResult = {
        schema: 1,
        engine: engine.id,
        engineVersion: engine.version,
        inputMode: inputMode(),
        userAgent: navigator.userAgent,
        options,
        load,
        highlight,
        features: { replaceAll, completion },
        typing,
        largeFile: {
          bytes: big.length,
          lines: big.split('\n').length - 1,
          openMs,
          typing: largeTyping,
          scroll,
        },
        memory: memoryInfo
          ? { usedJSHeapMB: toMB(memoryInfo.usedJSHeapSize), totalJSHeapMB: toMB(memoryInfo.totalJSHeapSize) }
          : null,
        domNodes: document.getElementsByTagName('*').length,
        throttledFrames,
        errors: [...errors],
        durationMs: round1(performance.now() - started),
      };
      post({ type: 'result', result });
      return result;
    } finally {
      running = false;
    }
  }

  function prepareInput(initial = '', cursor: number = initial.length, language: BenchLanguage = 'plaintext'): boolean {
    engine.setDocument(initial, language);
    engine.setCursor(cursor);
    engine.focus();
    recorder.attach(engine.inputRoot());
    recorder.reset();
    return true;
  }

  const api = {
    engine: engine.id,
    version: engine.version,
    load,
    run,
    /** Manual typing check on a phone: empty document, then the user types. */
    startTyping(): boolean {
      return prepareInput();
    },
    checkTyping(expected: string): TypingCheck {
      const actual = engine.text();
      const check: TypingCheck = {
        engine: engine.id,
        inputMode: inputMode(),
        expected,
        actual,
        match: actual === expected,
        firstDifference: firstDifference(actual, expected),
        input: recorder.stats(),
      };
      post({ type: 'typing', result: check });
      return check;
    },
    prepareInput,
    inputStats: (): InputStats => recorder.stats(),
    inputMode,
    text: (): string => engine.text(),
    errors: (): string[] => [...errors],
    focus: (): void => engine.focus(),
    /** Opens the large file and scrolls it once: the gate's memory session. */
    async openLarge(bytes: number = DEFAULT_OPTIONS.largeBytes): Promise<{ openMs: number; scroll: FrameSummary }> {
      const big = largeJavaScript(bytes);
      const start = performance.now();
      engine.setDocument(big, 'javascript');
      const openMs = round1((await afterPaint()) - start);
      const scroll = await scrollTimed(engine, 2000, DEFAULT_OPTIONS.scrollPxPerMs);
      return { openMs, scroll };
    },
    /** Hands the page to the gate's DevTools driver, which finds it by title. */
    awaitDriver(): void {
      document.title = `codeforge-bench:${engine.id}:driver`;
      post({ type: 'driver-wait' });
    },
    driverDone(summary: unknown): void {
      document.title = `codeforge-bench:${engine.id}`;
      post({ type: 'driver-done', summary });
    },
  };
  (window as unknown as { codeforgeBench: typeof api }).codeforgeBench = api;
  document.title = `codeforge-bench:${engine.id}`;
  post({ type: 'ready', engine: engine.id, engineVersion: engine.version, inputMode: inputMode(), load });
}
