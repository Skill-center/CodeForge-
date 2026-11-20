/// The terminal host over its Pigeon API (Phase 5 W2): the only Dart code
/// that sees the generated `TerminalApi` types (docs/ARCHITECTURE.md §2,
/// rule 3; tool/lint_imports.dart enforces it). terminal_api.g.dart is
/// generated from pigeons/terminal_api.dart by CI.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/errors/failure.dart';
import '../../../core/logging/logger.dart';
import '../../../core/terminal/terminal_models.dart';
import '../../contracts.dart';
import 'terminal_api.g.dart';

final class PigeonTerminalService implements TerminalService {
  PigeonTerminalService({TerminalApi? api}) : _api = api ?? TerminalApi();

  final TerminalApi _api;

  /// The host's batches and changes, as they arrive (TerminalEvents).
  final StreamController<TerminalOutput> _output =
      StreamController<TerminalOutput>.broadcast();
  final StreamController<TerminalInfo> _changes =
      StreamController<TerminalInfo>.broadcast();
  bool _hearing = false;

  // Kotlin answers every call at once but two: a start waits for a process
  // to start, and End all for every session to end (a grace period and a
  // kill phase each, at once).
  static const Duration _quick = Duration(seconds: 15);
  static const Duration _slow = Duration(seconds: 60);

  @override
  TerminalAvailability get availability => TerminalAvailability.available;

  @override
  String get unavailableReason => '';

  @override
  Stream<TerminalOutput> get output {
    _hear();
    return _output.stream;
  }

  @override
  Stream<TerminalInfo> get changes {
    _hear();
    return _changes.stream;
  }

  @override
  Future<Result<TerminalInfo>> start(TerminalSpec spec) {
    _hear();
    return _call('start', _slow, () async {
      final started = await _api.start(terminalSpecMessageFrom(spec));
      final session = started.session;
      if (session == null) {
        return Err(terminalFailureFrom(started.failure, started.detail));
      }
      return Ok(terminalInfoFrom(session));
    });
  }

  @override
  Future<Result<List<TerminalInfo>>> sessions() =>
      _call('sessions', _quick, () async {
        final found = await _api.sessions();
        return Ok([for (final session in found) terminalInfoFrom(session)]);
      });

  @override
  Future<Result<void>> write(int id, Uint8List bytes) =>
      _call('write', _quick, () async {
        return _done(await _api.write(id, bytes));
      });

  @override
  Future<Result<void>> resize(
    int id, {
    required int rows,
    required int columns,
  }) => _call('resize', _quick, () async {
    return _done(await _api.resize(id, rows, columns));
  });

  @override
  Future<void> acknowledge(int id, int offset) async {
    try {
      await _api.acknowledge(id, offset).timeout(_quick);
    } on PlatformException catch (error) {
      appLogger.warn(
        'terminal',
        'call_failed',
        fields: {'op': 'acknowledge', 'code': error.code},
      );
    } on TimeoutException {
      appLogger.warn(
        'terminal',
        'call_timed_out',
        fields: {'op': 'acknowledge'},
      );
    }
  }

  @override
  Future<Result<TerminalReplay>> attach(int id) {
    _hear();
    return _call('attach', _quick, () async {
      final replay = await _api.attach(id);
      final failure = replay.failure;
      if (failure != null) {
        return Err(terminalFailureFrom(failure, null));
      }
      return Ok(TerminalReplay(replay.offset, replay.bytes));
    });
  }

  @override
  Future<void> detach(int id) async {
    try {
      await _api.detach(id).timeout(_quick);
    } on PlatformException catch (error) {
      appLogger.warn(
        'terminal',
        'call_failed',
        fields: {'op': 'detach', 'code': error.code},
      );
    } on TimeoutException {
      appLogger.warn('terminal', 'call_timed_out', fields: {'op': 'detach'});
    }
  }

  @override
  Future<Result<void>> end(int id) => _call('end', _quick, () async {
    return _done(await _api.end(id));
  });

  @override
  Future<Result<int>> endAll() => _call('endAll', _slow, () async {
    return Ok(await _api.endAll());
  });

  @override
  Future<Result<void>> remove(int id) => _call('remove', _quick, () async {
    return _done(await _api.remove(id));
  });

  /// Stops hearing the host and closes [output] and [changes].
  Future<void> dispose() async {
    if (_hearing) {
      TerminalEvents.setUp(null);
      _hearing = false;
    }
    await _output.close();
    await _changes.close();
  }

  /// Takes the host's notices from now on, once per client.
  void _hear() {
    if (_hearing) {
      return;
    }
    _hearing = true;
    TerminalEvents.setUp(_Notices(_output, _changes));
  }

  /// A call that answers null when done, or the host's failure code.
  static Result<void> _done(String? failure) => failure == null
      ? const Ok(null)
      : Err(terminalFailureFrom(failure, null));

  /// Runs one call: its result, or a [TerminalFailure] for a host that
  /// failed or never answered.
  static Future<Result<T>> _call<T>(
    String op,
    Duration limit,
    Future<Result<T>> Function() call,
  ) async {
    try {
      return await call().timeout(limit);
    } on PlatformException catch (error) {
      appLogger.warn(
        'terminal',
        'call_failed',
        fields: {'op': op, 'code': error.code},
      );
      return Err(terminalFailureFor(error));
    } on TimeoutException catch (error) {
      appLogger.warn('terminal', 'call_timed_out', fields: {'op': op});
      return Err(
        TerminalFailure(
          'The terminal did not answer.',
          problem: TerminalProblem.unavailable,
          cause: error,
        ),
      );
    }
  }
}

/// Kotlin's batches and changes, into the streams.
final class _Notices implements TerminalEvents {
  _Notices(this._output, this._changes);

  final StreamController<TerminalOutput> _output;
  final StreamController<TerminalInfo> _changes;

  @override
  Future<void> output(int sessionId, int offset, Uint8List bytes) async {
    if (!_output.isClosed) {
      _output.add(TerminalOutput(sessionId, offset, bytes));
    }
  }

  @override
  Future<void> changed(TerminalInfoMessage info) async {
    if (!_changes.isClosed) {
      _changes.add(terminalInfoFrom(info));
    }
  }
}

/// The app's spec as the host's message.
TerminalSpecMessage terminalSpecMessageFrom(TerminalSpec spec) =>
    TerminalSpecMessage(
      project: spec.project,
      copy: spec.copy,
      program: spec.program,
      arguments: spec.arguments,
      environment: spec.environment,
      rows: spec.rows,
      columns: spec.columns,
      bufferBytes: spec.bufferBytes,
      label: spec.label,
    );

/// A host's session as the app's.
TerminalInfo terminalInfoFrom(TerminalInfoMessage message) {
  final failure = message.failure;
  return TerminalInfo(
    id: message.id,
    label: message.label,
    state: TerminalSessionState.fromCode(message.state),
    rows: message.rows,
    columns: message.columns,
    received: message.received,
    exitCode: message.exitCode,
    signal: message.signal,
    problem: failure == null ? null : TerminalProblem.fromCode(failure),
    detail: message.detail,
    leftovers: message.leftovers,
    remaining: message.remaining,
  );
}

/// The failure for a host's [code], told in [detail] when the host said
/// more.
TerminalFailure terminalFailureFrom(String? code, String? detail) {
  final problem = TerminalProblem.fromCode(code);
  return TerminalFailure(
    detail ?? _messages[problem] ?? 'The terminal failed ($code).',
    problem: problem,
  );
}

/// The failure for a host's error, or for Pigeon's own when no host
/// answered.
TerminalFailure terminalFailureFor(PlatformException error) =>
    error.code == 'channel-error'
    ? TerminalFailure(
        'The terminal needs Android.',
        problem: TerminalProblem.unavailable,
        cause: error,
      )
    : TerminalFailure(
        error.message ?? 'The terminal failed.',
        problem: TerminalProblem.unknown,
        cause: error,
      );

const Map<TerminalProblem, String> _messages = {
  TerminalProblem.notReady: 'The Linux runtime is not ready yet.',
  TerminalProblem.badRequest: 'The terminal refused that request.',
  TerminalProblem.notFound: 'The runtime has no such program.',
  TerminalProblem.tooMany: 'Eight terminals are open: close one first.',
  TerminalProblem.cannotStart: 'The shell could not start.',
  TerminalProblem.terminalFailed: 'No terminal could be opened.',
  TerminalProblem.launchFailed: "The runtime's launcher could not run.",
  TerminalProblem.ended: 'The terminal was ended.',
  TerminalProblem.signaled: 'The shell was ended by a signal.',
  TerminalProblem.lost: 'The connection to the terminal was lost.',
  TerminalProblem.noSuchSession: 'That terminal is gone.',
  TerminalProblem.notRunning: 'That terminal has ended.',
  TerminalProblem.inputFull: 'The terminal is not taking input fast enough.',
  TerminalProblem.stillRunning: 'That terminal still runs.',
};
