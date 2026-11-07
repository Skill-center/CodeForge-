import { EditorView, runScopeHandlers } from '@codemirror/view';

import { EditorController } from '../src/editor/controller';
import type { EditorMessageType, EditorToHost } from '../src/protocol/types';
import { FakeScheduler } from './helpers';

export interface Sent {
  type: EditorMessageType;
  payload: unknown;
}

/** A controller on a fresh page, with its timers and messages in the test's hands. */
export function setupController() {
  document.body.innerHTML = '<div id="editor"></div>';
  const parent = document.getElementById('editor') as HTMLElement;
  const scheduler = new FakeScheduler();
  const sent: Sent[] = [];
  const ctl = new EditorController({ parent, scheduler, emit: (type, payload) => void sent.push({ type, payload }) });
  const of = <K extends EditorMessageType>(type: K): Array<EditorToHost[K]> =>
    sent.filter((m) => m.type === type).map((m) => m.payload as EditorToHost[K]);
  return { ctl, scheduler, sent, of };
}

/**
 * Types [text] at the main cursor the way the browser delivers input: the
 * view's input handlers (auto-closing brackets) get the first say, then it
 * lands as typed text, which input rules such as re-indenting react to.
 */
export function typeText(view: EditorView, text: string): void {
  const { from, to } = view.state.selection.main;
  const typed = () =>
    view.state.update({
      changes: { from, to, insert: text },
      selection: { anchor: from + text.length },
      userEvent: 'input.type',
    });
  const handled = view.state.facet(EditorView.inputHandler).some((handler) => handler(view, from, to, text, typed));
  if (!handled) view.dispatch(typed());
}

/** Presses a key in the editor; true when a binding handled it. */
export function pressKey(view: EditorView, key: string, mods: { ctrl?: boolean; shift?: boolean } = {}): boolean {
  const event = new KeyboardEvent('keydown', { key, ctrlKey: mods.ctrl ?? false, shiftKey: mods.shift ?? false });
  return runScopeHandlers(view, event, 'editor');
}
