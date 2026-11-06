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
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';
import {
  bundledPackages,
  contentSecurityPolicy,
  editorFontFace,
  fillTemplate,
  inlineScript,
  noticesFor,
  sha256,
} from './page_kit.mjs';

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
// Inline-script escaping, CSP, package and licence collection: page_kit.mjs.
const script = inlineScript(result.outputFiles[0].text, fail);
const packages = bundledPackages(result.metafile, EDITOR);

const style = [
  editorFontFace(FONT),
  'html,body{margin:0;padding:0;height:100%;overflow:hidden;background:transparent;-webkit-text-size-adjust:100%;-webkit-tap-highlight-color:transparent;overscroll-behavior:none}',
  '#editor{height:100%}',
].join('');

const scriptHash = sha256(script, 'base64');
const csp = contentSecurityPolicy(scriptHash);

const template = readFileSync(join(EDITOR, 'src', 'page.html'), 'utf8');
const html = fillTemplate(template, { CSP: csp, STYLE: style, SCRIPT: script });
const gzipBytes = gzipSync(html, { level: 9 }).length;

const notices = noticesFor(packages, EDITOR, fail);

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
    `script ${kib(manifest.script.bytes)}; ${Object.keys(packages).length} packages; sha256 ${manifest.html.sha256}`,
);
if (gzipBytes > GZIP_BUDGET) fail(`gzipped size ${gzipBytes} B exceeds the ${GZIP_BUDGET} B budget`);
