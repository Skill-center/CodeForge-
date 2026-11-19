import { describe, expect, it } from 'vitest';

import { IME_KEY, type ImeEvent, type ImeHost, ImeInput } from '../src/terminal/ime';

/** The textarea, and what the page did with the input method's text. */
class Recorder implements ImeHost {
  readonly field = { value: '' };
  readonly typed: string[] = [];
  readonly pasted: string[] = [];
  readonly shown: Array<string | null> = [];

  type(data: string): void {
    this.typed.push(data);
  }
  paste(text: string): void {
    this.pasted.push(text);
  }
  compose(text: string | null): void {
    this.shown.push(text);
  }
}

/** An event on the way to [target]; `stopped` says whether xterm.js would still see it. */
function event(
  target: unknown,
  type: string,
  fields: { keyCode?: number; isComposing?: boolean; data?: string | null } = {},
): ImeEvent & { stopped: boolean } {
  return {
    type,
    target,
    ...fields,
    stopped: false,
    stopPropagation() {
      this.stopped = true;
    },
  };
}

function ime(): { page: Recorder; input: ImeInput } {
  const page = new Recorder();
  return { page, input: new ImeInput(page.field, page) };
}

/** An input method committing [text] as Android's Chrome reports it: a 229 key, the text, an input event. */
function commit(page: Recorder, input: ImeInput, text: string): Array<ImeEvent & { stopped: boolean }> {
  const key = event(page.field, 'keydown', { keyCode: IME_KEY });
  input.handle(key);
  page.field.value += text;
  const changed = event(page.field, 'input', { data: text });
  input.handle(changed);
  return [key, changed];
}

describe('terminal input method', () => {
  it('sends each commit once, empties the textarea, and keeps the events from xterm.js', () => {
    const { page, input } = ime();
    const events = [...'echo cf-typed-ok'].flatMap((ch) => commit(page, input, ch));
    expect(page.typed.join('')).toBe('echo cf-typed-ok');
    expect(page.field.value).toBe('');
    expect(events.every((e) => e.stopped)).toBe(true);
  });

  it('shows a composition and sends it once, when it ends', () => {
    const { page, input } = ime();
    input.handle(event(page.field, 'compositionstart'));
    for (const text of ['n', 'ni', 'nih', 'niha', 'nihao']) {
      input.handle(event(page.field, 'keydown', { keyCode: IME_KEY, isComposing: true }));
      input.handle(event(page.field, 'compositionupdate', { data: text }));
      page.field.value = text;
      input.handle(event(page.field, 'input', { data: text, isComposing: true }));
    }
    expect(page.typed).toEqual([]);
    expect(input.isComposing).toBe(true);
    page.field.value = '你好';
    input.handle(event(page.field, 'input', { data: '你好', isComposing: true }));
    input.handle(event(page.field, 'compositionend', { data: '你好' }));
    expect(page.typed).toEqual(['你好']);
    expect(page.shown).toEqual(['', 'n', 'ni', 'nih', 'niha', 'nihao', null]);
    expect(page.field.value).toBe('');
  });

  it('a composition edited down or canceled sends what is left, or nothing', () => {
    const { page, input } = ime();
    input.handle(event(page.field, 'compositionstart'));
    page.field.value = 'xyz';
    input.handle(event(page.field, 'compositionupdate', { data: 'xyz' }));
    page.field.value = '';
    input.handle(event(page.field, 'compositionupdate', { data: '' }));
    input.handle(event(page.field, 'compositionend', { data: '' }));
    expect(page.typed).toEqual([]);
    input.handle(event(page.field, 'compositionstart'));
    page.field.value = 'cop';
    input.handle(event(page.field, 'compositionend', { data: 'cop' }));
    expect(page.typed).toEqual(['cop']);
  });

  it('words composed one after another are each sent whole, in order', () => {
    const { page, input } = ime();
    // Gboard composing from a hardware keyboard: a word, then a space committed after it.
    for (const word of ['echo', 'cf-typed-ok']) {
      input.handle(event(page.field, 'compositionstart'));
      for (let i = 1; i <= word.length; i += 1) {
        input.handle(event(page.field, 'keydown', { keyCode: IME_KEY, isComposing: true }));
        page.field.value = word.slice(0, i);
        input.handle(event(page.field, 'input', { data: page.field.value, isComposing: true }));
      }
      input.handle(event(page.field, 'compositionend', { data: word }));
      if (word === 'echo') commit(page, input, ' ');
    }
    expect(page.typed.join('')).toBe('echo cf-typed-ok');
  });

  it('a named key goes to xterm.js after the text typed before it', () => {
    const { page, input } = ime();
    page.field.value = 'ls';
    const enter = event(page.field, 'keydown', { keyCode: 13 });
    input.handle(enter);
    expect(enter.stopped).toBe(false);
    expect(page.typed).toEqual(['ls']);
    const backspace = event(page.field, 'keydown', { keyCode: 8 });
    input.handle(backspace);
    expect(backspace.stopped).toBe(false);
    expect(page.typed).toEqual(['ls']);
  });

  it('a character xterm.js sent on its keypress is not sent again', () => {
    const { page, input } = ime();
    input.handle(event(page.field, 'keydown', { keyCode: 32 }));
    const press = event(page.field, 'keypress', { keyCode: 32 });
    input.handle(press);
    expect(press.stopped).toBe(false);
    page.field.value = ' ';
    input.handle(event(page.field, 'input', { data: ' ' }));
    input.handle(event(page.field, 'keyup', { keyCode: 32 }));
    expect(page.typed).toEqual([]);
    expect(page.field.value).toBe('');
    // The next commit from the input method is sent as usual.
    commit(page, input, 'x');
    expect(page.typed).toEqual(['x']);
  });

  it('a lone line break is Enter; a line break with more is a paste', () => {
    const { page, input } = ime();
    commit(page, input, '\n');
    commit(page, input, 'one\ntwo');
    expect(page.typed).toEqual(['\r']);
    expect(page.pasted).toEqual(['one\ntwo']);
  });

  it('leaves events for other targets alone', () => {
    const { page, input } = ime();
    page.field.value = 'x';
    const elsewhere = event({}, 'input', { data: 'x' });
    input.handle(elsewhere);
    expect(elsewhere.stopped).toBe(false);
    expect(page.typed).toEqual([]);
    const keyup = event(page.field, 'keyup', { keyCode: IME_KEY });
    input.handle(keyup);
    expect(keyup.stopped).toBe(false);
  });
});
