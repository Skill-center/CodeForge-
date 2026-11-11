/// Home's recents (Phase 3 W3): the projects on this device and the folders
/// opened before, most recently opened first, each with its kind, its
/// place and what was found when it was last checked.
///
/// Projects come from the session store's records and from the projects'
/// folders themselves, so a project whose record is gone (a database that
/// could not be opened) still shows. Folders are checked through the
/// storage broker: still there, gone, or no longer granted.
///
/// Records from before the recents kept places (Phase 3 W2's schema v1)
/// name folders only by a hash of their URI. Their places come back from
/// the grants the app still holds, whose URIs hash to the same ids, and
/// from the shell, which remembered the open folder's.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/files/workspace_location.dart';
import '../services/files/storage_broker.dart';
import '../services/storage/session_store.dart';
import 'providers.dart';
import 'shell_controller.dart';

/// What was found when a workspace was last checked.
enum WorkspaceStatus {
  /// Not checked yet.
  checking,

  available,

  /// Its folder is gone: deleted, moved or renamed, or its storage removed.
  missing,

  /// The app no longer has access to it: its grant was released or
  /// revoked, or its place was never recorded.
  accessLost,

  /// The check itself failed (the storage did not answer).
  unknown,
}

/// One entry of the recents.
final class RecentWorkspace {
  const RecentWorkspace({
    required this.location,
    required this.displayPath,
    required this.lastOpenedAt,
    this.status = WorkspaceStatus.checking,
  });

  final WorkspaceLocation location;

  /// Its place as Home shows it.
  final String displayPath;

  /// When it was last opened; the epoch for a project never opened.
  final DateTime lastOpenedAt;

  final WorkspaceStatus status;

  RecentWorkspace withStatus(WorkspaceStatus status) => RecentWorkspace(
    location: location,
    displayPath: displayPath,
    lastOpenedAt: lastOpenedAt,
    status: status,
  );
}

final class RecentsState {
  const RecentsState({this.loaded = false, this.entries = const []});

  /// The records were read at least once.
  final bool loaded;

  /// Most recently opened first.
  final List<RecentWorkspace> entries;

  /// The projects' folder names, to check a new project's name against.
  List<String> get projectFolders => [
    for (final entry in entries)
      if (entry.location case ProjectLocation(:final folder)) folder,
  ];
}

final class RecentsController extends Notifier<RecentsState> {
  int _generation = 0;

  @override
  RecentsState build() {
    ref.keepAlive();
    return const RecentsState();
  }

  /// Reads the recents again, then checks every entry. A refresh asked for
  /// while one runs replaces it.
  Future<void> refresh() async {
    final generation = ++_generation;
    final store = ref.read(sessionStoreProvider);
    final stored =
        (await store.loadWorkspaces()).valueOrNull ??
        const <WorkspaceRecord>[];
    final folders =
        (await ref.read(projectStorageProvider).folders()).valueOrNull ??
        const <String>[];
    if (!ref.mounted || generation != _generation) {
      return;
    }
    final records = await _withPlaces(store, stored);
    if (!ref.mounted || generation != _generation) {
      return;
    }
    final entries = _entries(
      records,
      folders,
      ref.read(shellControllerProvider).workspace,
    );
    state = RecentsState(loaded: true, entries: entries);
    final statuses = await Future.wait([
      for (final entry in entries) _check(entry.location, folders),
    ]);
    if (!ref.mounted || generation != _generation) {
      return;
    }
    state = RecentsState(
      loaded: true,
      entries: [
        for (final (index, entry) in entries.indexed)
          entry.withStatus(statuses[index]),
      ],
    );
  }

  /// [records] with the places of folders recorded without one filled in,
  /// from the shell's open folder and the grants the app holds, and stored.
  Future<List<WorkspaceRecord>> _withPlaces(
    SessionStore store,
    List<WorkspaceRecord> records,
  ) async {
    final unplaced = {
      for (final record in records)
        if (record.kind == WorkspaceKind.folder && record.location.isEmpty)
          record.id: record,
    };
    if (unplaced.isEmpty) {
      return records;
    }
    final places = <String, String>{};
    if (ref.read(shellControllerProvider).workspace case FolderLocation(
      :final id,
      :final treeUri,
    ) when treeUri.isNotEmpty && unplaced.containsKey(id)) {
      places[id] = treeUri;
    }
    final grants =
        (await ref.read(storageBrokerProvider).grants()).valueOrNull ??
        const <FolderGrant>[];
    for (final grant in grants) {
      final id = folderWorkspaceId(grant.treeUri);
      if (unplaced.containsKey(id)) {
        places.putIfAbsent(id, () => grant.treeUri);
      }
    }
    final placed = <WorkspaceRecord>[];
    for (final record in records) {
      final place = places[record.id];
      if (place == null) {
        placed.add(record);
        continue;
      }
      final displayPath = folderDisplayPath(place, record.name);
      await store.moveWorkspace(
        record.id,
        name: record.name,
        location: place,
        displayPath: displayPath,
      );
      placed.add(
        WorkspaceRecord(
          id: record.id,
          kind: record.kind,
          name: record.name,
          location: place,
          displayPath: displayPath,
          lastOpenedAt: record.lastOpenedAt,
        ),
      );
    }
    return placed;
  }

  /// The recents from [records], the open workspace [current] first when
  /// the records lack it (they could not be read, or were written before
  /// it opened), and the project [folders] no entry covers last.
  static List<RecentWorkspace> _entries(
    List<WorkspaceRecord> records,
    List<String> folders,
    WorkspaceLocation? current,
  ) {
    final entries = <RecentWorkspace>[];
    final ids = <String>{};
    final projectFolders = <String>{};
    if (current != null &&
        !(current is FolderLocation && current.treeUri.isEmpty) &&
        !records.any((record) => record.id == current.id)) {
      ids.add(current.id);
      if (current case ProjectLocation(:final folder)) {
        projectFolders.add(folder);
      }
      entries.add(
        RecentWorkspace(
          location: current,
          displayPath: displayPathOf(current),
          lastOpenedAt: DateTime.now().toUtc(),
        ),
      );
    }
    for (final record in records) {
      final location = workspaceFromParts(
        kind: record.kind.name,
        id: record.id,
        name: record.name,
        location: record.location,
      );
      if (location == null || !ids.add(location.id)) {
        continue;
      }
      if (location case ProjectLocation(:final folder)) {
        projectFolders.add(folder);
      }
      entries.add(
        RecentWorkspace(
          location: location,
          displayPath: displayPathOf(location),
          lastOpenedAt: record.lastOpenedAt,
        ),
      );
    }
    // Project folders without a record: never opened since a record was
    // lost, or since before the recents knew projects.
    final adopted = folders.where((f) => !projectFolders.contains(f)).toList()
      ..sort();
    for (final folder in adopted) {
      final project = folder == demoProjectFolder
          ? const DemoProjectLocation()
          : ProjectLocation(
              id: adoptedProjectId(folder),
              name: folder,
              folder: folder,
            );
      if (!ids.add(project.id)) {
        continue;
      }
      entries.add(
        RecentWorkspace(
          location: project,
          displayPath: displayPathOf(project),
          lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ),
      );
    }
    return entries;
  }

  Future<WorkspaceStatus> _check(
    WorkspaceLocation location,
    List<String> folders,
  ) async {
    switch (location) {
      case ProjectLocation(:final folder, :final isDemo):
        // The demo project is written again whenever it opens.
        return isDemo || folders.contains(folder)
            ? WorkspaceStatus.available
            : WorkspaceStatus.missing;
      case FolderLocation(:final treeUri):
        if (treeUri.isEmpty) {
          return WorkspaceStatus.accessLost;
        }
        final found = await ref.read(storageBrokerProvider).checkFolder(treeUri);
        return switch (found) {
          Ok<FolderInfo>(:final value) => switch (value.status) {
            FolderStatus.available => WorkspaceStatus.available,
            FolderStatus.missing => WorkspaceStatus.missing,
            FolderStatus.accessLost => WorkspaceStatus.accessLost,
          },
          Err<FolderInfo>(:final failure) => switch (failure) {
            FileFailure(problem: FileProblem.folderMissing) =>
              WorkspaceStatus.missing,
            FileFailure(problem: FileProblem.accessLost) =>
              WorkspaceStatus.accessLost,
            _ => WorkspaceStatus.unknown,
          },
        };
    }
  }
}

final recentsProvider = NotifierProvider<RecentsController, RecentsState>(
  RecentsController.new,
);
