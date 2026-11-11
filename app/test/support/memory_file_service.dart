/// An in-memory FileService for widget and controller tests. dart:io never
/// completes inside testWidgets' fake async zone, so those tests cannot use
/// the real service (test/services/local_file_service_test.dart covers it
/// on a real folder). This one stores bytes and runs the same codec and
/// path rules, so byte-order marks, CRLF files and refusals behave as they
/// do on disk.
library;

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

  /// [openWorkspace] fails with this, as a project whose folder is gone.
  Failure? failOpen;

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

  @override
  Future<Result<List<FileEntry>>> listDirectory(String path) async {
    final invalid = workspacePathProblem(path, allowRoot: true);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    final prefix = path.isEmpty ? '' : '$path/';
    final seen = <String, FileEntry>{};
    for (final filePath in _files.keys) {
      if (!filePath.startsWith(prefix)) {
        continue;
      }
      final rest = filePath.substring(prefix.length);
      final slash = rest.indexOf('/');
      final name = slash < 0 ? rest : rest.substring(0, slash);
      seen[name] = FileEntry(
        path: '$prefix$name',
        name: name,
        isDirectory: slash >= 0,
        hidden: name.startsWith('.'),
        sizeBytes: slash < 0 ? _files[filePath]!.length : null,
      );
    }
    if (path.isNotEmpty && seen.isEmpty) {
      return Err(
        FileFailure('$path does not exist.', problem: FileProblem.notFound),
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
    if (_files.keys.any((p) => p.startsWith('$path/'))) {
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
    return Ok(_put(path, encodeText(text, format)));
  }

  // ------------------------------------------------------------ test controls

  /// The bytes at [path], as they would be on disk.
  Uint8List? bytesOf(String path) => _files[path];

  /// The decoded text at [path]; null when absent or not text.
  String? textOf(String path) {
    final bytes = _files[path];
    return bytes == null ? null : decodeText(bytes).valueOrNull?.text;
  }

  bool exists(String path) => _files.containsKey(path);

  /// Every file's path.
  Iterable<String> get paths => _files.keys;

  /// Writes [text] the way another program would: a new stamp, no checks.
  void putText(
    String path,
    String text, {
    TextFormat format = TextFormat.standard,
  }) {
    _put(path, encodeText(text, format));
  }

  /// Deletes [path] the way another program would.
  void remove(String path) {
    _files.remove(path);
    _stamps.remove(path);
  }

  /// Writes raw [bytes] the way another program would.
  void putBytes(String path, List<int> bytes) {
    _put(path, Uint8List.fromList(bytes));
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
