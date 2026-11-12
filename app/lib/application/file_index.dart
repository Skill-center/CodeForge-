/// Go to File's index (Phase 3 W4): every file in the workspace, as a
/// fuzzy-matching target (core/files/fuzzy_match.dart).
///
/// - **Built** the first time Go to File opens in a workspace, through the
///   file service, top folders first. It never blocks the UI: every listing
///   is awaited, and the dialog shows the files found so far.
/// - **Skipped:** `.git` and `node_modules` folders, at any depth.
/// - **Limits:** it stops at [FileIndexController.maxEntries] files and says
///   so ([FileIndexState.truncated]), and at
///   [FileIndexController.maxDepth] folders deep. A folder that can't be
///   listed is left out; only the top folder failing fails the index.
/// - **Kept current** by the explorer's operations (FileOperations) and by
///   New File and Save As (DocumentController). Changes made outside the
///   app are W5's: until then they show after the workspace is opened
///   again. Changes apply one at a time, in order, after any build.
/// - **Per workspace:** switching workspaces drops it.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/files/fuzzy_match.dart';
import '../core/files/workspace_path.dart';
import '../core/logging/logger.dart';
import '../services/contracts.dart';
import 'providers.dart';

enum FileIndexStatus { idle, building, ready, failed }

final class FileIndexState {
  const FileIndexState({
    this.status = FileIndexStatus.idle,
    this.files = const [],
    this.truncated = false,
    this.failure,
  });

  final FileIndexStatus status;

  /// The files found, in the order they were found: top folders first.
  final List<FuzzyTarget> files;

  /// Whether the index stopped at [FileIndexController.maxEntries] with
  /// files left out.
  final bool truncated;

  /// Why the workspace's top folder could not be listed.
  final Failure? failure;
}

final class FileIndexController extends Notifier<FileIndexState> {
  /// The index stops at this many files.
  static const int maxEntries = 50000;

  /// Folders deeper than this are not listed.
  static const int maxDepth = 64;

  /// Folders the index never enters.
  static const Set<String> skippedFolders = {'.git', 'node_modules'};

  /// While building, the files found so far are shown every this many.
  static const int publishEvery = 2000;

  int _generation = 0;
  Future<void> _queue = Future<void>.value();

  @override
  FileIndexState build() {
    ref.watch(currentWorkspaceProvider);
    ref.watch(fileServiceProvider);
    _generation++;
    _queue = Future<void>.value();
    return const FileIndexState();
  }

  FileService get _files => ref.read(fileServiceProvider);

  /// Completes when every change asked for so far has been applied,
  /// including a rebuild one of them started.
  Future<void> get settled async {
    Future<void> current;
    do {
      current = _queue;
      await current;
    } while (!identical(current, _queue));
  }

  /// Builds the index, unless it is built or being built.
  void ensureBuilt() {
    if (state.status == FileIndexStatus.idle ||
        state.status == FileIndexStatus.failed) {
      unawaited(rebuild());
    }
  }

  /// Lists the whole workspace again.
  Future<void> rebuild() {
    final generation = ++_generation;
    state = const FileIndexState(status: FileIndexStatus.building);
    _queue = Future<void>.value();
    return _enqueue(generation, () => _build(generation));
  }

  /// A file was created at [path].
  void added(String path) {
    if (_inSkippedFolder(pathParent(path))) {
      return;
    }
    _change((current) {
      if (current.files.any((file) => file.path == path)) {
        return null;
      }
      if (current.files.length >= maxEntries) {
        return _ready(current.files, truncated: true);
      }
      return _ready([
        ...current.files,
        FuzzyTarget(path),
      ], truncated: current.truncated);
    });
  }

  /// Everything in the folder [folder] was created (a copy of a folder).
  void addedTree(String folder) {
    if (_inSkippedFolder(folder)) {
      return;
    }
    final generation = _generation;
    unawaited(
      _enqueue(generation, () async {
        if (state.status != FileIndexStatus.ready) {
          return;
        }
        final files = [...state.files];
        final known = {for (final file in files) file.path};
        final walked = await _walk(folder, files, known, generation);
        if (walked == null) {
          return;
        }
        state = _ready(files, truncated: state.truncated || walked.truncated);
      }),
    );
  }

  /// The file or folder at [from] is now at [to] (a rename or a move).
  void moved(String from, String to) {
    if (_inSkippedFolder(from) != _inSkippedFolder(to)) {
      // Into or out of .git or node_modules: what to list is not known.
      _change((current) {
        unawaited(rebuild());
        return null;
      });
      return;
    }
    _change((current) {
      var changed = false;
      final files = <FuzzyTarget>[];
      for (final file in current.files) {
        final moved = movedPath(file.path, from, to);
        if (moved == null) {
          files.add(file);
        } else {
          files.add(FuzzyTarget(moved));
          changed = true;
        }
      }
      return changed ? _ready(files, truncated: current.truncated) : null;
    });
  }

  /// The file or folder at [path] was deleted.
  void removed(String path) {
    _change((current) {
      final files = [
        for (final file in current.files)
          if (!isWithin(file.path, path)) file,
      ];
      return files.length == current.files.length
          ? null
          : _ready(files, truncated: current.truncated);
    });
  }

  /// Applies [change] to the built index, after everything queued before
  /// it; an index that is not built has nothing to keep current. [change]
  /// answers the new state, or null for no change.
  void _change(FileIndexState? Function(FileIndexState current) change) {
    unawaited(
      _enqueue(_generation, () async {
        if (state.status != FileIndexStatus.ready) {
          return;
        }
        final next = change(state);
        if (next != null) {
          state = next;
        }
      }),
    );
  }

  /// Runs [work] after everything queued before it, unless the index was
  /// rebuilt or dropped since [generation].
  Future<void> _enqueue(int generation, Future<void> Function() work) {
    final next = _queue.then((_) async {
      if (!ref.mounted || generation != _generation) {
        return;
      }
      try {
        await work();
      } on Object catch (error) {
        appLogger.error(
          'file_index',
          'update_failed',
          fields: {'error': error.runtimeType.toString()},
        );
      }
    });
    _queue = next;
    return next;
  }

  Future<void> _build(int generation) async {
    final watch = Stopwatch()..start();
    final files = <FuzzyTarget>[];
    final walked = await _walk(
      '',
      files,
      <String>{},
      generation,
      publish: true,
    );
    if (walked == null) {
      return;
    }
    if (walked.failure case final failure?) {
      state = FileIndexState(status: FileIndexStatus.failed, failure: failure);
      appLogger.warn(
        'file_index',
        'build_failed',
        fields: {
          'problem': failure is FileFailure ? failure.problem.name : 'other',
        },
      );
      return;
    }
    state = _ready(files, truncated: walked.truncated);
    appLogger.info(
      'file_index',
      'built',
      fields: {
        'files': files.length,
        'truncated': walked.truncated,
        'unlisted': walked.unlisted,
        'ms': watch.elapsedMilliseconds,
      },
    );
  }

  /// Lists [root] and everything in it, top folders first, adding files not
  /// in [known] to [files]. Null when the index was rebuilt or dropped
  /// meanwhile.
  Future<_Walk?> _walk(
    String root,
    List<FuzzyTarget> files,
    Set<String> known,
    int generation, {
    bool publish = false,
  }) async {
    final pending = Queue<(String, int)>()
      ..add((root, root.isEmpty ? 0 : root.split('/').length));
    var unlisted = 0;
    var published = files.length;
    while (pending.isNotEmpty) {
      final (folder, depth) = pending.removeFirst();
      final listed = await _files.listDirectory(folder);
      if (!ref.mounted || generation != _generation) {
        return null;
      }
      switch (listed) {
        case Err<List<FileEntry>>(:final failure):
          if (folder == root) {
            return _Walk(failure: failure);
          }
          unlisted++;
        case Ok<List<FileEntry>>(:final value):
          for (final entry in value) {
            if (entry.isDirectory) {
              if (depth < maxDepth && !skippedFolders.contains(entry.name)) {
                pending.add((entry.path, depth + 1));
              }
            } else if (!known.contains(entry.path)) {
              if (files.length >= maxEntries) {
                return _Walk(truncated: true, unlisted: unlisted);
              }
              known.add(entry.path);
              files.add(FuzzyTarget(entry.path));
            }
          }
      }
      if (publish && files.length - published >= publishEvery) {
        published = files.length;
        state = FileIndexState(
          status: FileIndexStatus.building,
          files: List.unmodifiable(files),
        );
      }
    }
    return _Walk(unlisted: unlisted);
  }

  static FileIndexState _ready(
    List<FuzzyTarget> files, {
    required bool truncated,
  }) => FileIndexState(
    status: FileIndexStatus.ready,
    files: List.unmodifiable(files),
    truncated: truncated,
  );

  /// Whether [path] is a skipped folder or inside one.
  static bool _inSkippedFolder(String path) =>
      path.isNotEmpty && path.split('/').any(skippedFolders.contains);
}

/// How a walk ended.
final class _Walk {
  const _Walk({this.truncated = false, this.unlisted = 0, this.failure});

  /// It stopped at the limit with files left out.
  final bool truncated;

  /// Folders that could not be listed.
  final int unlisted;

  /// The top folder could not be listed.
  final Failure? failure;
}

final fileIndexProvider = NotifierProvider<FileIndexController, FileIndexState>(
  FileIndexController.new,
);
