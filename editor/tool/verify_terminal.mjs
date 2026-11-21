/**
 * Verifies the built terminal page (app/assets/terminal/terminal.html), not
 * the sources, as tool/verify_bundle.mjs does for the editor's:
 * 1. the CSP hash matches the inline script byte for byte;
 * 2. the markup references nothing external (no src or href attributes);
 * 3. the manifest matches the file and the size budget holds;
 * 4. the page boots in a DOM with a fake host channel, with the real
 *    xterm.js, and answers a protocol round trip: ready → open → write
 *    acknowledged → snapshot → an extra key → a sanitized paste → refusals;
 *    since Phase 5 W6, the measurements (probe.ts) with the real xterm.js:
 *    WebGL asked for where there is none leaves the DOM renderer, an echo
 *    probe types through the input method's path and times the echo the
 *    test writes back, and a flood probe counts and hashes what lies
 *    between its marks; and the host's port (hostport.ts): without one the
 *    page says so in terminal.ready, and a second boot, given one as the
 *    app gives it, says it holds it and answers through it.
 */
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';
import { Window } from 'happy-dom';

const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'app', 'assets', 'terminal');
const html = readFileSync(join(OUT, 'terminal.html'), 'utf8');
const manifest = JSON.parse(readFileSync(join(OUT, 'manifest.json'), 'utf8'));
const notices = readFileSync(join(OUT, 'NOTICES.txt'), 'utf8');
const checks = [];
const check = (name, ok, detail = '') => {
  checks.push(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`);
  if (!ok) process.exitCode = 1;
};

const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
check('exactly one inline script', scripts.length === 1, `${scripts.length}`);
const script = scripts[0]?.[1] ?? '';
const cspHash = html.match(/script-src 'sha256-([A-Za-z0-9+/=]+)'/)?.[1];
const actual = createHash('sha256').update(script, 'utf8').digest('base64');
check('CSP pins the inline script hash', cspHash === actual, `sha256-${actual}`);
check('manifest records the same CSP hash', manifest.script.cspHash === `sha256-${actual}`);
const markup = html.replace(script, '');
check('no external references in the markup', !/\s(src|href)\s*=/i.test(markup));
check('CSP denies everything by default', /default-src 'none'/.test(html));
const sha = createHash('sha256').update(html).digest('hex');
check('manifest sha256 matches the file', manifest.html.sha256 === sha);
const gz = gzipSync(html, { level: 9 }).length;
check('gzipped size within budget', gz <= manifest.budget.gzipBytesMax, `${gz} B of ${manifest.budget.gzipBytesMax} B`);
check('manifest names xterm.js and protocol 1', manifest.engine === 'xterm' && manifest.protocol === 1, manifest.engineVersion);
for (const name of Object.keys(manifest.packages)) {
  check(`NOTICES.txt carries ${name}`, notices.includes(`${name} ${manifest.packages[name].version} (`));
}

// Boot the real page. happy-dom evaluates scripts only on request; this runs only our own bundle.
const window = new Window({
  url: 'https://appassets.androidplatform.net/terminal/',
  width: 412,
  height: 400,
  settings: { enableJavaScriptEvaluation: true, suppressInsecureJavaScriptEnvironmentWarning: true },
});
const received = [];
window.CodeForgeBridge = { postMessage: (raw) => received.push(JSON.parse(raw)) };
window.document.write(html);
await window.happyDOM.waitUntilComplete();
const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
for (let waited = 0; waited < 5000 && !received.some((m) => m.type === 'terminal.ready'); waited += 50) {
  await settle(50);
}
const ready = received.find((m) => m.type === 'terminal.ready');
check('page announces terminal.ready', ready !== undefined, ready ? `${ready.payload.engine} ${ready.payload.engineVersion}` : 'none');
check('without a host port, terminal.ready says so', ready?.payload.hostPort === false, JSON.stringify(ready?.payload));
if (typeof window.codeforge?.receive !== 'function') {
  check('page installs window.codeforge.receive', false);
  console.log(checks.join('\n'));
  process.exit(1);
}

const send = (id, type, payload) => window.codeforge.receive(JSON.stringify({ v: 1, id, type, payload }));
const responseTo = (id) => received.find((m) => m.type === 'response' && m.payload.re === id)?.payload;
const inputs = () => received.filter((m) => m.type === 'session.input').map((m) => m.payload.data);

send('h1', 'session.open', { sessionId: 7 });
const opened = responseTo('h1');
check('session.open answered with a size', opened?.ok === true && opened.result.cols > 0 && opened.result.rows > 0, JSON.stringify(opened?.result));
send('h2', 'session.write', { sessionId: 7, seq: 1, data: 'hello \x1b[1;32mworld\x1b[0m\r\n' });
check('a write gets no response', responseTo('h2') === undefined);
await settle(300);
const ack = received.find((m) => m.type === 'session.ack');
check('the write is acknowledged once parsed', ack?.payload.sessionId === 7 && ack.payload.seq === 1, JSON.stringify(ack?.payload));
send('h3', 'session.snapshot', { sessionId: 7 });
const snapshot = responseTo('h3')?.result;
check('the snapshot shows the output without its escapes', snapshot?.screen?.[0] === 'hello world', JSON.stringify(snapshot?.screen?.[0]));
send('h4', 'session.key', { sessionId: 7, key: 'up' });
check('an extra key sends its sequence', inputs().includes('\x1b[A'), JSON.stringify(inputs()));
send('h5', 'session.write', { sessionId: 7, seq: 2, data: '\x1b[?2004h' });
await settle(200);
send('h6', 'session.paste', { sessionId: 7, text: 'ls\x1b[201~ -l\r\nrm' });
check(
  'a paste is sanitized and bracketed',
  inputs().includes('\x1b[200~ls[201~ -l\rrm\x1b[201~'),
  JSON.stringify(inputs().at(-1)),
);
send('h7', 'session.write', { sessionId: 99, seq: 1, data: 'x' });
check('a write to an unknown session is refused', responseTo('h7')?.error?.code === 'unknown_session');
send('h8', 'session.open', { sessionId: 'x' });
check('an invalid request is answered with bad_payload', responseTo('h8')?.error?.code === 'bad_payload');
// The measurements (Phase 5 W6): the renderer, an echo, a flood.
const settleUntil = async (condition, ms = 5000) => {
  for (let waited = 0; waited < ms && !condition(); waited += 25) await settle(25);
  return condition();
};
/** The probe's report once it is no longer running (a fresh request id each time). */
let reads = 0;
const probeOutcome = async () => {
  let last;
  await settleUntil(() => {
    reads += 1;
    send(`pr${reads}`, 'probe.read', {});
    last = responseTo(`pr${reads}`)?.result;
    return last?.state !== 'running';
  });
  return last;
};
send('p1', 'probe.read', {});
check(
  'WebGL by default, and the DOM renderer where there is no WebGL2, with why',
  responseTo('p1')?.result?.state === 'idle' &&
    responseTo('p1')?.result?.renderers?.['7'] === 'dom' &&
    /WebGL2/.test(responseTo('p1')?.result?.webglError ?? ''),
  JSON.stringify(responseTo('p1')?.result),
);
send('p2', 'terminal.configure', { renderer: 'webgl' });
send('p3', 'probe.read', {});
const noWebgl = responseTo('p3')?.result;
check(
  'WebGL asked for again where there is none leaves the DOM renderer',
  responseTo('p2')?.ok === true && noWebgl?.renderers?.['7'] === 'dom' && /WebGL/.test(noWebgl?.webglError ?? ''),
  JSON.stringify(noWebgl),
);
send('p4', 'terminal.configure', { renderer: 'dom' });
send('p5', 'session.write', { sessionId: 7, seq: 3, data: '\x1b[2J\x1b[H$ ' });
await settle(200);
const inputsBefore = inputs().length;
send('p6', 'probe.echo', { sessionId: 7, count: 2, gapMs: 20 });
check('probe.echo answered at once', responseTo('p6')?.ok === true);
let echoSeq = 4;
for (let answered = 0; answered < 4; answered += 1) {
  const typed = await settleUntil(() => inputs().length > inputsBefore + answered);
  if (!typed) break;
  const data = inputs()[inputsBefore + answered];
  send(`pw${answered}`, 'session.write', { sessionId: 7, seq: echoSeq++, data: data === '\x7f' ? '\b \b' : data });
}
const echo = await probeOutcome();
check(
  'an echo probe types as the input method does, and times each echo',
  echo?.state === 'done' && echo.echo?.count === 2 && echo.echo?.lost === 0 &&
    JSON.stringify(inputs().slice(inputsBefore)) === JSON.stringify(['a', '\x7f', 'b', '\x7f']),
  JSON.stringify({ state: echo?.state, echo: echo?.echo, inputs: inputs().slice(inputsBefore) }),
);
const fnv = (text) => {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) h = Math.imul(h ^ text.charCodeAt(i), 0x01000193) >>> 0;
  return h.toString(16).padStart(8, '0');
};
const body = '\x1b[32m0000001\x1b[0m flood line\r\n'.repeat(200);
send('p8', 'probe.flood', { sessionId: 7, begin: '\x1b]777;b\x07', end: '\x1b]777;e\x07' });
send('p9', 'session.write', { sessionId: 7, seq: echoSeq++, data: `$ flood\r\n\x1b]777;b\x07${body.slice(0, 3000)}` });
send('p10', 'session.write', { sessionId: 7, seq: echoSeq++, data: `${body.slice(3000)}\x1b]777;e\x07$ ` });
const flood = await probeOutcome();
check(
  'a flood probe counts and hashes exactly what lies between its marks',
  flood?.state === 'done' && flood.flood?.chars === body.length && flood.flood?.hash === fnv(body) && flood.flood?.writes === 2,
  JSON.stringify({ state: flood?.state, chars: flood?.flood?.chars, hash: flood?.flood?.hash, expected: fnv(body) }),
);
send('h9', 'session.close', { sessionId: 7 });
check('session.close answered ok', responseTo('h9')?.ok === true);
const pageErrors = received.filter((m) => m.type === 'terminal.log' && m.payload.level === 'error');
check('no page errors logged', pageErrors.length === 0, pageErrors.map((m) => m.payload.message).join('; '));

await window.happyDOM.close();

// The host's port (Phase 5 W6): a second boot, given a port as the app gives
// it (a message without a source window, carrying one port). happy-dom has
// no MessageChannel: the port is a stand-in whose onmessage the page sets.
const ported = new Window({
  url: 'https://appassets.androidplatform.net/terminal/',
  width: 412,
  height: 400,
  settings: { enableJavaScriptEvaluation: true, suppressInsecureJavaScriptEnvironmentWarning: true },
});
const portReceived = [];
ported.CodeForgeBridge = { postMessage: (raw) => portReceived.push(JSON.parse(raw)) };
ported.document.write(html);
// As the app does once the page has loaded, but before happy-dom's
// waitUntilComplete, which would wait out the page's wait for the port.
for (let waited = 0; waited < 5000 && typeof ported.codeforge?.receive !== 'function'; waited += 10) {
  await settle(10);
}
const hostPort = { onmessage: null };
ported.dispatchEvent(new ported.MessageEvent('message', { data: 'codeforge-host-port', ports: [hostPort] }));
for (let waited = 0; waited < 5000 && !portReceived.some((m) => m.type === 'terminal.ready'); waited += 50) {
  await settle(50);
}
const portReady = portReceived.find((m) => m.type === 'terminal.ready');
check(
  'given the host port, terminal.ready says the page holds it',
  portReady?.payload.hostPort === true && typeof hostPort.onmessage === 'function',
  JSON.stringify(portReady?.payload),
);
const viaPort = (id, type, payload) => hostPort.onmessage?.({ data: JSON.stringify({ v: 1, id, type, payload }) });
viaPort('q1', 'session.open', { sessionId: 3 });
viaPort('q2', 'session.write', { sessionId: 3, seq: 1, data: 'through the port\r\n' });
await settle(300);
viaPort('q3', 'session.snapshot', { sessionId: 3 });
const portResponse = (id) => portReceived.find((m) => m.type === 'response' && m.payload.re === id)?.payload;
check(
  'host messages through the port are answered, acknowledged and drawn',
  portResponse('q1')?.ok === true &&
    portReceived.some((m) => m.type === 'session.ack' && m.payload.sessionId === 3 && m.payload.seq === 1) &&
    portResponse('q3')?.result?.screen?.[0] === 'through the port',
  JSON.stringify(portResponse('q3')?.result?.screen?.[0]),
);
ported.codeforge.receive(JSON.stringify({ v: 1, id: 'q4', type: 'session.close', payload: { sessionId: 3 } }));
check('window.codeforge.receive still answers beside the port', portResponse('q4')?.ok === true);
await ported.happyDOM.close();
console.log(checks.join('\n'));
