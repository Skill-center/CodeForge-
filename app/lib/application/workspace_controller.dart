/// The open workspace and its folder listings (docs/EDITOR_ARCHITECTURE.md,
/// "Files"). The explorer reads listings from here instead of calling the
/// file service itself (docs/ARCHITECTURE.md §2.4).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
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
  final Set<String> _loading = {};
  final Set<String> _stale = {};

  @override
  WorkspaceState build() {
    ref.keepAlive();
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
  /// meanwhile is missed.
  Future<void> load(String folder) async {
    if (_loading.contains(folder)) {
      _stale.add(folder);
      return;
    }
    _loading.add(folder);
    try {
      do {
        _stale.remove(folder);
        final result = await ref
            .read(fileServiceProvider)
            .listDirectory(folder);
        state = WorkspaceState(
          workspace: state.workspace,
          failure: state.failure,
          listings: {...state.listings, folder: result},
        );
      } while (_stale.contains(folder));
    } finally {
      _loading.remove(folder);
    }
  }

  /// Lists every listed folder again, after files were created.
  Future<void> refresh() async {
    await Future.wait([
      for (final folder in state.listings.keys.toList()) load(folder),
    ]);
  }
}

final workspaceControllerProvider =
    NotifierProvider<WorkspaceController, WorkspaceState>(
      WorkspaceController.new,
    );
