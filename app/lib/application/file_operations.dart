/// The explorer's operations on files and folders (Phase 3 W4,
/// docs/EDITOR_ARCHITECTURE.md, "Files"): each one changes the workspace
/// through the file service, then brings the open documents, the
/// explorer's view and its listings up to date.
///
/// Open documents follow every change (DocumentController.pathMoved and
/// pathDeleted), and so does Go to File's index (FileIndexController). A rename or a move keeps their tabs, unsaved text and
/// undo history, and moves their journal rows in one transaction. A delete
/// closes the tabs of clean documents and keeps those with unsaved
/// changes, marked deleted on disk. Nothing is ever replaced: a taken name
/// fails with [FileProblem.exists], and the explorer asks for another
/// (features/workbench/explorer_actions.dart, which also asks before a
/// delete). These do what they are told.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/files/workspace_path.dart';
import '../services/contracts.dart';
import 'documents/document_controller.dart';
import 'explorer_view_controller.dart';
import 'file_index.dart';
import 'providers.dart';
import 'workspace_controller.dart';

/// How many files a folder holds, as far as counting went.
final class FileCount {
  const FileCount({required this.files, required this.complete});

  final int files;

  /// False when counting stopped at [FileOperations.countLimit]: there may
  /// be more.
  final bool complete;
}

final class FileOperations {
  FileOperations(this._ref);

  /// Counting a folder's files stops here.
  static const int countLimit = 10000;

  /// How often Duplicate tries another name when the one it chose was
  /// taken meanwhile.
  static const int duplicateAttempts = 3;

  final Ref _ref;

  FileService get _files => _ref.read(fileServiceProvider);

  DocumentController get _documents =>
      _ref.read(documentControllerProvider.notifier);

  WorkspaceController get _workspace =>
      _ref.read(workspaceControllerProvider.notifier);

  ExplorerViewController get _view => _ref.read(explorerViewProvider.notifier);

  FileIndexController get _index => _ref.read(fileIndexProvider.notifier);

  /// Creates an empty file at [path], opens it and shows its row.
  Future<Result<void>> createFile(String path) async {
    final result = await _documents.createFile(path);
    if (result.isOk) {
      _view.reveal(path);
    }
    return result;
  }

  /// Creates the folder [path], and any missing folders above it, and
  /// shows its row.
  Future<Result<void>> createFolder(String path) async {
    final result = await _files.createFolder(path);
    if (result.isOk) {
      _view.reveal(path);
      await _workspace.changed();
    }
    return result;
  }

  /// Gives [path] the name [newName] in its folder; returns the new path.
  Future<Result<String>> rename(String path, String newName) {
    final newPath = pathJoin(pathParent(path), newName);
    return _relocate(path, newPath, () => _files.rename(path, newName));
  }

  /// Moves [path] into [folder], keeping its name; returns the new path.
  Future<Result<String>> move(String path, String folder) {
    final newPath = pathJoin(folder, pathBaseName(path));
    return _relocate(path, newPath, () => _files.move(path, folder));
  }

  Future<Result<String>> _relocate(
    String path,
    String newPath,
    Future<Result<String>> Function() change,
  ) async {
    if (newPath == path) {
      return Ok(path);
    }
    final occupant = _documents.occupant(newPath, from: path);
    if (occupant != null) {
      return Err(occupant);
    }
    // A save still running would write the old path again.
    await _documents.settle(path);
    final result = await change();
    if (result case Ok<String>(:final value) when value != path) {
      _documents.pathMoved(path, value);
      _view.pathMoved(path, value);
      _index.moved(path, value);
      await _workspace.changed(removed: path);
    }
    return result;
  }

  /// Copies [path] beside itself under a free name (`app copy.js`, then
  /// `app copy 2.js`); returns the copy's path.
  Future<Result<String>> duplicate(
    String path, {
    required bool isFolder,
  }) async {
    final folder = pathParent(path);
    final taken = <String>{};
    switch (await _files.listDirectory(folder)) {
      case Ok<List<FileEntry>>(:final value):
        taken.addAll([for (final entry in value) entry.name]);
      case Err<List<FileEntry>>(:final failure):
        return Err(failure);
    }
    for (var attempt = 0; attempt < duplicateAttempts; attempt++) {
      final name = copyName(pathBaseName(path), taken, isFolder: isFolder);
      final newPath = pathJoin(folder, name);
      switch (await _files.copy(path, newPath)) {
        case Ok<void>():
          if (isFolder) {
            _index.addedTree(newPath);
          } else {
            _index.added(newPath);
          }
          await _workspace.changed();
          return Ok(newPath);
        case Err<void>(failure: FileFailure(problem: FileProblem.exists)):
          // Taken since the folder was listed: the next name.
          taken.add(name);
        case Err<void>(:final failure):
          return Err(failure);
      }
    }
    return Err(
      FileFailure(
        'No free name was found for a copy of $path.',
        problem: FileProblem.exists,
      ),
    );
  }

  /// Deletes [path]: a file, or a folder with everything in it.
  Future<Result<void>> delete(String path) async {
    await _documents.settle(path);
    final result = await _files.delete(path);
    if (result.isOk) {
      _documents.pathDeleted(path);
      _view.pathRemoved(path);
      _index.removed(path);
      await _workspace.changed(removed: path);
    }
    return result;
  }

  /// How many files [folder] holds at any depth, counting up to
  /// [countLimit]: a delete says how many it takes.
  Future<Result<FileCount>> countFiles(String folder) async {
    var files = 0;
    final pending = [folder];
    while (pending.isNotEmpty) {
      switch (await _files.listDirectory(pending.removeLast())) {
        case Err<List<FileEntry>>(:final failure):
          return Err(failure);
        case Ok<List<FileEntry>>(:final value):
          for (final entry in value) {
            if (entry.isDirectory) {
              pending.add(entry.path);
              continue;
            }
            files += 1;
            if (files >= countLimit) {
              return Ok(FileCount(files: files, complete: false));
            }
          }
      }
    }
    return Ok(FileCount(files: files, complete: true));
  }
}

final fileOperationsProvider = Provider<FileOperations>(FileOperations.new);
