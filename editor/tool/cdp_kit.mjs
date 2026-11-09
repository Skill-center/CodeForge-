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

export class Cdp {
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

export async function adb(args, bin) {
  const { stdout } = await run(bin, args, { maxBuffer: 16 * 1024 * 1024 });
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

/** The DevTools targets on `port` (empty when nothing answers). */
export async function listTargets(port) {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`);
    const targets = await response.json();
    return Array.isArray(targets) ? targets : [];
  } catch {
    return [];
  }
}
