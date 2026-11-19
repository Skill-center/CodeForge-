#!/usr/bin/env node
/**
 * DevTools-protocol driver for the terminal's composition suite (Phase 5
 * W3, gate G3: "scripted composition loses nothing").
 *
 * The phase gate's terminal group (app/tool/ci/emulator_gate.sh) runs this
 * when integration_test/terminal_test.dart asks for it, with `cat > file`
 * running in the shown session and the terminal focused. Through real
 * browser input events on the terminal page it plays each case of
 * bench/terminal_composition_cases.json (Input.imeSetComposition,
 * Input.insertText, Input.dispatchKeyEvent), each ending with Enter, then
 * types COMPOSE-END. `cat` writes every line the terminal sent; the driver
 * reads the file back from the app's storage (adb shell run-as) and
 * compares it, line by line, with the cases' expected text.
 *
 * Usage:
 *   node tool/terminal_cdp.mjs --adb <adb> --package <app id> \
 *     --file <path in the app's data dir> --out <file.json>
 * Options: --port <local port> (default 9224), --cases <file>,
 * --timeout <seconds> (default 300).
 *
 * Exit status: 0 when every case's line arrived whole, 1 otherwise.
 * No dependencies: Node 22+ ships fetch and WebSocket (tool/cdp_kit.mjs).
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { adb, logger, PageSession, pressKey, probeTargets, sleep, webViewForwarder } from './cdp_kit.mjs';

const EDITOR = join(dirname(fileURLToPath(import.meta.url)), '..');
const TERMINAL_URL = 'https://appassets.androidplatform.net/terminal/';
const END_MARK = 'COMPOSE-END';
const STEP_GAP_MS = 60;
const CASE_GAP_MS = 250;

function parseArgs(argv) {
  const args = { port: 9224, timeout: 300, cases: join(EDITOR, 'bench', 'terminal_composition_cases.json') };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (flag === '--adb') args.adb = value;
    else if (flag === '--package') args.package = value;
    else if (flag === '--port') args.port = Number(value);
    else if (flag === '--file') args.file = value;
    else if (flag === '--out') args.out = value;
    else if (flag === '--cases') args.cases = value;
    else if (flag === '--timeout') args.timeout = Number(value);
    else continue;
    i += 1;
  }
  for (const required of ['adb', 'package', 'file', 'out']) {
    if (!args[required]) throw new Error(`--${required} is required`);
  }
  return args;
}

const log = logger('terminal-cdp');

/** Enter, as a keyboard sends it: xterm.js turns it into CR. */
async function pressEnter(cdp) {
  const key = { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 };
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', ...key, text: '\r', unmodifiedText: '\r' });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...key });
}

/** The shown terminal's input element has the focus: the test focused it; this makes sure. */
async function focusTerminal(cdp) {
  return cdp.evaluate(`(() => {
    const shown = [...document.querySelectorAll('.session')].find((s) => s.style.display !== 'none');
    const area = shown && shown.querySelector('.xterm-helper-textarea');
    if (!area) return 'no terminal';
    if (document.activeElement !== area) area.focus();
    return document.activeElement === area ? 'focused' : 'not focused';
  })()`);
}

async function play(cdp, testCase) {
  for (const [kind, value] of testCase.steps) {
    if (kind === 'compose') {
      await cdp.send('Input.imeSetComposition', { text: value, selectionStart: value.length, selectionEnd: value.length });
    } else if (kind === 'commit' || kind === 'insert') {
      await cdp.send('Input.insertText', { text: value });
    } else if (kind === 'key') {
      await pressKey(cdp, value);
    } else {
      throw new Error(`unknown step ${kind}`);
    }
    await sleep(STEP_GAP_MS);
  }
  await pressEnter(cdp);
  await sleep(CASE_GAP_MS);
}

async function readBack(args, deadline) {
  let content = '';
  while (Date.now() < deadline) {
    content = await adb(['shell', 'run-as', args.package, 'cat', args.file], args.adb).catch(() => '');
    if (content.split('\n').includes(END_MARK)) return content;
    await sleep(500);
  }
  return content;
}

const args = parseArgs(process.argv.slice(2));
const cases = JSON.parse(readFileSync(args.cases, 'utf8')).cases;
const report = { schema: 1, tool: 'editor/tool/terminal_cdp.mjs', startedAt: new Date().toISOString(), cases: cases.length };
const save = () => writeFileSync(args.out, `${JSON.stringify(report, null, 2)}\n`);
save();
const deadline = Date.now() + args.timeout * 1000;
const ensureForward = webViewForwarder(args, log);

async function findTerminal() {
  if (!(await ensureForward().catch(() => false))) return null;
  const { targets } = await probeTargets(args.port);
  return targets.find((t) => (t.url ?? '').startsWith(TERMINAL_URL)) ?? null;
}

let failures = cases.length;
try {
  const session = new PageSession({ find: findTerminal, log, waitMs: Math.max(1000, deadline - Date.now()) });
  report.focus = await session.run('focus', focusTerminal);
  log(`terminal input: ${report.focus}`);
  report.userAgent = await session.run('user agent', (cdp) => cdp.evaluate('navigator.userAgent'));
  for (const testCase of cases) {
    await session.run(testCase.id, (cdp) => play(cdp, testCase));
    log(`played ${testCase.id}`);
  }
  await session.run('end mark', async (cdp) => {
    await cdp.send('Input.insertText', { text: END_MARK });
    await pressEnter(cdp);
  });
  report.reconnects = session.reconnects;
  session.close();
  const content = await readBack(args, Math.min(deadline, Date.now() + 30000));
  const lines = content.split('\n');
  const end = lines.indexOf(END_MARK);
  const got = end < 0 ? lines : lines.slice(0, end);
  report.results = cases.map((testCase, i) => ({
    id: testCase.id,
    expected: testCase.expected,
    actual: got[i] ?? null,
    ok: got[i] === testCase.expected,
  }));
  report.extraLines = got.slice(cases.length);
  report.endMark = end >= 0;
  failures = report.results.filter((r) => !r.ok).length + (report.extraLines.length > 0 ? 1 : 0) + (end >= 0 ? 0 : 1);
} catch (error) {
  report.error = String(error?.message ?? error);
  log(`failed: ${report.error}`);
}
report.failures = failures;
report.finishedAt = new Date().toISOString();
save();
log(`terminal compose: ${cases.length} cases, ${failures} failures`);
for (const result of report.results ?? []) {
  log(`${result.ok ? 'ok  ' : 'FAIL'} ${result.id}: ${JSON.stringify(result.actual)}${result.ok ? '' : ` (expected ${JSON.stringify(result.expected)})`}`);
}
process.exit(failures === 0 ? 0 : 1);
