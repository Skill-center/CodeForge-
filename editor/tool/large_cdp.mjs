#!/usr/bin/env node
/**
 * DevTools driver for the large-file gate (Phase 2 W7, gate G7).
 *
 * app/integration_test/large_files_test.dart opens 1, 5 and 10 MiB files in
 * the real app on the emulator and asks for each step in the device log:
 *   LARGEGATE <run>.<n> prepare <file> [memory]
 *   LARGEGATE <run>.<n> measure <file> <chars> <lines> <text to type…>
 *   LARGEGATE <run>.<n> done
 * This driver polls the log (adb logcat -d), answers the newest request it
 * has not answered yet, and acknowledges it with an empty file,
 * files/largegate/ack.<id>.ok (or .failed), in the app's folder, written
 * through `run-as`. Debug builds only, like the WebView's DevTools socket.
 *   - prepare: fresh windows for the page's host-message timings and long
 *     tasks, so that measure sees the open's; with "memory", the app's and
 *     renderers' memory before the open.
 *   - measure: the page's handling of the doc.open (its own work, then the
 *     next painted frame) and the long tasks since prepare, the lines in
 *     the DOM, the memory with the file open, a 3 s scroll, then real key
 *     events typed at the cursor (the test put it on the middle line), each
 *     timed from its input event to the end of the next frame. The typed
 *     text reaching the app's copy of the document is the test's own check.
 * The page probe (bench/large_probe.ts, bundled here with esbuild) uses the
 * W3 benchmark's instruments, so the numbers compare with editor_bench.json.
 *
 * Usage:
 *   node tool/large_cdp.mjs --adb <adb> --package <app id> --out <file.json>
 *     [--port 9223] [--timeout <seconds, default 1200>]
 *   node tool/large_cdp.mjs --adb <adb> --package <app id> --memory-only --out <file.json>
 * The second form only samples memory: the gate uses it on the release
 * build, which has no DevTools socket.
 */
import { writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { Cdp, adb, listTargets, logger, pressKey, processMemory, sleep, webViewForwarder } from './cdp_kit.mjs';

const EDITOR = join(dirname(fileURLToPath(import.meta.url)), '..');
const PAGE_TITLE = 'CodeForge editor';
// The W3 benchmark's settings (bench/harness.ts, tool/bench_cdp.mjs).
const SCROLL_MS = 3000;
const SCROLL_PX_PER_MS = 6;
const KEY_GAP_MS = 60;
const ATTACH_MS = 30000;
const log = logger('large-cdp');

export const METHOD = {
  scroll: `scrollTop of .cm-scroller stepped every frame at ${SCROLL_PX_PER_MS} px/ms for ${SCROLL_MS} ms from the cursor's view, bouncing at the ends; frames over 32 ms are slow`,
  typing: `Input.dispatchKeyEvent key presses ${KEY_GAP_MS} ms apart at the cursor on the middle line, each timed from its input event to the end of the next frame (bench/input_recorder.ts)`,
  open: "the page's synchronous work on the doc.open message (window.codeforge.receive, wrapped), and from its arrival to the end of the next painted frame",
  longTasks: 'PerformanceObserver longtask entries (over 50 ms) between prepare and measure, and during the scroll and typing',
  memory: 'dumpsys meminfo TOTAL PSS of the app process and every WebView sandboxed renderer, with the file open',
};

/** One request line: "LARGEGATE <run>.<n> <kind> <words…>", or null. */
export function parseRequest(line) {
  const match = line.match(/LARGEGATE (\d+\.\d+) ([a-z]+)((?: \S+)*)\s*$/);
  if (!match) return null;
  return { id: match[1], kind: match[2], words: match[3].trim() === '' ? [] : match[3].trim().split(' ') };
}

/** The last request in a log dump, or null. */
export function newestRequest(logText) {
  const lines = logText.split('\n');
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const request = parseRequest(lines[i]);
    if (request) return request;
  }
  return null;
}

function parseArgs(argv) {
  const args = { port: 9223, timeout: 1200, memoryOnly: false };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (flag === '--memory-only') {
      args.memoryOnly = true;
      continue;
    }
    if (flag === '--adb') args.adb = value;
    else if (flag === '--package') args.package = value;
    else if (flag === '--port') args.port = Number(value);
    else if (flag === '--out') args.out = value;
    else if (flag === '--timeout') args.timeout = Number(value);
    else continue;
    i += 1;
  }
  if (!args.adb || !args.package || !args.out) throw new Error('--adb, --package and --out are required');
  return args;
}

let probeSource = null;
/** bench/large_probe.ts as one script that installs window.codeforgeLargeProbe. */
async function probe() {
  if (probeSource === null) {
    const { build } = await import('esbuild');
    const result = await build({
      entryPoints: [join(EDITOR, 'bench', 'large_probe.ts')],
      bundle: true,
      format: 'iife',
      target: 'es2020',
      write: false,
      logLevel: 'silent',
    });
    probeSource = result.outputFiles[0].text;
  }
  return probeSource;
}

export class Driver {
  constructor(args) {
    this.args = args;
    this.ensureForward = webViewForwarder(args, log);
    this.cdp = null;
    this.targetId = null;
    this.report = {
      schema: 1,
      tool: 'editor/tool/large_cdp.mjs',
      mode: 'driver',
      startedAt: new Date().toISOString(),
      method: METHOD,
      userAgent: null,
      files: {},
      errors: [],
    };
  }

  save() {
    writeFileSync(this.args.out, `${JSON.stringify(this.report, null, 2)}\n`);
  }

  /** The editor page with the probe installed, (re)connecting as needed. */
  async page() {
    const deadline = Date.now() + ATTACH_MS;
    let problem = 'no WebView DevTools socket for the app';
    while (Date.now() < deadline) {
      if (await this.ensureForward().catch(() => false)) {
        const targets = await listTargets(this.args.port);
        const target = targets.filter((t) => t.type === 'page' && t.title === PAGE_TITLE).pop();
        if (target) {
          if (!this.cdp || this.cdp.closed || this.targetId !== target.id) {
            this.cdp?.close();
            this.cdp = await Cdp.connect(target.webSocketDebuggerUrl);
            this.targetId = target.id;
            log(`attached to the editor page (${target.id})`);
          }
          if (!(await this.cdp.evaluate("typeof window.codeforgeLargeProbe === 'object'"))) {
            await this.cdp.evaluate(`${await probe()}\ntypeof window.codeforgeLargeProbe === 'object'`);
          }
          return this.cdp;
        }
        problem = `no "${PAGE_TITLE}" page among ${targets.length} DevTools target(s)`;
      }
      await sleep(1000);
    }
    throw new Error(problem);
  }

  async prepare(request) {
    const [file, extra] = request.words;
    if (!file) throw new Error('prepare needs a file name');
    const cdp = await this.page();
    this.report.userAgent ??= await cdp.evaluate('navigator.userAgent');
    const prepare = { request: request.id, at: new Date().toISOString() };
    prepare.messagesWatched = await cdp.evaluate('codeforgeLargeProbe.watchMessages()');
    prepare.longTasksWatched = await cdp.evaluate('codeforgeLargeProbe.watchLongTasks()');
    if (extra === 'memory') {
      prepare.memory = await processMemory(this.args);
      prepare.jsHeap = await cdp.evaluate('codeforgeLargeProbe.heap()');
    }
    this.report.files[file] = { prepare };
  }

  async measure(request) {
    const [file, chars, lines, ...words] = request.words;
    const text = words.join(' ');
    if (!file || !/^[a-z ]+$/.test(text)) {
      throw new Error(`measure needs a file and letters and spaces to type, not ${JSON.stringify(request.words)}`);
    }
    const cdp = await this.page();
    const entry = (this.report.files[file] ??= {});
    const measure = { request: request.id, at: new Date().toISOString(), chars: Number(chars), lines: Number(lines) };
    entry.measure = measure;
    const messages = await cdp.evaluate('codeforgeLargeProbe.takeMessages()');
    measure.open = messages.find((m) => m.type === 'doc.open') ?? null;
    measure.messages = messages.length;
    measure.openLongTasks = await cdp.evaluate('codeforgeLargeProbe.takeLongTasks()');
    measure.dom = await cdp.evaluate('codeforgeLargeProbe.dom()');
    measure.memory = await processMemory(this.args);
    measure.jsHeap = await cdp.evaluate('codeforgeLargeProbe.heap()');
    measure.scroll = await cdp.evaluate(`codeforgeLargeProbe.scroll(${SCROLL_MS}, ${SCROLL_PX_PER_MS})`, SCROLL_MS + 60000);
    log(`${file}: scroll ${measure.scroll.slowFramePct} % slow of ${measure.scroll.frames} frames`);
    // The page must believe it has the focus for key events to reach the
    // editor, whatever Android's focus is doing meanwhile.
    await cdp.send('Emulation.setFocusEmulationEnabled', { enabled: true }).catch((e) => {
      measure.focusEmulation = String(e.message ?? e);
    });
    measure.focused = await cdp.evaluate('codeforgeLargeProbe.focusEditor()');
    await cdp.evaluate('codeforgeLargeProbe.startTyping()');
    await sleep(300);
    for (const ch of text) {
      await pressKey(cdp, ch);
      await sleep(KEY_GAP_MS);
    }
    await sleep(500);
    measure.typing = { keys: text.length, ...(await cdp.evaluate('codeforgeLargeProbe.typingStats()')) };
    measure.longTasksWhileMeasuring = await cdp.evaluate('codeforgeLargeProbe.takeLongTasks()');
    log(`${file}: typing p95 ${measure.typing.p95Ms} ms over ${measure.typing.count} keys`);
  }

  async acknowledge(id, ok) {
    await adb(
      ['shell', 'run-as', this.args.package, 'touch', `files/largegate/ack.${id}.${ok ? 'ok' : 'failed'}`],
      this.args.adb,
    );
  }

  async run() {
    this.save();
    const deadline = Date.now() + this.args.timeout * 1000;
    const answered = new Set();
    log(`waiting for LARGEGATE requests (${this.args.package})`);
    while (Date.now() < deadline) {
      const dump = await adb(['logcat', '-d', '-v', 'raw', '-s', 'flutter:I'], this.args.adb).catch(() => '');
      const request = newestRequest(dump);
      if (!request || answered.has(request.id)) {
        await sleep(400);
        continue;
      }
      answered.add(request.id);
      log(`request ${request.id}: ${request.kind} ${request.words.slice(0, 3).join(' ')}`);
      if (request.kind === 'done') {
        this.report.finishedAt = new Date().toISOString();
        this.save();
        return true;
      }
      let ok = true;
      try {
        if (request.kind === 'prepare') await this.prepare(request);
        else if (request.kind === 'measure') await this.measure(request);
        else throw new Error(`unknown request ${request.kind}`);
      } catch (e) {
        ok = false;
        const error = String(e?.message ?? e);
        this.report.errors.push({ request: request.id, kind: request.kind, words: request.words.slice(0, 3), error });
        log(`request ${request.id} failed: ${error}`);
      }
      this.save();
      await this.acknowledge(request.id, ok).catch((e) => log(`could not acknowledge ${request.id}: ${e.message ?? e}`));
    }
    this.report.timedOut = true;
    this.save();
    return false;
  }

  close() {
    this.cdp?.close();
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.memoryOnly) {
    const memory = await processMemory(args);
    const report = { schema: 1, tool: 'editor/tool/large_cdp.mjs', mode: 'memory', at: new Date().toISOString(), memory };
    writeFileSync(args.out, `${JSON.stringify(report, null, 2)}\n`);
    log(`memory: app ${memory?.appPssMB} MB + renderers ${memory?.rendererPssMB} MB = ${memory?.totalPssMB} MB`);
    return 0;
  }
  const driver = new Driver(args);
  try {
    const done = await driver.run();
    log(done ? 'done' : 'timed out waiting for the test');
    return done ? 0 : 1;
  } finally {
    driver.close();
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then(
    (code) => process.exit(code),
    (e) => {
      console.error(e);
      process.exit(2);
    },
  );
}
