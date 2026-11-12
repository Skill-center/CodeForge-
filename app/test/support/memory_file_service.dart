/// An in-memory FileService for widget and controller tests. dart:io never
/// completes inside testWidgets' fake async zone, so those tests cannot use
/// the real service (test/services/local_file_service_test.dart covers it
/// on a real folder). This one stores bytes and runs the same codec and
/// path rules, so byte-order marks, CRLF files and refusals behave as they
/// do on disk. Since Phase 3 W4 it holds empty folders too, and does the
/// explorer's operations under the same rules as a project: nothing is
/// replaced, and a folder never goes into itself. Since W5 its folders can
/// be watched: changes made the way another program would (putText,
/// remove, …) notify their folder, and writes through the service do too
/// when [MemoryFileService.notifyOwnWrites] says so, as real storage does.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/file_stamp.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:codeforge/core/files/workspace_path.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/files/demo_workspace.dart';

final class MemoryFileService implements FileService {
  MemoryFileService({
    Map<String, String> seed = DemoWorkspace.files,
    this.workspace = const WorkspaceRef(
      id: DemoWorkspace.id,
      displayName: DemoWorkspace.displayName,
    ),
  }) {
    for (final MapEntry(:key, :value) in seed.entries) {
      putText(key, value);
    }
  }

  /// What [openWorkspace] answers: the demo project unless a test says.
  final WorkspaceRef workspace;

  /// Folders, empty ones included; others are implied by their files.
  final Set<String> _folders = {};

  /// What listings say an item allows, where a test says otherwise than
  /// [FileCapabilities.all].
  final Map<String, FileCapabilities> capabilities = {};

  /// Fails the next explorer operation with this.
  Failure? failNextChange;

  /// [openWorkspace] fails with this, as a project whose folder is gone.
  Failure? failOpen;

  /// Listing these folders fails with their failure, as a folder the app
  /// may not read would.
  final Map<String, Failure> failListings = {};

  final Map<String, Uint8List> _files = {};
  final Map<String, FileStamp> _stamps = {};
  int _clock = 0;

  /// Paths written through the service, in order.
  final List<String> writes = [];

  /// Fails the next write with this, as a full disk would.
  Failure? failNextWrite;

  @override
  Future<Result<WorkspaceRef>> openWorkspace() async {
    final failure = failOpen;
    return failure == null ? Ok(workspace) : Err(failure);
  }

  /// Every folder listed through the service, in order (Phase 3 W5).
  final List<String> listed = [];

  @override
  Future<Result<List<FileEntry>>> listDirectory(String path) async {
    listed.add(path);
    if (failListings[path] case final failure?) {
      return Err(failure);
    }
    final invalid = workspacePathProblem(path, allowRoot: true);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    if (_files.containsKey(path)) {
      return Err(
        FileFailure('$path is not a folder.', problem: FileProblem.wrongType),
      );
    }
    if (!isFolder(path)) {
      return Err(
        FileFailure('$path does not exist.', problem: FileProblem.notFound),
      );
    }
    final prefix = path.isEmpty ? '' : '$path/';
    final seen = <String, FileEntry>{};
    for (final itemPath in [..._files.keys, ..._folders]) {
      if (!itemPath.startsWith(prefix)) {
        continue;
      }
      final rest = itemPath.substring(prefix.length);
      final slash = rest.indexOf('/');
      final name = slash < 0 ? rest : rest.substring(0, slash);
      final isDirectory = slash >= 0 || _folders.contains(itemPath);
      final entryPath = '$prefix$name';
      seen[name] = FileEntry(
        path: entryPath,
        name: name,
        isDirectory: isDirectory,
        hidden: name.startsWith('.'),
        sizeBytes: isDirectory ? null : _files[itemPath]?.length,
        capabilities: capabilities[entryPath] ?? FileCapabilities.all,
      );
    }
    return Ok(seen.values.toList()..sort(compareFileEntries));
  }

  @override
  Future<Result<TextFile>> readText(String path) async {
    final invalid = workspacePathProblem(path);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    final bytes = _files[path];
    if (bytes == null) {
      return Err(
        FileFailure('$path does not exist.', problem: FileProblem.notFound),
      );
    }
    return switch (decodeText(bytes)) {
      Ok<DecodedText>(:final value) => Ok(
        TextFile(
          path: path,
          text: value.text,
          format: value.format,
          stamp: _stamps[path]!,
          mixedLineEndings: value.mixedLineEndings,
        ),
      ),
      Err<DecodedText>(:final failure) => Err(failure),
    };
  }

  @override
  Future<Result<FileStamp>> writeText(
    String path,
    String text, {
    TextFormat format = TextFormat.standard,
    WriteMode mode = WriteMode.replace,
    FileStamp? expected,
  }) async {
    final invalid = workspacePathProblem(path);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    if (isFolder(path)) {
      return Err(
        FileFailure('$path is a folder.', problem: FileProblem.wrongType),
      );
    }
    final exists = _files.containsKey(path);
    if (exists && mode == WriteMode.createNew) {
      return Err(
        FileFailure('$path already exists.', problem: FileProblem.exists),
      );
    }
    if (exists && expected != null && _stamps[path] != expected) {
      return Err(
        FileFailure(
          '$path changed on disk after it was opened.',
          problem: FileProblem.changedOnDisk,
        ),
      );
    }
    final failure = failNextWrite;
    if (failure != null) {
      failNextWrite = null;
      return Err(failure);
    }
    writes.add(path);
    final created = _topmostNew(path);
    final stamp = _put(path, encodeText(text, format));
    if (notifyOwnWrites) {
      _notify(pathParent(path));
      if (created != null) {
        _notify(pathParent(created));
      }
    }
    return Ok(stamp);
  }

  @override
  Future<Result<FileStamp>> stat(String path) async {
    final invalid = workspacePathProblem(path);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    stats.add(path);
    final stamp = _stamps[path];
    if (stamp != null) {
      return Ok(stamp);
    }
    if (isFolder(path)) {
      return Err(
        FileFailure('$path is not a file.', problem: FileProblem.wrongType),
      );
    }
    return Err(
      FileFailure('$path does not exist.', problem: FileProblem.notFound),
    );
  }

  @override
  Stream<void> watchFolder(String path) {
    final failure = failWatch;
    if (failure != null) {
      return Stream<void>.error(failure);
    }
    late final StreamController<void> controller;
    controller = StreamController<void>(
      onListen: () => _watchers.putIfAbsent(path, () => []).add(controller),
      onCancel: () {
        _watchers[path]?.remove(controller);
        if (_watchers[path]?.isEmpty ?? false) {
          _watchers.remove(path);
        }
        unawaited(controller.close());
      },
    );
    return controller.stream;
  }

  /// Whether writes through this service notify the folders they change,
  /// as on real storage (Phase 3 W5). Off unless a test says: the app's own
  /// saves then cause no notices at all.
  bool notifyOwnWrites = false;

  /// Watching any folder fails with this, as storage that can't watch.
  Failure? failWatch;

  /// The folders watched now, by path, with their listeners.
  final Map<String, List<StreamController<void>>> _watchers = {};

  /// The folders being watched now.
  Set<String> get watched => {..._watchers.keys};

  /// Every path [stat] was asked about, in order.
  final List<String> stats = [];

  /// Tells whoever watches [folder] that it changed.
  void _notify(String folder) {
    for (final controller in [...?_watchers[folder]]) {
      controller.add(null);
    }
  }

  /// The topmost folder above [path] that does not exist yet, or null: a
  /// write there creates it, which its own folder sees.
  String? _topmostNew(String path) {
    String? topmost;
    for (var folder = pathParent(path); folder.isNotEmpty;) {
      if (isFolder(folder)) {
        break;
      }
      topmost = folder;
      folder = pathParent(folder);
    }
    return topmost;
  }

  @override
  Future<Result<void>> createFolder(String path) async {
    final invalid = workspacePathProblem(path);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    if (exists(path)) {
      return Err(
        FileFailure('$path already exists.', problem: FileProblem.exists),
      );
    }
    for (var parent = pathParent(path); parent.isNotEmpty;) {
      if (_files.containsKey(parent)) {
        return Err(
          FileFailure(
            '$parent is a file, not a folder.',
            problem: FileProblem.wrongType,
          ),
        );
      }
      parent = pathParent(parent);
    }
    final failure = _takeFailure();
    if (failure != null) {
      return Err(failure);
    }
    _folders.add(path);
    return const Ok(null);
  }

  @override
  Future<Result<String>> rename(String path, String newName) async {
    final invalid = workspacePathProblem(path) ?? nameProblem(newName);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    final newPath = pathJoin(pathParent(path), newName);
    if (newPath == path) {
      return Ok(path);
    }
    return _relocate(path, newPath);
  }

  @override
  Future<Result<String>> move(String path, String folder) async {
    final invalid =
        workspacePathProblem(path) ??
        workspacePathProblem(folder, allowRoot: true);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    if (folder == path || folder.startsWith('$path/')) {
      return Err(
        FileFailure(
          '$path cannot be moved into itself.',
          problem: FileProblem.invalidPath,
        ),
      );
    }
    if (!isFolder(folder)) {
      return Err(
        FileFailure('$folder is not a folder.', problem: FileProblem.notFound),
      );
    }
    final newPath = pathJoin(folder, pathBaseName(path));
    if (newPath == path) {
      return Ok(path);
    }
    return _relocate(path, newPath);
  }

  Future<Result<String>> _relocate(String from, String to) async {
    if (!exists(from)) {
      return Err(
        FileFailure('$from does not exist.', problem: FileProblem.notFound),
      );
    }
    if (exists(to)) {
      return Err(
        FileFailure('$to already exists.', problem: FileProblem.exists),
      );
    }
    final failure = _takeFailure();
    if (failure != null) {
      return Err(failure);
    }
    String moved(String path) => '$to${path.substring(from.length)}';
    bool within(String path) => path == from || path.startsWith('$from/');
    for (final path in [..._files.keys]) {
      if (within(path)) {
        _files[moved(path)] = _files.remove(path)!;
        _stamps[moved(path)] = _stamps.remove(path)!;
      }
    }
    for (final path in [..._folders]) {
      if (within(path)) {
        _folders
          ..remove(path)
          ..add(moved(path));
      }
    }
    return Ok(to);
  }

  @override
  Future<Result<void>> copy(String path, String newPath) async {
    final invalid = workspacePathProblem(path) ?? workspacePathProblem(newPath);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    if (newPath == path || newPath.startsWith('$path/')) {
      return Err(
        FileFailure(
          '$path cannot be copied into itself.',
          problem: FileProblem.invalidPath,
        ),
      );
    }
    if (!exists(path)) {
      return Err(
        FileFailure('$path does not exist.', problem: FileProblem.notFound),
      );
    }
    if (exists(newPath)) {
      return Err(
        FileFailure('$newPath already exists.', problem: FileProblem.exists),
      );
    }
    final failure = _takeFailure();
    if (failure != null) {
      return Err(failure);
    }
    String copied(String item) => '$newPath${item.substring(path.length)}';
    bool within(String item) => item == path || item.startsWith('$path/');
    for (final item in [..._files.keys]) {
      if (within(item)) {
        _put(copied(item), Uint8List.fromList(_files[item]!));
      }
    }
    for (final item in [..._folders]) {
      if (within(item)) {
        _folders.add(copied(item));
      }
    }
    if (isFolder(path)) {
      _folders.add(newPath);
    }
    return const Ok(null);
  }

  @override
  Future<Result<void>> delete(String path) async {
    final invalid = workspacePathProblem(path);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    if (!exists(path)) {
      return Err(
        FileFailure('$path does not exist.', problem: FileProblem.notFound),
      );
    }
    final failure = _takeFailure();
    if (failure != null) {
      return Err(failure);
    }
    bool within(String item) => item == path || item.startsWith('$path/');
    for (final item in [..._files.keys]) {
      if (within(item)) {
        remove(item);
      }
    }
    _folders.removeWhere(within);
    // The folder that held it stays, even when it is empty now.
    final parent = pathParent(path);
    if (parent.isNotEmpty) {
      _folders.add(parent);
    }
    return const Ok(null);
  }

  Failure? _takeFailure() {
    final failure = failNextChange;
    failNextChange = null;
    return failure;
  }

  // ------------------------------------------------------------ test controls

  /// The bytes at [path], as they would be on disk.
  Uint8List? bytesOf(String path) => _files[path];

  /// The decoded text at [path]; null when absent or not text.
  String? textOf(String path) {
    final bytes = _files[path];
    return bytes == null ? null : decodeText(bytes).valueOrNull?.text;
  }

  /// A file or a folder at [path].
  bool exists(String path) => _files.containsKey(path) || isFolder(path);

  /// A folder at [path]: the root, an empty folder, or one holding files.
  bool isFolder(String path) =>
      path.isEmpty ||
      _folders.contains(path) ||
      _files.keys.any((p) => p.startsWith('$path/')) ||
      _folders.any((p) => p.startsWith('$path/'));

  /// Adds an empty folder the way another program would.
  void putFolder(String path) {
    final created = _topmostNew(path);
    _folders.add(path);
    _notify(pathParent(created ?? path));
  }

  /// Every file's path.
  Iterable<String> get paths => _files.keys;

  /// Writes [text] the way another program would: a new stamp, no checks.
  /// Since Phase 3 W5 the file's folder hears of it, and so does the folder
  /// of any folder the write creates.
  void putText(
    String path,
    String text, {
    TextFormat format = TextFormat.standard,
  }) {
    putBytes(path, encodeText(text, format));
  }

  /// Deletes the file [path] the way another program would; its folder
  /// hears of it.
  void remove(String path) {
    _files.remove(path);
    _stamps.remove(path);
    _notify(pathParent(path));
  }

  /// Writes raw [bytes] the way another program would.
  void putBytes(String path, List<int> bytes) {
    final created = _topmostNew(path);
    _put(path, Uint8List.fromList(bytes));
    _notify(pathParent(path));
    if (created != null) {
      _notify(pathParent(created));
    }
  }

  FileStamp _put(String path, Uint8List bytes) {
    _clock += 1;
    final stamp = FileStamp(
      modified: DateTime.fromMillisecondsSinceEpoch(_clock * 1000),
      size: bytes.length,
    );
    _files[path] = bytes;
    _stamps[path] = stamp;
    return stamp;
  }
}
