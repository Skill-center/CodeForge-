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
 * No dependencies: Node 22+ ships fetch and WebSocket.
 */
import { execFile } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
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

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const log = (message) => console.log(`[bench-cdp ${new Date().toISOString().slice(11, 19)}] ${message}`);

class Cdp {
  static async connect(url) {
    const ws = new WebSocket(url);
    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = () => reject(new Error(`cannot connect to ${url}`));
    });
    return new Cdp(ws);
  }

  constructor(ws) {
    this.ws = ws;
    this.nextId = 0;
    this.pending = new Map();
    ws.onmessage = (event) => {
      const message = JSON.parse(event.data);
      const waiter = message.id === undefined ? undefined : this.pending.get(message.id);
      if (!waiter) return;
      this.pending.delete(message.id);
      if (message.error) waiter.reject(new Error(`${waiter.method}: ${message.error.message}`));
      else waiter.resolve(message.result);
    };
    ws.onclose = () => {
      for (const waiter of this.pending.values()) waiter.reject(new Error('DevTools connection closed'));
      this.pending.clear();
    };
  }

  send(method, params = {}, timeoutMs = 60000) {
    const id = (this.nextId += 1);
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`${method} timed out`));
      }, timeoutMs);
    });
  }

  async evaluate(expression, timeoutMs = 60000) {
    const reply = await this.send(
      'Runtime.evaluate',
      { expression, awaitPromise: true, returnByValue: true },
      timeoutMs,
    );
    if (reply.exceptionDetails) {
      const details = reply.exceptionDetails;
      throw new Error(details.exception?.description ?? details.text ?? 'evaluation failed');
    }
    return reply.result.value;
  }

  close() {
    this.ws.close();
  }
}

function keyFor(ch) {
  if (ch === ' ') return { key: ' ', code: 'Space', windowsVirtualKeyCode: 32 };
  if (ch === 'Backspace') return { key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 };
  const upper = ch.toUpperCase();
  return { key: ch, code: `Key${upper}`, windowsVirtualKeyCode: upper.charCodeAt(0) };
}

async function pressKey(cdp, ch) {
  const key = keyFor(ch);
  const text = ch.length === 1 ? { text: ch, unmodifiedText: ch } : {};
  await cdp.send('Input.dispatchKeyEvent', { type: ch.length === 1 ? 'keyDown' : 'rawKeyDown', ...key, ...text });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...key });
}

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

async function adb(args, bin) {
  const { stdout } = await run(bin, args, { maxBuffer: 16 * 1024 * 1024 });
  return stdout.replace(/\r/g, '');
}

function totalPssKb(meminfo) {
  const match = meminfo.match(/TOTAL PSS:\s+(\d+)/) ?? meminfo.match(/^\s*TOTAL\s+(\d+)/m);
  return match ? Number(match[1]) : null;
}

async function processMemory(args) {
  if (!args.adb) return null;
  const kbToMb = (kb) => (kb === null ? null : Math.round((kb / 1024) * 10) / 10);
  const app = totalPssKb(await adb(['shell', 'dumpsys', 'meminfo', args.package], args.adb));
  const ps = await adb(['shell', 'ps', '-A', '-o', 'PID,NAME'], args.adb);
  const renderers = [];
  for (const line of ps.split('\n')) {
    const match = line.trim().match(/^(\d+)\s+(\S*sandboxed_process\S*)$/);
    if (!match) continue;
    const pss = totalPssKb(await adb(['shell', 'dumpsys', 'meminfo', match[1]], args.adb));
    renderers.push({ pid: Number(match[1]), name: match[2], pssMB: kbToMb(pss) });
  }
  const rendererMB = renderers.reduce((sum, r) => sum + (r.pssMB ?? 0), 0);
  return {
    method: 'dumpsys meminfo TOTAL PSS after the session (app process + every WebView sandboxed renderer)',
    appPssMB: kbToMb(app),
    renderers,
    rendererPssMB: Math.round(rendererMB * 10) / 10,
    totalPssMB: app === null ? null : Math.round((kbToMb(app) + rendererMB) * 10) / 10,
  };
}

let forwardedSocket = null;
/**
 * Forwards the local port to the app's WebView DevTools socket. WebView
 * names it after the app's pid; /proc/net/unix (what chrome://inspect
 * reads) is the fallback when the pid is unknown.
 */
async function ensureForward(args) {
  if (!args.adb) return true;
  const pid = (await adb(['shell', 'pidof', args.package], args.adb).catch(() => '')).trim().split(/\s+/)[0];
  // With the app's pid known its socket name is too (it may simply not
  // exist yet: no WebView created so far). Without a pid the fallback may
  // pick another app's socket, which is harmless: targets match by title,
  // and the next poll re-forwards once the app is running.
  let socket = /^\d+$/.test(pid ?? '') ? `webview_devtools_remote_${pid}` : null;
  if (!socket) {
    const unix = await adb(['shell', 'cat', '/proc/net/unix'], args.adb).catch(() => '');
    socket = [...unix.matchAll(/@(webview_devtools_remote_\d+)/g)].pop()?.[1] ?? null;
  }
  if (!socket) return false;
  if (socket !== forwardedSocket) {
    await adb(['forward', `tcp:${args.port}`, `localabstract:${socket}`], args.adb);
    forwardedSocket = socket;
    log(`forwarded tcp:${args.port} to ${socket}`);
  }
  return true;
}

async function driverTargets(port) {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`);
    const targets = await response.json();
    return targets.filter((t) => /^codeforge-bench:(codemirror|monaco):driver$/.test(t.title ?? ''));
  } catch {
    return [];
  }
}

async function drive(target, args) {
  const engine = target.title.split(':')[1];
  log(`driving ${engine} (${target.id})`);
  const cdp = await Cdp.connect(target.webSocketDebuggerUrl);
  const summary = { engine, startedAt: new Date().toISOString() };
  try {
    summary.inputMode = await cdp.evaluate('codeforgeBench.inputMode()');
    summary.userAgent = await cdp.evaluate('navigator.userAgent');
    summary.inputLatency = await inputLatency(cdp);
    log(`${engine}: input p50 ${summary.inputLatency.p50Ms} ms, p95 ${summary.inputLatency.p95Ms} ms`);
    summary.composition = await compositionSuite(cdp);
    log(`${engine}: composition ${summary.composition.cases - summary.composition.failures}/${summary.composition.cases} ok`);
    summary.memorySession = await cdp.evaluate('codeforgeBench.openLarge()', 120000);
    summary.jsHeap = await cdp.evaluate(
      'performance.memory ? { usedMB: Math.round(performance.memory.usedJSHeapSize / 104857.6) / 10, totalMB: Math.round(performance.memory.totalJSHeapSize / 104857.6) / 10 } : null',
    );
    summary.processMemory = await processMemory(args).catch((e) => ({ error: String(e.message ?? e) }));
    summary.pageErrors = await cdp.evaluate('codeforgeBench.errors()');
  } catch (e) {
    summary.error = String(e.message ?? e);
    log(`${engine}: ${summary.error}`);
  }
  try {
    await cdp.evaluate(`codeforgeBench.driverDone(${JSON.stringify({ ok: !summary.error })})`);
  } catch (e) {
    summary.handBackError = String(e.message ?? e);
  }
  cdp.close();
  return summary;
}

const args = parseArgs(process.argv.slice(2));
const report = { schema: 1, tool: 'editor/tool/bench_cdp.mjs', mode: args.adb ? 'adb' : 'local', engines: {} };
const save = () => writeFileSync(args.out, `${JSON.stringify(report, null, 2)}\n`);
save();
const deadline = Date.now() + args.timeout * 1000;
log(`waiting for benchmark pages (${args.adb ? `adb, ${args.package}` : `port ${args.port}`})`);
while (Date.now() < deadline) {
  if (args.engines && args.engines.every((e) => report.engines[e] && !report.engines[e].error)) break;
  if (!(await ensureForward(args).catch(() => false))) {
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
