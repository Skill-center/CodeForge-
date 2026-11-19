/**
 * Entry point of the terminal page (built into app/assets/terminal/terminal.html
 * by tool/build_terminal.mjs; Phase 5 W3).
 *
 * Transport, as the editor page's: the host injects a JavaScript channel
 * named `CodeForgeBridge` (webview_flutter) for page → host messages, and
 * calls `window.codeforge.receive(json)` for host → page messages.
 */
import { FitAddon } from '@xterm/addon-fit';
import { Unicode11Addon } from '@xterm/addon-unicode11';
import { Terminal } from '@xterm/xterm';

import { TerminalBridge } from './bridge';
import { DEFAULT_FONT_SIZE, type TerminalFactory, type TerminalLike, TerminalController } from './controller';
import { TERMINAL_PROTOCOL_VERSION } from './protocol';
import type { TouchPoint } from './touch';

declare const __XTERM_VERSION__: string;

/** The editor page declares the window's channel types; this page reads them through a cast. */
const page = window as unknown as {
  CodeForgeBridge?: { postMessage(message: string): void };
  codeforge?: { receive(raw: unknown): void };
};

/** One xterm.js terminal: the bundled font, Unicode 11 widths, no blinking (nothing animates forever). */
const createXterm: TerminalFactory = ({ fontSize, scrollback, theme }) => {
  const terminal = new Terminal({
    allowProposedApi: true,
    fontFamily: '"JetBrains Mono", monospace',
    fontSize,
    scrollback,
    theme,
    cursorBlink: false,
    drawBoldTextInBrightColors: true,
    scrollOnUserInput: true,
  });
  const fit = new FitAddon();
  terminal.loadAddon(fit);
  terminal.loadAddon(new Unicode11Addon());
  terminal.unicode.activeVersion = '11';
  return { terminal: terminal as unknown as TerminalLike, fit: () => fit.fit() };
};

const channel = page.CodeForgeBridge;
const bridge = new TerminalBridge((raw) => channel?.postMessage(raw));
const parent = document.getElementById('terminals') ?? document.body;
const controller = new TerminalController({
  parent,
  emit: (type, payload) => bridge.emit(type, payload),
  createTerminal: createXterm,
});
bridge.attach(controller);

page.codeforge = Object.freeze({ receive: (raw: unknown) => bridge.receive(raw) });

window.addEventListener('error', (event) => {
  bridge.log('error', `${event.message} (${event.filename}:${event.lineno})`);
});
window.addEventListener('unhandledrejection', (event) => {
  bridge.log('error', `unhandled rejection: ${String(event.reason)}`);
});

// Touch: scrolling and selecting (touch.ts). The terminals' `touch-action:
// none` keeps the WebView from panning and zooming. A tap's touches are left
// to the WebView: from a tap it takes the app's focus (and xterm.js, from
// the tap's mousedown, its input's), as in the editor's page; a page whose
// view lacks the focus gets no focus event, so canceling a tap kept the
// terminal from the keyboard (phase gate 44557551890). A drag's and a
// selection's touches are canceled, so the WebView synthesizes no mouse
// that would start xterm's own selection.
const points = (list: TouchList): TouchPoint[] =>
  Array.from(list, (touch) => ({ clientX: touch.clientX, clientY: touch.clientY }));
parent.addEventListener(
  'touchstart',
  (event) => {
    controller.gestures.down(points(event.touches));
  },
  { passive: true },
);
parent.addEventListener(
  'touchmove',
  (event) => {
    controller.gestures.move(points(event.touches));
    if (controller.gestures.consuming) event.preventDefault();
  },
  { passive: false },
);
parent.addEventListener(
  'touchend',
  (event) => {
    const end = controller.gestures.up();
    if (end === 'drag' || end === 'select') event.preventDefault();
  },
  { passive: false },
);
parent.addEventListener('touchcancel', () => controller.gestures.cancel());
// A long press is the page's selection: neither the WebView's menu nor
// xterm.js's right-click handling (which fills and selects its input).
parent.addEventListener(
  'contextmenu',
  (event) => {
    event.preventDefault();
    event.stopPropagation();
  },
  true,
);

// A paste through the WebView itself takes the same sanitized path as the app's.
parent.addEventListener(
  'paste',
  (event) => {
    event.preventDefault();
    event.stopPropagation();
    controller.pasteIntoActive(event.clipboardData?.getData('text/plain') ?? '');
  },
  true,
);

// The panel's size: the shown terminal follows it, at most every 50 ms.
let layoutTimer: ReturnType<typeof setTimeout> | null = null;
const scheduleLayout = (): void => {
  if (layoutTimer !== null) clearTimeout(layoutTimer);
  layoutTimer = setTimeout(() => {
    layoutTimer = null;
    controller.layout();
  }, 50);
};
if (typeof ResizeObserver !== 'undefined') new ResizeObserver(scheduleLayout).observe(parent);
window.addEventListener('resize', scheduleLayout);

/** The bundled font, loaded before any terminal measures its cells (at most 2 s). */
async function fontReady(): Promise<void> {
  const fonts = (document as Document & { fonts?: FontFaceSet }).fonts;
  if (!fonts || typeof fonts.load !== 'function') return;
  await Promise.race([
    fonts.load(`${DEFAULT_FONT_SIZE}px "JetBrains Mono"`).then(
      () => undefined,
      () => undefined,
    ),
    new Promise<void>((resolve) => setTimeout(resolve, 2000)),
  ]);
}

void fontReady().then(() =>
  bridge.emit('terminal.ready', {
    protocol: TERMINAL_PROTOCOL_VERSION,
    engine: 'xterm',
    engineVersion: __XTERM_VERSION__,
  }),
);
