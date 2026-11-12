/**
 * DevTools-protocol plumbing shared by the phase gate's WebView drivers:
 * tool/bench_cdp.mjs (Phase 2 W3, the engine benchmark) and
 * tool/large_cdp.mjs (Phase 2 W7, large files). A minimal client, adb, the
 * app's and renderers' memory, the forward to the app's WebView DevTools
 * socket, and key presses on a US layout.
 *
 * No dependencies: Node 22+ ships fetch and WebSocket.
 */
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** A log function whose lines start with "[<name> HH:MM:SS]". */
export function logger(name) {
  return (message) => console.log(`[${name} ${new Date().toISOString().slice(11, 19)}] ${message}`);
}

/** What a request on a DevTools connection that closed fails with. */
export const DROPPED = 'DevTools connection closed';

/**
 * Whether `error` means the DevTools session itself dropped (its socket
 * closed, a request went unanswered, or a new connection failed), not that
 * the page threw: what a reconnect may cure.
 */
export function isDropped(error) {
  const message = String(error?.message ?? error);
  return message === DROPPED || / timed out$/.test(message) || message.startsWith('cannot connect to ');
}

export class Cdp {
  /** Opens a session on `url`; a socket that does not open within `timeoutMs` fails. */
  static async connect(url, timeoutMs = 10000) {
    const ws = new WebSocket(url);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`cannot connect to ${url}: no answer in ${timeoutMs} ms`));
        try {
          ws.close();
        } catch {
          // Not open yet.
        }
      }, timeoutMs);
      ws.onopen = () => {
        clearTimeout(timer);
        resolve();
      };
      ws.onerror = () => {
        clearTimeout(timer);
        reject(new Error(`cannot connect to ${url}`));
      };
    });
    return new Cdp(ws);
  }

  constructor(ws) {
    this.ws = ws;
    this.nextId = 0;
    this.pending = new Map();
    this.closed = false;
    ws.onmessage = (event) => {
      const message = JSON.parse(event.data);
      const waiter = message.id === undefined ? undefined : this.pending.get(message.id);
      if (!waiter) return;
      this.pending.delete(message.id);
      if (message.error) waiter.reject(new Error(`${waiter.method}: ${message.error.message}`));
      else waiter.resolve(message.result);
    };
    ws.onclose = () => {
      this.closed = true;
      for (const waiter of this.pending.values()) waiter.reject(new Error(DROPPED));
      this.pending.clear();
    };
  }

  send(method, params = {}, timeoutMs = 60000) {
    // A closed socket drops what is sent without a word: say so at once
    // instead of waiting out the timeout.
    if (this.closed) return Promise.reject(new Error(DROPPED));
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

/** The key event fields for a letter, a space or Backspace (US layout). */
export function keyFor(ch) {
  if (ch === ' ') return { key: ' ', code: 'Space', windowsVirtualKeyCode: 32 };
  if (ch === 'Backspace') return { key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 };
  const upper = ch.toUpperCase();
  return { key: ch, code: `Key${upper}`, windowsVirtualKeyCode: upper.charCodeAt(0) };
}

/** One key press through the browser's input pipeline (Input.dispatchKeyEvent). */
export async function pressKey(cdp, ch) {
  const key = keyFor(ch);
  const text = ch.length === 1 ? { text: ch, unmodifiedText: ch } : {};
  await cdp.send('Input.dispatchKeyEvent', { type: ch.length === 1 ? 'keyDown' : 'rawKeyDown', ...key, ...text });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...key });
}

/**
 * Runs adb (or `bin`) with `args` and returns its output. A call that has not
 * finished within `timeoutMs` is stopped and fails, so a stuck device can
 * not hold a driver's loop (Phase 3 W6: a gate's driver waited minutes and
 * missed a whole engine).
 */
export async function adb(args, bin, timeoutMs = 20000) {
  const { stdout } = await run(bin, args, { maxBuffer: 16 * 1024 * 1024, timeout: timeoutMs });
  return stdout.replace(/\r/g, '');
}

/** TOTAL PSS in KB from `dumpsys meminfo` output, or null. */
export function totalPssKb(meminfo) {
  const match = meminfo.match(/TOTAL PSS:\s+(\d+)/) ?? meminfo.match(/^\s*TOTAL\s+(\d+)/m);
  return match ? Number(match[1]) : null;
}

/**
 * `dumpsys meminfo` TOTAL PSS of the app process and of every WebView
 * sandboxed renderer; null without adb.
 */
export async function processMemory(args) {
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

/**
 * A function that forwards local port `args.port` to the app's WebView
 * DevTools socket and says whether there is one. WebView names the socket
 * after the app's pid; /proc/net/unix (what chrome://inspect reads) is the
 * fallback when the pid is unknown. Without adb (a local Chromium on
 * `args.port`) there is nothing to forward.
 */
export function webViewForwarder(args, log) {
  let forwardedSocket = null;
  return async function ensureForward() {
    if (!args.adb) return true;
    const pid = (await adb(['shell', 'pidof', args.package], args.adb).catch(() => '')).trim().split(/\s+/)[0];
    // With the app's pid known its socket name is too (it may simply not
    // exist yet: no WebView created so far). Without a pid the fallback may
    // pick another app's socket, which is harmless: targets are matched by
    // title, and the next poll re-forwards once the app is running.
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
  };
}

/**
 * One page's DevTools session that reconnects when it drops (Phase 3 W6, an
 * owner decision): in Phase 2, 7 of the last 11 gates lost CodeMirror's
 * memory figures when the connection closed during the memory session
 * ("DevTools connection closed", then "Runtime.evaluate timed out" on the
 * hand-back).
 *
 * `run(stage, fn)` calls `fn(cdp)` and returns what it returns. If the
 * session dropped (`isDropped`), it finds the page again with `find()`
 * (polling every `pollMs` for up to `waitMs`), connects with `connect(url)`,
 * and calls `fn` again from the start, up to `attempts` calls in all; each
 * stage starts by setting up the page, so a call can be repeated. An error
 * from the page itself is thrown at once. Every reconnect is kept in
 * `reconnects` for the report.
 */
export class PageSession {
  constructor({ find, connect = (url) => Cdp.connect(url), log = () => {}, attempts = 3, waitMs = 30000, pollMs = 1000 }) {
    this.find = find;
    this.connect = connect;
    this.log = log;
    this.attempts = attempts;
    this.waitMs = waitMs;
    this.pollMs = pollMs;
    this.cdp = null;
    this.reconnects = [];
  }

  /** Connects to the page `find()` gives, waiting for it to show. */
  async open() {
    const deadline = Date.now() + this.waitMs;
    let lastError = new Error('page not found');
    for (;;) {
      const target = await this.find().catch((e) => {
        lastError = e;
        return null;
      });
      if (target) {
        try {
          this.cdp = await this.connect(target.webSocketDebuggerUrl);
          return this.cdp;
        } catch (e) {
          lastError = e;
        }
      }
      if (Date.now() >= deadline) throw lastError;
      await sleep(this.pollMs);
    }
  }

  async run(stage, fn) {
    for (let attempt = 1; ; attempt += 1) {
      try {
        if (!this.cdp || this.cdp.closed) await this.open();
        return await fn(this.cdp);
      } catch (error) {
        if (!isDropped(error) || attempt >= this.attempts) throw error;
        const message = String(error?.message ?? error);
        this.reconnects.push({ stage, attempt, error: message, at: new Date().toISOString() });
        this.log(`${stage}: ${message}; reconnecting for attempt ${attempt + 1} of ${this.attempts}`);
        this.close();
      }
    }
  }

  close() {
    try {
      this.cdp?.close();
    } catch {
      // Already closed.
    }
    this.cdp = null;
  }
}

/** The DevTools targets on `port` (empty when nothing answers within `timeoutMs`). */
export async function listTargets(port, timeoutMs = 5000) {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(timeoutMs) });
    const targets = await response.json();
    return Array.isArray(targets) ? targets : [];
  } catch {
    return [];
  }
}
