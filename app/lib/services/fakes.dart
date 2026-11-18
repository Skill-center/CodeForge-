/// Honest fakes (docs/ARCHITECTURE.md §2.4) for the services whose phase
/// has not come yet. Each reports its real availability instead of
/// pretending. Files stopped being fake in Phase 2 W4
/// (services/files/local_file_service.dart), the runtime in Phase 4 W3
/// (services/runtime/runtime_service.dart), and search in Phase 4 W6
/// (services/search/search_service.dart).
library;

import '../core/errors/failure.dart';
import 'contracts.dart';

final class FakeTerminalService implements TerminalService {
  @override
  TerminalAvailability get availability => TerminalAvailability.unavailable;

  @override
  String get unavailableReason =>
      'The terminal arrives in Phase 5, on the Linux runtime. '
      'This pane is a preview of the real thing.';
}

final class FakeGitService implements GitService {
  @override
  Future<Result<GitSummary>> summary() async =>
      const Ok(GitSummary(branch: 'main'));
}
