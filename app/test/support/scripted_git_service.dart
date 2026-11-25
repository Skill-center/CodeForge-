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

  /// Progress each remote operation reports before it answers.
  List<GitProgress> remoteProgress = const [];

  /// When set, a remote operation that is stopped answers with this.
  bool stopEndsRemote = true;

  Future<Result<void>> _remote(
    String call,
    void Function(GitProgress progress)? onProgress,
    Future<void>? stop,
  ) async {
    for (final progress in remoteProgress) {
      onProgress?.call(progress);
    }
    var stopped = false;
    if (stop != null && stopEndsRemote) {
      unawaited(stop.then((_) => stopped = true));
    }
    final result = await _operation(call);
    if (stopped) {
      return const Err(
        GitFailure('Stopped.', problem: GitProblem.stopped, operation: 'git'),
      );
    }
    return result;
  }

  @override
  Future<Result<void>> clone(
    String url,
    String name, {
    void Function(GitProgress progress)? onProgress,
    Future<void>? stop,
  }) => _remote('clone $url $name', onProgress, stop);

  @override
  Future<Result<void>> fetch(
    String project, {
    String? remote,
    void Function(GitProgress progress)? onProgress,
    Future<void>? stop,
  }) => _remote('fetch ${remote ?? ''}'.trim(), onProgress, stop);

  @override
  Future<Result<void>> pull(
    String project, {
    String? remote,
    String? branch,
    void Function(GitProgress progress)? onProgress,
    Future<void>? stop,
  }) => _remote(['pull', ?remote, ?branch].join(' '), onProgress, stop);

  @override
  Future<Result<void>> push(
    String project, {
    required String remote,
    required String branch,
    bool setUpstream = false,
    void Function(GitProgress progress)? onProgress,
    Future<void>? stop,
  }) => _remote(
    ['push', if (setUpstream) '--set-upstream', remote, branch].join(' '),
    onProgress,
    stop,
  );

  final StreamController<GitCredentialPrompt> _prompts =
      StreamController<GitCredentialPrompt>.broadcast(sync: true);
  final StreamController<int> _withdrawn = StreamController<int>.broadcast(
    sync: true,
  );
  final StreamController<GitCredentialRejected> _rejected =
      StreamController<GitCredentialRejected>.broadcast(sync: true);

  /// Every answer given, in order.
  final List<GitCredentialAnswer> answers = [];

  /// Closes the question streams.
  Future<void> dispose() async {
    await _prompts.close();
    await _withdrawn.close();
    await _rejected.close();
  }

  /// A remote run asks [prompt].
  void ask(GitCredentialPrompt prompt) => _prompts.add(prompt);

  /// The run no longer waits for prompt [id].
  void withdraw(int id) => _withdrawn.add(id);

  /// A host refused a stored credential, which was removed.
  void reject(GitCredentialRejected rejected) => _rejected.add(rejected);

  @override
  Stream<GitCredentialPrompt> get credentialPrompts => _prompts.stream;

  @override
  Stream<int> get withdrawnPrompts => _withdrawn.stream;

  @override
  Stream<GitCredentialRejected> get rejectedCredentials => _rejected.stream;

  @override
  Future<void> answerCredential(GitCredentialAnswer answer) async =>
      answers.add(answer);

  /// The stored accounts; what was removed; the SSH key.
  List<GitAccount> accountsValue = [];
  final List<GitAccount> removedAccounts = [];
  GitSshKey? sshKeyValue;
  final List<String> keysMade = [];

  /// When set, making a key fails with it.
  GitFailure? keyFailure;

  @override
  Future<Result<List<GitAccount>>> accounts() async => Ok([...accountsValue]);

  @override
  Future<Result<bool>> removeAccount(GitAccount account) async {
    removedAccounts.add(account);
    final before = accountsValue.length;
    accountsValue = [
      for (final a in accountsValue)
        if (a != account) a,
    ];
    return Ok(accountsValue.length < before);
  }

  @override
  Future<Result<GitSshKey?>> sshKey() async => Ok(sshKeyValue);

  @override
  Future<Result<GitSshKey>> createSshKey(String comment) async {
    keysMade.add(comment);
    final failure = keyFailure;
    if (failure != null) {
      return Err(failure);
    }
    final key = GitSshKey(
      publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9e $comment',
      fingerprint: 'SHA256:sZVteXLRGzEQhTLCFLG+1j2m1cQg3biayChuIwnxsos',
      comment: comment,
    );
    sshKeyValue = key;
    return Ok(key);
  }

  @override
  Future<Result<bool>> deleteSshKey() async {
    final had = sshKeyValue != null;
    sshKeyValue = null;
    return Ok(had);
  }
}
