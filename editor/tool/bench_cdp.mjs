#!/usr/bin/env node
/**
 * DevTools-protocol driver for the editor benchmark (Phase 2 W3).
 *
 * The app's benchmark page hands itself over by setting its title to
 * "codeforge-bench:<engine>:driver" (codeforgeBench.awaitDriver). For every
 * such page this driver runs, through real browser input events:
 *   1. input latency: 60 key presses (Input.dispatchKeyEvent); the page times
 *      each input event to the end of the next frame;
 *   2. the composition suite (bench/composition_cases.json):
 *      Input.imeSetComposition / Input.insertText, including CJK and emoji;
 *   3. a memory session: the 1 MiB file opened and scrolled, then (adb mode)
 *      `dumpsys meminfo` for the app and the WebView renderer process(es);
 * then calls codeforgeBench.driverDone(summary) so the app moves on.
 *
 * Usage:
 *   node tool/bench_cdp.mjs --adb <adb> --package <app id> --out <file.json>
 *   node tool/bench_cdp.mjs --port 9222 --out <file.json>   (a local Chromium)
 * Options: --timeout <seconds> (default 1200), --engines codemirror,monaco
 * (exit once each has been driven).
 *
 * No dependencies: Node 22+ ships fetch and WebSocket. The DevTools client,
 * adb, memory and key helpers are shared with tool/large_cdp.mjs
 * (tool/cdp_kit.mjs).
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { listTargets, logger, PageSession, pressKey, processMemory, sleep, webViewForwarder } from './cdp_kit.mjs';

const EDITOR = join(dirname(fileURLToPath(import.meta.url)), '..');
const CASES = JSON.parse(readFileSync(join(EDITOR, 'bench', 'composition_cases.json'), 'utf8')).cases;
/** Letters and spaces only, so every key has an unambiguous US key code. */
const KEY_TEXT = 'the quick brown fox jumps over the lazy dog and keeps running'.slice(0, 60);
const KEY_GAP_MS = 60;
const STEP_GAP_MS = 40;

function parseArgs(argv) {
  const args = { port: 9222, timeout: 1200, engines: null };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (flag === '--adb') args.adb = value;
    else if (flag === '--package') args.package = value;
    else if (flag === '--port') args.port = Number(value);
    else if (flag === '--out') args.out = value;
    else if (flag === '--timeout') args.timeout = Number(value);
    else if (flag === '--engines') args.engines = value.split(',');
    else continue;
    i += 1;
  }
  if (!args.out) throw new Error('--out is required');
  return args;
}

const log = logger('bench-cdp');

async function inputLatency(cdp) {
  await cdp.evaluate("codeforgeBench.prepareInput('', 0)");
  await sleep(300);
  for (const ch of KEY_TEXT) {
    await pressKey(cdp, ch);
    await sleep(KEY_GAP_MS);
  }
  await sleep(300);
  const stats = await cdp.evaluate('codeforgeBench.inputStats()');
  const text = await cdp.evaluate('codeforgeBench.text()');
  return { keys: KEY_TEXT.length, textMatches: text === KEY_TEXT, ...stats };
}

async function compositionSuite(cdp) {
  const results = [];
  for (const testCase of CASES) {
    const initial = testCase.initial ?? '';
    const cursor = testCase.cursor ?? initial.length;
    await cdp.evaluate(`codeforgeBench.prepareInput(${JSON.stringify(initial)}, ${cursor})`);
    await sleep(150);
    let error = null;
    try {
      for (const [kind, value] of testCase.steps) {
        if (kind === 'compose') {
          await cdp.send('Input.imeSetComposition', {
            text: value,
            selectionStart: value.length,
            selectionEnd: value.length,
          });
        } else if (kind === 'commit' || kind === 'insert') {
          await cdp.send('Input.insertText', { text: value });
        } else if (kind === 'key') {
          await pressKey(cdp, value);
        } else {
          throw new Error(`unknown step ${kind}`);
        }
        await sleep(STEP_GAP_MS);
      }
    } catch (e) {
      error = String(e.message ?? e);
    }
    await sleep(200);
    const actual = await cdp.evaluate('codeforgeBench.text()');
    results.push({ id: testCase.id, expected: testCase.expected, actual, ok: !error && actual === testCase.expected, error });
  }
  return { cases: results.length, failures: results.filter((r) => !r.ok).length, results };
}

async function driverTargets(port) {
  const targets = await listTargets(port);
  return targets.filter((t) => /^codeforge-bench:(codemirror|monaco):driver$/.test(t.title ?? ''));
}

/**
 * The page being driven, found again after a dropped session (Phase 3 W6):
 * the same target, or else the same engine's page waiting for the driver.
 * The forward is renewed first, in case the app's socket moved.
 */
function findAgain(args, target) {
  return async () => {
    await ensureForward().catch(() => false);
    const targets = await driverTargets(args.port);
    return targets.find((t) => t.id === target.id) ?? targets.find((t) => t.title === target.title) ?? null;
  };
}

async function drive(target, args) {
  const engine = target.title.split(':')[1];
  log(`driving ${engine} (${target.id})`);
  // Each stage sets the page up itself, so a stage that lost its session
  // runs again from the start once the page is found again.
  const session = new PageSession({ find: findAgain(args, target), log: (m) => log(`${engine}: ${m}`) });
  const summary = { engine, startedAt: new Date().toISOString() };
  try {
    summary.inputMode = await session.run('input mode', (cdp) => cdp.evaluate('codeforgeBench.inputMode()'));
    summary.userAgent = await session.run('user agent', (cdp) => cdp.evaluate('navigator.userAgent'));
    summary.inputLatency = await session.run('input latency', inputLatency);
    log(`${engine}: input p50 ${summary.inputLatency.p50Ms} ms, p95 ${summary.inputLatency.p95Ms} ms`);
    summary.composition = await session.run('composition', compositionSuite);
    log(`${engine}: composition ${summary.composition.cases - summary.composition.failures}/${summary.composition.cases} ok`);
    summary.memorySession = await session.run('memory session', (cdp) => cdp.evaluate('codeforgeBench.openLarge()', 120000));
    summary.jsHeap = await session.run('js heap', (cdp) =>
      cdp.evaluate(
        'performance.memory ? { usedMB: Math.round(performance.memory.usedJSHeapSize / 104857.6) / 10, totalMB: Math.round(performance.memory.totalJSHeapSize / 104857.6) / 10 } : null',
      ),
    );
    summary.processMemory = await processMemory(args).catch((e) => ({ error: String(e.message ?? e) }));
    summary.pageErrors = await session.run('page errors', (cdp) => cdp.evaluate('codeforgeBench.errors()'));
  } catch (e) {
    summary.error = String(e.message ?? e);
    log(`${engine}: ${summary.error}`);
  }
  try {
    await session.run('hand back', (cdp) =>
      cdp.evaluate(`codeforgeBench.driverDone(${JSON.stringify({ ok: !summary.error })})`),
    );
  } catch (e) {
    summary.handBackError = String(e.message ?? e);
  }
  summary.reconnects = session.reconnects;
  session.close();
  return summary;
}

const args = parseArgs(process.argv.slice(2));
const ensureForward = webViewForwarder(args, log);
const report = { schema: 1, tool: 'editor/tool/bench_cdp.mjs', mode: args.adb ? 'adb' : 'local', engines: {} };
const save = () => writeFileSync(args.out, `${JSON.stringify(report, null, 2)}\n`);
save();
const deadline = Date.now() + args.timeout * 1000;
log(`waiting for benchmark pages (${args.adb ? `adb, ${args.package}` : `port ${args.port}`})`);
while (Date.now() < deadline) {
  if (args.engines && args.engines.every((e) => report.engines[e] && !report.engines[e].error)) break;
  if (!(await ensureForward().catch(() => false))) {
    await sleep(2000);
    continue;
  }
  const [target] = await driverTargets(args.port);
  if (!target) {
    await sleep(1000);
    continue;
  }
  const summary = await drive(target, args);
  report.engines[summary.engine] = summary;
  save();
}
log('done');
