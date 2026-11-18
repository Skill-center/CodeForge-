/**
 * THIRD_PARTY_NOTICES.md's section for the editor page (Phase 4 W7): every
 * runtime package that can end up in the shipped bundle, from
 * package-lock.json, with its version and licence. Dev-only tools are not
 * distributed and are left out, as in tool/check_licenses.mjs. The licence
 * texts themselves ship in the app as assets/editor/NOTICES.txt, written by
 * tool/build.mjs, and appear in the app's licence page (About).
 *
 *   node tool/notices.mjs          rewrite the section
 *   node tool/notices.mjs --check  fail if it is stale (the editor job)
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const EDITOR = join(dirname(fileURLToPath(import.meta.url)), '..');
const NOTICES = join(EDITOR, '..', 'THIRD_PARTY_NOTICES.md');
const BEGIN = '<!-- editor:begin -->';
const END = '<!-- editor:end -->';

const lock = JSON.parse(readFileSync(join(EDITOR, 'package-lock.json'), 'utf8'));
const rows = [];
for (const [path, entry] of Object.entries(lock.packages)) {
  if (!path.startsWith('node_modules/') || entry.dev || entry.devOptional) continue;
  const name = path.slice(path.lastIndexOf('node_modules/') + 'node_modules/'.length);
  rows.push({ name, version: entry.version, license: entry.license ?? 'UNKNOWN' });
}
rows.sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version));

const tally = new Map();
for (const row of rows) tally.set(row.license, (tally.get(row.license) ?? 0) + 1);
const counts = [...tally.entries()]
  .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
  .map(([license, count]) => `${license} ${count}`)
  .join(', ');

const section = [
  BEGIN,
  '<!-- Written by editor/tool/notices.mjs from editor/package-lock.json. Do not edit by hand: CI checks it. -->',
  '',
  `**${rows.length} packages** can end up in the editor page's bundle: ${counts}. Their licence texts ship in the app as \`assets/editor/NOTICES.txt\` and appear in its licence page.`,
  '',
  '| Package | Version | Licence |',
  '|---|---|---|',
  ...rows.map((row) => `| ${row.name} | ${row.version} | ${row.license} |`),
  '',
  END,
].join('\n');

const text = readFileSync(NOTICES, 'utf8');
const begin = text.indexOf(BEGIN);
const end = text.indexOf(END);
if (begin < 0 || end < begin || text.indexOf(BEGIN, begin + 1) >= 0) {
  console.error(`notices: ${NOTICES} needs exactly one ${BEGIN} ... ${END} section`);
  process.exit(2);
}
const updated = text.slice(0, begin) + section + text.slice(end + END.length);
if (process.argv.includes('--check')) {
  if (updated !== text) {
    console.error('notices: the editor section of THIRD_PARTY_NOTICES.md is stale: run node tool/notices.mjs');
    process.exit(1);
  }
  console.log(`notices: the editor section is current (${rows.length} packages)`);
} else {
  writeFileSync(NOTICES, updated);
  console.log(`notices: wrote the editor section (${rows.length} packages)`);
}
