/// A repository scripted by the test (Phase 7 W2), for the Git controller
/// and the widgets: its status is what the test sets, a status can be held
/// until the test lets it finish, and each operation is recorded and
/// answered as the test says.
library;

import 'dart:async';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/services/contracts.dart';

/// A clean repository on `main`.
const GitStatus cleanMain = GitStatus(
  branch: GitBranchState(
    head: 'main',
    oid: '1111111111111111111111111111111111111111',
  ),
);

final class ScriptedGitService implements GitService {
  ScriptedGitService({this.available = true, GitStatus status = cleanMain})
    : statusResult = Ok(status);

  @override
  final bool available;

  /// What the next status answers.
  Result<GitStatus> statusResult;

  /// When set, each status waits for it before answering.
  Completer<void>? holdStatus;

  /// The projects each status was asked for, in order.
  final List<String> statusCalls = [];

  /// Statuses asked for and not answered yet.
  int statusesRunning = 0;

  /// The most statuses that ran at once.
  int mostStatusesAtOnce = 0;

  /// Each operation, as `name argument...`, in the order they started.
  final List<String> calls = [];

  /// What operations answer.
  Result<void> operationResult = const Ok(null);

  /// When set, each operation waits for it before answering.
  Completer<void>? holdOperations;

  /// Operations running now, and the most that ran at once.
  int operationsRunning = 0;
  int mostOperationsAtOnce = 0;

  /// What an operation does to the status, run when it finishes.
  void Function(String call)? onOperation;

  GitIdentity identityValue = const GitIdentity();

  /// Every identity set, in order.
  final List<GitIdentity> identitiesSet = [];

  /// When set, reading the identity fails with it.
  GitFailure? identityFailure;

  @override
  Future<Result<GitStatus>> status(String project, {int? maxFiles}) async {
    statusCalls.add(project);
    statusesRunning += 1;
    if (statusesRunning > mostStatusesAtOnce) {
      mostStatusesAtOnce = statusesRunning;
    }
    try {
      final hold = holdStatus;
      if (hold != null) {
        await hold.future;
      }
      return statusResult;
    } finally {
      statusesRunning -= 1;
    }
  }

  Future<Result<void>> _operation(String call) async {
    calls.add(call);
    operationsRunning += 1;
    if (operationsRunning > mostOperationsAtOnce) {
      mostOperationsAtOnce = operationsRunning;
    }
    try {
      final hold = holdOperations;
      if (hold != null) {
        await hold.future;
      }
      onOperation?.call(call);
      return operationResult;
    } finally {
      operationsRunning -= 1;
    }
  }

  @override
  Future<Result<void>> stage(String project, List<String> paths) =>
      _operation('stage ${paths.join(' ')}');

  @override
  Future<Result<void>> stageAll(String project) => _operation('stage_all');

  @override
  Future<Result<void>> unstage(String project, List<String> paths) =>
      _operation('unstage ${paths.join(' ')}');

  @override
  Future<Result<void>> discard(String project, List<String> paths) =>
      _operation('discard ${paths.join(' ')}');

  @override
  Future<Result<void>> deleteUntracked(String project, List<String> paths) =>
      _operation('delete_untracked ${paths.join(' ')}');

  @override
  Future<Result<void>> commit(
    String project,
    String message, {
    bool amend = false,
  }) => _operation('commit${amend ? ' --amend' : ''} $message');

  @override
  Future<Result<List<GitCommit>>> log(
    String project, {
    int max = 100,
    int skip = 0,
    String? path,
  }) async => const Ok(<GitCommit>[]);

  @override
  Future<Result<List<GitCommitFile>>> commitFiles(
    String project,
    String commit, {
    String? parent,
  }) async => const Ok(<GitCommitFile>[]);

  @override
  Future<Result<String>> fileAt(
    String project,
    String path, {
    String? revision,
  }) async => const Ok('');

  @override
  Future<Result<List<GitBranch>>> branches(String project) async =>
      const Ok(<GitBranch>[]);

  @override
  Future<Result<void>> createBranch(
    String project,
    String name, {
    String? from,
    bool switchTo = true,
  }) => _operation('create_branch $name');

  @override
  Future<Result<void>> switchBranch(
    String project,
    String name, {
    void Function(GitProgress progress)? onProgress,
  }) => _operation('switch $name');

  @override
  Future<Result<void>> deleteBranch(
    String project,
    String name, {
    bool force = false,
  }) => _operation('delete_branch $name');

  @override
  Future<Result<void>> merge(
    String project,
    String branch, {
    void Function(GitProgress progress)? onProgress,
  }) => _operation('merge $branch');

  @override
  Future<Result<void>> abortMerge(String project) => _operation('abort_merge');

  @override
  Future<Result<void>> init(String project, {String initialBranch = 'main'}) =>
      _operation('init $initialBranch');

  @override
  Future<Result<GitIdentity>> identity() async {
    final failure = identityFailure;
    return failure == null ? Ok(identityValue) : Err(failure);
  }

  @override
  Future<Result<void>> setIdentity(GitIdentity identity) async {
    identitiesSet.add(identity);
    identityValue = GitIdentity(
      name: (identity.name?.trim().isEmpty ?? true)
          ? null
          : identity.name!.trim(),
      email: (identity.email?.trim().isEmpty ?? true)
          ? null
          : identity.email!.trim(),
    );
    return const Ok(null);
  }

  @override
  Future<Result<bool>> isValidBranchName(String name) async =>
      Ok(name.isNotEmpty && !name.contains(' ') && !name.contains('..'));
}
