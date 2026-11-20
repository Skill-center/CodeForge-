/**
 * `file:line` links in a terminal's output (Phase 5 W4): what a run's errors
 * point at, as node's stack frames, Python's tracebacks, Ruby, Perl, bash
 * and compilers print them. A tap or a click on one sends `session.link`
 * with `path:line` or `path:line:column`; the app finds the file in the
 * workspace and opens it at that line. DOM-free, so
 * test/terminal_links.test.ts drives it with plain strings.
 */

export interface FileLink {
  /** Where the link is in the text: [start, end). */
  start: number;
  end: number;
  /** What `session.link` sends. */
  text: string;
}

/** A path with an extension: a letter starts the extension, so `127.0.0.1:80` is none. */
const PATH = String.raw`(?:\.{1,2}\/|\/|~\/)?(?:[\w.@+~-]+\/)*[\w.@+~-]*[\w@+~-]\.[A-Za-z][A-Za-z0-9]{0,7}`;

interface Pattern {
  regex: RegExp;
  /** Groups: the path, the line, the column (optional). */
  path: number;
  line: number;
  column?: number;
}

const PATTERNS: Pattern[] = [
  // Python: File "app.py", line 12, in <module>
  { regex: /File "([^"\n]+)", line (\d+)/g, path: 1, line: 2 },
  // Perl: died at script.pl line 3.
  { regex: new RegExp(String.raw`\bat (${PATH}) line (\d+)`, 'g'), path: 1, line: 2 },
  // bash: ./build.sh: line 3: foo: command not found
  { regex: new RegExp(String.raw`(${PATH}): line (\d+)`, 'g'), path: 1, line: 2 },
  // node, ruby, compilers: main.js:12:5, /abs/app.rb:3:in 'x', file:///a/b.mjs:7:1
  { regex: new RegExp(String.raw`(?:file:\/\/)?(${PATH}):(\d+)(?::(\d+))?`, 'g'), path: 1, line: 2, column: 3 },
];

/** At most this many characters are looked at: a link sits in a line, not a flood. */
export const MAX_LINK_TEXT = 4096;

/** The `file:line` links in [text], in order, none overlapping. */
export function findFileLinks(text: string): FileLink[] {
  const sample = text.length > MAX_LINK_TEXT ? text.slice(0, MAX_LINK_TEXT) : text;
  const found: FileLink[] = [];
  for (const pattern of PATTERNS) {
    pattern.regex.lastIndex = 0;
    for (let match = pattern.regex.exec(sample); match !== null; match = pattern.regex.exec(sample)) {
      const path = match[pattern.path];
      const line = Number(match[pattern.line]);
      if (!path || !Number.isSafeInteger(line) || line < 1) continue;
      const start = match.index;
      const end = start + match[0].length;
      // A web address is not a file: http://host.name:8080 and the like.
      if (!match[0].startsWith('file:') && /[a-z][a-z0-9+.-]*:\/*$/i.test(sample.slice(Math.max(0, start - 16), start))) {
        continue;
      }
      if (found.some((other) => start < other.end && other.start < end)) continue;
      const column = pattern.column === undefined ? undefined : match[pattern.column];
      found.push({ start, end, text: column ? `${path}:${line}:${column}` : `${path}:${line}` });
    }
  }
  return found.sort((a, b) => a.start - b.start);
}

/** The link at [offset] in [text], if one covers it. */
export function linkAt(text: string, offset: number): FileLink | undefined {
  return findFileLinks(text).find((link) => offset >= link.start && offset < link.end);
}
