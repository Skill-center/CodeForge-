// @vitest-environment node
import { describe, expect, it } from 'vitest';

import { BUDGETS, buildReport, check, median, reassemble, renderText } from '../tool/large_report.mjs';

const chunks = (json, size, prefix = '01:23 +0: ') => {
  const parts = Math.ceil(json.length / size);
  return Array.from(
    { length: parts },
    (_, i) => `${prefix}CODEFORGE_LARGE_JSON ${i + 1}/${parts} ${json.slice(i * size, (i + 1) * size)}`,
  );
};

const itest = {
  schema: 1,
  build: 'debug',
  typed: 'abc',
  files: [
    { file: 'large_1mb.js', language: 'javascript', chars: 1048614, lines: 35107, openMs: 900, openReturnMs: 400, pageAnswerMs: 500, saveMs: 120 },
    { file: 'large_1mb.txt', language: 'plaintext', chars: 1048614, lines: 35107, openMs: 700, openReturnMs: 380, pageAnswerMs: 320, saveMs: 110 },
  ],
  store: {
    pragma: { NORMAL: 1, FULL: 2 },
    snapshots: [{ mib: 1, chars: 1048614, digestMs: 30, normalMs: [40, 20, 30], fullMs: [60, 50, 55] }],
    changes: { count: 4, normalMs: [1, 2, 3, 4], fullMs: [5, 6, 7, 8] },
  },
  leftOpen: 'large_1mb.js',
};

const cdp = {
  userAgent: 'Mozilla/5.0 (Linux; Android 16) Chrome/140',
  method: { scroll: 's' },
  files: {
    'large_1mb.js': {
      prepare: { memory: { appPssMB: 150, rendererPssMB: 60, totalPssMB: 210 } },
      measure: {
        open: { type: 'doc.open', processMs: 72.3, paintedMs: 119.3 },
        openLongTasks: { supported: true, count: 2, totalMs: 201, maxMs: 101 },
        dom: { lines: 93 },
        scroll: { slowFramePct: 9.5 },
        typing: { p95Ms: 31.9 },
        memory: { totalPssMB: 251 },
      },
    },
  },
  errors: [{ request: '7.4', kind: 'measure', error: 'no "CodeForge editor" page' }],
};

describe('large-file report (tool/large_report.mjs)', () => {
  it('reassembles the chunks of the latest complete attempt', () => {
    const first = JSON.stringify({ attempt: 1, pad: 'x'.repeat(50) });
    const second = JSON.stringify({ attempt: 2, pad: 'y'.repeat(50) });
    const text = [...chunks(first, 20).slice(0, 2), 'noise', ...chunks(second, 20), ''].join('\n');
    expect(reassemble(text)).toEqual({ attempt: 2, pad: 'y'.repeat(50) });
  });

  it('gives nothing for missing, incomplete or broken reports', () => {
    expect(reassemble(null)).toBeNull();
    expect(reassemble('no report here')).toBeNull();
    expect(reassemble(chunks(JSON.stringify({ a: 'b'.repeat(40) }), 10).slice(1).join('\n'))).toBeNull();
    expect(reassemble('CODEFORGE_LARGE_JSON 1/1 {broken')).toBeNull();
  });

  it('takes medians and checks budgets, inclusive or exclusive', () => {
    expect(median([30, 10, 20])).toBe(20);
    expect(median([4, 1, 3, 2])).toBe(2.5);
    expect(median([])).toBeNull();
    expect(median(undefined)).toBeNull();
    expect(check('typingP95Ms', 32)).toEqual({ value: 32, budget: 32, within: true });
    expect(check('scrollSlowFramePct', 5)).toEqual({ value: 5, budget: 5, within: false });
    expect(check('scrollSlowFramePct', 4.9).within).toBe(true);
    expect(check('totalPssMB', undefined)).toEqual({ value: null, budget: BUDGETS.totalPssMB.max, within: null });
  });

  it('merges the app, the page and the release build into one report', () => {
    const report = buildReport({
      itest,
      cdp,
      release: { memory: { appPssMB: 120, rendererPssMB: 70, totalPssMB: 190 } },
      env: { accel: 'kvm' },
      generatedAt: 'now',
    });
    expect(report.environment.accel).toBe('kvm');
    expect(report.environment.build).toMatch(/^debug APK/);
    const [js, txt] = report.files;
    expect(js.mib).toBe(1);
    expect(js.page.open.processMs).toBe(72.3);
    expect(js.page.domLines).toBe(93);
    expect(js.checks.typingP95Ms.within).toBe(true);
    expect(js.checks.scrollSlowFramePct.within).toBe(false);
    expect(js.checks.totalPssMB.within).toBe(false);
    expect(txt.page).toBeNull();
    expect(txt.checks.typingP95Ms.within).toBeNull();
    expect(report.baselineMemory.memory.totalPssMB).toBe(210);
    expect(report.store.snapshots[0]).toMatchObject({ normalMedianMs: 30, fullMedianMs: 55, digestMs: 30 });
    expect(report.store.changes).toEqual({ count: 4, normalMedianMs: 2.5, fullMedianMs: 6.5 });
    expect(report.releaseMemory).toMatchObject({ session: 'large_1mb.js', totalPssMB: 190, check: { within: true } });
    expect(report.problems).toEqual([
      'driver, request 7.4 (measure): no "CodeForge editor" page',
      'large_1mb.txt: no page-side measurements',
    ]);
  });

  it('flags a release sample taken without an editor page', () => {
    const report = buildReport({
      itest,
      cdp: { ...cdp, errors: [] },
      release: { memory: { appPssMB: 90, renderers: [], rendererPssMB: 0, totalPssMB: 90 } },
      generatedAt: 'now',
    });
    expect(report.problems).toContain(
      'release build: no WebView renderer was running when its memory was sampled (no editor open?)',
    );
  });

  it('says what is missing when a side gave nothing', () => {
    const report = buildReport({ itest: null, cdp: null, release: null, generatedAt: 'now' });
    expect(report.files).toEqual([]);
    expect(report.store).toBeNull();
    expect(report.releaseMemory).toBeNull();
    expect(report.problems).toEqual([
      'no app-side report (CODEFORGE_LARGE_JSON lines) in the test output',
      'no DevTools driver report',
    ]);
  });

  it('renders a table per file, the store and the release memory', () => {
    const text = renderText(
      buildReport({ itest, cdp, release: { memory: { appPssMB: 120, rendererPssMB: 70, totalPssMB: 190 } }, generatedAt: 'now' }),
    );
    const jsRow = text.split('\n').find((line) => line.startsWith('large_1mb.js'));
    expect(jsRow).toContain('400/500');
    expect(jsRow).toContain('72.3/119.3');
    expect(jsRow).toContain('2, 201 ms');
    expect(jsRow).toContain('9.5 % ✗');
    expect(jsRow).toContain('31.9 ms ✓');
    expect(jsRow).toContain('251 ✗');
    expect(text).toContain('Before the first open: app 150 MB + renderers 60 MB = 210 MB');
    expect(text).toMatch(/1 MiB\s+30\s+55\s+30/);
    expect(text).toMatch(/1 change \(x4\)\s+2\.5\s+6\.5/);
    expect(text).toContain('Release build, session restored with large_1mb.js open: app 120 MB + renderers 70 MB = 190 MB ✓');
    expect(text).toContain('Problems:');
    const empty = renderText(buildReport({ itest: null, cdp: null, release: null, generatedAt: 'now' }));
    expect(empty).toContain('Release build memory: not measured');
  });
});
