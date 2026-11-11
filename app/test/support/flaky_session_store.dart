/// A session store that can fail on demand (test/application/
/// document_journal_test.dart, document_controller_test.dart).
library;

import 'package:codeforge/core/editor/journal.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/storage/session_store.dart';

/// A session store whose writes fail while [failing] (or throw, while
/// [throwing]): a full disk, a broken database.
final class FlakySessionStore implements SessionStore {
  final MemorySessionStore inner = MemorySessionStore();
  bool failing = false;
  bool throwing = false;

  Future<Result<void>> _write(Future<Result<void>> Function() write) async {
    if (throwing) {
      throw StateError('database is closed');
    }
    if (failing) {
      return const Err(StorageFailure('disk full'));
    }
    return write();
  }

  @override
  Future<Result<void>> touchWorkspace(
    WorkspaceLocation workspace, {
    required String displayPath,
  }) => _write(
    () => inner.touchWorkspace(workspace, displayPath: displayPath),
  );

  @override
  Future<Result<List<WorkspaceRecord>>> loadWorkspaces() =>
      inner.loadWorkspaces();

  @override
  Future<Result<void>> moveWorkspace(
    String id, {
    required String name,
    required String location,
    required String displayPath,
  }) => _write(
    () => inner.moveWorkspace(
      id,
      name: name,
      location: location,
      displayPath: displayPath,
    ),
  );

  @override
  Future<Result<void>> forgetWorkspace(String id) =>
      _write(() => inner.forgetWorkspace(id));

  @override
  Future<Result<ExplorerView?>> loadView(String workspaceId) =>
      inner.loadView(workspaceId);

  @override
  Future<Result<void>> saveView(String workspaceId, ExplorerView view) =>
      _write(() => inner.saveView(workspaceId, view));

  @override
  Future<Result<List<SavedTab>>> loadTabs(String workspaceId) =>
      inner.loadTabs(workspaceId);

  @override
  Future<Result<void>> saveTabs(String workspaceId, List<SavedTab> tabs) =>
      _write(() => inner.saveTabs(workspaceId, tabs));

  @override
  Future<Result<List<JournalEntry>>> loadJournal(String workspaceId) =>
      inner.loadJournal(workspaceId);

  @override
  Future<Result<void>> writeSnapshot(
    JournalSnapshot snapshot, {
    bool restart = false,
  }) => _write(() => inner.writeSnapshot(snapshot, restart: restart));

  @override
  Future<Result<void>> appendChange(
    String workspaceId,
    String path,
    JournalChange change,
  ) => _write(() => inner.appendChange(workspaceId, path, change));

  @override
  Future<Result<void>> discardJournal(String workspaceId, String path) =>
      _write(() => inner.discardJournal(workspaceId, path));

  @override
  Future<void> close() async {}
}
