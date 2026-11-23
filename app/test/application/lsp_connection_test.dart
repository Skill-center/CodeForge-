/// JSON-RPC over one server's messages (Phase 6 W4, gate G4): ids and
/// answers matched in any order, timeouts and cancellation with
/// `$/cancelRequest`, the server's errors, its own requests answered, and
/// each request's stages timed from the host's stamps. Since Phase 6 W7, a
/// server that says nothing after it is asked something is reported.
library;

import 'dart:convert';

import 'package:codeforge/application/lsp/lsp_connection.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_lsp_clock.dart';

Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Matcher _fails(LspProblem problem) => isA<Err<Object?>>().having(
  (e) => e.failure,
  'failure',
  isA<LspFailure>().having((f) => f.problem, 'problem', problem),
);

/// A connection over a recorded pipe.
final class _Pipe {
  _Pipe({this.writtenAfterUs = 100, Duration? silenceLimit}) {
    connection = LspConnection(
      server: LspServerId.pyright,
      send: (json) async {
        sent.add(jsonDecode(json) as Map<String, Object?>);
        if (refuse) {
          return const Err(LspFailure('gone', problem: LspProblem.notRunning));
        }
        return Ok(LspWritten(writtenUs: clock.monotonicUs + writtenAfterUs));
      },
      clock: clock,
      onRequest: (method, params) async {
        requests.add(method);
        return switch (method) {
          'workspace/configuration' => const LspReply.result([
            {'a': 1},
          ]),
          'client/registerCapability' => const LspReply.result(null),
          _ => const LspReply.error(JsonRpcErrors.methodNotFound, 'not here'),
        };
      },
      onNotification: (method, params) => notifications.add(method),
      onTiming: timings.add,
      silenceLimit: silenceLimit,
      onSilent: () {
        silences += 1;
        return false;
      },
    );
  }

  final int writtenAfterUs;
  final FakeLspClock clock = FakeLspClock();
  final List<Map<String, Object?>> sent = [];
  final List<String> requests = [];
  final List<String> notifications = [];
  final List<LspTiming> timings = [];
  bool refuse = false;
  late final LspConnection connection;

  /// How often the connection reported the server silent.
  int silences = 0;

  void answer(Object id, Object? result, {int? readUs}) => connection.receive(
    jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
    readUs: readUs,
  );

  List<Map<String, Object?>> cancels() => [
    for (final message in sent)
      if (message['method'] == r'$/cancelRequest') message,
  ];
}

void main() {
  test('requests are numbered, and answers find theirs in any order', () async {
    final pipe = _Pipe();
    final first = pipe.connection.request('textDocument/hover', {
      'x': 1,
    }, timeout: const Duration(seconds: 10));
    final second = pipe.connection.request(
      'textDocument/definition',
      null,
      timeout: const Duration(seconds: 10),
    );
    await _drain();
    expect(pipe.sent, [
      {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'textDocument/hover',
        'params': {'x': 1},
      },
      {'jsonrpc': '2.0', 'id': 2, 'method': 'textDocument/definition'},
    ]);
    expect(pipe.connection.waiting, 2);
    pipe
      ..answer(2, 'two')
      ..answer(1, {'contents': 'one'});
    expect((await first).valueOrNull, {'contents': 'one'});
    expect((await second).valueOrNull, 'two');
    expect(pipe.connection.waiting, 0);
  });

  test('a request past its timeout fails, the server is told to stop, and '
      'its late answer is dropped', () async {
    final pipe = _Pipe();
    final asked = pipe.connection.request(
      'textDocument/completion',
      null,
      timeout: const Duration(seconds: 2),
    );
    await _drain();
    pipe.clock.advance(const Duration(milliseconds: 1999));
    expect(pipe.cancels(), isEmpty);
    pipe.clock.advance(const Duration(milliseconds: 1));
    expect(await asked, _fails(LspProblem.timeout));
    await _drain();
    expect(pipe.cancels().single['params'], {'id': 1});
    pipe.answer(1, ['late']);
    expect(pipe.connection.waiting, 0);
    expect(pipe.timings.single.outcome, 'timeout');
    expect(pipe.timings.single.totalUs, 2000000);
  });

  test('a request called off fails at once and the server is told', () async {
    final pipe = _Pipe();
    final cancel = LspCancel();
    final asked = pipe.connection.request(
      'textDocument/completion',
      null,
      timeout: const Duration(seconds: 2),
      cancel: cancel,
    );
    await _drain();
    cancel.cancel();
    expect(await asked, _fails(LspProblem.cancelled));
    await _drain();
    expect(pipe.cancels().single['params'], {'id': 1});
    expect(pipe.clock.pending, 0);
    // One already called off does not go out.
    expect(
      await pipe.connection.request(
        'textDocument/hover',
        null,
        timeout: const Duration(seconds: 1),
        cancel: cancel,
      ),
      _fails(LspProblem.cancelled),
    );
    expect(
      pipe.sent.where((m) => m['method'] == 'textDocument/hover'),
      isEmpty,
    );
  });

  test("the server's errors fail the request with their code", () async {
    final pipe = _Pipe();
    final failed = pipe.connection.request(
      'textDocument/rename',
      null,
      timeout: const Duration(seconds: 10),
    );
    final cancelled = pipe.connection.request(
      'textDocument/completion',
      null,
      timeout: const Duration(seconds: 2),
    );
    await _drain();
    pipe.connection
      ..receive(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': JsonRpcErrors.contentModified, 'message': 'moved'},
        }),
      )
      ..receive(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 2,
          'error': {'code': JsonRpcErrors.requestCancelled, 'message': ''},
        }),
      );
    final result = await failed;
    expect(result, _fails(LspProblem.serverError));
    final failure = result.failureOrNull! as LspFailure;
    expect(failure.errorCode, JsonRpcErrors.contentModified);
    expect(failure.message, 'moved');
    expect(await cancelled, _fails(LspProblem.cancelled));
  });

  test(
    "the server's own requests are answered; its notifications heard",
    () async {
      final pipe = _Pipe();
      pipe.connection
        ..receive(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 7,
            'method': 'workspace/configuration',
            'params': {'items': <Object?>[]},
          }),
        )
        ..receive(
          jsonEncode({'jsonrpc': '2.0', 'id': 'r8', 'method': 'unknown/thing'}),
        )
        ..receive(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'window/logMessage',
            'params': {'type': 3, 'message': 'hi'},
          }),
        );
      await _drain();
      expect(pipe.requests, ['workspace/configuration', 'unknown/thing']);
      expect(pipe.notifications, ['window/logMessage']);
      expect(pipe.sent, [
        {
          'jsonrpc': '2.0',
          'id': 7,
          'result': [
            {'a': 1},
          ],
        },
        {
          'jsonrpc': '2.0',
          'id': 'r8',
          'error': {
            'code': JsonRpcErrors.methodNotFound,
            'message': 'not here',
          },
        },
      ]);
    },
  );

  test('what is not JSON-RPC is counted and dropped', () {
    final pipe = _Pipe();
    pipe.connection
      ..receive('not json')
      ..receive('[1, 2]')
      ..receive(jsonEncode({'jsonrpc': '2.0', 'result': 1}));
    expect(pipe.connection.malformed, 3);
  });

  test('closing fails every request waiting, as the problem named', () async {
    final pipe = _Pipe();
    final asked = pipe.connection.request(
      'textDocument/hover',
      null,
      timeout: const Duration(seconds: 10),
    );
    await _drain();
    pipe.connection.close(LspProblem.restarting, 'Pyright is restarting.');
    expect(await asked, _fails(LspProblem.restarting));
    expect(pipe.clock.pending, 0);
    expect(
      await pipe.connection.request(
        'textDocument/hover',
        null,
        timeout: const Duration(seconds: 10),
      ),
      _fails(LspProblem.notRunning),
    );
    pipe.connection.notify('exit', null);
    await _drain();
    expect(pipe.sent.length, 1);
  });

  test('a request the host could not write fails with its problem', () async {
    final pipe = _Pipe()..refuse = true;
    final asked = pipe.connection.request(
      'textDocument/hover',
      null,
      timeout: const Duration(seconds: 10),
    );
    expect(await asked, _fails(LspProblem.notRunning));
    expect(pipe.clock.pending, 0);
  });

  test("each request's time splits into the host's queue, the server and "
      'the delivery', () async {
    final pipe = _Pipe(writtenAfterUs: 300);
    final sentAt = pipe.clock.monotonicUs;
    final asked = pipe.connection.request(
      'textDocument/completion',
      null,
      timeout: const Duration(seconds: 2),
    );
    await _drain();
    // Written 300 µs after the send; read 40 ms after that; handled 2 ms
    // after the read.
    pipe.clock.advance(const Duration(milliseconds: 42, microseconds: 300));
    pipe.answer(1, <Object?>[], readUs: sentAt + 300 + 40000);
    await asked;
    final timing = pipe.timings.single;
    expect(timing.server, LspServerId.pyright);
    expect(timing.method, 'textDocument/completion');
    expect(timing.outcome, 'ok');
    expect(timing.queueUs, 300);
    expect(timing.serverUs, 40000);
    expect(timing.deliveryUs, 2000);
    expect(timing.totalUs, 42300);
  });

  test('without the host\'s stamps only the total is known', () async {
    final pipe = _Pipe();
    final asked = pipe.connection.request(
      'textDocument/hover',
      null,
      timeout: const Duration(seconds: 2),
    );
    await _drain();
    pipe.answer(1, null);
    await asked;
    expect(pipe.timings.single.deliveryUs, isNull);
    expect(pipe.timings.single.serverUs, isNull);
    expect(pipe.timings.single.queueUs, 100);
  });

  test('calling a request off twice calls it off once', () async {
    final pipe = _Pipe();
    final cancel = LspCancel();
    final asked = pipe.connection.request(
      'textDocument/completion',
      null,
      timeout: const Duration(seconds: 2),
      cancel: cancel,
    );
    expect(cancel.isCancelled, isFalse);
    cancel
      ..cancel()
      ..cancel();
    expect(cancel.isCancelled, isTrue);
    expect(await asked, _fails(LspProblem.cancelled));
    await _drain();
    expect(pipe.cancels(), hasLength(1));
  });

  test('a server that says nothing for the limit after it is asked is '
      'reported, and again each limit while it stays so; what it says moves '
      'the limit on, and an answer that leaves nothing waiting ends the '
      'watch', () async {
    final pipe = _Pipe(silenceLimit: const Duration(seconds: 30));
    pipe.clock.advance(const Duration(minutes: 1));
    expect(pipe.clock.pending, 0, reason: 'nothing asked, nothing watched');

    final answered = pipe.connection.request(
      'textDocument/hover',
      null,
      timeout: const Duration(seconds: 10),
    );
    await _drain();
    pipe.clock.advance(const Duration(seconds: 5));
    pipe.answer(1, null);
    expect(await answered, isA<Ok<Object?>>());
    expect(pipe.clock.pending, 0, reason: 'answered: the watch ends');

    final waiting = pipe.connection.request(
      'textDocument/definition',
      null,
      timeout: const Duration(minutes: 5),
    );
    await _drain();
    pipe.clock.advance(const Duration(seconds: 20));
    pipe.connection.receive(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': r'$/progress',
        'params': <String, Object?>{},
      }),
    );
    pipe.clock.advance(const Duration(milliseconds: 29999));
    expect(pipe.silences, 0);
    pipe.clock.advance(const Duration(milliseconds: 1));
    expect(pipe.silences, 1);
    pipe.clock.advance(const Duration(seconds: 30));
    expect(pipe.silences, 2, reason: 'not dealt with: watched again');
    pipe.connection.close(LspProblem.restarting, 'hung');
    expect(await waiting, _fails(LspProblem.restarting));
    expect(pipe.clock.pending, 0);
  });

  test('a request given up still counts, since a server answers even '
      'those', () async {
    final pipe = _Pipe(silenceLimit: const Duration(seconds: 30));
    final asked = pipe.connection.request(
      'textDocument/completion',
      null,
      timeout: const Duration(seconds: 2),
    );
    await _drain();
    pipe.clock.advance(const Duration(seconds: 2));
    expect(await asked, _fails(LspProblem.timeout));
    pipe.clock.advance(const Duration(milliseconds: 27999));
    expect(pipe.silences, 0);
    pipe.clock.advance(const Duration(milliseconds: 1));
    expect(pipe.silences, 1);
    // Its late answer is news: the watch ends.
    pipe.answer(1, null);
    expect(pipe.clock.pending, 0);
  });

  test('without a limit nothing is watched', () async {
    final pipe = _Pipe();
    final asked = pipe.connection.request(
      'textDocument/hover',
      null,
      timeout: const Duration(minutes: 5),
    );
    await _drain();
    expect(pipe.clock.pending, 1, reason: 'only its timeout');
    pipe.clock.advance(const Duration(minutes: 5));
    expect(await asked, _fails(LspProblem.timeout));
    expect(pipe.silences, 0);
  });
}
