/// TerminalView against a scripted page (test/support/fake_terminal_surface).
/// testWidgets supplies fake time, so the ready timeout runs exactly and
/// every test proves no timer outlives the view.
library;

import 'package:codeforge/application/terminal/terminal_view.dart';
import 'package:codeforge/core/editor/rate_limiter.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/terminal/terminal_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_terminal_surface.dart';

void main() {
  late FakeTerminalSurface page;
  late TerminalView view;
  late List<TerminalViewEvent> events;

  /// Microtasks and stream deliveries only; no time passes.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  Future<void> createView(
    WidgetTester tester, {
    bool start = true,
    MessageRateLimiter? rateLimiter,
  }) async {
    page = FakeTerminalSurface();
    view = TerminalView(
      surface: page,
      loadPage: () async => const Ok(fakeTerminalPage),
      rateLimiter: rateLimiter,
    );
    events = [];
    final subscription = view.events.listen(events.add);
    addTearDown(subscription.cancel);
    if (start) {
      await view.start();
      await settle(tester);
    }
  }

  testWidgets('the page loads on start, once, and announces itself', (
    tester,
  ) async {
    await createView(tester, start: false);
    expect(view.status.phase, TerminalViewPhase.idle);
    expect(page.loads, 0);
    await view.start();
    await view.start();
    await settle(tester);
    expect(page.loads, 1);
    expect(view.isReady, isTrue);
    expect(view.status.engineVersion, '0.0.0');
    expect(events.whereType<TerminalPageStarted>().single.starts, 1);
    await view.dispose();
  });

  testWidgets('host messages go through the page’s port once it holds one', (
    tester,
  ) async {
    await createView(tester, start: false);
    page.pageHoldsPort = true;
    await view.start();
    await settle(tester);
    expect(page.portRequests, 1);
    expect(page.throughPort, isTrue);
    expect(view.throughPort, isTrue);
    // A page restarted without it goes back to scripts.
    page.pageHoldsPort = false;
    page.restartPage();
    await settle(tester);
    expect(page.portRequests, 1);
    expect(view.throughPort, isFalse);
    await view.dispose();
  });

  testWidgets('without a port on either side, the page keeps scripts', (
    tester,
  ) async {
    await createView(tester);
    expect(page.portRequests, 0);
    expect(view.throughPort, isFalse);
    await view.dispose();
    await createView(tester, start: false);
    page
      ..pageHoldsPort = true
      ..hasPort = false;
    await view.start();
    await settle(tester);
    expect(page.portRequests, 1);
    expect(view.throughPort, isFalse);
    expect(view.isReady, isTrue);
    await view.dispose();
  });

  testWidgets('a page that never starts fails after the timeout', (
    tester,
  ) async {
    await createView(tester, start: false);
    page.announceReady = false;
    await view.start();
    await settle(tester);
    expect(view.status.phase, TerminalViewPhase.loading);
    await tester.pump(const Duration(seconds: 21));
    expect(view.status.phase, TerminalViewPhase.failed);
    expect(view.status.message, contains('did not start'));
    await view.dispose();
  });

  testWidgets('a WebView older than the page’s floor is refused, with why', (
    tester,
  ) async {
    await createView(tester, start: false);
    page.engineMajor = 69;
    await view.start();
    await settle(tester);
    expect(view.status.phase, TerminalViewPhase.failed);
    expect(view.status.message, contains('version 69'));
    expect(page.loads, 0);
    await view.dispose();
  });

  testWidgets('requests wait for nothing before the page is ready', (
    tester,
  ) async {
    await createView(tester, start: false);
    expect((await view.open(1)).isOk, isFalse);
    expect(view.write(1, 0, 'x'), isFalse);
    expect(page.received, isEmpty);
    await view.dispose();
  });

  testWidgets('open answers the fitted size; writes come back as acks', (
    tester,
  ) async {
    await createView(tester);
    page.columns = 51;
    page.rows = 17;
    final size = (await view.open(4)).orThrow;
    expect(size, (columns: 51, rows: 17));
    expect(view.write(4, 0, 'hello '), isTrue);
    expect(view.write(4, 1, 'world'), isTrue);
    await settle(tester);
    expect(page.sessions[4]!.written.toString(), 'hello world');
    expect(
      [
        for (final event in events.whereType<TerminalAcknowledged>())
          (event.sessionId, event.seq),
      ],
      [(4, 0), (4, 1)],
    );
    await view.dispose();
  });

  testWidgets('a write the page refuses waits for no answer', (tester) async {
    await createView(tester);
    expect(view.write(9, 0, 'nobody'), isTrue);
    await settle(tester);
    expect(events.whereType<TerminalAcknowledged>(), isEmpty);
    expect(page.received.single.type, 'session.write');
    await view.dispose();
  });

  testWidgets('keys, pastes, selection and the snapshot reach the page', (
    tester,
  ) async {
    await createView(tester);
    await view.open(1);
    expect((await view.key(1, 'up', ctrl: true)).isOk, isTrue);
    expect((await view.paste(1, 'echo hi\n')).isOk, isTrue);
    page.sessions[1]!.selection = 'picked';
    expect((await view.copy(1)).orThrow, 'picked');
    expect((await view.select(1, all: false)).isOk, isTrue);
    page.sessions[1]!.screen = const [r'$ ls', 'a.txt'];
    final snapshot = (await view.snapshot(1, scrollback: 5)).orThrow;
    expect(snapshot.screen, [r'$ ls', 'a.txt']);
    expect(snapshot.columns, page.columns);
    expect(snapshot.alternate, isFalse);
    expect(page.keys.single, (sessionId: 1, key: 'up', ctrl: true, alt: false));
    expect(page.pastes.single.text, 'echo hi\n');
    expect(page.selects, ['none']);
    expect(page.rejected, isEmpty);
    await view.dispose();
  });

  testWidgets('a paste over the limit is refused before the page', (
    tester,
  ) async {
    await createView(tester);
    await view.open(1);
    final result = await view.paste(1, 'x' * (maxPasteChars + 1));
    expect(result.failureOrNull, isA<TerminalFailure>());
    expect(page.pastes, isEmpty);
    await view.dispose();
  });

  testWidgets('what the page reports becomes events', (tester) async {
    await createView(tester);
    await view.open(2);
    page
      ..type(2, 'ls\r')
      ..type(2, '\u001b[M !!', binary: true)
      ..resize(2, columns: 40, rows: 12)
      ..select(2, 'x')
      ..reportFocus(focused: true)
      ..releaseModifiers()
      ..title(2, 'nano')
      ..bell(2);
    await settle(tester);
    final input = events.whereType<TerminalInput>().toList();
    expect(
      [for (final e in input) (e.sessionId, e.data, e.binary)],
      [(2, 'ls\r', false), (2, '\u001b[M !!', true)],
    );
    final resized = events.whereType<TerminalResized>().single;
    expect((resized.columns, resized.rows), (40, 12));
    expect(events.whereType<TerminalSelectionChanged>().single.active, isTrue);
    expect(events.whereType<TerminalFocusChanged>().single.focused, isTrue);
    expect(events.whereType<TerminalModifiersChanged>().single.ctrl, isFalse);
    expect(events.whereType<TerminalTitled>().single.title, 'nano');
    expect(events.whereType<TerminalBell>().single.sessionId, 2);
    await view.dispose();
  });

  testWidgets('a restart is announced, and the appearance sent again', (
    tester,
  ) async {
    await createView(tester);
    await view.configure({'fontSize': 15});
    expect(page.configuration?['fontSize'], 15);
    page.restartPage();
    await settle(tester);
    expect(view.pageStarts, 2);
    expect(events.whereType<TerminalPageStarted>().last.starts, 2);
    expect(page.configuration?['fontSize'], 15);
    await view.dispose();
  });

  testWidgets('the renderer and the probes reach the page (Phase 5 W6)', (
    tester,
  ) async {
    await createView(tester);
    await view.configure({'fontSize': 15});
    expect((await view.setRenderer('webgl')).isOk, isTrue);
    expect(page.configuration?['renderer'], 'webgl');
    expect(page.configuration?['fontSize'], 15);
    await view.open(3);
    expect((await view.startEchoProbe(3, count: 20, gapMs: 30)).isOk, isTrue);
    expect(
      (await view.startFloodProbe(3, begin: '\x1b]777;b\x07', end: 'END')).isOk,
      isTrue,
    );
    expect(page.probes, [
      {'type': 'probe.echo', 'sessionId': 3, 'count': 20, 'gapMs': 30},
      {
        'type': 'probe.flood',
        'sessionId': 3,
        'begin': '\x1b]777;b\x07',
        'end': 'END',
      },
    ]);
    // A probe on a session with no view is refused, as any request is.
    expect((await view.startEchoProbe(9)).isOk, isFalse);
    page.probeReport = const {
      'state': 'done',
      'kind': 'echo',
      'sessionId': 3,
      'renderers': {'3': 'webgl'},
      'echo': {'count': 20, 'p95Ms': 12.5, 'lost': 0},
    };
    final report = (await view.readProbe()).orThrow;
    expect(report['state'], 'done');
    expect((report['echo']! as Map<String, Object?>)['p95Ms'], 12.5);
    // A restart keeps the renderer with the appearance.
    page.restartPage();
    await settle(tester);
    expect(page.configuration?['renderer'], 'webgl');
    await view.dispose();
  });

  testWidgets('invalid page messages are dropped, and floods are limited', (
    tester,
  ) async {
    await createView(
      tester,
      // The page's terminal.ready takes the first of four tokens.
      rateLimiter: MessageRateLimiter(capacity: 4, refillPerSecond: 0),
    );
    page
      ..emitRaw('{not json')
      ..emit('session.input', {'sessionId': 0, 'data': 'x'})
      ..type(1, 'a')
      ..type(1, 'b');
    await settle(tester);
    expect(events.whereType<TerminalInput>().map((e) => e.data), ['a']);
    expect(view.droppedMessages, 1);
    await view.dispose();
  });
}
