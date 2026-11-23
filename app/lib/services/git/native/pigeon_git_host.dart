/// The Git host over its Pigeon API (Phase 7 W2): the only Dart code that
/// sees the generated `GitApi` types (docs/ARCHITECTURE.md §2, rule 3;
/// tool/lint_imports.dart enforces it). git_api.g.dart is generated from
/// pigeons/git_api.dart by CI.
///
/// Dart picks each run's id and takes its events from then on, before the
/// host answers: a run's records, progress and exit may come before the
/// answer to `run` does.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/errors/failure.dart';
import '../../../core/git/git_errors.dart';
import '../../../core/logging/logger.dart';
import '../../contracts.dart';
import 'git_api.g.dart';

final class PigeonGitHost implements GitHost {
  PigeonGitHost({GitApi? api})
    : _api = api ?? GitApi(),
      // Ids differ from a previous Dart isolate's (a hot restart keeps the
      // host and its runs).
      _nextId = DateTime.now().millisecondsSinceEpoch % 1000000000 * 1000;

  final GitApi _api;
  final Map<int, _Run> _runs = {};
  int _nextId;
  bool _hearing = false;
  bool _disposed = false;

  /// `run` answers at once: the command runs, or why not.
  static const Duration _answerLimit = Duration(seconds: 15);

  @override
  bool get available => true;

  @override
  Future<Result<GitOutcome>> run(
    GitInvocation invocation, {
    void Function(List<String> records)? onRecords,
    void Function(String text, bool closing)? onProgress,
    Future<void>? stop,
  }) async {
    final operation = invocation.operation;
    if (_disposed) {
      return Err(_unavailable(operation));
    }
    _hear();
    final id = _nextId++;
    final run = _Run(onRecords, onProgress);
    _runs[id] = run;
    final GitStartMessage started;
    try {
      started = await _api
          .run(
            GitRunMessage(
              runId: id,
              project: invocation.project,
              operation: operation,
              arguments: invocation.arguments,
              maxRecords: invocation.maxRecords,
            ),
          )
          .timeout(_answerLimit);
    } on PlatformException catch (error) {
      _runs.remove(id);
      appLogger.warn(
        'git',
        'call_failed',
        fields: {'op': operation, 'code': error.code},
      );
      return Err(_unavailable(operation, cause: error));
    } on TimeoutException catch (error) {
      _runs.remove(id);
      appLogger.warn('git', 'call_timed_out', fields: {'op': operation});
      // It may run all the same: it is stopped.
      unawaited(_stop(id));
      return Err(_unavailable(operation, cause: error));
    }
    final refused = started.failure;
    if (refused != null) {
      _runs.remove(id);
      final problem = GitProblem.fromCode(refused);
      appLogger.info(
        'git',
        'refused',
        fields: {'op': operation, 'failure': problem.code},
      );
      return Err(
        GitFailure(
          gitProblemMessage(problem),
          problem: problem,
          operation: operation,
          detail: started.detail,
        ),
      );
    }
    if (stop != null) {
      void stopIt() {
        if (_runs.containsKey(id)) {
          unawaited(_stop(id));
        }
      }

      unawaited(stop.then((_) => stopIt(), onError: (Object _) => stopIt()));
    }
    return run.done.future;
  }

  /// Stops hearing the host; runs not yet ended fail as unavailable.
  Future<void> dispose() async {
    _disposed = true;
    if (_hearing) {
      GitEvents.setUp(null);
      _hearing = false;
    }
    final pending = [..._runs.entries];
    _runs.clear();
    for (final MapEntry(key: id, value: run) in pending) {
      unawaited(_stop(id));
      run.complete(Err(_unavailable(null)));
    }
  }

  void _hear() {
    if (_hearing) {
      return;
    }
    _hearing = true;
    GitEvents.setUp(_Notices(this));
  }

  Future<void> _stop(int id) async {
    try {
      await _api.stop(id).timeout(_answerLimit);
    } on PlatformException {
      // No host to stop it: nothing runs.
    } on TimeoutException {
      // The host did not answer; its own limits end the run.
    }
  }

  void _output(int runId, List<String> records) =>
      _runs[runId]?.output(records);

  void _progress(int runId, String text, bool closing) =>
      _runs[runId]?.progress(text, closing);

  void _exited(GitExitMessage exit) {
    final run = _runs.remove(exit.runId);
    if (run == null) {
      return;
    }
    final failure = exit.failure;
    if (failure != null) {
      final problem = GitProblem.fromCode(failure);
      run.complete(
        Err(
          GitFailure(
            gitProblemMessage(problem),
            problem: problem,
            operation: exit.operation,
            stderr: exit.stderr,
            detail: exit.detail,
          ),
        ),
      );
      return;
    }
    run.complete(
      Ok(
        GitOutcome(
          operation: exit.operation,
          exitCode: exit.exitCode,
          stderr: exit.stderr,
          records: run.kept,
          recordCount: exit.records,
          chars: exit.chars,
          truncated: exit.truncated,
          elapsedMs: exit.elapsedMs,
        ),
      ),
    );
  }

  static GitFailure _unavailable(String? operation, {Object? cause}) =>
      GitFailure(
        gitProblemMessage(GitProblem.unavailable),
        problem: GitProblem.unavailable,
        operation: operation,
        cause: cause,
      );
}

/// One run: where its records go, and its end.
final class _Run {
  _Run(this._onRecords, this._onProgress);

  final void Function(List<String> records)? _onRecords;
  final void Function(String text, bool closing)? _onProgress;

  /// Its records, when no listener takes them.
  final List<String> kept = [];
  final Completer<Result<GitOutcome>> done = Completer<Result<GitOutcome>>();

  void output(List<String> records) {
    final listener = _onRecords;
    if (listener == null) {
      kept.addAll(records);
    } else {
      listener(records);
    }
  }

  void progress(String text, bool closing) => _onProgress?.call(text, closing);

  void complete(Result<GitOutcome> result) {
    if (!done.isCompleted) {
      done.complete(result);
    }
  }
}

/// Kotlin's events, to their runs.
final class _Notices implements GitEvents {
  _Notices(this._host);

  final PigeonGitHost _host;

  @override
  Future<void> output(int runId, List<String> records) async =>
      _host._output(runId, records);

  @override
  Future<void> progress(int runId, String text, bool closing) async =>
      _host._progress(runId, text, closing);

  @override
  Future<void> exited(GitExitMessage exit) async => _host._exited(exit);
}
