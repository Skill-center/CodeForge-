/**
 * Licence gate for the editor's runtime dependencies (the packages that can
 * end up in the shipped bundle). Dev-only tools are not distributed and are
 * not checked. Mirrors app/tool/check_licenses.dart for pub packages.
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ALLOWED = new Set(['MIT', 'ISC', 'BSD-2-Clause', 'BSD-3-Clause', 'Apache-2.0', '0BSD']);
const EDITOR = join(dirname(fileURLToPath(import.meta.url)), '..');
const lock = JSON.parse(readFileSync(join(EDITOR, 'package-lock.json'), 'utf8'));

const rows = [];
const bad = [];
for (const [path, entry] of Object.entries(lock.packages)) {
  if (!path.startsWith('node_modules/') || entry.dev || entry.devOptional) continue;
  const name = path.slice(path.lastIndexOf('node_modules/') + 'node_modules/'.length);
  const license = entry.license ?? 'UNKNOWN';
  rows.push(`${name}@${entry.version} ${license}`);
  if (!ALLOWED.has(license)) bad.push(`${name}@${entry.version}: ${license}`);
}
console.log(`licence gate: ${rows.length} runtime packages checked against ${[...ALLOWED].join(', ')}`);
if (bad.length > 0) {
  console.error(`disallowed or missing licences:\n  ${bad.join('\n  ')}`);
  process.exit(1);
}
