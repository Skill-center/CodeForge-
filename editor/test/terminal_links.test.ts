import { describe, expect, it } from 'vitest';

import { findFileLinks, linkAt } from '../src/terminal/links';

const texts = (line: string) => findFileLinks(line).map((link) => link.text);

describe('file:line links in a run’s output', () => {
  it('finds node’s stack frames, with or without a function, and file URLs', () => {
    expect(texts('    at main (/data/data/dev.codeforge.app/files/workspaces/demo/main.js:12:5)')).toEqual([
      '/data/data/dev.codeforge.app/files/workspaces/demo/main.js:12:5',
    ]);
    expect(texts('    at file:///data/x/src/app.mjs:3:7')).toEqual(['/data/x/src/app.mjs:3:7']);
    expect(texts('/w/demo/main.js:4')).toEqual(['/w/demo/main.js:4']);
    expect(texts('SyntaxError in ./src/util.js:9:1 and lib/a.test.ts:2:3')).toEqual([
      './src/util.js:9:1',
      'lib/a.test.ts:2:3',
    ]);
  });

  it('finds Python’s, Ruby’s, Perl’s and bash’s ways of saying it', () => {
    expect(texts('  File "/w/demo/app.py", line 12, in <module>')).toEqual(['/w/demo/app.py:12']);
    expect(texts('  File "my scripts/run me.py", line 3')).toEqual(['my scripts/run me.py:3']);
    expect(texts("app.rb:3:in 'greet': undefined method")).toEqual(['app.rb:3']);
    expect(texts('Died at report.pl line 7.')).toEqual(['report.pl:7']);
    expect(texts('./build.sh: line 3: frobnicate: command not found')).toEqual(['./build.sh:3']);
  });

  it('leaves out what only looks like one', () => {
    expect(texts('Listening on http://localhost:3000 and http://example.com:8080/x')).toEqual([]);
    expect(texts('connect to 127.0.0.1:5432')).toEqual([]);
    expect(texts('at 12:30:45 the build ended')).toEqual([]);
    expect(texts('version 1.2:3')).toEqual([]);
    expect(texts('main.js:0')).toEqual([]);
  });

  it('says which link an offset is in', () => {
    const line = 'Error at main.js:4:2 then util.js:8';
    expect(linkAt(line, line.indexOf('main'))?.text).toBe('main.js:4:2');
    expect(linkAt(line, line.indexOf('util.js') + 8)?.text).toBe('util.js:8');
    expect(linkAt(line, line.indexOf('util.js') + 9)).toBeUndefined();
    expect(linkAt(line, 0)).toBeUndefined();
  });
});
