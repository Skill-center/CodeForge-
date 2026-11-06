/**
 * Entry point of the editor page (built into app/assets/editor/editor.html).
 *
 * Transport: the host injects a JavaScript channel named `CodeForgeBridge`
 * (webview_flutter) for editor → host messages, and calls
 * `window.codeforge.receive(json)` for host → editor messages.
 */
import { Bridge } from './bridge';
import { EditorController } from './editor/controller';
import { LANGUAGE_IDS, PROTOCOL_VERSION } from './protocol/types';

declare const __ENGINE_VERSION__: string;

interface HostChannel {
  postMessage(message: string): void;
}

declare global {
  interface Window {
    CodeForgeBridge?: HostChannel;
    codeforge?: { receive(raw: unknown): void };
  }
}

const channel = window.CodeForgeBridge;
const bridge = new Bridge((raw) => channel?.postMessage(raw));
const parent = document.getElementById('editor') ?? document.body;
const controller = new EditorController({ parent, emit: (type, payload) => bridge.emit(type, payload) });
bridge.attach(controller);

window.codeforge = Object.freeze({ receive: (raw: unknown) => bridge.receive(raw) });

window.addEventListener('error', (event) => {
  bridge.log('error', `${event.message} (${event.filename}:${event.lineno})`);
});
window.addEventListener('unhandledrejection', (event) => {
  bridge.log('error', `unhandled rejection: ${String(event.reason)}`);
});
// The page is about to be hidden (app paused): hand the host every edit now.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') controller.flush();
});

bridge.emit('editor.ready', {
  protocol: PROTOCOL_VERSION,
  engine: 'codemirror',
  engineVersion: __ENGINE_VERSION__,
  languages: [...LANGUAGE_IDS],
});
