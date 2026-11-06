import type { ChangeSetJson } from './types';

export class ChangeApplyError extends Error {}

/** Document lengths (UTF-16 code units) before and after a change set. */
export function changeLengths(changes: ChangeSetJson): { before: number; after: number } {
  let before = 0;
  let after = 0;
  for (const part of changes) {
    if (typeof part === 'number') {
      before += part;
      after += part;
    } else {
      before += part[0];
      const lines = part.slice(1) as string[];
      if (lines.length > 0) after += lines.reduce((sum, line) => sum + line.length, 0) + lines.length - 1;
    }
  }
  return { before, after };
}

/**
 * Applies CodeMirror change-set JSON to plain text. This is the reference
 * for the host's shadow buffer (app/lib/services/editor/), which must behave
 * identically on the shared fixtures in test/fixtures/changes/.
 */
export function applyChanges(text: string, changes: ChangeSetJson): string {
  const out: string[] = [];
  let pos = 0;
  for (const part of changes) {
    if (typeof part === 'number') {
      if (pos + part > text.length) throw new ChangeApplyError('change set is longer than the document');
      out.push(text.slice(pos, pos + part));
      pos += part;
    } else {
      const [deleted, ...lines] = part;
      if (pos + deleted > text.length) throw new ChangeApplyError('change set is longer than the document');
      pos += deleted;
      if (lines.length > 0) out.push(lines.join('\n'));
    }
  }
  if (pos !== text.length) throw new ChangeApplyError('change set is shorter than the document');
  return out.join('');
}
