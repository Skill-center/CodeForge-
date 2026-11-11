/// Opening workspaces (Phase 3 W2): the built-in project, or a folder the
/// user picks from shared storage through Android's folder picker
/// (docs/SECURITY.md §4.1).
///
/// The open workspace is remembered in the shell envelope, so a cold start
/// reopens it (W3 moves workspaces into the database, with recents).
/// Switching stores the open documents first: each workspace keeps its own
/// tabs and unsaved text in the session store, by workspace id.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/files/workspace_location.dart';
import '../core/logging/logger.dart';
import '../services/contracts.dart';
import '../services/files/storage_broker.dart';
import 'documents/document_controller.dart';
import 'providers.dart';
import 'shell_controller.dart';
import 'workspace_controller.dart';

final class WorkspaceSwitcher {
  WorkspaceSwitcher(this._ref);

  final Ref _ref;

  /// Shows the folder picker and opens the folder the user picks. Ok(null)
  /// when the user backs out.
  Future<Result<WorkspaceRef?>> pickFolder() async {
    final picked = await _ref
        .read(storageBrokerProvider)
        .pickFolder(initialUri: _ref.read(folderPickerStartProvider));
    switch (picked) {
      case Err<FolderInfo?>(:final failure):
        appLogger.warn(
          'workspace',
          'folder_pick_failed',
          fields: {'error': failure.message},
        );
        return Err(failure);
      case Ok<FolderInfo?>(:final value):
        if (value == null) {
          return const Ok(null);
        }
        if (value.status != FolderStatus.available) {
          return Err(
            FileFailure(
              'The folder could not be opened.',
              problem: value.status == FolderStatus.missing
                  ? FileProblem.folderMissing
                  : FileProblem.accessLost,
            ),
          );
        }
        return open(FolderLocation(treeUri: value.treeUri, name: value.name));
    }
  }

  /// Makes [location] the open workspace and opens it, listing its root.
  /// The current workspace's tabs and unsaved text are stored first; they
  /// come back when it opens again.
  Future<Result<WorkspaceRef>> open(WorkspaceLocation location) async {
    if (_ref.read(currentWorkspaceProvider) != location) {
      await _ref.read(documentControllerProvider.notifier).leaveWorkspace();
      await _ref
          .read(shellControllerProvider.notifier)
          .setFolder(location is FolderLocation ? location : null);
      appLogger.info(
        'workspace',
        'switched',
        fields: {
          'kind': location is FolderLocation ? 'folder' : 'project',
          'id': location.id,
        },
      );
    }
    return _ref.read(workspaceControllerProvider.notifier).open();
  }
}

final workspaceSwitcherProvider = Provider<WorkspaceSwitcher>(
  WorkspaceSwitcher.new,
);
