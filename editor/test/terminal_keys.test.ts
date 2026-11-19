import { describe, expect, it } from 'vitest';

import { applyModifiers, ctrlCharacter, keySequence, sanitizePaste } from '../src/terminal/keys';

describe('extra keys', () => {
  it('sends the arrows as the cursor mode expects', () => {
    expect(keySequence('up', {}, false)).toBe('\x1b[A');
    expect(keySequence('down', {}, false)).toBe('\x1b[B');
    expect(keySequence('right', {}, false)).toBe('\x1b[C');
    expect(keySequence('left', {}, false)).toBe('\x1b[D');
    expect(keySequence('up', {}, true)).toBe('\x1bOA');
    expect(keySequence('left', {}, true)).toBe('\x1bOD');
    expect(keySequence('home', {}, false)).toBe('\x1b[H');
    expect(keySequence('end', {}, true)).toBe('\x1bOF');
  });

  it('adds xterm modifier parameters to cursor keys, in either mode', () => {
    expect(keySequence('up', { ctrl: true }, false)).toBe('\x1b[1;5A');
    expect(keySequence('right', { alt: true }, true)).toBe('\x1b[1;3C');
    expect(keySequence('left', { shift: true, ctrl: true }, false)).toBe('\x1b[1;6D');
    expect(keySequence('home', { ctrl: true, alt: true, shift: true }, false)).toBe('\x1b[1;8H');
  });

  it('sends the editing keys as tilde sequences', () => {
    expect(keySequence('insert', {}, false)).toBe('\x1b[2~');
    expect(keySequence('delete', {}, false)).toBe('\x1b[3~');
    expect(keySequence('pageUp', {}, true)).toBe('\x1b[5~');
    expect(keySequence('pageDown', { ctrl: true }, false)).toBe('\x1b[6;5~');
  });

  it('sends Esc, Tab, Enter and Backspace, with Alt as a prefix', () => {
    expect(keySequence('escape', {}, false)).toBe('\x1b');
    expect(keySequence('escape', { alt: true }, false)).toBe('\x1b\x1b');
    expect(keySequence('tab', {}, false)).toBe('\t');
    expect(keySequence('tab', { shift: true }, false)).toBe('\x1b[Z');
    expect(keySequence('enter', {}, false)).toBe('\r');
    expect(keySequence('backspace', {}, false)).toBe('\x7f');
    expect(keySequence('backspace', { ctrl: true }, false)).toBe('\x08');
    expect(keySequence('backspace', { alt: true }, false)).toBe('\x1b\x7f');
  });

  it('sends a character key as typed, with Ctrl and Alt applied', () => {
    expect(keySequence('|', {}, false)).toBe('|');
    expect(keySequence('~', {}, false)).toBe('~');
    expect(keySequence('/', { ctrl: true }, false)).toBe('\x1f');
    expect(keySequence('c', { ctrl: true }, false)).toBe('\x03');
    expect(keySequence('x', { alt: true }, false)).toBe('\x1bx');
    expect(keySequence('d', { ctrl: true, alt: true }, false)).toBe('\x1b\x04');
  });
});

describe('Ctrl and Alt on typed text', () => {
  it('maps characters to control codes as terminals do', () => {
    expect(ctrlCharacter('a')).toBe('\x01');
    expect(ctrlCharacter('Z')).toBe('\x1a');
    expect(ctrlCharacter('c')).toBe('\x03');
    expect(ctrlCharacter('[')).toBe('\x1b');
    expect(ctrlCharacter('\\')).toBe('\x1c');
    expect(ctrlCharacter(']')).toBe('\x1d');
    expect(ctrlCharacter('@')).toBe('\x00');
    expect(ctrlCharacter(' ')).toBe('\x00');
    expect(ctrlCharacter('?')).toBe('\x7f');
    expect(ctrlCharacter('8')).toBe('\x7f');
    expect(ctrlCharacter('2')).toBe('\x00');
    expect(ctrlCharacter('6')).toBe('\x1e');
    expect(ctrlCharacter('9')).toBeNull();
    expect(ctrlCharacter('é')).toBeNull();
    expect(ctrlCharacter('ab')).toBeNull();
  });

  it('applies the latched modifiers to one character, never to a word', () => {
    expect(applyModifiers('c', { ctrl: true })).toBe('\x03');
    expect(applyModifiers('f', { alt: true })).toBe('\x1bf');
    expect(applyModifiers('9', { ctrl: true })).toBe('9');
    expect(applyModifiers('9', { ctrl: true, alt: true })).toBe('\x1b9');
    expect(applyModifiers('hello', { ctrl: true, alt: true })).toBe('hello');
    expect(applyModifiers('x', {})).toBe('x');
  });
});

describe('pasted text', () => {
  it('loses every control character but tab and line breaks', () => {
    expect(sanitizePaste('a\x1b[201~b')).toBe('a[201~b');
    expect(sanitizePaste('one\ttwo\nthree')).toBe('one\ttwo\nthree');
    expect(sanitizePaste('x\x00\x07\x08\x7fy')).toBe('xy');
    expect(sanitizePaste('c1\x9b31mz\x85')).toBe('c131mz');
  });

  it('turns CRLF and lone CR into LF, which xterm sends as CR', () => {
    expect(sanitizePaste('a\r\nb\rc\n')).toBe('a\nb\nc\n');
  });

  it('keeps every other character, wide ones and emoji included', () => {
    expect(sanitizePaste('héllo 你好 👩‍💻')).toBe('héllo 你好 👩‍💻');
  });
});
