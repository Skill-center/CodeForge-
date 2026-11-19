/**
 * Verifies the built terminal page (app/assets/terminal/terminal.html), not
 * the sources, as tool/verify_bundle.mjs does for the editor's:
 * 1. the CSP hash matches the inline script byte for byte;
 * 2. the markup references nothing external (no src or href attributes);
 * 3. the manifest matches the file and the size budget holds;
 * 4. the page boots in a DOM with a fake host channel, with the real
 *    xterm.js, and answers a protocol round trip: ready → open → write
 *    acknowledged → snapshot → an extra key → a sanitized paste → refusals.
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
send('h9', 'session.close', { sessionId: 7 });
check('session.close answered ok', responseTo('h9')?.ok === true);
const pageErrors = received.filter((m) => m.type === 'terminal.log' && m.payload.level === 'error');
check('no page errors logged', pageErrors.length === 0, pageErrors.map((m) => m.payload.message).join('; '));

await window.happyDOM.close();
console.log(checks.join('\n'));
