/// Honest fakes (docs/ARCHITECTURE.md §2.4) for the services whose phase
/// has not come yet, or that have no host here. Each reports its real
/// availability instead of pretending. Files stopped being fake in Phase 2
/// W4 (services/files/local_file_service.dart), the runtime in Phase 4 W3
/// (services/runtime/runtime_service.dart), search in Phase 4 W6
/// (services/search/search_service.dart), the terminal in Phase 5 W3
/// (services/terminal/native/pigeon_terminal_service.dart), the language
/// servers' host in Phase 6 W4 (services/lsp/native/pigeon_lsp_service.dart),
/// and git in Phase 7 W2 (services/git/host_git_service.dart).
library;

import 'dart:typed_data';

import '../core/errors/failure.dart';
import '../core/git/git_models.dart';
import '../core/lsp/lsp_models.dart';
import '../core/terminal/terminal_models.dart';
import 'contracts.dart';

/// No language servers' host: nothing starts, and the status strip shows no
/// server chip. Widget tests that do not exercise the language servers use
/// this; the Pigeon client (services/lsp/native/, Phase 6 W4) is the real
/// one, and test/support/scripted_lsp_service.dart scripts a server.
final class FakeLspService implements LspService {
  static const LspFailure _unavailable = LspFailure(
    'Language servers run on the Linux runtime, on Android.',
    problem: LspProblem.unavailable,
  );

  @override
  bool get available => false;

  @override
  Stream<LspIncoming> get messages => const Stream<LspIncoming>.empty();

  @override
  Stream<LspExit> get exits => const Stream<LspExit>.empty();

  @override
  Future<Result<LspStarted>> start(
    LspServerId server,
    LspWorkspace workspace,
  ) async => const Err<LspStarted>(_unavailable);

  @override
  Future<Result<LspWritten>> send(int handle, String message) async =>
      const Err<LspWritten>(_unavailable);

  @override
  Future<Result<void>> stop(int handle) async => const Err<void>(_unavailable);

  @override
  Future<Result<List<LspServerInfo>>> servers() async =>
      const Ok<List<LspServerInfo>>(<LspServerInfo>[]);
}

/// No terminal host: every session call fails as unavailable. Widget tests
/// that do not exercise the terminal use this, and the pane then says the
/// terminal needs Android; the Pigeon client (services/terminal/native/,
/// Phase 5 W2) is the real one.
final class FakeTerminalService implements TerminalService {
  static const TerminalFailure _unavailable = TerminalFailure(
    'The terminal needs the Linux runtime, on Android.',
    problem: TerminalProblem.unavailable,
  );

  @override
  TerminalAvailability get availability => TerminalAvailability.unavailable;

  @override
  String get unavailableReason =>
      'The terminal runs on the Linux runtime, on Android. '
      'Here it has no runtime to run on.';

  @override
  Stream<TerminalOutput> get output => const Stream<TerminalOutput>.empty();

  @override
  Stream<TerminalInfo> get changes => const Stream<TerminalInfo>.empty();

  @override
  Future<Result<TerminalInfo>> start(TerminalSpec spec) async =>
      const Err<TerminalInfo>(_unavailable);

  @override
  Future<Result<List<TerminalInfo>>> sessions() async =>
      const Ok<List<TerminalInfo>>(<TerminalInfo>[]);

  @override
  Future<Result<void>> write(int id, Uint8List bytes) async =>
      const Err<void>(_unavailable);

  @override
  Future<Result<void>> resize(
    int id, {
    required int rows,
    required int columns,
  }) async => const Err<void>(_unavailable);

  @override
  Future<void> acknowledge(int id, int offset) async {}

  @override
  Future<Result<TerminalReplay>> attach(int id) async =>
      const Err<TerminalReplay>(_unavailable);

  @override
  Future<void> detach(int id) async {}

  @override
  Future<Result<void>> end(int id) async => const Err<void>(_unavailable);

  @override
  Future<Result<int>> endAll() async => const Ok<int>(0);

  @override
  Future<Result<void>> remove(int id) async => const Err<void>(_unavailable);
}

/// No Git host: nothing runs, every call fails as unavailable, and the
/// status strip shows no branch chip. Widget tests that do not exercise
/// git use this; HostGitService over the Pigeon host (services/git/,
/// Phase 7 W2) is the real one, and test/support/scripted_git_service.dart
/// scripts a repository.
final class FakeGitService implements GitService {
  static const GitFailure _unavailable = GitFailure(
    'Git runs on the Linux runtime, on Android.',
    problem: GitProblem.unavailable,
  );

  @override
  bool get available => false;

  @override
  Future<Result<GitStatus>> status(String project, {int? maxFiles}) async =>
      const Err<GitStatus>(_unavailable);

  @override
  Future<Result<void>> stage(String project, List<String> paths) async =>
      const Err<void>(_unavailable);

  @override
  Future<Result<void>> stageAll(String project) async =>
      const Err<void>(_unavailable);

  @override
  Future<Result<void>> unstage(String project, List<String> paths) async =>
      const Err<void>(_unavailable);

  @override
  Future<Result<void>> discard(String project, List<String> paths) async =>
      const Err<void>(_unavailable);

  @override
  Future<Result<void>> deleteUntracked(
    String project,
    List<String> paths,
  ) async => const Err<void>(_unavailable);

  @override
  Future<Result<void>> commit(
    String project,
    String message, {
    bool amend = false,
  }) async => const Err<void>(_unavailable);

  @override
  Future<Result<List<GitCommit>>> log(
    String project, {
    int max = 100,
    int skip = 0,
    String? path,
  }) async => const Err<List<GitCommit>>(_unavailable);

  @override
  Future<Result<List<GitCommitFile>>> commitFiles(
    String project,
    String commit, {
    String? parent,
  }) async => const Err<List<GitCommitFile>>(_unavailable);

  @override
  Future<Result<String>> fileAt(
    String project,
    String path, {
    String? revision,
  }) async => const Err<String>(_unavailable);

  @override
  Future<Result<List<GitBranch>>> branches(String project) async =>
      const Err<List<GitBranch>>(_unavailable);

  @override
  Future<Result<void>> createBranch(
    String project,
    String name, {
    String? from,
    bool switchTo = true,
  }) async => const Err<void>(_unavailable);

  @override
  Future<Result<void>> switchBranch(
    String project,
    String name, {
    void Function(GitProgress progress)? onProgress,
  }) async => const Err<void>(_unavailable);

  @override
  Future<Result<void>> deleteBranch(
    String project,
    String name, {
    bool force = false,
  }) async => const Err<void>(_unavailable);

  @override
  Future<Result<void>> merge(
    String project,
    String branch, {
    void Function(GitProgress progress)? onProgress,
  }) async => const Err<void>(_unavailable);

  @override
  Future<Result<void>> abortMerge(String project) async =>
      const Err<void>(_unavailable);

  @override
  Future<Result<void>> init(
    String project, {
    String initialBranch = 'main',
  }) async => const Err<void>(_unavailable);

  @override
  Future<Result<GitIdentity>> identity() async =>
      const Err<GitIdentity>(_unavailable);

  @override
  Future<Result<void>> setIdentity(GitIdentity identity) async =>
      const Err<void>(_unavailable);

  @override
  Future<Result<bool>> isValidBranchName(String name) async =>
      const Err<bool>(_unavailable);

  @override
  Future<Result<void>> clone(
    String url,
    String name, {
    void Function(GitProgress progress)? onProgress,
    Future<void>? stop,
  }) async => const Err<void>(_unavailable);

  @override
  Future<Result<void>> fetch(
    String project, {
    String? remote,
    void Function(GitProgress progress)? onProgress,
    Future<void>? stop,
  }) async => const Err<void>(_unavailable);

  @override
  Future<Result<void>> pull(
    String project, {
    String? remote,
    String? branch,
    void Function(GitProgress progress)? onProgress,
    Future<void>? stop,
  }) async => const Err<void>(_unavailable);

  @override
  Future<Result<void>> push(
    String project, {
    required String remote,
    required String branch,
    bool setUpstream = false,
    void Function(GitProgress progress)? onProgress,
    Future<void>? stop,
  }) async => const Err<void>(_unavailable);

  @override
  Stream<GitCredentialPrompt> get credentialPrompts => const Stream.empty();

  @override
  Stream<int> get withdrawnPrompts => const Stream.empty();

  @override
  Stream<GitCredentialRejected> get rejectedCredentials => const Stream.empty();

  @override
  Future<void> answerCredential(GitCredentialAnswer answer) async {}

  @override
  Future<Result<List<GitAccount>>> accounts() async =>
      const Err<List<GitAccount>>(_unavailable);

  @override
  Future<Result<bool>> removeAccount(GitAccount account) async =>
      const Err<bool>(_unavailable);

  @override
  Future<Result<GitSshKey?>> sshKey() async =>
      const Err<GitSshKey?>(_unavailable);

  @override
  Future<Result<GitSshKey>> createSshKey(String comment) async =>
      const Err<GitSshKey>(_unavailable);

  @override
  Future<Result<bool>> deleteSshKey() async => const Err<bool>(_unavailable);
}
