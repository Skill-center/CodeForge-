/**
 * What the extra-keys row and the latched modifiers send (Phase 5 W3), as
 * xterm sends them: the terminal's own modes decide (application cursor keys
 * turn `ESC [ A` into `ESC O A`), so these run in the page, which knows them.
 * Pure functions: test/terminal_keys.test.ts covers them.
 */
import type { KeyName } from './protocol';

export interface Modifiers {
  ctrl?: boolean;
  alt?: boolean;
  shift?: boolean;
}

const ESC = '\x1b';

/** xterm's modifier parameter: 1 + shift 1 + alt 2 + ctrl 4. */
function modifierParameter(mods: Modifiers): number {
  return 1 + (mods.shift ? 1 : 0) + (mods.alt ? 2 : 0) + (mods.ctrl ? 4 : 0);
}

const CURSOR_FINALS: Partial<Record<KeyName, string>> = {
  up: 'A',
  down: 'B',
  right: 'C',
  left: 'D',
  home: 'H',
  end: 'F',
};

const TILDE_CODES: Partial<Record<KeyName, number>> = {
  insert: 2,
  delete: 3,
  pageUp: 5,
  pageDown: 6,
};

/**
 * The control character Ctrl turns [ch] into, as terminals do: letters and
 * `@[\]^_` to C0, `?` to DEL, space and `2` to NUL, `3`–`7` to ESC…US, `8`
 * to DEL, `/` to US. Null when Ctrl means nothing for [ch].
 */
export function ctrlCharacter(ch: string): string | null {
  if (ch.length !== 1) return null;
  const code = ch.charCodeAt(0);
  if (code >= 0x61 && code <= 0x7a) return String.fromCharCode(code - 0x60);
  if (code >= 0x40 && code <= 0x5f) return String.fromCharCode(code - 0x40);
  switch (ch) {
    case ' ':
    case '2':
      return '\x00';
    case '3':
      return '\x1b';
    case '4':
      return '\x1c';
    case '5':
      return '\x1d';
    case '6':
      return '\x1e';
    case '7':
    case '/':
      return '\x1f';
    case '8':
    case '?':
      return '\x7f';
    default:
      return null;
  }
}

/**
 * Typed text with the latched modifiers applied: Ctrl to a single character,
 * Alt as an ESC prefix. Longer text (an input method's word) goes as typed.
 */
export function applyModifiers(data: string, mods: Modifiers): string {
  if (data.length !== 1) return data;
  let out = data;
  if (mods.ctrl) {
    const control = ctrlCharacter(data);
    if (control !== null) out = control;
  }
  return mods.alt ? ESC + out : out;
}

/**
 * The bytes for a named key or one character, under the terminal's
 * application cursor mode and the modifiers held with it.
 */
export function keySequence(key: KeyName | string, mods: Modifiers, applicationCursor: boolean): string {
  const modified = Boolean(mods.ctrl || mods.alt || mods.shift);
  const final = CURSOR_FINALS[key as KeyName];
  if (final !== undefined) {
    if (modified) return `${ESC}[1;${modifierParameter(mods)}${final}`;
    return applicationCursor ? `${ESC}O${final}` : `${ESC}[${final}`;
  }
  const tilde = TILDE_CODES[key as KeyName];
  if (tilde !== undefined) {
    return modified ? `${ESC}[${tilde};${modifierParameter(mods)}~` : `${ESC}[${tilde}~`;
  }
  const alt = mods.alt ? ESC : '';
  switch (key) {
    case 'escape':
      return alt + ESC;
    case 'tab':
      return mods.shift ? `${ESC}[Z` : alt + '\t';
    case 'enter':
      return alt + '\r';
    case 'backspace':
      return alt + (mods.ctrl ? '\x08' : '\x7f');
    default:
      return applyModifiers(key, { ctrl: mods.ctrl, alt: mods.alt });
  }
}

/**
 * Pasted text made safe for a terminal: no control characters but tab and
 * line breaks (an ESC could end bracketed paste early and run what follows),
 * no C1 controls, line breaks as LF (xterm turns them into CR).
 */
export function sanitizePaste(text: string): string {
  return text
    .replace(/\r\n?/g, '\n')
    .replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, '');
}
