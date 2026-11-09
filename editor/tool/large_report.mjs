#!/usr/bin/env node
/**
 * Merges the large-file gate's evidence (Phase 2 W7, gate G7) into
 * ci-results/gate/large_files.json + large_files.txt:
 *   - the app side: CODEFORGE_LARGE_JSON lines printed by
 *     app/integration_test/large_files_test.dart (write, open, sync of the
 *     typed text, journal, save; the session store at each size with
 *     synchronous NORMAL against FULL);
 *   - the page side: tool/large_cdp.mjs's JSON (long tasks while opening,
 *     lines in the DOM, memory, scrolling, typing);
 *   - the release build's memory over the session the test left open
 *     (tool/large_cdp.mjs --memory-only).
 * Budgets are ADR-0004's. Misses are information for the large-file policy,
 * so this script never fails the gate.
 *
 * Usage: node tool/large_report.mjs --itest <file> --cdp <file> [--release <file>]
 *          [--env key=value ...] --out-json <file> --out-txt <file>
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const BUDGETS = {
  typingP95Ms: { max: 32, label: 'input → frame p95, DevTools keys mid-file' },
  scrollSlowFramePct: { max: 5, exclusive: true, label: 'scrolling, frames over 32 ms' },
  totalPssMB: { max: 250, label: 'memory, app + renderer PSS' },
};

const MIB = 1024 * 1024;
const round = (n, digits = 1) => Math.round(n * 10 ** digits) / 10 ** digits;

export function median(values) {
  const sorted = (values ?? []).filter((v) => typeof v === 'number').sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const mid = Math.floor(sorted.length / 2);
  return round(sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2);
}

export function check(name, value) {
  const budget = BUDGETS[name];
  if (typeof value !== 'number') return { value: value ?? null, budget: budget.max, within: null };
  const within = budget.exclusive ? value < budget.max : value <= budget.max;
  return { value, budget: budget.max, within };
}

/**
 * Reassembles "CODEFORGE_LARGE_JSON <i>/<n> <chunk>" lines. A retried
 * attempt starts over at 1/<n>: the latest complete series wins.
 */
export function reassemble(text) {
  const parts = new Map();
  let total = 0;
  for (const line of (text ?? '').split('\n')) {
    const match = line.match(/CODEFORGE_LARGE_JSON (\d+)\/(\d+) (.*)$/);
    if (!match) continue;
    if (Number(match[1]) === 1) parts.clear();
    parts.set(Number(match[1]), match[3]);
    total = Number(match[2]);
  }
  if (total === 0 || parts.size !== total) return null;
  try {
    return JSON.parse(Array.from({ length: total }, (_, i) => parts.get(i + 1)).join(''));
  } catch {
    return null;
  }
}

function pageSide(measure) {
  if (!measure) return null;
  return {
    open: measure.open ?? null,
    openLongTasks: measure.openLongTasks ?? null,
    domLines: measure.dom?.lines ?? null,
    scroll: measure.scroll ?? null,
    typing: measure.typing ?? null,
    focused: measure.focused ?? null,
    memory: measure.memory ?? null,
    jsHeap: measure.jsHeap ?? null,
  };
}

/** One report from the three inputs (each may be missing). */
export function buildReport({ itest, cdp, release, env = {}, generatedAt = new Date().toISOString() }) {
  const problems = [];
  if (!itest) problems.push('no app-side report (CODEFORGE_LARGE_JSON lines) in the test output');
  if (!cdp) problems.push('no DevTools driver report');
  if (itest && itest.complete === false) {
    problems.push(`the app-side report is partial: the test stopped after ${itest.files?.length ?? 0} file(s)`);
  }
  for (const error of cdp?.errors ?? []) problems.push(`driver, request ${error.request} (${error.kind}): ${error.error}`);
  const files = (itest?.files ?? []).map((app) => {
    const measure = cdp?.files?.[app.file]?.measure ?? null;
    if (cdp && !measure) problems.push(`${app.file}: no page-side measurements`);
    if (app.gotoOk === false) problems.push(`${app.file}: go to line failed, so typing was measured where the cursor was`);
    for (const event of app.trouble ?? []) problems.push(`${app.file}: ${event}`);
    return {
      file: app.file,
      language: app.language,
      largeFile: app.largeFile ?? null,
      chars: app.chars,
      mib: round(app.chars / MIB, 2),
      lines: app.lines,
      app: {
        writeMs: app.writeMs ?? null,
        openMs: app.openMs ?? null,
        openReturnMs: app.openReturnMs ?? null,
        pageAnswerMs: app.pageAnswerMs ?? null,
        gotoOk: app.gotoOk ?? null,
        gotoMs: app.gotoMs ?? null,
        typedArrived: app.typedArrived ?? null,
        syncMs: app.syncMs ?? null,
        persistMs: app.persistMs ?? null,
        saveMs: app.saveMs ?? null,
        trouble: app.trouble ?? [],
      },
      page: pageSide(measure),
      checks: {
        typingP95Ms: check('typingP95Ms', measure?.typing?.p95Ms),
        scrollSlowFramePct: check('scrollSlowFramePct', measure?.scroll?.slowFramePct),
        totalPssMB: check('totalPssMB', measure?.memory?.totalPssMB),
      },
    };
  });
  if (Array.isArray(release?.memory?.renderers) && release.memory.renderers.length === 0) {
    problems.push('release build: no WebView renderer was running when its memory was sampled (no editor open?)');
  }
  const baseline = Object.values(cdp?.files ?? {}).find((f) => f.prepare?.memory)?.prepare ?? null;
  const store = itest?.store
    ? {
        pragma: itest.store.pragma ?? null,
        snapshots: (itest.store.snapshots ?? []).map((s) => ({
          mib: s.mib,
          chars: s.chars,
          digestMs: s.digestMs ?? null,
          normalMedianMs: median(s.normalMs),
          fullMedianMs: median(s.fullMs),
          normalMs: s.normalMs ?? [],
          fullMs: s.fullMs ?? [],
        })),
        changes: itest.store.changes
          ? {
              count: itest.store.changes.count,
              normalMedianMs: median(itest.store.changes.normalMs),
              fullMedianMs: median(itest.store.changes.fullMs),
            }
          : null,
      }
    : null;
  return {
    schema: 1,
    kind: 'codeforge-large-files-gate',
    gate: 'G7',
    generatedAt,
    environment: {
      device: 'CI emulator, API 36 google_apis x86_64, swiftshader_indirect GPU',
      build: `${itest?.build ?? 'debug'} APK (the DevTools socket needs it; Flutter refuses profile mode on emulators)`,
      userAgent: cdp?.userAgent ?? null,
      ...env,
    },
    method: { app: itest?.method ?? null, page: cdp?.method ?? null },
    policy: itest?.policy ?? null,
    budgets: BUDGETS,
    typed: itest?.typed ?? null,
    baselineMemory: baseline ? { memory: baseline.memory ?? null, jsHeap: baseline.jsHeap ?? null } : null,
    files,
    store,
    releaseMemory: release?.memory
      ? {
          session: itest?.leftOpen ?? null,
          ...release.memory,
          check: check('totalPssMB', release.memory.totalPssMB),
        }
      : null,
    problems,
  };
}

const mark = (c) => (c.within === null ? '' : c.within ? ' ✓' : ' ✗');
const num = (v, suffix = '') => (typeof v === 'number' ? `${v}${suffix}` : '–');

function table(rows) {
  const widths = rows[0].map((_, i) => Math.max(...rows.map((r) => String(r[i]).length)));
  return rows.map((r) => r.map((cell, i) => String(cell).padEnd(widths[i])).join('  ').trimEnd()).join('\n');
}

/** The report as text for the gate's summary and evidence. */
export function renderText(report) {
  const out = [];
  out.push('Large files (Phase 2 W7, gate G7): open, scroll, typing and memory');
  out.push(`${report.environment.device}; ${report.environment.build}`);
  if (report.environment.userAgent) out.push(`WebView: ${report.environment.userAgent}`);
  out.push(`Budgets (ADR-0004): typing p95 <= ${BUDGETS.typingP95Ms.max} ms, scroll frames over 32 ms < ${BUDGETS.scrollSlowFramePct.max} %, memory <= ${BUDGETS.totalPssMB.max} MB`);
  if (report.policy) {
    const { plainTextAboveChars, maxTextFileBytes } = report.policy;
    out.push(
      `Large-file policy: plain text above ${num(plainTextAboveChars)} characters; files over ${num(maxTextFileBytes)} bytes are refused`,
    );
  }
  out.push('');
  out.push('open: documents.open until the page shows the document (app side, read+decode / bridge+page);');
  out.push('page: its own work on the doc.open message / until the next frame was painted;');
  out.push('typing: input to frame, median / p95 (the budget is on p95).');
  const rows = [
    ['file', 'language', 'MiB', 'lines', 'open ms', 'app/bridge', 'page ms', 'long tasks', 'scroll slow', 'typing p50/p95', 'memory MB', 'save ms'],
  ];
  for (const f of report.files) {
    const p = f.page;
    rows.push([
      f.file,
      `${f.language ?? '–'}${f.largeFile ? '*' : ''}`,
      num(f.mib),
      num(f.lines),
      num(f.app.openMs),
      `${num(f.app.openReturnMs)}/${num(f.app.pageAnswerMs)}`,
      `${num(p?.open?.processMs)}/${num(p?.open?.paintedMs)}`,
      p?.openLongTasks ? `${p.openLongTasks.count}, ${p.openLongTasks.totalMs} ms` : '–',
      `${num(p?.scroll?.slowFramePct, ' %')}${mark(f.checks.scrollSlowFramePct)}`,
      `${num(p?.typing?.p50Ms)}/${num(p?.typing?.p95Ms, ' ms')}${mark(f.checks.typingP95Ms)}`,
      `${num(p?.memory?.totalPssMB)}${mark(f.checks.totalPssMB)}`,
      num(f.app.saveMs),
    ]);
  }
  out.push(table(rows));
  if (report.files.some((f) => f.largeFile)) {
    out.push('* plain text by the large-file policy: highlighting, folding and syntax indentation are off');
  }
  if (report.baselineMemory?.memory) {
    const m = report.baselineMemory.memory;
    out.push('');
    out.push(`Before the first open: app ${num(m.appPssMB)} MB + renderers ${num(m.rendererPssMB)} MB = ${num(m.totalPssMB)} MB`);
  }
  if (report.store) {
    out.push('');
    out.push('Session store (ADR-0008), median ms per write, synchronous NORMAL (the app) against FULL:');
    const storeRows = [['size', 'snapshot NORMAL', 'snapshot FULL', 'digest (UI isolate)']];
    for (const s of report.store.snapshots) {
      storeRows.push([`${s.mib} MiB`, num(s.normalMedianMs), num(s.fullMedianMs), num(s.digestMs)]);
    }
    if (report.store.changes) {
      const c = report.store.changes;
      storeRows.push([`1 change (x${c.count})`, num(c.normalMedianMs), num(c.fullMedianMs), '']);
    }
    out.push(table(storeRows));
  }
  out.push('');
  if (report.releaseMemory) {
    const r = report.releaseMemory;
    out.push(
      `Release build, session restored with ${r.session ?? 'the test\u2019s session'} open: app ${num(r.appPssMB)} MB + renderers ${num(r.rendererPssMB)} MB = ${num(r.totalPssMB)} MB${mark(r.check)}`,
    );
  } else {
    out.push('Release build memory: not measured');
  }
  out.push('');
  out.push('Notes: the emulator renders in software, which bounds every frame-timed number (ADR-0004);');
  out.push('compare sizes and languages with each other, not with the budgets. App-side times come from a');
  out.push('debug (JIT) build, so they are pessimistic; the page-side numbers do not depend on the app build.');
  if (report.problems.length > 0) {
    out.push('');
    out.push('Problems:');
    for (const problem of report.problems) out.push(`  - ${problem}`);
  }
  return `${out.join('\n')}\n`;
}

function parseArgs(argv) {
  const args = { env: {} };
  for (let i = 0; i < argv.length; i += 2) {
    const [flag, value] = [argv[i], argv[i + 1]];
    if (flag === '--env') {
      const at = value.indexOf('=');
      args.env[value.slice(0, at)] = value.slice(at + 1);
    } else {
      args[flag.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
    }
  }
  return args;
}

const readText = (file) => (file && existsSync(file) ? readFileSync(file, 'utf8') : null);
const readJson = (file) => {
  const text = readText(file);
  if (text === null) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = parseArgs(process.argv.slice(2));
  const report = buildReport({
    itest: reassemble(readText(args.itest)),
    cdp: readJson(args.cdp),
    release: readJson(args.release),
    env: args.env,
  });
  if (args.outJson) writeFileSync(args.outJson, `${JSON.stringify(report, null, 2)}\n`);
  const text = renderText(report);
  if (args.outTxt) writeFileSync(args.outTxt, text);
  process.stdout.write(text);
}
