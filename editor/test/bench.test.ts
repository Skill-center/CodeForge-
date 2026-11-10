import { createHash } from 'node:crypto';

import { describe, expect, it } from 'vitest';

import cases from '../bench/composition_cases.json';
import { BENCH_LANGUAGES, STUB_COMPLETIONS } from '../bench/engine';
import { largeJavaScript, SAMPLES, TYPING_TEXT } from '../bench/samples';
import { firstDifference, frameSummary, percentile, summarize } from '../bench/stats';

describe('benchmark statistics', () => {
  it('uses nearest-rank percentiles', () => {
    const sorted = Array.from({ length: 20 }, (_, i) => i + 1);
    expect(percentile(sorted, 0.5)).toBe(10);
    expect(percentile(sorted, 0.95)).toBe(19);
    expect(percentile(sorted, 1)).toBe(20);
    expect(percentile([], 0.5)).toBe(0);
    expect(percentile([7], 0.95)).toBe(7);
  });

  it('summarizes unsorted samples, rounded to 0.1 ms', () => {
    expect(summarize([3.04, 1, 2, 10.06])).toEqual({ count: 4, p50Ms: 2, p95Ms: 10.1, maxMs: 10.1, meanMs: 4 });
    expect(summarize([])).toEqual({ count: 0, p50Ms: 0, p95Ms: 0, maxMs: 0, meanMs: 0 });
  });

  it('counts frames over the jank threshold', () => {
    const intervals = [...Array<number>(95).fill(16.7), 33, 40, 50, 16.7, 32];
    const summary = frameSummary(intervals);
    expect(summary.frames).toBe(100);
    expect(summary.slowFrames).toBe(3); // 32 ms itself is not slow
    expect(summary.slowFramePct).toBe(3);
    expect(summary.maxFrameMs).toBe(50);
  });

  it('finds the first differing UTF-16 unit', () => {
    expect(firstDifference('hello', 'hello')).toBe(-1);
    expect(firstDifference('hello', 'help')).toBe(3);
    expect(firstDifference('ab', 'abc')).toBe(2);
    expect(firstDifference('😀', '😃')).toBe(1);
  });
});

describe('benchmark documents', () => {
  it('has a sample for every benchmark language', () => {
    for (const language of BENCH_LANGUAGES) expect(SAMPLES[language].length).toBeGreaterThan(100);
  });

  it('types exactly 60 characters without brackets or quotes', () => {
    expect(TYPING_TEXT).toHaveLength(60);
    expect(TYPING_TEXT).not.toMatch(/[()[\]{}'"`]/);
  });

  it('generates the large file deterministically, cut at a line end', () => {
    const text = largeJavaScript(1024 * 1024);
    expect(text.length).toBeGreaterThanOrEqual(1024 * 1024);
    expect(text.length).toBeLessThan(1024 * 1024 + 200);
    expect(text.endsWith('\n')).toBe(true);
    expect(largeJavaScript(1024 * 1024)).toBe(text);
    expect(text).not.toMatch(/[^\x09\x0a\x20-\x7e]/); // ASCII: characters equal bytes
  });

  it('generates the large-file gate\'s files, pinned by SHA-256', () => {
    // The app's port (app/lib/core/editor/large_samples.dart) writes the
    // same bytes, for the gate and for Settings → Developer → Create large
    // test files; app/test/core/large_samples_test.dart pins the same.
    const pins: Array<[number, number, string]> = [
      [524160, 524164, 'afc78e8f04e8ce74613755f4459287c4c10223d0feb003fe8bda3ebd711c357e'],
      [1048576, 1048614, 'bdc70485be76830f76676be3fa652f55f68cbd906f502f3dddfd6c7d31928055'],
      [5242880, 5242929, '909e9b7c99b1d21ac5da67c9b2b440e4930341b044602c407105dd6b6068f756'],
      [10485632, 10485681, 'c21701a8065528b5562ea35f2d86f1661bf7e605dde6351ad66c2d6ea8e51c64'],
    ];
    for (const [target, length, digest] of pins) {
      const text = largeJavaScript(target);
      expect(text.length).toBe(length);
      expect(createHash('sha256').update(text, 'utf8').digest('hex')).toBe(digest);
    }
  });

  it('offers the same stub completions to both engines', () => {
    expect(new Set(STUB_COMPLETIONS).size).toBe(STUB_COMPLETIONS.length);
    expect(STUB_COMPLETIONS.every((word) => word.startsWith('co'))).toBe(true);
  });
});

describe('composition cases', () => {
  it('are well formed', () => {
    const ids = new Set<string>();
    for (const testCase of cases.cases) {
      expect(ids.has(testCase.id)).toBe(false);
      ids.add(testCase.id);
      expect(testCase.expected.length).toBeGreaterThan(0);
      for (const [kind, value] of testCase.steps) {
        expect(['compose', 'commit', 'insert', 'key']).toContain(kind);
        expect(typeof value).toBe('string');
      }
    }
    expect(ids).toContain('pinyin');
    expect(ids).toContain('emoji');
  });

  it('cover CJK, Hangul and multi-code-point emoji', () => {
    const expected = cases.cases.map((c) => c.expected).join('');
    expect(expected).toMatch(/\p{Script=Han}/u);
    expect(expected).toMatch(/\p{Script=Hangul}/u);
    expect(expected).toContain('\u200d'); // a ZWJ sequence
    expect(expected).toMatch(/\p{Emoji_Modifier}/u);
  });
});
