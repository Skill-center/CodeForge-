/// The open workspace and its folder listings (docs/EDITOR_ARCHITECTURE.md,
/// "Files"). The explorer reads listings from here instead of calling the
/// file service itself (docs/ARCHITECTURE.md §2.4).
///
/// Since Phase 3 W2 the workspace can change (workspace_switcher.dart): a
/// new file service is a new workspace, so the controller starts over, and
/// work the previous one still had in flight lands nowhere.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/files/workspace_path.dart';
import '../core/logging/logger.dart';
import '../services/contracts.dart';
import 'providers.dart';

final class WorkspaceState {
  const WorkspaceState({
    this.workspace,
    this.failure,
    this.listings = const {},
  });

  /// The open workspace; null until it opened.
  final WorkspaceRef? workspace;

  /// Why the workspace did not open, when it did not.
  final Failure? failure;

  /// Listed folders ('' is the root): their entries, or why not.
  final Map<String, Result<List<FileEntry>>> listings;
}

final class WorkspaceController extends Notifier<WorkspaceState> {
  Future<Result<WorkspaceRef>>? _opening;

  /// Listings in progress, by folder, and folders asked for again while
  /// theirs was. Per workspace: a listing the last one started lands
  /// nowhere, and does not hold this one's back.
  Map<String, Future<void>> _loading = {};
  Set<String> _stale = {};

  @override
  WorkspaceState build() {
    ref.keepAlive();
    // Another workspace opened: everything here starts over.
    ref.watch(fileServiceProvider);
    _loading = {};
    _stale = {};
    return const WorkspaceState();
  }

  /// Opens the workspace (creating it on first run) and lists its root.
  /// Concurrent callers share one attempt; after a failure, call again.
  Future<Result<WorkspaceRef>> open() async {
    final current = state.workspace;
    if (current != null) {
      return Ok(current);
    }
    final result = await (_opening ??= ref
        .read(fileServiceProvider)
        .openWorkspace());
    if (!ref.mounted) {
      // Another workspace opened meanwhile.
      return result;
    }
    _opening = null;
    switch (result) {
      case Ok<WorkspaceRef>(:final value):
        if (state.workspace == null) {
          state = WorkspaceState(workspace: value, listings: state.listings);
          appLogger.info('workspace', 'opened', fields: {'id': value.id});
        }
        await load('');
      case Err<WorkspaceRef>(:final failure):
        state = WorkspaceState(failure: failure, listings: state.listings);
        appLogger.warn(
          'workspace',
          'open_failed',
          fields: {'error': failure.message},
        );
    }
    return result;
  }

  /// Lists [folder], or lists it again. A request that arrives while the
  /// folder is being listed runs once more afterwards, so nothing created
  /// meanwhile is missed; either way the future completes once the listing
  /// is as fresh as the last request (Phase 3 W5: the file watcher reads it
  /// right after).
  Future<void> load(String folder) {
    final running = _loading[folder];
    if (running != null) {
      _stale.add(folder);
      return running;
    }
    final loading = _loading;
    final listing = _listUntilFresh(folder, loading, _stale);
    // Set after the listing reached its first await, before it can end.
    loading[folder] = listing;
    return listing;
  }

  Future<void> _listUntilFresh(
    String folder,
    Map<String, Future<void>> loading,
    Set<String> stale,
  ) async {
    try {
      do {
        stale.remove(folder);
        final result = await ref
            .read(fileServiceProvider)
            .listDirectory(folder);
        if (!ref.mounted || !identical(loading, _loading)) {
          return;
        }
        state = WorkspaceState(
          workspace: state.workspace,
          failure: state.failure,
          listings: {...state.listings, folder: result},
        );
      } while (stale.contains(folder));
    } finally {
      // This very load: dropped from the map, not awaited.
      unawaited(loading.remove(folder));
    }
  }

  /// [folder] is gone (Phase 3 W5: deleted outside the app): its listing
  /// and those of the folders in it go. The root stays: its failure shows.
  void forget(String folder) {
    if (folder.isEmpty) {
      return;
    }
    final kept = {
      for (final entry in state.listings.entries)
        if (!isWithin(entry.key, folder)) entry.key: entry.value,
    };
    if (kept.length == state.listings.length) {
      return;
    }
    state = WorkspaceState(
      workspace: state.workspace,
      failure: state.failure,
      listings: kept,
    );
  }

  /// Lists every listed folder again, after files were created.
  Future<void> refresh() async {
    await Future.wait([
      for (final folder in state.listings.keys.toList()) load(folder),
    ]);
  }

  /// The explorer changed the workspace (Phase 3 W4). The listings of
  /// [removed] and of everything in it go (it was moved, renamed or
  /// deleted), and every folder still listed is listed again.
  Future<void> changed({String? removed}) async {
    if (removed != null && removed.isNotEmpty) {
      state = WorkspaceState(
        workspace: state.workspace,
        failure: state.failure,
        listings: {
          for (final entry in state.listings.entries)
            if (!isWithin(entry.key, removed)) entry.key: entry.value,
        },
      );
    }
    await refresh();
  }
}

final workspaceControllerProvider =
    NotifierProvider<WorkspaceController, WorkspaceState>(
      WorkspaceController.new,
    );
