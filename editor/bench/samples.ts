/**
 * Documents the benchmark opens. Both engines get exactly the same text.
 * Everything is generated deterministically: same input, same document.
 */
import type { BenchLanguage } from './engine';

export const SAMPLES: Record<Exclude<BenchLanguage, 'plaintext'>, string> = {
  javascript: [
    "import { readFile } from 'node:fs/promises';",
    '',
    '/** Sums the prices of the items in an order. */',
    'export async function orderTotal(path, taxRate = 0.19) {',
    "  const order = JSON.parse(await readFile(path, 'utf8'));",
    '  let total = 0;',
    '  for (const item of order.items) {',
    '    if (item.quantity <= 0) continue;',
    '    total += item.price * item.quantity;',
    '  }',
    '  const label = `order ${order.id}: ${total.toFixed(2)}`;',
    '  console.log(label, /\\d+/.test(label));',
    '  return Math.round(total * (1 + taxRate) * 100) / 100;',
    '}',
    '',
  ].join('\n'),
  typescript: [
    'export interface Item {',
    '  readonly id: number;',
    '  name: string;',
    '  price: number;',
    '  tags?: string[];',
    '}',
    '',
    "type Sort = 'name' | 'price';",
    '',
    'export function sortItems<T extends Item>(items: readonly T[], by: Sort = \'name\'): T[] {',
    '  const copy = [...items];',
    "  copy.sort((a, b) => (by === 'name' ? a.name.localeCompare(b.name) : a.price - b.price));",
    '  return copy;',
    '}',
    '',
    'export class Cart {',
    '  private readonly items = new Map<number, Item>();',
    '  add(item: Item): void {',
    '    this.items.set(item.id, item);',
    '  }',
    '}',
    '',
  ].join('\n'),
  python: [
    'from dataclasses import dataclass',
    'from typing import Iterable',
    '',
    '',
    '@dataclass(frozen=True)',
    'class Item:',
    '    name: str',
    '    price: float',
    '    quantity: int = 1',
    '',
    '',
    'def order_total(items: Iterable[Item], tax_rate: float = 0.19) -> float:',
    '    """Sums the prices of the items in an order."""',
    '    total = sum(i.price * i.quantity for i in items if i.quantity > 0)',
    '    print(f"total={total:.2f}")',
    '    return round(total * (1 + tax_rate), 2)',
    '',
    '',
    'if __name__ == "__main__":',
    '    print(order_total([Item("pen", 1.5, 4), Item("book", 12.0)]))',
    '',
  ].join('\n'),
  json: [
    '{',
    '  "name": "codeforge-sample",',
    '  "version": "1.0.0",',
    '  "private": true,',
    '  "scripts": { "test": "vitest run", "build": "node build.mjs" },',
    '  "items": [',
    '    { "id": 1, "price": 12.5, "tags": ["new", "sale"], "active": true },',
    '    { "id": 2, "price": 3, "tags": [], "active": false, "note": null }',
    '  ]',
    '}',
    '',
  ].join('\n'),
  html: [
    '<!doctype html>',
    '<html lang="en">',
    '<head>',
    '  <meta charset="utf-8">',
    '  <title>Order summary</title>',
    '  <link rel="stylesheet" href="style.css">',
    '</head>',
    '<body class="page">',
    '  <!-- The list is filled in by app.js -->',
    '  <main id="app" data-order="42">',
    '    <h1>Order <span class="id">#42</span></h1>',
    '    <ul class="items"><li>Pen &times; 4</li><li>Book</li></ul>',
    '    <button type="button" disabled>Pay</button>',
    '  </main>',
    '</body>',
    '</html>',
    '',
  ].join('\n'),
  css: [
    ':root {',
    '  --accent: #4f8cff;',
    '  --radius: 8px;',
    '}',
    '',
    '.page main > h1 .id::before {',
    "  content: '';",
    '  color: var(--accent);',
    '}',
    '',
    '@media (max-width: 600px) {',
    '  .items li:nth-child(2n + 1) {',
    '    padding: 4px calc(var(--radius) * 2);',
    '    border-radius: var(--radius);',
    '    background: rgba(79, 140, 255, 0.12) !important;',
    '  }',
    '}',
    '',
  ].join('\n'),
};

/**
 * A JavaScript document of at least `bytes` characters (ASCII, so characters
 * equal bytes), cut at a line end. Blocks differ by number, so no two lines
 * of neighbouring blocks are identical.
 */
export function largeJavaScript(bytes: number): string {
  const parts: string[] = [];
  let size = 0;
  for (let n = 0; size < bytes; n += 1) {
    const block = [
      `// Block ${n}: generated for the large-file benchmark.`,
      `export function compute${n}(items, factor = ${n % 97}) {`,
      '  const result = [];',
      '  for (let i = 0; i < items.length; i += 1) {',
      `    const value = items[i] * factor + ${n};`,
      '    if (value % 2 === 0) {',
      `      result.push({ id: i, value, label: 'item-' + i + '-${n}' });`,
      '    } else {',
      "      result.push(null); // odd values are skipped",
      '    }',
      '  }',
      '  return result.filter(Boolean);',
      '}',
      '',
      '',
    ].join('\n');
    parts.push(block);
    size += block.length;
  }
  const text = parts.join('');
  const cut = text.indexOf('\n', bytes - 1);
  return cut < 0 ? text : text.slice(0, cut + 1);
}

/**
 * What the automated typing scenario types: code-like, 60 characters, no
 * brackets or quotes (engines auto-close those differently, which would make
 * the two runs type different text).
 */
export const TYPING_TEXT = 'let total = price * count + tax - discount / rate + shipping';
