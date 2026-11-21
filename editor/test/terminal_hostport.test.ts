import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  HOST_PORT_HELLO,
  type HostPort,
  type HostPortMessage,
  type HostPortTarget,
  listenForHostPort,
} from '../src/terminal/hostport';

/** The window as the page listens to it: messages are handed in by the test. */
class FakeWindow implements HostPortTarget {
  private readonly listeners: Array<(event: HostPortMessage) => void> = [];

  addEventListener(_type: 'message', listener: (event: HostPortMessage) => void): void {
    this.listeners.push(listener);
  }

  post(event: HostPortMessage): void {
    for (const listener of this.listeners) listener(event);
  }
}

function port(): HostPort & { deliver(data: unknown): void } {
  const fake = {
    onmessage: null as HostPort['onmessage'],
    deliver(data: unknown) {
      fake.onmessage?.({ data });
    },
  };
  return fake;
}

const fromApp = (ports: HostPort[], data: unknown = HOST_PORT_HELLO): HostPortMessage => ({
  data,
  source: null,
  ports,
});

describe('the host port (Phase 5 W6)', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('takes the port the app posts and hands on what arrives through it', async () => {
    const window = new FakeWindow();
    const received: unknown[] = [];
    const listener = listenForHostPort(window, (raw) => received.push(raw));
    expect(listener.attached).toBe(false);
    const waiting = listener.wait(1500);
    const hostPort = port();
    window.post(fromApp([hostPort]));
    expect(listener.attached).toBe(true);
    await expect(waiting).resolves.toBe(true);
    hostPort.deliver('{"v":1}');
    hostPort.deliver('{"v":1,"id":"h2"}');
    expect(received).toEqual(['{"v":1}', '{"v":1,"id":"h2"}']);
    // Already held: no wait.
    await expect(listener.wait(1500)).resolves.toBe(true);
  });

  it('announces itself without a port once the wait is over', async () => {
    const listener = listenForHostPort(new FakeWindow(), () => undefined);
    const waiting = listener.wait(1500);
    await vi.advanceTimersByTimeAsync(1499);
    let settled = false;
    void waiting.then(() => (settled = true));
    await Promise.resolve();
    expect(settled).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    await expect(waiting).resolves.toBe(false);
  });

  it('ignores anything that is not the app’s port', () => {
    const window = new FakeWindow();
    const received: unknown[] = [];
    const listener = listenForHostPort(window, (raw) => received.push(raw));
    const fromPage = port();
    // The page's own scripts post with a source window.
    window.post({ data: HOST_PORT_HELLO, source: {}, ports: [fromPage] });
    // Another message, no port, or two ports.
    const other = port();
    window.post(fromApp([other], 'something else'));
    window.post(fromApp([]));
    window.post(fromApp([port(), port()]));
    expect(listener.attached).toBe(false);
    expect(fromPage.onmessage).toBeNull();
    expect(other.onmessage).toBeNull();
  });

  it('takes a later port as well: the app opens a new one for each load', () => {
    const window = new FakeWindow();
    const received: unknown[] = [];
    listenForHostPort(window, (raw) => received.push(raw));
    const first = port();
    const second = port();
    window.post(fromApp([first]));
    window.post(fromApp([second]));
    first.deliver('one');
    second.deliver('two');
    expect(received).toEqual(['one', 'two']);
  });
});
