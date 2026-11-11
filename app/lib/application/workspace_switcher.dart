/// Opening and managing workspaces (Phase 3 W2, W3): projects in the app's
/// own storage, created, renamed and deleted from Home, and folders the
/// user picks from shared storage through Android's folder picker
/// (docs/SECURITY.md §4.1), reconnected when they move and given back
/// when they leave the recents.
///
/// The open workspace is remembered in the shell envelope, so a cold start
/// reopens it, and the recents in the session store. Switching stores the
/// open documents first: each workspace keeps its own tabs, unsaved text
/// and explorer view in the session store, by workspace id, which never
/// changes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/files/workspace_location.dart';
import '../core/logging/logger.dart';
import '../services/contracts.dart';
import '../services/files/demo_workspace.dart';
import '../services/files/project_storage.dart';
import '../services/files/saf_file_service.dart';
import '../services/files/storage_broker.dart';
import '../services/storage/session_store.dart';
import 'documents/document_controller.dart';
import 'providers.dart';
import 'shell_controller.dart';
import 'workspace_controller.dart';

final class WorkspaceSwitcher {
  WorkspaceSwitcher(this._ref);

  final Ref _ref;

  SessionStore get _store => _ref.read(sessionStoreProvider);

  StorageBroker get _broker => _ref.read(storageBrokerProvider);

  ProjectStorage get _projects => _ref.read(projectStorageProvider);

  bool _isOpen(WorkspaceLocation workspace) =>
      _ref.read(currentWorkspaceProvider).id == workspace.id;

  /// Stores the open documents and closes them in the editor; their tabs
  /// and unsaved text come back when their workspace opens again.
  Future<void> _leave() =>
      _ref.read(documentControllerProvider.notifier).leaveWorkspace();

  /// Shows the folder picker and opens the folder the user picks. Ok(null)
  /// when the user backs out.
  Future<Result<WorkspaceRef?>> pickFolder() async {
    switch (await _pick(_ref.read(folderPickerStartProvider))) {
      case Err<FolderInfo?>(:final failure):
        return Err(failure);
      case Ok<FolderInfo?>(:final value):
        if (value == null) {
          return const Ok(null);
        }
        return open(await _folderFor(value));
    }
  }

  /// Android's folder picker, starting at [start]: the folder picked, which
  /// must be there and granted; Ok(null) when the user backs out.
  Future<Result<FolderInfo?>> _pick(String? start) async {
    final picked = await _broker.pickFolder(initialUri: start);
    switch (picked) {
      case Err<FolderInfo?>(:final failure):
        appLogger.warn(
          'workspace',
          'folder_pick_failed',
          fields: {'error': failure.message},
        );
        return Err(failure);
      case Ok<FolderInfo?>(:final value):
        if (value == null || value.status == FolderStatus.available) {
          return picked;
        }
        return Err(
          FileFailure(
            'The folder could not be opened.',
            problem: value.status == FolderStatus.missing
                ? FileProblem.folderMissing
                : FileProblem.accessLost,
          ),
        );
    }
  }

  Future<List<WorkspaceRecord>> _records() async =>
      (await _store.loadWorkspaces()).valueOrNull ?? const <WorkspaceRecord>[];

  /// The workspace for the folder [info] names: the recents' entry for
  /// that place when there is one, so it keeps its id, or a new one.
  Future<FolderLocation> _folderFor(FolderInfo info) async {
    final records = await _records();
    final name = info.name.isEmpty ? 'Folder' : info.name;
    for (final record in records) {
      if (record.kind == WorkspaceKind.folder &&
          record.location == info.treeUri) {
        return FolderLocation(treeUri: info.treeUri, name: name, id: record.id);
      }
    }
    // The usual id may name another folder: one reconnected at this
    // folder's old place.
    final usual = folderWorkspaceId(info.treeUri);
    final taken = records.any(
      (record) => record.id == usual && record.location.isNotEmpty,
    );
    return FolderLocation(
      treeUri: info.treeUri,
      name: name,
      id: taken ? newFolderId() : null,
    );
  }

  /// Makes [location] the open workspace and opens it, listing its root,
  /// and the recents record it. The current workspace's tabs and unsaved
  /// text are stored first; they come back when it opens again.
  Future<Result<WorkspaceRef>> open(WorkspaceLocation location) async {
    if (location is FolderLocation && location.treeUri.isEmpty) {
      // Recorded before the recents kept places (Phase 3 W2).
      return Err(
        FileFailure(
          'CodeForge no longer has access to "${location.name}". Reconnect '
          'it from Home to give it access again.',
          problem: FileProblem.accessLost,
        ),
      );
    }
    if (_ref.read(currentWorkspaceProvider) != location) {
      // A workspace that is gone or no longer granted is reported before
      // the open one is left, so it stays open.
      final found = await _check(location);
      if (found case Err<WorkspaceRef>(:final failure)) {
        return Err(failure);
      }
      await _leave();
      await _ref.read(shellControllerProvider.notifier).setWorkspace(location);
      appLogger.info(
        'workspace',
        'switched',
        fields: {'kind': location.kind.name, 'id': location.id},
      );
    }
    final opened = await _ref.read(workspaceControllerProvider.notifier).open();
    if (opened.isOk) {
      await _store.touchWorkspace(
        location,
        displayPath: displayPathOf(location),
      );
    }
    return opened;
  }

  /// Whether [location] can open: its folder is there and granted. The
  /// demo project always can (it is written again when it is not there).
  Future<Result<WorkspaceRef>> _check(WorkspaceLocation location) async {
    switch (location) {
      case ProjectLocation(isDemo: true):
        return const Ok(
          WorkspaceRef(id: demoWorkspaceId, displayName: demoProjectName),
        );
      case final ProjectLocation project:
        return _projects.files(project).openWorkspace();
      case final FolderLocation folder:
        return SafFileService(broker: _broker, folder: folder).openWorkspace();
    }
  }

  /// Creates a project named [name], empty or with the demo project's
  /// files, and records it in the recents. The caller opens it.
  Future<Result<ProjectLocation>> createProject(
    String name, {
    bool fromTemplate = false,
  }) async {
    final taken = (await _projects.folders()).valueOrNull ?? const <String>[];
    final invalid = projectNameProblem(name, taken: taken);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    final created = await _projects.create(
      name,
      seed: fromTemplate ? DemoWorkspace.files : const {},
    );
    if (created case Err<void>(:final failure)) {
      return Err(failure);
    }
    final project = ProjectLocation(id: newProjectId(), name: name, folder: name);
    await _store.touchWorkspace(project, displayPath: displayPathOf(project));
    appLogger.info(
      'workspace',
      'project_created',
      fields: {'template': fromTemplate},
    );
    return Ok(project);
  }

  /// Renames [project], its folder and then its record, in that order; a
  /// record that can't be written puts the folder back. It keeps its id,
  /// so its tabs, unsaved text and view follow. The demo project keeps its
  /// name.
  Future<Result<ProjectLocation>> renameProject(
    ProjectLocation project,
    String name,
  ) async {
    if (project.isDemo) {
      return const Err(
        FileFailure(
          'The demo project keeps its name.',
          problem: FileProblem.unsupported,
        ),
      );
    }
    final taken = [
      for (final folder
          in (await _projects.folders()).valueOrNull ?? const <String>[])
        if (folder != project.folder) folder,
    ];
    final invalid = projectNameProblem(name, taken: taken);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    if (name == project.folder) {
      return Ok(project);
    }
    final open = _isOpen(project);
    if (open) {
      await _leave();
    }
    final renamed = ProjectLocation(id: project.id, name: name, folder: name);
    final moved = await _projects.rename(project.folder, name);
    if (moved case Err<void>(:final failure)) {
      return Err(failure);
    }
    final recorded = await _store.moveWorkspace(
      project.id,
      name: name,
      location: name,
      displayPath: displayPathOf(renamed),
    );
    if (recorded case Err<void>(:final failure)) {
      await _projects.rename(name, project.folder);
      return Err(failure);
    }
    if (open) {
      await _ref.read(shellControllerProvider.notifier).setWorkspace(renamed);
    }
    appLogger.info('workspace', 'project_renamed');
    return Ok(renamed);
  }

  /// How many files [project] holds and how many of its documents have
  /// unsaved changes, for the question before it is deleted.
  Future<({int files, int unsaved})> projectContents(
    ProjectLocation project,
  ) async {
    final files = (await _projects.countFiles(project.folder)).valueOrNull;
    return (files: files ?? 0, unsaved: await unsavedCount(project));
  }

  /// How many of [workspace]'s documents have unsaved changes.
  Future<int> unsavedCount(WorkspaceLocation workspace) async {
    if (_isOpen(workspace)) {
      // The open workspace's journal may not be stored yet.
      await _ref.read(documentControllerProvider.notifier).checkpoint();
    }
    return (await _store.loadJournal(workspace.id)).valueOrNull?.length ?? 0;
  }

  /// Deletes [project]: its folder, then everything the app kept about it
  /// (tabs, unsaved text, explorer view). When it is open its documents
  /// close first, and the demo project becomes the open workspace; the
  /// demo project itself is written again the next time it opens.
  Future<Result<void>> deleteProject(ProjectLocation project) async {
    if (_isOpen(project)) {
      await _leave();
      if (!project.isDemo) {
        await _ref
            .read(shellControllerProvider.notifier)
            .setWorkspace(const DemoProjectLocation());
      }
    }
    final deleted = await _projects.delete(project.folder);
    if (deleted case Err<void>(:final failure)) {
      return Err(failure);
    }
    if (project.isDemo) {
      // Its file service remembers the folder it found.
      _ref.invalidate(projectFileServiceProvider);
      _ref.read(shellControllerProvider.notifier).markDemoWorkspaceDeleted();
    }
    appLogger.info('workspace', 'project_deleted');
    return _store.forgetWorkspace(project.id);
  }

  /// Takes [folder] off the recents: gives its grant back to Android (which
  /// limits how many an app keeps) and forgets what the app kept about it.
  /// The folder and its files stay where they are.
  Future<Result<void>> removeFolder(FolderLocation folder) async {
    if (_isOpen(folder)) {
      await _leave();
      await _ref
          .read(shellControllerProvider.notifier)
          .setWorkspace(const DemoProjectLocation());
    }
    await _release(folder.treeUri);
    appLogger.info('workspace', 'folder_removed');
    return _store.forgetWorkspace(folder.id);
  }

  Future<void> _release(String treeUri) async {
    if (treeUri.isEmpty) {
      return;
    }
    if (await _broker.releaseGrant(treeUri) case Err<void>(:final failure)) {
      appLogger.warn(
        'workspace',
        'grant_release_failed',
        fields: {'error': failure.message},
      );
    }
  }

  /// Reopens the folder picker at [folder]'s old place. The folder picked
  /// comes back to the caller: [folder] itself is reconnected at once
  /// ([isSameFolder]), another needs the user's word before it replaces
  /// the entry ([reconnect], or [dropPicked]). Ok(null) when the user backs
  /// out.
  Future<Result<FolderInfo?>> pickForReconnect(FolderLocation folder) =>
      _pick(folderPickerStart(folder.treeUri) ?? folder.treeUri.nullIfEmpty);

  /// Whether [picked] is [folder]: the same grant, or the folder its id
  /// was first made from.
  bool isSameFolder(FolderLocation folder, FolderInfo picked) =>
      picked.treeUri == folder.treeUri ||
      folderWorkspaceId(picked.treeUri) == folder.id;

  /// Points [folder]'s entry at [picked], keeping its id, so its tabs,
  /// unsaved text and view follow, gives back the old place's grant, and
  /// opens it. A folder the recents already hold under another entry is
  /// refused: open that entry instead.
  Future<Result<WorkspaceRef>> reconnect(
    FolderLocation folder,
    FolderInfo picked,
  ) async {
    final records = await _records();
    final pickedId = folderWorkspaceId(picked.treeUri);
    final elsewhere = records.where(
      (record) =>
          record.id != folder.id &&
          (record.location == picked.treeUri ||
              (record.location.isEmpty && record.id == pickedId)),
    );
    if (elsewhere.isNotEmpty) {
      return Err(
        FileFailure(
          '"${elsewhere.first.name}" is already in your recents: open it '
          'from there.',
          problem: FileProblem.exists,
        ),
      );
    }
    final name = picked.name.isEmpty ? folder.name : picked.name;
    final moved = FolderLocation(
      treeUri: picked.treeUri,
      name: name,
      id: folder.id,
    );
    if (folder.treeUri != picked.treeUri) {
      await _release(folder.treeUri);
    }
    final recorded = await _store.moveWorkspace(
      folder.id,
      name: name,
      location: picked.treeUri,
      displayPath: displayPathOf(moved),
    );
    if (recorded case Err<void>(:final failure)) {
      return Err(failure);
    }
    appLogger.info('workspace', 'folder_reconnected');
    return open(moved);
  }

  /// Gives back the grant of a folder picked and then turned down, unless
  /// an entry of the recents is that folder.
  Future<void> dropPicked(FolderInfo picked) async {
    final records = await _records();
    if (records.any((record) => record.location == picked.treeUri)) {
      return;
    }
    await _release(picked.treeUri);
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

final workspaceSwitcherProvider = Provider<WorkspaceSwitcher>(
  WorkspaceSwitcher.new,
);
