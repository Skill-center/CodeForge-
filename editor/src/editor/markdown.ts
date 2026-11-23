/**
 * The language servers' documentation, drawn (Phase 6 W5): hover text and a
 * completion's documentation arrive as Markdown or plain text (LSP's
 * MarkupContent). This draws the part of Markdown the servers write, with
 * code blocks in the monospace font (PHASE_6_PLAN W5), and nothing more:
 *
 * - fenced code blocks, paragraphs, hard line breaks, rules, headings and
 *   list items;
 * - inline code, bold, italics, and links as their text (the page never
 *   navigates);
 * - everything as text: no HTML from a server reaches the DOM, since every
 *   node is built here and filled with `textContent`.
 */
import type { MarkupJson } from '../protocol/types';

const FENCE = /^ {0,3}(`{3,}|~{3,})\s*([\w#+.-]*)\s*$/;
const RULE = /^ {0,3}([-*_])(\s*\1){2,}\s*$/;
const HEADING = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/;
const LIST_ITEM = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
const HARD_BREAK = /( {2,}|\\)$/;

/** Bold, italics, links and escapes, outside code spans. */
const INLINE = /\*\*([^*]+)\*\*|__([^_]+)__|\*([^*\s][^*]*)\*|(?<![\w])_([^_\s][^_]*)_(?![\w])|\[([^\]]+)\]\([^)]*\)|\\([\\`*_{}[\]()#+\-.!|<>])/g;

function element<K extends keyof HTMLElementTagNameMap>(
  doc: Document,
  tag: K,
  className?: string,
): HTMLElementTagNameMap[K] {
  const node = doc.createElement(tag);
  if (className) node.className = className;
  return node;
}

/** Appends [text]'s inline Markdown to [parent]. */
function appendInline(doc: Document, parent: HTMLElement, text: string): void {
  // Code spans first: nothing inside them is Markdown.
  const parts = text.split(/(`+)([^`]|[^`].*?[^`])\1(?!`)/);
  // split() with two groups yields: text, ticks, code, text, ticks, code, ...
  for (let i = 0; i < parts.length; i += 3) {
    appendEmphasis(doc, parent, parts[i] ?? '');
    const code = parts[i + 2];
    if (code !== undefined) {
      const span = element(doc, 'code', 'cm-cf-inline-code');
      span.textContent = code.trim() === '' ? code : code.replace(/^ (.*) $/, '$1');
      parent.append(span);
    }
  }
}

function appendEmphasis(doc: Document, parent: HTMLElement, text: string): void {
  let at = 0;
  for (const match of text.matchAll(INLINE)) {
    const index = match.index ?? 0;
    if (index > at) parent.append(doc.createTextNode(text.slice(at, index)));
    const [, bold1, bold2, em1, em2, link, escaped] = match;
    if (bold1 !== undefined || bold2 !== undefined) {
      const strong = element(doc, 'strong');
      strong.textContent = bold1 ?? bold2 ?? '';
      parent.append(strong);
    } else if (em1 !== undefined || em2 !== undefined) {
      const em = element(doc, 'em');
      em.textContent = em1 ?? em2 ?? '';
      parent.append(em);
    } else if (link !== undefined) {
      parent.append(doc.createTextNode(link));
    } else {
      parent.append(doc.createTextNode(escaped ?? ''));
    }
    at = index + match[0].length;
  }
  if (at < text.length) parent.append(doc.createTextNode(text.slice(at)));
}

/** A paragraph of [lines], with a line break where a line asks for one. */
function paragraph(doc: Document, lines: string[]): HTMLElement {
  const p = element(doc, 'p');
  lines.forEach((line, i) => {
    const last = i === lines.length - 1;
    const hard = !last && HARD_BREAK.test(line);
    appendInline(doc, p, (hard ? line.replace(HARD_BREAK, '') : line).trim());
    if (!last) p.append(hard ? element(doc, 'br') : doc.createTextNode(' '));
  });
  return p;
}

/** Draws [markup] as DOM, in a `cm-cf-doc` block. */
export function renderMarkup(markup: MarkupJson, doc: Document = document): HTMLElement {
  const root = element(doc, 'div', 'cm-cf-doc');
  const text = markup.value.replace(/\r\n?/g, '\n');
  if (markup.kind === 'plaintext') {
    const pre = element(doc, 'pre', 'cm-cf-plain');
    pre.textContent = text;
    root.append(pre);
    return root;
  }
  const lines = text.split('\n');
  let prose: string[] = [];
  const endProse = () => {
    if (prose.length > 0) root.append(paragraph(doc, prose));
    prose = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? '';
    const fence = FENCE.exec(line);
    if (fence) {
      endProse();
      const marker = fence[1] ?? '```';
      // Closed by a line of the same character, at least as many of them.
      const closer = new RegExp(`^ {0,3}${marker[0] === '~' ? '~' : '`'}{${marker.length},}\\s*$`);
      const body: string[] = [];
      for (i += 1; i < lines.length && !closer.test(lines[i] ?? ''); i++) body.push(lines[i] ?? '');
      const pre = element(doc, 'pre', 'cm-cf-code');
      const code = element(doc, 'code');
      if (fence[2]) code.dataset.language = fence[2];
      code.textContent = body.join('\n');
      pre.append(code);
      root.append(pre);
      continue;
    }
    if (line.trim() === '') {
      endProse();
      continue;
    }
    if (RULE.test(line)) {
      endProse();
      root.append(element(doc, 'hr'));
      continue;
    }
    const heading = HEADING.exec(line);
    if (heading) {
      endProse();
      const p = element(doc, 'p', 'cm-cf-heading');
      const strong = element(doc, 'strong');
      appendInline(doc, strong, heading[2] ?? '');
      p.append(strong);
      root.append(p);
      continue;
    }
    const item = LIST_ITEM.exec(line);
    if (item) {
      endProse();
      const li = element(doc, 'div', 'cm-cf-li');
      const depth = Math.min(4, Math.floor((item[1] ?? '').replace(/\t/g, '    ').length / 2));
      if (depth > 0) li.style.paddingLeft = `${depth}em`;
      const marker = item[2] ?? '-';
      li.append(doc.createTextNode(/^\d/.test(marker) ? `${marker} ` : '• '));
      appendInline(doc, li, item[3] ?? '');
      root.append(li);
      continue;
    }
    prose.push(line);
  }
  endProse();
  return root;
}
