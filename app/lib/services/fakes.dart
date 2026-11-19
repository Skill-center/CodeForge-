/// Honest fakes (docs/ARCHITECTURE.md §2.4) for the services whose phase
/// has not come yet. Each reports its real availability instead of
/// pretending. Files stopped being fake in Phase 2 W4
/// (services/files/local_file_service.dart), the runtime in Phase 4 W3
/// (services/runtime/runtime_service.dart), and search in Phase 4 W6
/// (services/search/search_service.dart).
library;

import 'dart:typed_data';

import '../core/errors/failure.dart';
import '../core/terminal/terminal_models.dart';
import 'contracts.dart';

/// No terminal host: every session call fails as unavailable. The
/// workbench's pane uses this until its view arrives (Phase 5 W3); the
/// Pigeon client (services/terminal/native/) is the real one.
final class FakeTerminalService implements TerminalService {
  static const TerminalFailure _unavailable = TerminalFailure(
    'The terminal needs the Linux runtime, on Android.',
    problem: TerminalProblem.unavailable,
  );

  @override
  TerminalAvailability get availability => TerminalAvailability.unavailable;

  @override
  String get unavailableReason =>
      'The terminal arrives in Phase 5, on the Linux runtime. '
      'This pane is a preview of the real thing.';

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
