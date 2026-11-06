/**
 * Shared pieces of the page builds: the production editor page
 * (tool/build.mjs) and the Phase 2 W3 benchmark pages (tool/build_bench.mjs).
 *
 * Every page is one self-contained HTML document: inline script, inline
 * style, inline fonts. Its Content-Security-Policy pins the script's SHA-256,
 * so the WebView itself refuses a tampered script, and the page makes no
 * requests at all.
 */
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import ts from 'typescript';

/** Licences the shipped pages may contain (mirrors tool/check_licenses.mjs). */
export const ALLOWED_LICENCES = new Set(['MIT', 'ISC', 'BSD-2-Clause', 'BSD-3-Clause', 'Apache-2.0', '0BSD']);

export const sha256 = (data, encoding = 'hex') => createHash('sha256').update(data).digest(encoding);

/**
 * True when an SPDX expression can be satisfied with allowed licences: a
 * single identifier, or an OR-list with at least one allowed choice
 * ("(MPL-2.0 OR Apache-2.0)" is used under Apache-2.0). AND/WITH
 * expressions are not accepted.
 */
export function licenceAllowed(expression) {
  if (typeof expression !== 'string') return false;
  const bare = expression.trim().replace(/^\((.*)\)$/, '$1');
  if (/\s(AND|WITH)\s/.test(bare)) return false;
  return bare.split(/\s+OR\s+/).some((id) => ALLOWED_LICENCES.has(id.trim()));
}

/**
 * Inside a <script> element the HTML tokenizer treats "<!--" specially
 * (script data escaped state), so it must not appear in an inline script.
 * esbuild already escapes "</script"; this rewrites "<!--" as "\x3C!--",
 * which is exactly equivalent inside string, untagged template and regular
 * expression literals (also with the u flag). The bundle is parsed to prove
 * every occurrence is inside such a literal; anything else fails the build.
 */
export function escapeCommentOpeners(code, fail) {
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

/** Escapes the bundle for an inline <script> and proves nothing can end it early. */
export function inlineScript(code, fail) {
  const script = escapeCommentOpeners(code.trimEnd(), fail);
  if (/<\/script/i.test(script) || script.includes('<!--')) {
    fail('the bundle contains a sequence that would end an inline <script>');
  }
  return script;
}

/** Inline CSS must not be able to end its <style> element either. */
export function inlineStyle(css, fail) {
  if (/<\/style/i.test(css)) fail('the stylesheet contains a sequence that would end an inline <style>');
  return css;
}

/**
 * The npm packages in a bundle, sorted by name. By default every package
 * esbuild read counts; with `emittedOnly`, only packages that contributed
 * bytes to an output (tree-shaken imports drop out).
 */
export function bundledPackages(metafile, editorDir, { emittedOnly = false } = {}) {
  const bundled = new Map();
  const inputs = emittedOnly
    ? Object.values(metafile.outputs).flatMap((output) =>
        Object.entries(output.inputs)
          .filter(([, info]) => info.bytesInOutput > 0)
          .map(([input]) => input),
      )
    : Object.keys(metafile.inputs);
  for (const input of inputs) {
    const match = input.match(/node_modules\/((?:@[^/]+\/)?[^/]+)\//);
    if (match && !bundled.has(match[1])) {
      const meta = JSON.parse(readFileSync(join(editorDir, 'node_modules', match[1], 'package.json'), 'utf8'));
      bundled.set(match[1], { version: meta.version, license: meta.license });
    }
  }
  return Object.fromEntries([...bundled.entries()].sort(([a], [b]) => a.localeCompare(b)));
}

export function licenceText(name, editorDir, fail) {
  for (const file of ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'license', 'LICENCE']) {
    const path = join(editorDir, 'node_modules', name, file);
    if (existsSync(path)) return readFileSync(path, 'utf8').trim();
  }
  fail(`no licence file found for bundled package ${name}`);
  return '';
}

/**
 * NOTICES.txt: one section per package, headed "name version (licence)",
 * sections divided by a line of 72 dashes (parsed by the app's
 * parseEditorNotices). `extra` appends text to a package's section, such as
 * a third-party notices file the package itself ships.
 */
export function noticesFor(packages, editorDir, fail, extra = {}) {
  return Object.entries(packages)
    .map(([name, meta]) => {
      const more = extra[name] ? `\n\n${extra[name].trim()}` : '';
      return `${name} ${meta.version} (${meta.license})\n\n${licenceText(name, editorDir, fail)}${more}\n`;
    })
    .join(`\n${'-'.repeat(72)}\n\n`);
}

export function contentSecurityPolicy(scriptHash) {
  return [
    "default-src 'none'",
    `script-src 'sha256-${scriptHash}'`,
    "style-src 'unsafe-inline'",
    'font-src data:',
    "base-uri 'none'",
    "form-action 'none'",
  ].join('; ');
}

/** The editor font, embedded so the page needs no font request. */
export function editorFontFace(fontPath) {
  return `@font-face{font-family:"JetBrains Mono";src:url(data:font/ttf;base64,${readFileSync(fontPath).toString('base64')}) format("truetype");font-weight:400;font-style:normal;font-display:block}`;
}

/**
 * Fills a page template. Function replacers: minified code contains `$`
 * sequences that a string replacement would interpret.
 */
export function fillTemplate(template, values) {
  let html = template;
  for (const [key, value] of Object.entries(values)) {
    const token = `{{${key}}}`;
    if (!html.includes(token)) throw new Error(`template has no ${token}`);
    html = html.replace(token, () => value);
  }
  return html;
}
