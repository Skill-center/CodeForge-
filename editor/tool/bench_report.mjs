#!/usr/bin/env node
/**
 * Merges the phase gate's editor benchmark evidence (Phase 2 W3) into
 * ci-results/gate/editor_bench.json + editor_bench.txt:
 *   - the in-app runs: CODEFORGE_BENCH_JSON lines printed by
 *     app/integration_test/editor_bench_test.dart (one output file per engine),
 *   - the DevTools driver's results (tool/bench_cdp.mjs),
 *   - the benchmark page manifest (sizes, hashes).
 * Every metric is compared with its ADR-0004 / EDITOR_ARCHITECTURE §1 budget.
 * Information for the engine decision: this script never fails the gate.
 *
 * Usage: node tool/bench_report.mjs --itest codemirror=<file> --itest monaco=<file>
 *          --cdp <file> --manifest <file> --env accel=kvm ... \
 *          --out-json <file> --out-txt <file>
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

const BUDGETS = {
  readyMs: { max: 800, label: 'cold load → first editor frame' },
  typingP95Ms: { max: 32, label: 'typing p95, engine path' },
  inputP95Ms: { max: 32, label: 'input p95, DevTools key events' },
  scrollSlowFramePct: { max: 5, exclusive: true, label: '1 MiB scroll, frames > 32 ms' },
  compositionFailures: { max: 0, label: 'IME composition failures' },
  totalPssMB: { max: 250, label: 'memory, app + renderer PSS' },
  gzipBytes: { max: 1.5 * 1024 * 1024, label: 'shipped size, gzipped' },
};

function parseArgs(argv) {
  const args = { itest: {}, env: {} };
  for (let i = 0; i < argv.length; i += 2) {
    const [flag, value] = [argv[i], argv[i + 1]];
    if (flag === '--itest' || flag === '--env') {
      const at = value.indexOf('=');
      args[flag.slice(2)][value.slice(0, at)] = value.slice(at + 1);
    } else {
      args[flag.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
    }
  }
  return args;
}

const readJson = (file) => (file && existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : null);

/** Reassembles "CODEFORGE_BENCH_JSON <engine> <i>/<n> <chunk>" lines. */
function reassemble(text, engine) {
  const parts = new Map();
  let total = 0;
  for (const line of text.split('\n')) {
    const match = line.match(/CODEFORGE_BENCH_JSON (\S+) (\d+)\/(\d+) (.*)$/);
    if (!match || match[1] !== engine) continue;
    // A retried attempt starts over: keep the latest complete series.
    if (Number(match[2]) === 1) parts.clear();
    parts.set(Number(match[2]), match[4]);
    total = Number(match[3]);
  }
  if (total === 0 || parts.size !== total) return null;
  try {
    return JSON.parse(Array.from({ length: total }, (_, i) => parts.get(i + 1)).join(''));
  } catch {
    return null;
  }
}

function check(name, value) {
  const budget = BUDGETS[name];
  if (typeof value !== 'number') return { value: value ?? null, budget: budget.max, within: null };
  const within = budget.exclusive ? value < budget.max : value <= budget.max;
  return { value, budget: budget.max, within };
}

const args = parseArgs(process.argv.slice(2));
const manifest = readJson(args.manifest);
const cdp = readJson(args.cdp);
const report = {
  schema: 1,
  kind: 'codeforge-editor-bench-gate',
  generatedAt: new Date().toISOString(),
  environment: {
    device: 'CI emulator, API 36 google_apis x86_64, swiftshader_indirect GPU',
    build: 'debug APK (profile mode is refused on emulators)',
    ...args.env,
  },
  budgets: Object.fromEntries(Object.entries(BUDGETS).map(([k, v]) => [k, v])),
  notes: [
    'In-app runs: 3 per engine, each in a fresh WebView, medians reported.',
    'Each engine runs in its own app process, so its memory is its own.',
    'Typing p95 (engine path) dispatches through the engine; input p95 adds the browser input pipeline (DevTools key events). Neither includes the OS keyboard.',
    'Memory is PSS (a lower bound of RSS) after a short scripted session, not the 10-minute session of the plan. The pages\' own performance.memory figure is quantized and cached per renderer process by Chromium, so it is kept in the raw runs only.',
    'Monaco runs without web workers (in-process fallback) and without its worker-based language services.',
  ],
  engines: {},
};

const lines = [
  `Editor benchmark (Phase 2 W3) — ${report.environment.device}; ${report.environment.build}` +
    (args.env.accel ? `; accel=${args.env.accel}` : ''),
];
const fmt = (v, unit = '') => (typeof v === 'number' ? `${Math.round(v * 10) / 10}${unit}` : 'n/a');
const mark = (c) => (c.within === null ? '   ' : c.within ? 'ok ' : 'OVER');

for (const engine of ['codemirror', 'monaco']) {
  const file = args.itest[engine];
  const inApp = file && existsSync(file) ? reassemble(readFileSync(file, 'utf8'), engine) : null;
  const page = manifest?.pages?.[engine] ?? null;
  const driven = cdp?.engines?.[engine] ?? null;
  const summary = inApp?.summary?.[engine] ?? null;
  const medians = summary?.medians ?? {};
  const checks = {
    readyMs: check('readyMs', medians.readyMs),
    typingP95Ms: check('typingP95Ms', medians.typingP95Ms),
    inputP95Ms: check('inputP95Ms', driven?.inputLatency?.p95Ms),
    scrollSlowFramePct: check('scrollSlowFramePct', medians.scrollSlowFramePct),
    compositionFailures: check('compositionFailures', driven?.composition?.failures),
    totalPssMB: check('totalPssMB', driven?.processMemory?.totalPssMB),
    gzipBytes: check('gzipBytes', page?.gzipBytes),
  };
  report.engines[engine] = {
    page,
    summary,
    checks,
    driver: driven,
    inApp: inApp ? { runs: inApp.runs, errors: inApp.errors, pageErrors: inApp.pageErrors, driverPhases: inApp.driverPhases } : null,
    missing: [!inApp && 'in-app results', !driven && 'driver results'].filter(Boolean),
  };
  lines.push(
    '',
    `${engine} ${page?.engineVersion ?? ''}  page ${fmt(page ? page.gzipBytes / 1024 : null, ' KiB')} gzipped` +
      `  input ${summary?.inputMode ?? driven?.inputMode ?? 'n/a'}  runs ${summary?.runs ?? 0}`,
  );
  for (const [name, c] of Object.entries(checks)) {
    const unit = name === 'gzipBytes' ? ' B' : name.endsWith('Pct') ? ' %' : name.endsWith('MB') ? ' MB' : name.endsWith('Ms') ? ' ms' : '';
    lines.push(`  ${mark(c)} ${BUDGETS[name].label.padEnd(34)} ${fmt(c.value, unit).padStart(12)}  (budget ${c.budget}${unit})`);
  }
  lines.push(
    `      1 MiB open ${fmt(medians.largeOpenMs, ' ms')}, 1 MiB typing p95 ${fmt(medians.largeTypingP95Ms, ' ms')}, ` +
      `features ${summary?.featuresOk ? 'ok' : 'n/a'}, highlighting ${summary?.highlightOk ? 'ok' : 'n/a'}`,
    // Phase 3 W1: the same 1 MiB as plain text, as the app opens files
    // above its large-file limit. Record-only: no budget of its own.
    `      1 MiB as plain text: open ${fmt(medians.plainOpenMs, ' ms')}, typing p95 ${fmt(medians.plainTypingP95Ms, ' ms')}, ` +
      `scroll frames > 32 ms ${fmt(medians.plainScrollSlowFramePct, ' %')} (record-only)`,
  );
  const failed = (driven?.composition?.results ?? []).filter((r) => !r.ok);
  if (failed.length > 0) lines.push(`      composition failures: ${failed.map((r) => `${r.id} → ${JSON.stringify(r.actual)}`).join('; ')}`);
  if (report.engines[engine].missing.length > 0) lines.push(`      missing: ${report.engines[engine].missing.join(', ')}`);
}

writeFileSync(args.outJson, `${JSON.stringify(report, null, 2)}\n`);
writeFileSync(args.outTxt, `${lines.join('\n')}\n`);
console.log(lines.join('\n'));
