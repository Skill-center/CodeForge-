/// Changes made outside the app (Phase 3 W5, docs/EDITOR_ARCHITECTURE.md
/// §6): which folders are watched, and what a change does.
///
/// - **Watched:** neither backend watches a whole tree, so the folders the
///   user can see are watched one by one: the workspace root, the folders
///   of the open documents (the active one's first), then the expanded
///   folders that show, shallowest first; [FileWatchSettings.maxFolders]
///   at most. FileService.watchFolder says how: inotify in a project, the
///   provider's change notices in a folder from shared storage.
/// - **Gathered:** notices gather for [FileWatchSettings.batch] from the
///   first one, so a tool that rewrites many files lists each folder once.
/// - **What a batch does:** each folder that changed is listed again (the
///   explorer shows the new listing, and Go to File's index follows), then
///   the open documents in it are compared with their files
///   (DocumentController.checkDisk), which reloads, asks or closes.
/// - **Re-checked anyway:** every open document when the app comes back to
///   the foreground, the active one when a tab is activated, and all of
///   them every [FileWatchSettings.recheckEvery] while in the foreground:
///   for storage that sends no notices, and for documents in folders past
///   the limit. A save records the stamp it wrote, so the app's own writes
///   change nothing.
/// - **In the background** nothing runs: notices wait. Coming back tries
///   again the watches that failed, compares every open document with its
///   file and lists every watched folder again, since notices may have
///   been missed.
///
/// The workbench keeps this alive while it shows, and tells it when the
/// app goes to the background and comes back.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/files/workspace_path.dart';
import '../core/logging/logger.dart';
import '../services/contracts.dart';
import 'documents/document_controller.dart';
import 'explorer_view_controller.dart';
import 'file_index.dart';
import 'git/git_controller.dart';
import 'lsp/lsp_controller.dart';
import 'providers.dart';
import 'workspace_controller.dart';

/// How the watcher paces itself.
final class FileWatchSettings {
  const FileWatchSettings({
    this.batch = const Duration(milliseconds: 300),
    this.recheckEvery = const Duration(seconds: 5),
    this.maxFolders = 64,
  });

  /// How long notices gather before a batch runs.
  final Duration batch;

  /// How often open documents are compared with their files in the
  /// foreground, notices or not.
  final Duration recheckEvery;

  /// The most folders watched at once.
  final int maxFolders;
}

final fileWatchSettingsProvider = Provider<FileWatchSettings>(
  (ref) => const FileWatchSettings(),
);

/// The folders to watch, most wanted first: the root, the folders of the
/// open documents (the active one's first), then the expanded folders that
/// show (every folder above them expanded), shallowest first; at most
/// [maxFolders].
List<String> foldersToWatch({
  required List<String> openPaths,
  required String? activePath,
  required Set<String> expanded,
  required int maxFolders,
}) {
  final folders = <String>{''};
  if (activePath != null) {
    folders.add(pathParent(activePath));
  }
  for (final path in openPaths) {
    folders.add(pathParent(path));
  }
  bool shows(String folder) {
    for (var above = pathParent(folder); above.isNotEmpty;) {
      if (!expanded.contains(above)) {
        return false;
      }
      above = pathParent(above);
    }
    return true;
  }

  final shown = [
    for (final folder in expanded)
      if (folder.isNotEmpty && shows(folder)) folder,
  ]..sort(compareShallowFirst);
  folders.addAll(shown);
  return folders.take(maxFolders).toList();
}

/// Orders paths by depth, then by name: a folder before what is in it.
int compareShallowFirst(String a, String b) {
  final depth = _depth(a).compareTo(_depth(b));
  return depth != 0 ? depth : a.compareTo(b);
}

int _depth(String path) => path.isEmpty ? 0 : '/'.allMatches(path).length + 1;

final class FileWatchController extends Notifier<List<String>> {
  final Map<String, StreamSubscription<void>> _subscriptions = {};
  final Set<String> _changed = {};
  Timer? _batch;
  Timer? _recheck;

  /// The app is in the foreground. Kept across workspaces: it is the
  /// app's state, not the workspace's.
  bool _foreground = true;

  /// Counts the builds, so work a previous workspace started lands nowhere.
  int _generation = 0;

  late FileWatchSettings _settings;

  @override
  List<String> build() {
    final files = ref.watch(fileServiceProvider);
    _settings = ref.watch(fileWatchSettingsProvider);
    _generation += 1;
    _changed.clear();
    ref.onDispose(() {
      for (final subscription in _subscriptions.values) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
      _batch?.cancel();
      _batch = null;
      _recheck?.cancel();
      _recheck = null;
    });
    ref.listen(
      documentControllerProvider.select((s) => s.openPaths),
      (_, _) => _watchWanted(),
    );
    ref.listen(documentControllerProvider.select((s) => s.activePath), (
      previous,
      next,
    ) {
      _watchWanted();
      if (next != null && next != previous && _foreground) {
        unawaited(_documents.checkDisk(paths: [next], active: _isForeground));
      }
    });
    ref.listen(
      explorerViewProvider.select((s) => s.expanded),
      (_, _) => _watchWanted(),
    );
    if (_foreground) {
      _startRechecks();
    }
    final wanted = _wanted();
    for (final folder in wanted) {
      _subscribe(folder, files);
    }
    return wanted;
  }

  DocumentController get _documents =>
      ref.read(documentControllerProvider.notifier);

  /// Whether the app is in the foreground: a check under way takes nothing
  /// in once it is not.
  bool _isForeground() => _foreground;

  /// The app went to the background: notices wait until it comes back.
  void paused() {
    _foreground = false;
    _batch?.cancel();
    _batch = null;
    _recheck?.cancel();
    _recheck = null;
  }

  /// The app came back: watches that failed are tried again, every open
  /// document is compared with its file and every watched folder listed
  /// again, since notices may have been missed meanwhile.
  Future<void> resumed() async {
    if (_foreground) {
      return;
    }
    _foreground = true;
    _startRechecks();
    _batch?.cancel();
    _batch = null;
    _changed.clear();
    // Watches that failed start again; their folders are listed below,
    // with every other one.
    _watchWanted(relist: false);
    final generation = _generation;
    final listed = ref.read(workspaceControllerProvider).listings;
    final folders = [
      for (final folder in state)
        if (listed.containsKey(folder)) folder,
    ];
    appLogger.debug('watch', 'resumed', fields: {'folders': folders.length});
    // The documents do not wait for the listings: they are what the user
    // looks at.
    await Future.wait([
      _documents.checkDisk(active: _isForeground),
      _relistAll(folders, generation),
    ]);
  }

  /// Lists [folders] again, one at a time, until the workspace changes.
  Future<void> _relistAll(List<String> folders, int generation) async {
    for (final folder in folders) {
      await _relist(folder);
      if (!ref.mounted || generation != _generation) {
        return;
      }
    }
  }

  List<String> _wanted() {
    final documents = ref.read(documentControllerProvider);
    return foldersToWatch(
      openPaths: documents.openPaths,
      activePath: documents.activePath,
      expanded: ref.read(explorerViewProvider).expanded,
      maxFolders: _settings.maxFolders,
    );
  }

  /// Watches what is wanted now, and nothing else. A folder watched anew
  /// that has a listing is listed again, unless [relist] is false.
  void _watchWanted({bool relist = true}) {
    final wanted = _wanted();
    final keep = wanted.toSet();
    for (final folder in [..._subscriptions.keys]) {
      if (!keep.contains(folder)) {
        unawaited(_subscriptions.remove(folder)?.cancel());
      }
    }
    final files = ref.read(fileServiceProvider);
    final listed = ref.read(workspaceControllerProvider).listings;
    for (final folder in wanted) {
      if (_subscriptions.containsKey(folder)) {
        continue;
      }
      _subscribe(folder, files);
      // Listed while nobody watched it (collapsed, then expanded again):
      // the listing may be old.
      if (relist && listed.containsKey(folder) && _foreground) {
        unawaited(_relist(folder));
      }
    }
    if (!listEquals(state, wanted)) {
      state = wanted;
    }
  }

  void _subscribe(String folder, FileService files) {
    final generation = _generation;
    _subscriptions[folder] = files
        .watchFolder(folder)
        .listen(
          (_) => _noticed(folder),
          onError: (Object error) {
            // Gone, or the storage can't watch it: tried again when the
            // folders to watch change, or the app comes back.
            appLogger.debug(
              'watch',
              'watch_failed',
              fields: {
                'path': folder,
                'error': error is Failure
                    ? error.message
                    : error.runtimeType.toString(),
              },
            );
            if (generation == _generation) {
              unawaited(_subscriptions.remove(folder)?.cancel());
            }
          },
          onDone: () {
            if (generation == _generation) {
              _subscriptions.remove(folder);
            }
          },
        );
  }

  void _noticed(String folder) {
    _changed.add(folder);
    if (_foreground) {
      _batch ??= Timer(_settings.batch, () => unawaited(_runBatch()));
    }
  }

  Future<void> _runBatch() async {
    _batch = null;
    if (_changed.isEmpty) {
      return;
    }
    final folders = [..._changed]..sort(compareShallowFirst);
    _changed.clear();
    final generation = _generation;
    appLogger.debug('watch', 'batch', fields: {'folders': folders.length});
    // The repository's status follows files changed outside the app (Phase
    // 7 W2), once the status strip has it.
    if (ref.exists(gitControllerProvider)) {
      ref.read(gitControllerProvider.notifier).changed();
    }
    for (final folder in folders) {
      await _relist(folder);
      // Gone to the background meanwhile: the rest waits for the app to come
      // back, whose catch-up lists every folder and checks every document.
      // A batch under way had taken a change in while away (Phase 5 W2's
      // phase gate 44461809588, the watch group).
      if (!ref.mounted || generation != _generation || !_foreground) {
        return;
      }
    }
    final open = ref.read(documentControllerProvider).openPaths;
    await _documents.checkDisk(
      paths: [
        for (final path in open)
          if (folders.any((folder) => isWithin(path, folder))) path,
      ],
      active: _isForeground,
    );
  }

  /// Lists [folder] again: through the explorer's listings when it has
  /// one, so the tree shows it, and into Go to File's index either way. A
  /// folder that is gone leaves the listings, the index and the expanded
  /// folders.
  Future<void> _relist(String folder) async {
    final workspace = ref.read(workspaceControllerProvider.notifier);
    final Result<List<FileEntry>> listed;
    if (ref.read(workspaceControllerProvider).listings.containsKey(folder)) {
      await workspace.load(folder);
      if (!ref.mounted) {
        return;
      }
      final listing = ref.read(workspaceControllerProvider).listings[folder];
      if (listing == null) {
        return;
      }
      listed = listing;
    } else {
      listed = await ref.read(fileServiceProvider).listDirectory(folder);
      if (!ref.mounted) {
        return;
      }
    }
    switch (listed) {
      case Ok<List<FileEntry>>(:final value):
        ref.read(fileIndexProvider.notifier).folderListed(folder, value);
        // What changed in it, for the language servers that asked (Phase 6
        // W4), once the status strip has them running.
        if (ref.exists(lspControllerProvider)) {
          ref.read(lspControllerProvider.notifier).folderListed(folder, value);
        }
      case Err<List<FileEntry>>(
        failure: FileFailure(problem: FileProblem.notFound),
      ):
        if (folder.isEmpty) {
          return;
        }
        appLogger.info('watch', 'folder_gone', fields: {'path': folder});
        workspace.forget(folder);
        ref.read(explorerViewProvider.notifier).pathRemoved(folder);
        ref.read(fileIndexProvider.notifier).removed(folder);
        if (ref.exists(lspControllerProvider)) {
          ref.read(lspControllerProvider.notifier).folderGone(folder);
        }
      case Err<List<FileEntry>>():
        break;
    }
  }

  void _startRechecks() {
    _recheck?.cancel();
    _recheck = Timer.periodic(_settings.recheckEvery, (_) {
      if (_foreground) {
        unawaited(_documents.checkDisk(active: _isForeground));
      }
    });
  }
}

final fileWatchProvider =
    NotifierProvider.autoDispose<FileWatchController, List<String>>(
      FileWatchController.new,
    );
