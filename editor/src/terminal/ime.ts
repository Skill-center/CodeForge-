/**
 * The input method's text, taken from xterm.js (Phase 5 W3).
 *
 * xterm.js reads its hidden textarea three ways: a key it can name, on
 * keydown; an `insertText` input event; and, for keyCode 229 (an input
 * method's key) and for compositions, the textarea's text read back on a
 * timer and diffed with String.replace. On Android every key of an input
 * method is 229, and Gboard composes words even from a hardware keyboard:
 * the timers raced the compositions, and "echo cf-typed-ok" arrived as
 * "echohoocf--ttypped-ok" (phase gate 44575917666).
 *
 * Here one path owns the input method's text. The textarea is the method's
 * buffer, and it is emptied as soon as its text is sent: after each input
 * event outside a composition, and when a composition ends. The page sends
 * that text as typed (a lone line break as Enter; a line break with more is
 * a paste), and shows a composition at the cursor until it ends. Keys with a
 * name (keyCode other than 229) stay xterm.js's: from a hardware keyboard,
 * letters, the arrows, Enter, Tab, Escape and Ctrl combinations reach it as
 * before, after any text already typed. A character xterm.js sends on its
 * keypress (a space, a capital) still lands in the textarea, and that input
 * is only emptied, not sent again. With the buffer empty, an input method's
 * Backspace arrives as a key too (Android sends DEL when there is no text
 * before the cursor), which xterm.js sends.
 *
 * DOM-free apart from the event shapes, so test/terminal_ime.test.ts drives
 * it with plain objects; the controller attaches it to each session's
 * element, in the capture phase, before xterm.js's own listeners on the
 * textarea.
 */

/** Where the input method's text goes. */
export interface ImeHost {
  /** Text as typed: xterm.js's own path for a key, so the latched Ctrl and Alt apply. */
  type(data: string): void;
  /** Text with a line break and more: a paste (sanitized, bracketed when the program asks). */
  paste(text: string): void;
  /** Shows the composition at the cursor; null hides it. */
  compose(text: string | null): void;
}

/** The textarea: only its text is read and emptied. */
export interface ImeField {
  value: string;
}

/** The parts of an input, keyboard or composition event the page reads. */
export interface ImeEvent {
  readonly type: string;
  readonly target: unknown;
  readonly keyCode?: number;
  readonly isComposing?: boolean;
  readonly data?: string | null;
  stopPropagation(): void;
}

/** What the page listens to, in the capture phase. */
export const IME_EVENTS = [
  'keydown',
  'keypress',
  'keyup',
  'input',
  'compositionstart',
  'compositionupdate',
  'compositionend',
] as const;

/** keyCode of a key an input method processes. */
export const IME_KEY = 229;

export class ImeInput {
  private composing = false;
  /** A keypress since the last keydown: xterm.js sent its character. */
  private pressed = false;

  constructor(
    private readonly field: ImeField,
    private readonly host: ImeHost,
  ) {}

  /** True between a composition's start and its end. */
  get isComposing(): boolean {
    return this.composing;
  }

  /**
   * Handles one event seen on the way to the textarea. Events for other
   * targets pass untouched; the input method's keys, its input and its
   * compositions are kept from xterm.js.
   */
  handle(event: ImeEvent): void {
    if (event.target !== this.field) return;
    switch (event.type) {
      case 'keydown':
        this.pressed = false;
        if (event.keyCode === IME_KEY) {
          // The input method's: its text follows in input and composition events.
          event.stopPropagation();
          return;
        }
        // A named key, for xterm.js: the text typed before it goes first.
        if (!this.composing) this.flush();
        return;
      case 'compositionstart':
        event.stopPropagation();
        this.composing = true;
        this.host.compose('');
        return;
      case 'compositionupdate':
        event.stopPropagation();
        this.host.compose(event.data ?? '');
        return;
      case 'compositionend':
        event.stopPropagation();
        this.composing = false;
        this.host.compose(null);
        this.flush();
        return;
      case 'keypress':
        // xterm.js sends this character itself (it never cancels a keypress).
        this.pressed = true;
        return;
      case 'keyup':
        this.pressed = false;
        return;
      case 'input':
        event.stopPropagation();
        if (this.pressed) {
          // The keypress's character, already sent: only the textarea keeps it.
          this.pressed = false;
          if (!this.composing) this.field.value = '';
          return;
        }
        if (!this.composing && !event.isComposing) this.flush();
        return;
      default:
        return;
    }
  }

  /** Sends what the input method put in the textarea, and empties it. */
  flush(): void {
    const text = this.field.value;
    if (text === '') return;
    this.field.value = '';
    const lineBreaks = /\r\n|\r|\n/g;
    if (text.replace(lineBreaks, '') === '') {
      this.host.type('\r'.repeat(text.match(lineBreaks)?.length ?? 0));
    } else if (/[\r\n]/.test(text)) {
      this.host.paste(text);
    } else {
      this.host.type(text);
    }
  }
}
