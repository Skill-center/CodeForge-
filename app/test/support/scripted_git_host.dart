/// A Git host scripted by the test (Phase 7 W2): every command is recorded
/// as the host would receive it, and answered by [ScriptedGitHost.answer],
/// by default git's success with no output. Records and progress reach the
/// listeners as the Pigeon host delivers them.
///
/// Since Phase 7 W3 it also asks for credentials as the host does: the test
/// adds prompts ([ScriptedGitHost.ask]), and every answer is recorded; the
/// stored accounts and the SSH key are the test's.
library;

import 'dart:async';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/git/git_errors.dart';
import 'package:codeforge/core/git/git_models.dart';
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

  final StreamController<GitCredentialPrompt> _prompts =
      StreamController<GitCredentialPrompt>.broadcast(sync: true);
  final StreamController<int> _withdrawn =
      StreamController<int>.broadcast(sync: true);
  final StreamController<GitCredentialRejected> _rejected =
      StreamController<GitCredentialRejected>.broadcast(sync: true);

  /// Every answer given, in order.
  final List<GitCredentialAnswer> answers = [];

  /// The stored accounts, and the accounts removed.
  List<GitAccount> accountsValue = [];
  final List<GitAccount> removed = [];

  GitSshKey? sshKeyValue;
  final List<String> keysMade = [];

  /// Closes the question streams.
  Future<void> dispose() async {
    await _prompts.close();
    await _withdrawn.close();
    await _rejected.close();
  }

  /// A run asks [prompt], as the host's broker would.
  void ask(GitCredentialPrompt prompt) => _prompts.add(prompt);

  /// The host gives up waiting for prompt [id].
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

  @override
  Future<Result<List<GitAccount>>> accounts() async => Ok([...accountsValue]);

  @override
  Future<Result<bool>> removeAccount(GitAccount account) async {
    removed.add(account);
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
