// @vitest-environment node
import { describe, expect, it } from 'vitest';

import { keyFor, pressKey, totalPssKb, webViewForwarder, listTargets } from '../tool/cdp_kit.mjs';
import { METHOD, newestRequest, parseRequest } from '../tool/large_cdp.mjs';

describe('large-file driver requests (tool/large_cdp.mjs)', () => {
  it('parses the requests the test prints', () => {
    expect(parseRequest('LARGEGATE 1762300000000.1 prepare large_1mb.js memory')).toEqual({
      id: '1762300000000.1',
      kind: 'prepare',
      words: ['large_1mb.js', 'memory'],
    });
    expect(parseRequest('LARGEGATE 17.2 measure large_5mb.txt 5242929 174624 the quick brown fox')).toEqual({
      id: '17.2',
      kind: 'measure',
      words: ['large_5mb.txt', '5242929', '174624', 'the', 'quick', 'brown', 'fox'],
    });
    expect(parseRequest('LARGEGATE 17.9 done')).toEqual({ id: '17.9', kind: 'done', words: [] });
  });

  it('accepts a log prefix and trailing blanks, and nothing that is not a request', () => {
    expect(parseRequest('11-05 10:00:00.000  1234  1250 I flutter : LARGEGATE 3.4 done  ')?.id).toBe('3.4');
    expect(parseRequest('LARGEGATE 3 done')).toBeNull();
    expect(parseRequest('LARGEGATE 3.4 Done')).toBeNull();
    expect(parseRequest('LARGEGATE 3.4')).toBeNull();
    expect(parseRequest('flutter: large-files: large_1mb.js opened in 900 ms')).toBeNull();
    expect(parseRequest('')).toBeNull();
  });

  it('answers the newest request in a log dump', () => {
    const dump = [
      'LARGEGATE 5.1 prepare large_1mb.js memory',
      'some other line',
      'LARGEGATE 5.2 measure large_1mb.js 1048614 35107 abc',
      'CODEFORGE_LARGE_JSON 1/1 {}',
      '',
    ].join('\n');
    expect(newestRequest(dump)?.id).toBe('5.2');
    expect(newestRequest('nothing here\n')).toBeNull();
    expect(newestRequest('')).toBeNull();
  });

  it('describes its method for the report', () => {
    expect(Object.keys(METHOD).sort()).toEqual(['longTasks', 'memory', 'open', 'scroll', 'typing']);
  });
});

describe('DevTools kit (tool/cdp_kit.mjs)', () => {
  it('maps letters, the space and Backspace to key events', () => {
    expect(keyFor('a')).toEqual({ key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65 });
    expect(keyFor(' ')).toEqual({ key: ' ', code: 'Space', windowsVirtualKeyCode: 32 });
    expect(keyFor('Backspace')).toEqual({ key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 });
  });

  it('presses a key as a down with its text and an up', async () => {
    const sent = [];
    const cdp = { send: async (method, params) => sent.push([method, params.type, params.text ?? null]) };
    await pressKey(cdp, 'q');
    await pressKey(cdp, 'Backspace');
    expect(sent).toEqual([
      ['Input.dispatchKeyEvent', 'keyDown', 'q'],
      ['Input.dispatchKeyEvent', 'keyUp', null],
      ['Input.dispatchKeyEvent', 'rawKeyDown', null],
      ['Input.dispatchKeyEvent', 'keyUp', null],
    ]);
  });

  it('reads TOTAL PSS from either dumpsys meminfo layout', () => {
    expect(totalPssKb('...\n           TOTAL PSS:   123456            TOTAL RSS:   200000\n')).toBe(123456);
    expect(totalPssKb('** MEMINFO in pid 42 **\n        TOTAL    98765    90000\n')).toBe(98765);
    expect(totalPssKb('No process found for: dev.codeforge.app\n')).toBeNull();
  });

  it('has nothing to forward without adb, and no targets where nothing listens', async () => {
    const ensureForward = webViewForwarder({ port: 1 }, () => {});
    expect(await ensureForward()).toBe(true);
    expect(await listTargets(1)).toEqual([]);
  });
});
