import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import type { Extension } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { tags as t } from '@lezer/highlight';

import type { Palette } from '../protocol/types';

export { DEFAULT_PALETTE } from './palette';

/** Maps highlight tags onto the seven contrast-audited syntax roles. */
export function forgeHighlightStyle(p: Palette): HighlightStyle {
  const s = p.syntax;
  return HighlightStyle.define([
    {
      tag: [t.keyword, t.controlKeyword, t.moduleKeyword, t.operatorKeyword, t.definitionKeyword, t.modifier, t.self],
      color: s.keyword,
    },
    { tag: [t.string, t.special(t.string), t.regexp, t.character, t.attributeValue, t.escape], color: s.string },
    { tag: [t.number, t.bool, t.null, t.atom, t.unit], color: s.number },
    {
      tag: [t.function(t.variableName), t.function(t.propertyName), t.function(t.definition(t.variableName)), t.macroName, t.attributeName],
      color: s.function,
    },
    { tag: [t.typeName, t.className, t.namespace, t.tagName, t.definition(t.typeName)], color: s.type },
    { tag: [t.comment, t.lineComment, t.blockComment, t.docComment, t.meta], color: s.comment },
    { tag: [t.operator, t.derefOperator, t.compareOperator, t.arithmeticOperator, t.logicOperator, t.bitwiseOperator, t.updateOperator, t.definitionOperator], color: s.operator },
    { tag: t.heading, color: s.keyword, fontWeight: 'bold' },
    { tag: [t.link, t.url], color: s.function, textDecoration: 'underline' },
    { tag: t.monospace, color: s.string },
    { tag: t.emphasis, fontStyle: 'italic' },
    { tag: t.strong, fontWeight: 'bold' },
    { tag: t.strikethrough, textDecoration: 'line-through' },
    { tag: t.invalid, color: s.number },
  ]);
}

/** Editor chrome (gutter, selection, panels) plus syntax colours. */
export function forgeTheme(p: Palette): Extension {
  const chrome = EditorView.theme(
    {
      '&': { color: p.foreground, backgroundColor: p.background, height: '100%' },
      '.cm-scroller': {
        fontFamily: '"JetBrains Mono", monospace',
        lineHeight: '1.5',
        fontVariantLigatures: 'none',
        fontFeatureSettings: '"calt" 0, "liga" 0',
      },
      '.cm-content': { caretColor: p.cursor },
      '.cm-cursor, .cm-dropCursor': { borderLeftColor: p.cursor, borderLeftWidth: '2px' },
      '&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection':
        { backgroundColor: p.selection },
      '.cm-activeLine': { backgroundColor: p.activeLine },
      '.cm-gutters': {
        backgroundColor: p.gutterBackground,
        color: p.gutterForeground,
        border: 'none',
        borderRight: `1px solid ${p.border}`,
      },
      '.cm-activeLineGutter': { backgroundColor: p.activeLine, color: p.foreground },
      '&.cm-focused .cm-matchingBracket': { backgroundColor: p.matchingBracket },
      '.cm-searchMatch': { backgroundColor: p.searchMatch },
      '.cm-searchMatch.cm-searchMatch-selected': { backgroundColor: p.selection },
      '.cm-selectionMatch': { backgroundColor: p.searchMatch },
      '.cm-panels': { backgroundColor: p.panelBackground, color: p.foreground },
      '.cm-panels.cm-panels-top': { borderBottom: `1px solid ${p.border}` },
      '.cm-panels.cm-panels-bottom': { borderTop: `1px solid ${p.border}` },
      '.cm-foldPlaceholder': { backgroundColor: p.panelBackground, border: `1px solid ${p.border}`, color: p.gutterForeground },
      '.cm-tooltip': { backgroundColor: p.panelBackground, border: `1px solid ${p.border}`, color: p.foreground },
    },
    { dark: p.dark },
  );
  return [chrome, syntaxHighlighting(forgeHighlightStyle(p))];
}

/** Font size in CSS px (the host maps the user's setting onto it). */
export function fontSizeTheme(px: number): Extension {
  return EditorView.theme({ '&': { fontSize: `${px}px` } });
}
