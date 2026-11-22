/// The language servers' host over its Pigeon API (Phase 6 W4): the only Dart
/// code that sees the generated `LspApi` types (docs/ARCHITECTURE.md §2, rule
/// 3; tool/lint_imports.dart enforces it). lsp_api.g.dart is generated from
/// pigeons/lsp_api.dart by CI.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/errors/failure.dart';
import '../../../core/logging/logger.dart';
import '../../../core/lsp/lsp_models.dart';
import '../../contracts.dart';
import 'lsp_api.g.dart';

final class PigeonLspService implements LspService {
  PigeonLspService({LspApi? api}) : _api = api ?? LspApi();

  final LspApi _api;

  /// The host's messages and exits, as they arrive (LspEvents), in order.
  final StreamController<LspIncoming> _messages =
      StreamController<LspIncoming>.broadcast();
  final StreamController<LspExit> _exits =
      StreamController<LspExit>.broadcast();
  bool _hearing = false;

  // A start may install the server first (3.6 s for Pyright's first install
  // on the phone, W2); a send answers once its message is written, which a
  // server that has stopped reading holds up; everything else at once.
  static const Duration _quick = Duration(seconds: 15);
  static const Duration _slow = Duration(seconds: 120);

  @override
  bool get available => true;

  @override
  Stream<LspIncoming> get messages {
    _hear();
    return _messages.stream;
  }

  @override
  Stream<LspExit> get exits {
    _hear();
    return _exits.stream;
  }

  @override
  Future<Result<LspStarted>> start(
    LspServerId server,
    LspWorkspace workspace,
  ) {
    _hear();
    return _call('start', _slow, () async {
      final started = await _api.start(
        server.id,
        workspace.project,
        workspace.copy,
      );
      final handle = started.handle;
      final root = started.root;
      if (handle == null || root == null) {
        return Err(
          lspFailureFrom(
            started.failure,
            started.detail,
            running: started.running,
          ),
        );
      }
      return Ok(
        LspStarted(
          handle: handle,
          root: root,
          bin: started.bin,
          serverDirectory: started.serverDirectory,
        ),
      );
    });
  }

  @override
  Future<Result<LspWritten>> send(int handle, String message) =>
      _call('send', _quick, () async {
        final sent = await _api.send(handle, message);
        final failure = sent.failure;
        if (failure != null) {
          return Err(lspFailureFrom(failure, null));
        }
        return Ok(LspWritten(writtenUs: sent.writtenUs));
      });

  @override
  Future<Result<void>> stop(int handle) => _call('stop', _quick, () async {
    final failure = await _api.stop(handle);
    return failure == null
        ? const Ok<void>(null)
        : Err<void>(lspFailureFrom(failure, null));
  });

  @override
  Future<Result<List<LspServerInfo>>> servers() =>
      _call('servers', _quick, () async {
        final found = await _api.servers();
        return Ok([for (final server in found) lspServerInfoFrom(server)]);
      });

  /// Stops hearing the host and closes [messages] and [exits].
  Future<void> dispose() async {
    if (_hearing) {
      LspEvents.setUp(null);
      _hearing = false;
    }
    await _messages.close();
    await _exits.close();
  }

  /// Takes the host's notices from now on, once per client.
  void _hear() {
    if (_hearing) {
      return;
    }
    _hearing = true;
    LspEvents.setUp(_Notices(_messages, _exits));
  }

  /// Runs one call: its result, or an [LspFailure] for a host that failed or
  /// never answered.
  static Future<Result<T>> _call<T>(
    String op,
    Duration limit,
    Future<Result<T>> Function() call,
  ) async {
    try {
      return await call().timeout(limit);
    } on PlatformException catch (error) {
      appLogger.warn(
        'lsp',
        'call_failed',
        fields: {'op': op, 'code': error.code},
      );
      return Err(lspFailureFor(error));
    } on TimeoutException catch (error) {
      appLogger.warn('lsp', 'call_timed_out', fields: {'op': op});
      return Err(
        LspFailure(
          'The language servers did not answer.',
          problem: LspProblem.unavailable,
          cause: error,
        ),
      );
    }
  }
}

/// Kotlin's messages and exits, into the streams.
final class _Notices implements LspEvents {
  _Notices(this._messages, this._exits);

  final StreamController<LspIncoming> _messages;
  final StreamController<LspExit> _exits;

  @override
  Future<void> received(int handle, String json, int readUs) async {
    if (!_messages.isClosed) {
      _messages.add(LspIncoming(handle, json, readUs: readUs));
    }
  }

  @override
  Future<void> exited(LspExitMessage exit) async {
    if (!_exits.isClosed) {
      _exits.add(lspExitFrom(exit));
    }
  }
}

/// A host's exit as the app's.
LspExit lspExitFrom(LspExitMessage message) => LspExit(
  handle: message.handle,
  server: message.server,
  end: LspEnd.fromCode(message.end),
  exitCode: message.exitCode,
  signal: message.signal,
  detail: message.detail,
  stderr: message.stderr,
  leftovers: message.leftovers,
  remaining: message.remaining,
);

/// A host's running server as the app's.
LspServerInfo lspServerInfoFrom(LspServerMessage message) => LspServerInfo(
  handle: message.handle,
  server: message.server,
  project: message.project,
  copy: message.copy,
  startedAtMs: message.startedAtMs,
  installMs: message.installMs,
  received: message.received,
  sent: message.sent,
  pssKib: message.pssKib,
  rssKib: message.rssKib,
  processes: message.processes,
);

/// The failure for a host's [code], told in [detail] when the host said more.
LspFailure lspFailureFrom(String? code, String? detail, {int? running}) {
  final problem = LspProblem.fromCode(code);
  return LspFailure(
    detail ??
        _problemMessages[problem] ??
        'The language server failed ($code).',
    problem: problem,
    running: running,
  );
}

/// The failure for a host's error, or for Pigeon's own when no host
/// answered.
LspFailure lspFailureFor(PlatformException error) =>
    error.code == 'channel-error'
    ? LspFailure(
        'Language servers need Android.',
        problem: LspProblem.unavailable,
        cause: error,
      )
    : LspFailure(
        error.message ?? 'The language servers failed.',
        problem: LspProblem.unknown,
        cause: error,
      );

const Map<LspProblem, String> _problemMessages = {
  LspProblem.notReady: 'The Linux runtime is not ready yet.',
  LspProblem.badRequest: 'The language servers refused that request.',
  LspProblem.notInApk: 'This build carries no such language server.',
  LspProblem.damaged: "The language server's files are damaged.",
  LspProblem.storage: 'There is no room to install the language server.',
  LspProblem.tooMany: 'Two language servers run already.',
  LspProblem.alreadyRunning: 'That language server runs already.',
  LspProblem.launchFailed: "The runtime's node could not start.",
  LspProblem.noSuchServer: 'That language server is gone.',
  LspProblem.notRunning: 'That language server has ended.',
  LspProblem.queueFull: 'The language server is not reading fast enough.',
};
