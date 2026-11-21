/**
 * The host's MessagePort (Phase 5 W6). As the page finishes loading, the app
 * posts it one end of a message channel (Android's WebView.postWebMessage;
 * app/android's webview/PagePorts.kt). From then on host messages can
 * arrive through that port instead of as one script each
 * (`window.codeforge.receive`, which stays for a host without a port). A
 * script per message cost the page a parse and a compile for every batch of
 * output, and on the phone V8 had not collected the scripts of a 10 MiB
 * flood 15 s later (docs/TERMINAL_ARCHITECTURE.md §2.2).
 *
 * Order: the page says in `terminal.ready` whether it holds the port, and
 * the host sends nothing before `terminal.ready`. So the host never has a
 * script in flight when it starts sending through the port, and messages
 * through one port keep their order. A port the host sends through before
 * the page listens keeps its messages until the page does.
 */

/** The data of the app's message that carries the port. */
export const HOST_PORT_HELLO = 'codeforge-host-port';

/**
 * How long the page waits for the port before it announces itself without
 * one (ms). The app posts it as soon as the page has loaded; a host that
 * posts none (an older app, a test) costs the page this much at start.
 */
export const HOST_PORT_WAIT_MS = 1500;

/** The part of a MessagePort this needs. */
export interface HostPort {
  onmessage: ((event: { data: unknown }) => void) | null;
}

/** The part of a message event this needs. */
export interface HostPortMessage {
  readonly data: unknown;
  readonly source: unknown;
  readonly ports: ReadonlyArray<HostPort>;
}

/** Where the app's message arrives: the window. */
export interface HostPortTarget {
  addEventListener(type: 'message', listener: (event: HostPortMessage) => void): void;
}

export interface HostPortListener {
  /** Whether the page holds a port from the app. */
  readonly attached: boolean;
  /** Resolves with [attached] once a port is there, or after [ms] without one. */
  wait(ms: number): Promise<boolean>;
}

/**
 * Takes the app's port from each message on [target] that carries one and
 * hands everything that arrives through it to [receive]. Only the app's own
 * messages count: one that WebView.postWebMessage sends has no source
 * window, while whatever the page's own scripts post to the window has one.
 * A later port is taken as well (the app opens a new one for each load,
 * closing the one before), and nothing else the window receives is touched.
 */
export function listenForHostPort(target: HostPortTarget, receive: (raw: unknown) => void): HostPortListener {
  let attached = false;
  const waiting: Array<(attached: boolean) => void> = [];
  target.addEventListener('message', (event) => {
    if (event.source !== null || event.data !== HOST_PORT_HELLO || event.ports.length !== 1) return;
    const port = event.ports[0];
    if (port === undefined) return;
    // Setting onmessage starts the port: what the host sent meanwhile follows.
    port.onmessage = (message) => receive(message.data);
    attached = true;
    for (const resolve of waiting.splice(0)) resolve(true);
  });
  return {
    get attached() {
      return attached;
    },
    wait(ms: number): Promise<boolean> {
      if (attached) return Promise.resolve(true);
      return new Promise((resolve) => {
        const done = (value: boolean) => {
          const index = waiting.indexOf(done);
          if (index !== -1) waiting.splice(index, 1);
          resolve(value);
        };
        waiting.push(done);
        setTimeout(() => done(attached), ms);
      });
    },
  };
}
