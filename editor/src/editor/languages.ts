import { css } from '@codemirror/lang-css';
import { html } from '@codemirror/lang-html';
import { javascript } from '@codemirror/lang-javascript';
import { json } from '@codemirror/lang-json';
import { markdown } from '@codemirror/lang-markdown';
import { python } from '@codemirror/lang-python';
import { indentUnit, type Language, LanguageSupport } from '@codemirror/language';
import type { Extension } from '@codemirror/state';

import { LANGUAGE_IDS, type LanguageId } from '../protocol/types';

interface LanguageDef {
  /** Indentation inserted by Tab and auto-indent. */
  indent: string;
  support: () => LanguageSupport | null;
}

const DEFS: Record<LanguageId, LanguageDef> = {
  plaintext: { indent: '  ', support: () => null },
  javascript: { indent: '  ', support: () => javascript() },
  jsx: { indent: '  ', support: () => javascript({ jsx: true }) },
  typescript: { indent: '  ', support: () => javascript({ typescript: true }) },
  tsx: { indent: '  ', support: () => javascript({ typescript: true, jsx: true }) },
  python: { indent: '    ', support: () => python() },
  json: { indent: '  ', support: () => json() },
  html: { indent: '  ', support: () => html() },
  css: { indent: '  ', support: () => css() },
  markdown: { indent: '  ', support: () => markdown({ codeLanguages: fencedCodeLanguage }) },
};

/** Info strings of Markdown fenced code blocks → language id. */
const FENCE_ALIASES: Record<string, LanguageId> = {
  js: 'javascript',
  javascript: 'javascript',
  mjs: 'javascript',
  cjs: 'javascript',
  jsx: 'jsx',
  ts: 'typescript',
  typescript: 'typescript',
  tsx: 'tsx',
  py: 'python',
  python: 'python',
  json: 'json',
  html: 'html',
  css: 'css',
};

const fenceCache = new Map<LanguageId, Language | null>();

function fencedCodeLanguage(info: string): Language | null {
  const id = FENCE_ALIASES[info.trim().toLowerCase()];
  if (id === undefined) return null;
  if (!fenceCache.has(id)) fenceCache.set(id, DEFS[id].support()?.language ?? null);
  return fenceCache.get(id) ?? null;
}

export function isLanguageId(value: string): value is LanguageId {
  return (LANGUAGE_IDS as readonly string[]).includes(value);
}

/** Syntax support plus indentation for one language. */
export function languageExtension(id: LanguageId): Extension {
  const def = DEFS[id];
  const support = def.support();
  return support ? [support, indentUnit.of(def.indent)] : [indentUnit.of(def.indent)];
}

/** The Lezer language for [id], or null for plain text (used by tests). */
export function languageOf(id: LanguageId): Language | null {
  return DEFS[id].support()?.language ?? null;
}
