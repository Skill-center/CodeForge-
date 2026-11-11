/// Projects in memory for widget and controller tests (Phase 3 W3): the
/// same contract as the device's project folders
/// (lib/services/files/project_storage.dart), which
/// test/services/project_storage_test.dart covers on a real folder. Each
/// project's files are a [MemoryFileService].
library;

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/file_stamp.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/files/workspace_path.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/files/project_storage.dart';

import 'memory_file_service.dart';

final class MemoryProjectStorage implements ProjectStorage {
  /// The project folders, by name.
  final Map<String, MemoryFileService> projects = {};

  /// Every call, by name, in order.
  final List<String> calls = [];

  /// Fails the next create, rename or delete with this.
  FileFailure? failNext;

  /// Adds a project folder holding [files].
  MemoryFileService add(String folder, {Map<String, String> files = const {}}) {
    return projects[folder] = MemoryFileService(seed: files);
  }

  Err<T>? _failure<T>() {
    final failure = failNext;
    failNext = null;
    return failure == null ? null : Err(failure);
  }

  bool _taken(String name, {String? except}) => projects.keys.any(
    (folder) => folder != except && folder.toLowerCase() == name.toLowerCase(),
  );

  @override
  Future<Result<List<String>>> folders() async {
    calls.add('folders');
    return Ok(projects.keys.toList());
  }

  @override
  Future<Result<bool>> exists(String folder) async {
    calls.add('exists');
    return Ok(projects.containsKey(folder));
  }

  @override
  Future<Result<void>> create(
    String folder, {
    Map<String, String> seed = const {},
  }) async {
    calls.add('create');
    final failure = _failure<void>();
    if (failure != null) {
      return failure;
    }
    final invalid = nameProblem(folder);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    if (_taken(folder)) {
      return Err(
        FileFailure(
          'A project named "$folder" already exists.',
          problem: FileProblem.exists,
        ),
      );
    }
    add(folder, files: seed);
    return const Ok(null);
  }

  @override
  Future<Result<void>> rename(String from, String to) async {
    calls.add('rename');
    final failure = _failure<void>();
    if (failure != null) {
      return failure;
    }
    final files = projects[from];
    if (files == null) {
      return Err(
        FileFailure(
          'The project "$from" is missing: its folder is gone.',
          problem: FileProblem.folderMissing,
        ),
      );
    }
    if (from == to) {
      return const Ok(null);
    }
    if (_taken(to, except: from)) {
      return Err(
        FileFailure(
          'A project named "$to" already exists.',
          problem: FileProblem.exists,
        ),
      );
    }
    projects
      ..remove(from)
      ..[to] = files;
    return const Ok(null);
  }

  @override
  Future<Result<void>> delete(String folder) async {
    calls.add('delete');
    final failure = _failure<void>();
    if (failure != null) {
      return failure;
    }
    projects.remove(folder);
    return const Ok(null);
  }

  @override
  Future<Result<int>> countFiles(String folder, {int limit = 100000}) async {
    calls.add('countFiles');
    final files = projects[folder];
    final count = files?.paths.length ?? 0;
    return Ok(count > limit ? limit : count);
  }

  @override
  FileService files(ProjectLocation project) => _ProjectFiles(this, project);
}

/// One project's files: its folder's [MemoryFileService], found by the
/// project's folder name each time, so a deleted folder is missing.
final class _ProjectFiles implements FileService {
  _ProjectFiles(this._storage, this._project);

  final MemoryProjectStorage _storage;
  final ProjectLocation _project;

  Result<MemoryFileService> _folder() {
    var files = _storage.projects[_project.folder];
    if (files == null && _project.isDemo) {
      files = _storage.add(_project.folder, files: DemoWorkspace.files);
    }
    return files == null
        ? Err(
            FileFailure(
              'The project "${_project.name}" is missing: its folder is gone.',
              problem: FileProblem.folderMissing,
            ),
          )
        : Ok(files);
  }

  @override
  Future<Result<WorkspaceRef>> openWorkspace() async {
    switch (_folder()) {
      case Ok<MemoryFileService>():
        return Ok(WorkspaceRef(id: _project.id, displayName: _project.name));
      case Err<MemoryFileService>(:final failure):
        return Err(failure);
    }
  }

  @override
  Future<Result<List<FileEntry>>> listDirectory(String path) async {
    switch (_folder()) {
      case Ok<MemoryFileService>(:final value):
        return value.listDirectory(path);
      case Err<MemoryFileService>(:final failure):
        return Err(failure);
    }
  }

  @override
  Future<Result<TextFile>> readText(String path) async {
    switch (_folder()) {
      case Ok<MemoryFileService>(:final value):
        return value.readText(path);
      case Err<MemoryFileService>(:final failure):
        return Err(failure);
    }
  }

  @override
  Future<Result<FileStamp>> writeText(
    String path,
    String text, {
    TextFormat format = TextFormat.standard,
    WriteMode mode = WriteMode.replace,
    FileStamp? expected,
  }) async {
    switch (_folder()) {
      case Ok<MemoryFileService>(:final value):
        return value.writeText(
          path,
          text,
          format: format,
          mode: mode,
          expected: expected,
        );
      case Err<MemoryFileService>(:final failure):
        return Err(failure);
    }
  }

  /// [body] over the project's folder, or why it is missing.
  Future<Result<T>> _within<T>(
    Future<Result<T>> Function(MemoryFileService files) body,
  ) async {
    switch (_folder()) {
      case Ok<MemoryFileService>(:final value):
        return body(value);
      case Err<MemoryFileService>(:final failure):
        return Err(failure);
    }
  }

  @override
  Future<Result<void>> createFolder(String path) =>
      _within((files) => files.createFolder(path));

  @override
  Future<Result<String>> rename(String path, String newName) =>
      _within((files) => files.rename(path, newName));

  @override
  Future<Result<String>> move(String path, String folder) =>
      _within((files) => files.move(path, folder));

  @override
  Future<Result<void>> copy(String path, String newPath) =>
      _within((files) => files.copy(path, newPath));

  @override
  Future<Result<void>> delete(String path) =>
      _within((files) => files.delete(path));
}
