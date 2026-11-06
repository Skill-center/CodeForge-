/**
 * Records real input → next frame latency, whatever the input source: the
 * phone's keyboard (Gboard), DevTools Input.* events in the phase gate, or a
 * hardware keyboard. Each input event's timeStamp is compared with the end of
 * the next frame.
 *
 * Engines receive text differently: contenteditable and textareas fire
 * beforeinput; an element with an EditContext (CodeMirror on Android Chrome
 * 126+, Monaco wherever the API exists) gets textupdate on the context
 * instead. keydown fires in every mode (Gboard sends keyCode 229).
 *
 * One keystroke = a keydown plus one or two text events, timed from its
 * first event to the end of the frame after its last one. A text event joins
 * the current keystroke while that keystroke is still being timed (a long
 * task can delay the text events: Monaco once took 104 ms between keydown and
 * textupdate) or within KEY_WINDOW_MS of it; otherwise it is text input
 * without a key (an IME commit, the emoji keyboard, voice) and is timed on
 * its own.
 */
import { summarize, type Summary } from './stats';
import { afterPaint } from './timing';

const KEY_WINDOW_MS = 50;

export interface InputStats extends Summary {
  events: Record<string, number>;
}

type EditContextHost = Element & { editContext?: EventTarget | null };

interface Keystroke {
  start: number;
  /** Bumped by every event of the keystroke; only the latest frame counts. */
  token: number;
  done: boolean;
}

export class InputRecorder {
  private samples: number[] = [];
  private current: Keystroke | null = null;
  private events: Record<string, number> = {};
  private readonly detach: Array<() => void> = [];

  attach(root: HTMLElement): void {
    this.dispose();
    const listen = (target: EventTarget, type: string, measure: boolean) => {
      const handler = (event: Event) => this.onEvent(type, event, measure);
      target.addEventListener(type, handler, true);
      this.detach.push(() => target.removeEventListener(type, handler, true));
    };
    for (const type of ['keydown', 'beforeinput']) listen(root, type, true);
    for (const type of ['compositionstart', 'compositionend']) listen(root, type, false);
    for (const element of [root, ...Array.from(root.querySelectorAll('*'))]) {
      const context = (element as EditContextHost).editContext;
      if (context) {
        listen(context, 'textupdate', true);
        for (const type of ['compositionstart', 'compositionend']) listen(context, type, false);
      }
    }
  }

  reset(): void {
    this.samples = [];
    this.events = {};
    this.current = null;
  }

  stats(): InputStats {
    return { ...summarize(this.samples), events: { ...this.events } };
  }

  dispose(): void {
    for (const off of this.detach.splice(0)) off();
  }

  private onEvent(type: string, event: Event, measure: boolean): void {
    this.events[type] = (this.events[type] ?? 0) + 1;
    if (!measure) return;
    const at = event.timeStamp;
    const keystroke = this.current;
    if (type !== 'keydown' && keystroke && (!keystroke.done || at - keystroke.start < KEY_WINDOW_MS)) {
      if (!keystroke.done) this.arm(keystroke);
      return;
    }
    const next: Keystroke = { start: at, token: 0, done: false };
    this.current = next;
    this.arm(next);
  }

  /** Times the keystroke to the end of the frame after its latest event. */
  private arm(keystroke: Keystroke): void {
    keystroke.token += 1;
    const token = keystroke.token;
    void afterPaint().then((end) => {
      if (keystroke.done || token !== keystroke.token) return;
      keystroke.done = true;
      this.samples.push(end - keystroke.start);
    });
  }
}
