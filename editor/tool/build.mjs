/**
 * Builds the editor page: one self-contained HTML document (inline script,
 * inline style, inline font) at app/assets/editor/editor.html.
 *
 * Why one document: webview_flutter 4.14.1 exposes no request interception,
 * so Android's WebViewAssetLoader is unreachable. The host loads this
 * document with loadHtmlString under https://appassets.androidplatform.net/,
 * and its Content-Security-Policy pins the script's SHA-256. The page makes
 * no requests at all, and the WebView itself refuses a tampered script.
 *
 * Outputs (gitignored, rebuilt by CI): editor.html, manifest.json, NOTICES.txt.
 * The build is deterministic: same inputs, same bytes, no timestamps.
 */
import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';
import ts from 'typescript';

const EDITOR = join(dirname(fileURLToPath(import.meta.url)), '..');
const REPO = join(EDITOR, '..');
const OUT = join(REPO, 'app', 'assets', 'editor');
const FONT = join(REPO, 'app', 'assets', 'fonts', 'JetBrainsMono_400Regular.ttf');
/** ADR-0004 gate budget for the shipped editor, gzipped. */
export const GZIP_BUDGET = 1.5 * 1024 * 1024;

function fail(message) {
  console.error(`editor build failed: ${message}`);
  process.exit(1);
}

const sha256 = (data, encoding = 'hex') => createHash('sha256').update(data).digest(encoding);

const pkg = JSON.parse(readFileSync(join(EDITOR, 'package.json'), 'utf8'));
const engineVersion = pkg.dependencies['@codemirror/view'];

const result = await build({
  absWorkingDir: EDITOR,
  entryPoints: ['src/main.ts'],
  bundle: true,
  minify: true,
  format: 'iife',
  platform: 'browser',
  target: ['es2020', 'chrome87'],
  charset: 'utf8',
  legalComments: 'none', // licence texts ship in NOTICES.txt instead
  define: { __ENGINE_VERSION__: JSON.stringify(engineVersion) },
  metafile: true,
  write: false,
  logLevel: 'warning',
});
/**
 * Inside a <script> element the HTML tokenizer treats "<!--" specially
 * (script data escaped state), so it must not appear in an inline script.
 * esbuild already escapes "</script"; this rewrites "<!--" as "\x3C!--",
 * which is exactly equivalent inside string, untagged template and regular
 * expression literals (also with the u flag). The bundle is parsed to prove
 * every occurrence is inside such a literal; anything else fails the build.
 */
function escapeCommentOpeners(code) {
  const positions = [...code.matchAll(/<!--/g)].map((m) => m.index);
  if (positions.length === 0) return code;
  const file = ts.createSourceFile('bundle.js', code, ts.ScriptTarget.ES2020, true, ts.ScriptKind.JS);
  const K = ts.SyntaxKind;
  const templateParts = new Set([K.NoSubstitutionTemplateLiteral, K.TemplateHead, K.TemplateMiddle, K.TemplateTail]);
  const isTagged = (node) => {
    let template = node;
    if (node.kind === K.TemplateMiddle || node.kind === K.TemplateTail) template = node.parent.parent;
    else if (node.kind === K.TemplateHead) template = node.parent;
    return template.parent?.kind === K.TaggedTemplateExpression;
  };
  const safe = new Set();
  const visit = (node) => {
    const literal =
      node.kind === K.StringLiteral ||
      node.kind === K.RegularExpressionLiteral ||
      (templateParts.has(node.kind) && !isTagged(node));
    if (literal) {
      const start = node.getStart(file);
      const end = node.getEnd();
      for (const p of positions) if (p >= start && p + 4 <= end) safe.add(p);
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  const unsafe = positions.filter((p) => !safe.has(p));
  if (unsafe.length > 0) fail(`"<!--" outside a string or regex literal at offsets ${unsafe.join(', ')}`);
  return code.replaceAll('<!--', '\\x3C!--');
}

const script = escapeCommentOpeners(result.outputFiles[0].text.trimEnd());
if (/<\/script/i.test(script) || script.includes('<!--')) {
  fail('the bundle contains a sequence that would end an inline <script>');
}

// Packages that actually ended up in the bundle.
const bundled = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  const match = input.match(/node_modules\/((?:@[^/]+\/)?[^/]+)\//);
  if (match && !bundled.has(match[1])) {
    const meta = JSON.parse(readFileSync(join(EDITOR, 'node_modules', match[1], 'package.json'), 'utf8'));
    bundled.set(match[1], { version: meta.version, license: meta.license });
  }
}
const packages = Object.fromEntries([...bundled.entries()].sort(([a], [b]) => a.localeCompare(b)));

const style = [
  `@font-face{font-family:"JetBrains Mono";src:url(data:font/ttf;base64,${readFileSync(FONT).toString('base64')}) format("truetype");font-weight:400;font-style:normal;font-display:block}`,
  'html,body{margin:0;padding:0;height:100%;overflow:hidden;background:transparent;-webkit-text-size-adjust:100%;-webkit-tap-highlight-color:transparent;overscroll-behavior:none}',
  '#editor{height:100%}',
].join('');

const scriptHash = sha256(script, 'base64');
const csp = [
  "default-src 'none'",
  `script-src 'sha256-${scriptHash}'`,
  "style-src 'unsafe-inline'",
  'font-src data:',
  "base-uri 'none'",
  "form-action 'none'",
].join('; ');

const template = readFileSync(join(EDITOR, 'src', 'page.html'), 'utf8');
// Function replacers: the minified script contains `$` sequences that a
// string replacement would interpret.
const html = template
  .replace('{{CSP}}', () => csp)
  .replace('{{STYLE}}', () => style)
  .replace('{{SCRIPT}}', () => script);
const gzipBytes = gzipSync(html, { level: 9 }).length;

function licenceText(name) {
  for (const file of ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'license', 'LICENCE']) {
    const path = join(EDITOR, 'node_modules', name, file);
    if (existsSync(path)) return readFileSync(path, 'utf8').trim();
  }
  fail(`no licence file found for bundled package ${name}`);
}
const notices = Object.entries(packages)
  .map(([name, meta]) => `${name} ${meta.version} (${meta.license})\n\n${licenceText(name)}\n`)
  .join(`\n${'-'.repeat(72)}\n\n`);

const manifest = {
  schema: 1,
  protocol: 1,
  engine: 'codemirror',
  engineVersion,
  html: { file: 'editor.html', bytes: Buffer.byteLength(html), gzipBytes, sha256: sha256(html) },
  script: { bytes: Buffer.byteLength(script), cspHash: `sha256-${scriptHash}` },
  budget: { gzipBytesMax: GZIP_BUDGET },
  packages,
};

mkdirSync(OUT, { recursive: true });
writeFileSync(join(OUT, 'editor.html'), html);
writeFileSync(join(OUT, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
writeFileSync(join(OUT, 'NOTICES.txt'), notices);

const kib = (n) => `${(n / 1024).toFixed(1)} KiB`;
console.log(
  `editor.html: ${kib(manifest.html.bytes)} (${kib(gzipBytes)} gzipped, budget ${kib(GZIP_BUDGET)}); ` +
    `script ${kib(manifest.script.bytes)}; ${bundled.size} packages; sha256 ${manifest.html.sha256}`,
);
if (gzipBytes > GZIP_BUDGET) fail(`gzipped size ${gzipBytes} B exceeds the ${GZIP_BUDGET} B budget`);
