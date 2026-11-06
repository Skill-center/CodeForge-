import { ensureSyntaxTree, indentUnit } from '@codemirror/language';
import { EditorState } from '@codemirror/state';
import { tags } from '@lezer/highlight';
import { describe, expect, it } from 'vitest';

import { isLanguageId, languageExtension, languageOf } from '../src/editor/languages';
import { DEFAULT_PALETTE, forgeHighlightStyle } from '../src/editor/theme';
import { LANGUAGE_IDS, type LanguageId } from '../src/protocol/types';

const SAMPLES: Record<Exclude<LanguageId, 'plaintext'>, { code: string; top: string; node: string }> = {
  javascript: { code: 'const a = "x"; // c', top: 'Script', node: 'VariableDefinition' },
  jsx: { code: 'const el = <div className="a">hi</div>;', top: 'Script', node: 'JSXElement' },
  typescript: { code: 'let n: number = 1;', top: 'Script', node: 'TypeAnnotation' },
  tsx: { code: 'const C = (p: P) => <b>{p.x}</b>;', top: 'Script', node: 'JSXElement' },
  python: { code: 'def f(x):\n    return "y"\n', top: 'Script', node: 'FunctionDefinition' },
  json: { code: '{"a": [1, true, null]}', top: 'JsonText', node: 'Property' },
  html: { code: '<p class="x">hi</p>', top: 'Document', node: 'Element' },
  css: { code: 'a { color: red; }', top: 'StyleSheet', node: 'RuleSet' },
  markdown: { code: '# Title\n\n```js\nconst a = 1;\n```\n', top: 'Document', node: 'FencedCode' },
};

function treeOf(id: LanguageId, code: string) {
  const state = EditorState.create({ doc: code, extensions: languageExtension(id) });
  const tree = ensureSyntaxTree(state, state.doc.length, 5000);
  if (!tree) throw new Error('parse timed out');
  return tree;
}

describe('languages', () => {
  it('knows every protocol language id', () => {
    for (const id of LANGUAGE_IDS) expect(isLanguageId(id)).toBe(true);
    expect(isLanguageId('cobol')).toBe(false);
  });

  for (const [id, sample] of Object.entries(SAMPLES) as Array<[Exclude<LanguageId, 'plaintext'>, (typeof SAMPLES)[keyof typeof SAMPLES]]>) {
    it(`parses ${id}`, () => {
      expect(languageOf(id)).not.toBeNull();
      const tree = treeOf(id, sample.code);
      expect(tree.type.name).toBe(sample.top);
      const names = new Set<string>();
      tree.iterate({ enter: (node) => void names.add(node.type.name) });
      expect(names).toContain(sample.node);
    });
  }

  it('parses fenced code inside Markdown with the nested language', () => {
    // Nested code is mounted as an overlay; resolveInner enters overlays
    // (plain iteration does not), just as the highlighter does.
    const tree = treeOf('markdown', '```python\ndef f(): pass\n```\n');
    const path: string[] = [];
    for (let node: { name: string; parent: unknown } | null = tree.resolveInner(14, 1); node; node = node.parent as typeof node) {
      path.push(node.name);
    }
    expect(path).toEqual(['VariableName', 'FunctionDefinition', 'Script', 'FencedCode', 'Document']);
  });

  it('treats plain text as having no grammar', () => {
    expect(languageOf('plaintext')).toBeNull();
    const state = EditorState.create({ doc: 'just text', extensions: languageExtension('plaintext') });
    expect(state.doc.toString()).toBe('just text');
  });

  it('indents Python with four spaces and the rest with two', () => {
    const unit = (id: LanguageId) => EditorState.create({ extensions: languageExtension(id) }).facet(indentUnit);
    expect(unit('python')).toBe('    ');
    expect(unit('javascript')).toBe('  ');
    expect(unit('plaintext')).toBe('  ');
  });
});

describe('theme', () => {
  it('maps each syntax role onto its palette colour', () => {
    const style = forgeHighlightStyle(DEFAULT_PALETTE);
    const rules = style.module?.getRules() ?? '';
    const roles: Array<[readonly (typeof tags.keyword)[], string]> = [
      [[tags.keyword], DEFAULT_PALETTE.syntax.keyword],
      [[tags.string], DEFAULT_PALETTE.syntax.string],
      [[tags.number], DEFAULT_PALETTE.syntax.number],
      [[tags.function(tags.variableName)], DEFAULT_PALETTE.syntax.function],
      [[tags.typeName], DEFAULT_PALETTE.syntax.type],
      [[tags.lineComment], DEFAULT_PALETTE.syntax.comment],
      [[tags.operator], DEFAULT_PALETTE.syntax.operator],
    ];
    for (const [tagList, colour] of roles) {
      const cls = style.style(tagList);
      expect(cls).toBeTruthy();
      expect(rules).toMatch(new RegExp(`\\.${cls}\\s*\\{[^}]*color:\\s*${colour}`, 'i'));
    }
  });
});
