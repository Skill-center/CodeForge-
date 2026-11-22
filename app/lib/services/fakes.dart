/// Honest fakes (docs/ARCHITECTURE.md §2.4) for the services whose phase
/// has not come yet, or that have no host here. Each reports its real
/// availability instead of pretending. Files stopped being fake in Phase 2
/// W4 (services/files/local_file_service.dart), the runtime in Phase 4 W3
/// (services/runtime/runtime_service.dart), search in Phase 4 W6
/// (services/search/search_service.dart), the terminal in Phase 5 W3
/// (services/terminal/native/pigeon_terminal_service.dart), and the language
/// servers' host in Phase 6 W4 (services/lsp/native/pigeon_lsp_service.dart).
library;

import 'dart:typed_data';

import '../core/errors/failure.dart';
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

final class FakeGitService implements GitService {
  @override
  Future<Result<GitSummary>> summary() async =>
      const Ok(GitSummary(branch: 'main'));
}
