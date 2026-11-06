/// Honest fakes (docs/ARCHITECTURE.md §2.4) for the services whose phase
/// has not come yet. Each reports its real availability instead of
/// pretending. Files stopped being fake in Phase 2 W4
/// (services/files/local_file_service.dart).
library;

import '../core/errors/failure.dart';
import 'contracts.dart';

final class FakeTerminalService implements TerminalService {
  @override
  TerminalAvailability get availability => TerminalAvailability.unavailable;

  @override
  String get unavailableReason =>
      'The Linux runtime and terminal arrive in Phases 4–5. '
      'This pane is a preview of the real thing.';
}

final class FakeRuntimeService implements RuntimeService {
  @override
  Future<Result<RuntimeState>> state() async =>
      const Ok(RuntimeState.notInstalled);
}

final class FakeGitService implements GitService {
  @override
  Future<Result<GitSummary>> summary() async =>
      const Ok(GitSummary(branch: 'main'));
}

/// File-name search over the workspace's top folder, until Phase 3.
final class FakeSearchService implements SearchService {
  FakeSearchService(this._files);

  final FileService _files;

  @override
  Future<Result<List<String>>> searchFiles(String query) async {
    if (query.isEmpty) {
      return const Ok([]);
    }
    final listing = await _files.listDirectory('');
    return switch (listing) {
      Ok<List<FileEntry>>(:final value) => Ok(
        value
            .where(
              (e) => !e.isDirectory && e.name.contains(query.toLowerCase()),
            )
            .map((e) => e.path)
            .toList(),
      ),
      Err<List<FileEntry>>(:final failure) => Err(failure),
    };
  }
}
