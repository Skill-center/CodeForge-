/// A Git host scripted by the test (Phase 7 W2): every command is recorded
/// as the host would receive it, and answered by [ScriptedGitHost.answer],
/// by default git's success with no output. Records and progress reach the
/// listeners as the Pigeon host delivers them.
library;

import 'dart:async';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/git/git_errors.dart';
import 'package:codeforge/services/contracts.dart';

/// What one scripted command does.
final class GitScript {
  const GitScript({
    this.exitCode = 0,
    this.records = const [],
    this.stderr = '',
    this.progress = const [],
    this.problem,
    this.truncated = false,
  });

  /// git's exit; null with [truncated] when the host ended it at the cap.
  final int? exitCode;
  final List<String> records;
  final String stderr;

  /// Progress lines, each with whether it closes its run.
  final List<(String, bool)> progress;

  /// The host refused or ended the command with this.
  final GitProblem? problem;

  final bool truncated;
}

typedef GitAnswer = FutureOr<GitScript> Function(GitInvocation invocation);

final class ScriptedGitHost implements GitHost {
  ScriptedGitHost({this.available = true, GitAnswer? answer})
    : answer = answer ?? ((_) => const GitScript());

  @override
  final bool available;

  GitAnswer answer;

  final List<GitInvocation> invocations = [];

  /// Each command as `[operation, ...arguments]`.
  List<List<String>> get commands => [
    for (final invocation in invocations)
      [invocation.operation, ...invocation.arguments],
  ];

  @override
  Future<Result<GitOutcome>> run(
    GitInvocation invocation, {
    void Function(List<String> records)? onRecords,
    void Function(String text, bool closing)? onProgress,
    Future<void>? stop,
  }) async {
    invocations.add(invocation);
    final script = await answer(invocation);
    final problem = script.problem;
    if (problem != null) {
      return Err(
        GitFailure(
          gitProblemMessage(problem),
          problem: problem,
          operation: invocation.operation,
          stderr: script.stderr,
        ),
      );
    }
    for (final (text, closing) in script.progress) {
      onProgress?.call(text, closing);
    }
    if (onRecords != null && script.records.isNotEmpty) {
      onRecords(script.records);
    }
    return Ok(
      GitOutcome(
        operation: invocation.operation,
        exitCode: script.exitCode,
        stderr: script.stderr,
        records: onRecords == null ? script.records : const [],
        recordCount: script.records.length,
        chars: script.records.fold(0, (sum, r) => sum + r.length),
        truncated: script.truncated,
      ),
    );
  }
}
