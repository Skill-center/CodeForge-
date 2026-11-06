import { describe, expect, it } from 'vitest';

import { contentSecurityPolicy, fillTemplate, inlineScript, inlineStyle, licenceAllowed } from '../tool/page_kit.mjs';

const fail = (message) => {
  throw new Error(message);
};

describe('page kit', () => {
  it('accepts allowed licences and OR-choices only', () => {
    expect(licenceAllowed('MIT')).toBe(true);
    expect(licenceAllowed('(MPL-2.0 OR Apache-2.0)')).toBe(true);
    expect(licenceAllowed('GPL-3.0')).toBe(false);
    expect(licenceAllowed('(MIT AND GPL-3.0)')).toBe(false);
    expect(licenceAllowed('MIT WITH Some-exception')).toBe(false);
    expect(licenceAllowed(undefined)).toBe(false);
  });

  it('escapes "<!--" inside literals and rejects it in code', () => {
    expect(inlineScript('const a = "<!--";\n', fail)).toBe('const a = "\\x3C!--";');
    expect(inlineScript('const r = /<!--/;', fail)).toBe('const r = /\\x3C!--/;');
    expect(() => inlineScript('x<!--y', fail)).toThrow(/outside a string/);
    expect(() => inlineScript('const s = "</script>";', fail)).toThrow(/end an inline <script>/);
  });

  it('keeps a stylesheet from closing its element', () => {
    expect(inlineStyle('a{color:red}', fail)).toBe('a{color:red}');
    expect(() => inlineStyle('a{}</style><script>', fail)).toThrow(/inline <style>/);
  });

  it('pins the script hash and denies everything else', () => {
    const csp = contentSecurityPolicy('abc=');
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain("script-src 'sha256-abc='");
    expect(csp).not.toContain('worker-src');
  });

  it('fills every placeholder literally', () => {
    expect(fillTemplate('<{{A}}|{{B}}>', { A: '$&', B: 'x' })).toBe('<$&|x>');
    expect(() => fillTemplate('{{A}}', { B: 'x' })).toThrow(/no \{\{B\}\}/);
  });
});
