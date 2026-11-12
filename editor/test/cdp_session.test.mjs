// @vitest-environment node
// The benchmark driver's reconnect (Phase 3 W6, an owner decision): a
// DevTools session that drops is found again and the stage runs again.
import { createServer } from 'node:http';
import { createServer as createTcpServer } from 'node:net';

import { describe, expect, it } from 'vitest';

import { Cdp, DROPPED, PageSession, adb, isDropped, listTargets } from '../tool/cdp_kit.mjs';

/** A fake connection: `evaluate` answers from `script`, in order. */
function fakeCdp(script, log) {
  const cdp = {
    closed: false,
    evaluate: async (expression) => {
      log.push(expression);
      const next = script.shift();
      if (next instanceof Error) {
        if (next.message === DROPPED) cdp.closed = true;
        throw next;
      }
      return next;
    },
    close: () => {
      cdp.closed = true;
    },
  };
  return cdp;
}

/** A page the session can find while `present` says so. */
function fakePage(connections) {
  const page = { present: true, finds: 0, connects: 0 };
  page.find = async () => {
    page.finds += 1;
    return page.present ? { id: 'T1', title: 'codeforge-bench:codemirror:driver', webSocketDebuggerUrl: 'ws://x/T1' } : null;
  };
  page.connect = async (url) => {
    expect(url).toBe('ws://x/T1');
    page.connects += 1;
    return connections.shift();
  };
  return page;
}

describe('isDropped', () => {
  it('knows a dropped session from a page error', () => {
    expect(isDropped(new Error(DROPPED))).toBe(true);
    expect(isDropped(new Error('Runtime.evaluate timed out'))).toBe(true);
    expect(isDropped(new Error('cannot connect to ws://127.0.0.1:9222/x'))).toBe(true);
    expect(isDropped(new Error('codeforgeBench is not defined'))).toBe(false);
    expect(isDropped(new Error('page not found'))).toBe(false);
    expect(isDropped('Runtime.evaluate timed out')).toBe(true);
  });
});

describe('Cdp', () => {
  it('fails at once on a closed socket instead of timing out', async () => {
    const sent = [];
    const ws = { send: (data) => sent.push(data), close: () => {} };
    const cdp = new Cdp(ws);
    const pending = cdp.send('Runtime.evaluate', {}, 60000);
    ws.onclose();
    await expect(pending).rejects.toThrow(DROPPED);
    await expect(cdp.send('Runtime.evaluate', {}, 60000)).rejects.toThrow(DROPPED);
    expect(sent).toHaveLength(1);
  });
});

describe('PageSession', () => {
  it('runs a stage again on a new connection when the session drops', async () => {
    const calls = [];
    const first = fakeCdp(['editcontext', new Error(DROPPED)], calls);
    const second = fakeCdp([{ openMs: 140 }], calls);
    const page = fakePage([first, second]);
    const logged = [];
    const session = new PageSession({ find: page.find, connect: page.connect, log: (m) => logged.push(m), pollMs: 1 });

    expect(await session.run('input mode', (cdp) => cdp.evaluate('mode'))).toBe('editcontext');
    expect(await session.run('memory session', (cdp) => cdp.evaluate('openLarge'))).toEqual({ openMs: 140 });

    expect(calls).toEqual(['mode', 'openLarge', 'openLarge']);
    expect(page.connects).toBe(2);
    expect(session.reconnects).toEqual([
      { stage: 'memory session', attempt: 1, error: DROPPED, at: expect.any(String) },
    ]);
    expect(logged).toEqual([`memory session: ${DROPPED}; reconnecting for attempt 2 of 3`]);
  });

  it('reconnects after a request that timed out', async () => {
    const calls = [];
    const first = fakeCdp([new Error('Runtime.evaluate timed out')], calls);
    const second = fakeCdp([true], calls);
    const page = fakePage([first, second]);
    const session = new PageSession({ find: page.find, connect: page.connect, pollMs: 1 });

    expect(await session.run('hand back', (cdp) => cdp.evaluate('driverDone'))).toBe(true);
    expect(first.closed).toBe(true);
    expect(session.reconnects.map((r) => r.error)).toEqual(['Runtime.evaluate timed out']);
  });

  it('throws an error from the page at once, without reconnecting', async () => {
    const calls = [];
    const page = fakePage([fakeCdp([new Error('codeforgeBench is not defined')], calls)]);
    const session = new PageSession({ find: page.find, connect: page.connect, pollMs: 1 });

    await expect(session.run('input mode', (cdp) => cdp.evaluate('mode'))).rejects.toThrow('codeforgeBench is not defined');
    expect(page.connects).toBe(1);
    expect(session.reconnects).toEqual([]);
  });

  it('gives up after its attempts', async () => {
    const calls = [];
    const page = fakePage([
      fakeCdp([new Error(DROPPED)], calls),
      fakeCdp([new Error(DROPPED)], calls),
      fakeCdp([new Error(DROPPED)], calls),
    ]);
    const session = new PageSession({ find: page.find, connect: page.connect, attempts: 3, pollMs: 1 });

    await expect(session.run('memory session', (cdp) => cdp.evaluate('openLarge'))).rejects.toThrow(DROPPED);
    expect(calls).toHaveLength(3);
    expect(session.reconnects).toHaveLength(2);
  });

  it('waits for the page to show again, and stops when it does not', async () => {
    const calls = [];
    const page = fakePage([fakeCdp([new Error(DROPPED)], calls), fakeCdp(['back'], calls)]);
    const session = new PageSession({ find: page.find, connect: page.connect, pollMs: 1, waitMs: 2000 });
    // The page is gone for a few polls after the drop, then back.
    const find = page.find;
    let gone = 0;
    session.find = async () => {
      if (page.connects === 1 && gone < 3) {
        gone += 1;
        return null;
      }
      return find();
    };
    expect(await session.run('composition', (cdp) => cdp.evaluate('suite'))).toBe('back');
    expect(gone).toBe(3);

    // A page that never comes back: the stage fails with "page not found".
    const lost = new PageSession({ find: async () => null, connect: page.connect, pollMs: 1, waitMs: 20 });
    await expect(lost.run('input mode', (cdp) => cdp.evaluate('mode'))).rejects.toThrow('page not found');
  });
});

// A gate's driver once waited minutes on calls that never finished, and
// missed a whole engine (Phase 3 W6): every call it makes now gives up.
describe('timeouts', () => {
  it('lists no targets when DevTools does not answer', async () => {
    const server = createServer(() => {});
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address();
    const started = Date.now();
    expect(await listTargets(port, 200)).toEqual([]);
    expect(Date.now() - started).toBeLessThan(3000);
    server.closeAllConnections();
    server.close();
  });

  it('stops an adb call that does not finish', async () => {
    const started = Date.now();
    await expect(adb(['5'], 'sleep', 200)).rejects.toThrow();
    expect(Date.now() - started).toBeLessThan(3000);
  });

  it('fails a connection that never opens, as a dropped session', async () => {
    const sockets = [];
    const server = createTcpServer((socket) => sockets.push(socket));
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address();
    const failure = await Cdp.connect(`ws://127.0.0.1:${port}/devtools/page/x`, 200).catch((e) => e);
    expect(String(failure.message)).toMatch(/^cannot connect to .*: no answer in 200 ms$/);
    expect(isDropped(failure)).toBe(true);
    for (const socket of sockets) socket.destroy();
    server.close();
  });
});
