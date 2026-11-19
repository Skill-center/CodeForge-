/**
 * Builds the terminal page (Phase 5 W3): one self-contained HTML document at
 * app/assets/terminal/terminal.html, in the editor page's way (tool/build.mjs,
 * tool/page_kit.mjs): inline script, inline style (xterm.js's stylesheet and
 * the bundled monospace font), a Content-Security-Policy that pins the
 * script's SHA-256, and no requests at all.
 *
 * Outputs (gitignored, rebuilt by CI): terminal.html, manifest.json,
 * NOTICES.txt. Deterministic: same inputs, same bytes.
 */
import { build, transform } from 'esbuild';
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
  inlineStyle,
  noticesFor,
  sha256,
} from './page_kit.mjs';

const EDITOR = join(dirname(fileURLToPath(import.meta.url)), '..');
const REPO = join(EDITOR, '..');
const OUT = join(REPO, 'app', 'assets', 'terminal');
const FONT = join(REPO, 'app', 'assets', 'fonts', 'JetBrainsMono_400Regular.ttf');
/**
 * The terminal page's budget, gzipped. The page is loaded from a string at
 * every start of its WebView, like the editor's (ADR-0004: 1.5 MiB). The
 * terminal's is set at about one and a half times its size at W3 (174 KiB),
 * so that growth is a decision, not a drift.
 */
export const GZIP_BUDGET = 256 * 1024;

function fail(message) {
  console.error(`terminal build failed: ${message}`);
  process.exit(1);
}

const pkg = JSON.parse(readFileSync(join(EDITOR, 'package.json'), 'utf8'));
const engineVersion = pkg.dependencies['@xterm/xterm'];
if (!engineVersion) fail('@xterm/xterm is not a dependency');

const result = await build({
  absWorkingDir: EDITOR,
  entryPoints: ['src/terminal/main.ts'],
  bundle: true,
  minify: true,
  format: 'iife',
  platform: 'browser',
  target: ['es2020', 'chrome87'],
  charset: 'utf8',
  legalComments: 'none', // licence texts ship in NOTICES.txt instead
  define: { __XTERM_VERSION__: JSON.stringify(engineVersion) },
  metafile: true,
  write: false,
  logLevel: 'warning',
});
const script = inlineScript(result.outputFiles[0].text, fail);
const packages = bundledPackages(result.metafile, EDITOR);
if (!packages['@xterm/xterm']) fail('the bundle does not contain @xterm/xterm');

// xterm.js's own stylesheet (its licence is in NOTICES.txt), minified.
const xtermCss = await transform(readFileSync(join(EDITOR, 'node_modules', '@xterm', 'xterm', 'css', 'xterm.css'), 'utf8'), {
  loader: 'css',
  minify: true,
  legalComments: 'none',
});

const style = inlineStyle(
  [
    editorFontFace(FONT),
    xtermCss.code.trim(),
    'html,body{margin:0;padding:0;height:100%;overflow:hidden;background:transparent;-webkit-text-size-adjust:100%;-webkit-tap-highlight-color:transparent;overscroll-behavior:none}',
    '#terminals{position:fixed;inset:0;touch-action:none}',
    '.session{position:absolute;inset:0}',
    '.session .xterm{height:100%;box-sizing:border-box;padding:4px 2px 0 6px}',
  ].join(''),
  fail,
);

const scriptHash = sha256(script, 'base64');
const csp = contentSecurityPolicy(scriptHash);

const template = readFileSync(join(EDITOR, 'src', 'terminal', 'page.html'), 'utf8');
const html = fillTemplate(template, { CSP: csp, STYLE: style, SCRIPT: script });
const gzipBytes = gzipSync(html, { level: 9 }).length;

const notices = noticesFor(packages, EDITOR, fail);

const manifest = {
  schema: 1,
  protocol: 1,
  engine: 'xterm',
  engineVersion,
  html: { file: 'terminal.html', bytes: Buffer.byteLength(html), gzipBytes, sha256: sha256(html) },
  script: { bytes: Buffer.byteLength(script), cspHash: `sha256-${scriptHash}` },
  budget: { gzipBytesMax: GZIP_BUDGET },
  packages,
};

mkdirSync(OUT, { recursive: true });
writeFileSync(join(OUT, 'terminal.html'), html);
writeFileSync(join(OUT, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
writeFileSync(join(OUT, 'NOTICES.txt'), notices);

const kib = (n) => `${(n / 1024).toFixed(1)} KiB`;
console.log(
  `terminal.html: ${kib(manifest.html.bytes)} (${kib(gzipBytes)} gzipped, budget ${kib(GZIP_BUDGET)}); ` +
    `script ${kib(manifest.script.bytes)}; ${Object.keys(packages).length} packages; sha256 ${manifest.html.sha256}`,
);
if (gzipBytes > GZIP_BUDGET) fail(`gzipped size ${gzipBytes} B exceeds the ${GZIP_BUDGET} B budget`);
