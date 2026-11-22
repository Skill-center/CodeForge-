/// JSON-RPC 2.0 over one server's messages (Phase 6 W4; PHASE_6_PLAN W4).
///
/// The host carries whole messages (LSP's framing is Kotlin's), so this is
/// JSON-RPC alone: numbered requests, each with its own timeout, answers
/// matched to them, `$/cancelRequest` when a request is called off or runs
/// out of time, and the server's own requests answered. Answers that come
/// after their request was given up are dropped. Each request's time is
/// split into its stages when the host says when it wrote the request and
/// when it read the answer (LspTiming).
library;

import 'dart:async';
import 'dart:convert';

import '../../core/errors/failure.dart';
import '../../core/logging/logger.dart';
import '../../core/lsp/lsp_models.dart';
import 'lsp_clock.dart';

/// The error codes of JSON-RPC and LSP the client sends or meets.
abstract final class JsonRpcErrors {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
  static const int serverNotInitialized = -32002;
  static const int requestCancelled = -32800;
  static const int contentModified = -32801;
  static const int serverCancelled = -32802;
}

/// What the client answers one of the server's own requests.
final class LspReply {
  const LspReply.result(this.result) : errorCode = null, errorMessage = null;

  const LspReply.error(int code, String message)
    : result = null,
      errorCode = code,
      errorMessage = message;

  final Object? result;
  final int? errorCode;
  final String? errorMessage;
}

/// Lets whoever asked call a request off: the user moved on (W5's
/// completion, when the cursor leaves).
final class LspCancel {
  bool _cancelled = false;
  void Function()? _onCancel;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    final onCancel = _onCancel;
    _onCancel = null;
    onCancel?.call();
  }
}

/// Sends one JSON-RPC message to the server: done once the host wrote it.
typedef LspSend = Future<Result<LspWritten>> Function(String json);

/// Answers one of the server's requests.
typedef LspRequestHandler =
    Future<LspReply> Function(String method, Object? params);

/// Takes one of the server's notifications.
typedef LspNotificationHandler = void Function(String method, Object? params);

final class LspConnection {
  LspConnection({
    required this.server,
    required LspSend send,
    required LspClock clock,
    required LspRequestHandler onRequest,
    required LspNotificationHandler onNotification,
    void Function(LspTiming timing)? onTiming,
  }) : _send = send,
       _clock = clock,
       _onRequest = onRequest,
       _onNotification = onNotification,
       _onTiming = onTiming;

  final LspServerId server;
  final LspSend _send;
  final LspClock _clock;
  final LspRequestHandler _onRequest;
  final LspNotificationHandler _onNotification;
  final void Function(LspTiming timing)? _onTiming;

  final Map<int, _Pending> _pending = {};
  int _nextId = 1;
  bool _closed = false;

  /// Messages that were not JSON-RPC, since the connection began.
  int malformed = 0;

  /// Requests waiting for their answers.
  int get waiting => _pending.length;

  bool get isClosed => _closed;

  /// Sends request [method] and answers its result, or an [LspFailure]: the
  /// server's error ([LspProblem.serverError], or [LspProblem.cancelled] for
  /// its RequestCancelled), [LspProblem.timeout] after [timeout],
  /// [LspProblem.cancelled] when [cancel] is called first, or the problem
  /// [close] names.
  Future<Result<Object?>> request(
    String method,
    Object? params, {
    required Duration timeout,
    LspCancel? cancel,
  }) {
    if (_closed) {
      return Future<Result<Object?>>.value(
        Err<Object?>(
          LspFailure(
            '${server.title} is not running.',
            problem: LspProblem.notRunning,
          ),
        ),
      );
    }
    if (cancel != null && cancel.isCancelled) {
      return Future<Result<Object?>>.value(
        Err<Object?>(
          LspFailure('$method was called off.', problem: LspProblem.cancelled),
        ),
      );
    }
    final id = _nextId++;
    final pending = _Pending(id, method, _clock.monotonicUs);
    _pending[id] = pending;
    pending.timer = _clock.timer(
      timeout,
      () => _abandon(
        id,
        LspProblem.timeout,
        '${server.title} did not answer $method within '
        '${timeout.inMilliseconds} ms.',
      ),
    );
    cancel?._onCancel = () =>
        _abandon(id, LspProblem.cancelled, '$method was called off.');
    unawaited(
      _sendRequest(pending, <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': ?params,
      }),
    );
    return pending.completer.future;
  }

  /// Sends notification [method].
  void notify(String method, Object? params) {
    if (_closed) {
      return;
    }
    unawaited(
      _sendNotification(<String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        'params': ?params,
      }),
    );
  }

  /// Takes one whole message the server wrote, which the host read at
  /// [readUs] (monotonic µs) when it says.
  void receive(String json, {int? readUs}) {
    if (_closed) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      _malformed('not_json');
      return;
    }
    if (decoded is! Map<String, Object?>) {
      _malformed('not_an_object');
      return;
    }
    final method = decoded['method'];
    final id = decoded['id'];
    if (method is String) {
      if (id != null) {
        unawaited(_answer(id, method, decoded['params']));
      } else {
        _onNotification(method, decoded['params']);
      }
      return;
    }
    final number = switch (id) {
      final int value => value,
      final String value => int.tryParse(value),
      _ => null,
    };
    if (number == null) {
      _malformed('answer_without_id');
      return;
    }
    final pending = _pending.remove(number);
    if (pending == null) {
      // Answered after it was given up (its timeout, or called off).
      return;
    }
    pending.timer?.cancel();
    final handledUs = _clock.monotonicUs;
    final error = decoded['error'];
    final Result<Object?> result;
    if (error is Map<String, Object?>) {
      final code = error['code'];
      final message = error['message'];
      result = Err<Object?>(
        LspFailure(
          message is String && message.isNotEmpty
              ? message
              : '${server.title} failed ${pending.method}.',
          problem: code == JsonRpcErrors.requestCancelled
              ? LspProblem.cancelled
              : LspProblem.serverError,
          errorCode: code is int ? code : null,
        ),
      );
    } else {
      result = Ok<Object?>(decoded['result']);
    }
    _timed(
      pending,
      result is Ok<Object?> ? 'ok' : 'error',
      endUs: handledUs,
      readUs: readUs,
    );
    pending.completer.complete(result);
  }

  /// Ends every request waiting, as [problem]; nothing is sent or taken in
  /// from then on.
  void close(LspProblem problem, String message) {
    if (_closed) {
      return;
    }
    _closed = true;
    final abandoned = _pending.values.toList();
    _pending.clear();
    for (final pending in abandoned) {
      pending.timer?.cancel();
      _timed(pending, problem.code);
      pending.completer.complete(
        Err<Object?>(LspFailure(message, problem: problem)),
      );
    }
  }

  Future<void> _sendRequest(
    _Pending pending,
    Map<String, Object?> message,
  ) async {
    final written = await _write(message);
    switch (written) {
      case Ok<LspWritten>(:final value):
        pending.writtenUs = value.writtenUs;
      case Err<LspWritten>(:final failure):
        if (_pending.remove(pending.id) == null) {
          return;
        }
        pending.timer?.cancel();
        _timed(
          pending,
          failure is LspFailure ? failure.problem.code : 'unknown',
        );
        pending.completer.complete(Err<Object?>(failure));
    }
  }

  Future<void> _sendNotification(Map<String, Object?> message) async {
    final written = await _write(message);
    if (written case Err<LspWritten>(:final failure)) {
      appLogger.debug(
        'lsp',
        'notification_not_sent',
        fields: {
          'server': server.id,
          'method': message['method'],
          'problem': failure is LspFailure ? failure.problem.code : 'unknown',
        },
      );
    }
  }

  /// Answers the server's request [id] for [method].
  Future<void> _answer(Object id, String method, Object? params) async {
    LspReply reply;
    try {
      reply = await _onRequest(method, params);
    } on Object catch (error) {
      appLogger.error(
        'lsp',
        'server_request_failed',
        fields: {
          'server': server.id,
          'method': method,
          'error': error.runtimeType.toString(),
        },
      );
      reply = const LspReply.error(
        JsonRpcErrors.internalError,
        'CodeForge failed to answer.',
      );
    }
    if (_closed) {
      return;
    }
    final code = reply.errorCode;
    await _write(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      if (code == null) 'result': reply.result,
      if (code != null)
        'error': <String, Object?>{
          'code': code,
          'message': reply.errorMessage ?? '',
        },
    });
  }

  Future<Result<LspWritten>> _write(Map<String, Object?> message) =>
      _send(jsonEncode(message));

  /// Gives up request [id] as [problem], and tells the server to stop
  /// working on it.
  void _abandon(int id, LspProblem problem, String message) {
    final pending = _pending.remove(id);
    if (pending == null) {
      return;
    }
    pending.timer?.cancel();
    notify(r'$/cancelRequest', <String, Object?>{'id': id});
    _timed(pending, problem.code);
    pending.completer.complete(
      Err<Object?>(LspFailure(message, problem: problem)),
    );
  }

  void _timed(_Pending pending, String outcome, {int? endUs, int? readUs}) {
    final onTiming = _onTiming;
    if (onTiming == null) {
      return;
    }
    final end = endUs ?? _clock.monotonicUs;
    final written = pending.writtenUs;
    onTiming(
      LspTiming(
        server: server,
        method: pending.method,
        outcome: outcome,
        totalUs: _positive(end - pending.sentUs),
        queueUs: written == null ? null : _positive(written - pending.sentUs),
        serverUs: written == null || readUs == null
            ? null
            : _positive(readUs - written),
        deliveryUs: readUs == null ? null : _positive(end - readUs),
      ),
    );
  }

  void _malformed(String what) {
    malformed += 1;
    appLogger.warn(
      'lsp',
      'malformed_message',
      fields: {'server': server.id, 'what': what, 'count': malformed},
    );
  }

  /// Clocks on two threads can disagree by a hair: a stage is never below 0.
  static int _positive(int micros) => micros < 0 ? 0 : micros;
}

/// A request waiting for its answer.
final class _Pending {
  _Pending(this.id, this.method, this.sentUs);

  final int id;
  final String method;

  /// When the client sent it, on the monotonic clock.
  final int sentUs;
  final Completer<Result<Object?>> completer = Completer<Result<Object?>>();
  Timer? timer;

  /// When the host wrote it to the server's stdin, once it says.
  int? writtenUs;
}
