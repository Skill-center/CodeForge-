/**
 * Verifies the built page (app/assets/editor/editor.html), not the sources:
 * 1. the CSP hash matches the inline script byte for byte;
 * 2. the markup references nothing external (no src or href attributes);
 * 3. the manifest matches the file and the size budget holds;
 * 4. the page boots in a DOM with a fake host channel and answers a full
 *    protocol round trip: ready → open → toolbar insert → batched change →
 *    snapshot.
 */
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';
import { Window } from 'happy-dom';

const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'app', 'assets', 'editor');
const html = readFileSync(join(OUT, 'editor.html'), 'utf8');
const manifest = JSON.parse(readFileSync(join(OUT, 'manifest.json'), 'utf8'));
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

// Boot the real page.
// happy-dom evaluates scripts only on request; this runs only our own bundle.
const window = new Window({
  url: 'https://appassets.androidplatform.net/editor/',
  width: 412,
  height: 800,
  settings: { enableJavaScriptEvaluation: true, suppressInsecureJavaScriptEnvironmentWarning: true },
});
const received = [];
window.CodeForgeBridge = { postMessage: (raw) => received.push(JSON.parse(raw)) };
window.document.write(html);
await window.happyDOM.waitUntilComplete();
const ready = received.find((m) => m.type === 'editor.ready');
check('page announces editor.ready', ready !== undefined, ready ? `${ready.payload.engine} ${ready.payload.engineVersion}` : 'none');
if (typeof window.codeforge?.receive !== 'function') {
  check('page installs window.codeforge.receive', false);
  console.log(checks.join('\n'));
  process.exit(1);
}

const send = (id, type, payload) => window.codeforge.receive(JSON.stringify({ v: 1, id, type, payload }));
const responseTo = (id) => received.find((m) => m.type === 'response' && m.payload.re === id)?.payload;
send('h1', 'doc.open', { docId: 'd1', text: 'const a = 1;', language: 'javascript', version: 0 });
check('doc.open answered ok', responseTo('h1')?.ok === true);
send('h2', 'cmd.insert', { text: '()', cursorOffset: 1 });
check('cmd.insert answered ok', responseTo('h2')?.ok === true);
await new Promise((resolve) => setTimeout(resolve, 400));
const changed = received.find((m) => m.type === 'doc.changed');
check('edit arrives as one batched doc.changed', changed?.payload?.version === 1, JSON.stringify(changed?.payload?.changes));
send('h3', 'doc.snapshot', { docId: 'd1' });
check('snapshot returns the edited text', responseTo('h3')?.result?.text === '()const a = 1;');
send('h4', 'doc.open', { docId: 'bad id', text: '', language: 'javascript', version: 0 });
check('invalid request answered with bad_payload', responseTo('h4')?.error?.code === 'bad_payload');
const pageErrors = received.filter((m) => m.type === 'editor.log' && m.payload.level === 'error');
check('no page errors logged', pageErrors.length === 0, pageErrors.map((m) => m.payload.message).join('; '));

await window.happyDOM.close();
console.log(checks.join('\n'));
