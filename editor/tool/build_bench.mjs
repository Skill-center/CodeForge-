/**
 * Builds the Phase 2 W3 engine benchmark pages (docs/phases/PHASE_2_PLAN.md,
 * W3) into app/assets/editor_bench/:
 *   codemirror.html, monaco.html  one self-contained document per engine,
 *                                 built and loaded exactly like the
 *                                 production page (inline everything, CSP
 *                                 pinning the script hash)
 *   manifest.json                 per-page size, gzip size, sha256, packages
 *   NOTICES.txt                   licences of everything either page bundles
 *
 * Only non-release builds bundle these pages: CI runs this script for the
 * phase gate's debug APK and the phone profile APK, and the directory holds
 * just its README otherwise (it is gitignored apart from that file).
 * Deterministic: same inputs, same bytes.
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
  inlineStyle,
  licenceAllowed,
  noticesFor,
  sha256,
} from './page_kit.mjs';

const EDITOR = join(dirname(fileURLToPath(import.meta.url)), '..');
const REPO = join(EDITOR, '..');
const OUT = join(REPO, 'app', 'assets', 'editor_bench');
const FONT = join(REPO, 'app', 'assets', 'fonts', 'JetBrainsMono_400Regular.ttf');
/** The ADR-0004 shipped-size budget, reported per engine (not enforced here). */
const GZIP_BUDGET = 1.5 * 1024 * 1024;

function fail(message) {
  console.error(`bench build failed: ${message}`);
  process.exit(1);
}

const pkg = JSON.parse(readFileSync(join(EDITOR, 'package.json'), 'utf8'));
const ENGINES = {
  codemirror: { entry: 'bench/codemirror.ts', version: pkg.dependencies['@codemirror/view'] },
  monaco: { entry: 'bench/monaco.ts', version: pkg.devDependencies['monaco-editor'] },
};
if (!ENGINES.codemirror.version || !ENGINES.monaco.version) fail('engine versions missing from package.json');

const template = readFileSync(join(EDITOR, 'bench', 'page.html'), 'utf8');
const baseStyle = [
  editorFontFace(FONT),
  'html,body{margin:0;padding:0;height:100%;overflow:hidden;background:#0F1115;-webkit-text-size-adjust:100%;-webkit-tap-highlight-color:transparent;overscroll-behavior:none}',
  '#editor{height:100%}',
].join('');

const manifest = { schema: 1, budget: { gzipBytesMax: GZIP_BUDGET }, pages: {} };
const allPackages = {};
mkdirSync(OUT, { recursive: true });

for (const [engine, { entry, version }] of Object.entries(ENGINES)) {
  const result = await build({
    absWorkingDir: EDITOR,
    entryPoints: [entry],
    outdir: 'bench-out', // names the in-memory outputs; nothing is written
    bundle: true,
    minify: true,
    format: 'iife',
    platform: 'browser',
    target: ['es2020', 'chrome87'],
    charset: 'utf8',
    legalComments: 'none', // licence texts ship in NOTICES.txt instead
    loader: { '.ttf': 'dataurl' }, // Monaco's codicon font, inlined (CSP font-src data:)
    define: { __BENCH_ENGINE_VERSION__: JSON.stringify(version), __ENGINE_VERSION__: JSON.stringify(version) },
    metafile: true,
    write: false,
    logLevel: 'error',
  });
  const js = result.outputFiles.find((f) => f.path.endsWith('.js'));
  const css = result.outputFiles.find((f) => f.path.endsWith('.css'));
  if (!js) fail(`${engine}: esbuild produced no script`);
  const script = inlineScript(js.text, fail);
  const style = inlineStyle(baseStyle + (css ? css.text.trim() : ''), fail);
  const scriptHash = sha256(script, 'base64');
  const html = fillTemplate(template, {
    CSP: contentSecurityPolicy(scriptHash),
    TITLE: `codeforge-bench:${engine}`,
    STYLE: style,
    SCRIPT: script,
  });
  const packages = bundledPackages(result.metafile, EDITOR, { emittedOnly: true });
  for (const [name, meta] of Object.entries(packages)) {
    if (!licenceAllowed(meta.license)) fail(`${engine}: ${name}@${meta.version} has licence ${meta.license}`);
    allPackages[name] = meta;
  }
  const file = `${engine}.html`;
  writeFileSync(join(OUT, file), html);
  manifest.pages[engine] = {
    file,
    engineVersion: version,
    bytes: Buffer.byteLength(html),
    gzipBytes: gzipSync(html, { level: 9 }).length,
    scriptBytes: Buffer.byteLength(script),
    styleBytes: Buffer.byteLength(style),
    sha256: sha256(html),
    cspHash: `sha256-${scriptHash}`,
    packages,
  };
}

const sortedPackages = Object.fromEntries(Object.entries(allPackages).sort(([a], [b]) => a.localeCompare(b)));
const monacoNotices = readFileSync(join(EDITOR, 'node_modules', 'monaco-editor', 'ThirdPartyNotices.txt'), 'utf8');
writeFileSync(
  join(OUT, 'NOTICES.txt'),
  noticesFor(sortedPackages, EDITOR, fail, { 'monaco-editor': `Third-party notices shipped with monaco-editor:\n\n${monacoNotices}` }),
);
writeFileSync(join(OUT, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);

const kib = (n) => `${(n / 1024).toFixed(1)} KiB`;
for (const [engine, page] of Object.entries(manifest.pages)) {
  console.log(
    `${page.file}: ${kib(page.bytes)} (${kib(page.gzipBytes)} gzipped, ADR budget ${kib(GZIP_BUDGET)}); ` +
      `${Object.keys(page.packages).length} package${Object.keys(page.packages).length === 1 ? '' : 's'}; ${engine} ${page.engineVersion}; sha256 ${page.sha256}`,
  );
}
