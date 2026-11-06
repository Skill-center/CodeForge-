/// The file service on real storage (docs/EDITOR_ARCHITECTURE.md, "Files").
///
/// One workspace folder, app-private in Phase 2. Every path is checked
/// twice: as text (core/files/workspace_path.dart) and again after
/// resolving symbolic links against the canonical root, so nothing outside
/// the workspace is read or written. Writes are atomic: the bytes go to a
/// temporary file beside the target, are flushed to the device, and one
/// rename replaces the target, so an interrupted save leaves the old file
/// as it was.
library;

import 'dart:io';

import '../../core/errors/failure.dart';
import '../../core/files/file_stamp.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_path.dart';
import '../../core/logging/logger.dart';
import '../contracts.dart';
import 'demo_workspace.dart';

/// Runs after a save's temporary file is complete, just before it replaces
/// the target. A test seam: throwing here is a save interrupted at the
/// worst moment.
typedef BeforeCommit = Future<void> Function(String path);

final class LocalFileService implements FileService {
  LocalFileService({
    required Future<String> Function() rootPath,
    Map<String, String> seed = DemoWorkspace.files,
    WorkspaceRef workspace = const WorkspaceRef(
      id: DemoWorkspace.id,
      displayName: DemoWorkspace.displayName,
    ),
    BeforeCommit? beforeCommit,
  }) : _rootPath = rootPath,
       _seed = seed,
       _workspace = workspace,
       _beforeCommit = beforeCommit;

  /// Where the workspace folder is (or will be created).
  final Future<String> Function() _rootPath;
  final Map<String, String> _seed;
  final WorkspaceRef _workspace;
  final BeforeCommit? _beforeCommit;

  String? _root;
  Future<Result<String>>? _opening;

  @override
  Future<Result<WorkspaceRef>> openWorkspace() async {
    return switch (await _canonicalRoot()) {
      Ok<String>() => Ok(_workspace),
      Err<String>(:final failure) => Err(failure),
    };
  }

  @override
  Future<Result<List<FileEntry>>> listDirectory(String path) async {
    final String real;
    switch (await _resolve(path, allowRoot: true)) {
      case Ok<String>(:final value):
        real = value;
      case Err<String>(:final failure):
        return Err(failure);
    }
    final type = FileSystemEntity.typeSync(real);
    if (type == FileSystemEntityType.notFound) {
      return Err(
        FileFailure(
          '${_label(path)} does not exist.',
          problem: FileProblem.notFound,
        ),
      );
    }
    if (type != FileSystemEntityType.directory) {
      return Err(
        FileFailure(
          '${_label(path)} is not a folder.',
          problem: FileProblem.wrongType,
        ),
      );
    }
    try {
      final entries = <FileEntry>[];
      await for (final entity in Directory(real).list(followLinks: false)) {
        final name = pathBaseName(entity.path);
        // Symbolic links stay out of the tree until Phase 3 decides how
        // they appear, and a save's temporary file is never shown.
        if (entity is Link || name.endsWith(reservedTempSuffix)) {
          continue;
        }
        entries.add(
          FileEntry(
            path: pathJoin(path, name),
            name: name,
            isDirectory: entity is Directory,
            hidden: name.startsWith('.'),
          ),
        );
      }
      entries.sort(compareFileEntries);
      return Ok(entries);
    } on FileSystemException catch (error) {
      return Err(
        FileFailure(
          '${_label(path)} could not be listed.',
          problem: FileProblem.io,
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<TextFile>> readText(String path) async {
    final String real;
    switch (await _resolve(path)) {
      case Ok<String>(:final value):
        real = value;
      case Err<String>(:final failure):
        return Err(failure);
    }
    final file = File(real);
    try {
      for (var attempt = 0; ; attempt++) {
        final before = file.statSync();
        if (before.type == FileSystemEntityType.notFound) {
          return Err(
            FileFailure('$path does not exist.', problem: FileProblem.notFound),
          );
        }
        if (before.type != FileSystemEntityType.file) {
          return Err(
            FileFailure('$path is not a file.', problem: FileProblem.wrongType),
          );
        }
        if (before.size > maxTextFileBytes) {
          return Err(
            FileFailure(
              '$path is larger than ${maxTextFileBytes ~/ (1024 * 1024)} MB, '
              'the most the editor opens for now.',
              problem: FileProblem.tooLarge,
            ),
          );
        }
        final bytes = await file.readAsBytes();
        final after = file.statSync();
        final changedMeanwhile =
            after.modified != before.modified || after.size != bytes.length;
        if (changedMeanwhile && attempt < 2) {
          // Something wrote the file while it was being read: read again.
          continue;
        }
        final stamp = FileStamp(modified: after.modified, size: after.size);
        return switch (decodeText(bytes)) {
          Ok<DecodedText>(:final value) => Ok(
            TextFile(
              path: path,
              text: value.text,
              format: value.format,
              stamp: stamp,
              mixedLineEndings: value.mixedLineEndings,
            ),
          ),
          Err<DecodedText>(:final failure) => Err(failure),
        };
      }
    } on FileSystemException catch (error) {
      return Err(
        FileFailure(
          '$path could not be read.',
          problem: FileProblem.io,
          cause: error,
        ),
      );
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
    final String real;
    switch (await _resolve(path)) {
      case Ok<String>(:final value):
        real = value;
      case Err<String>(:final failure):
        return Err(failure);
    }
    final target = File(real);
    final existing = target.statSync();
    final exists = existing.type != FileSystemEntityType.notFound;
    if (exists && existing.type != FileSystemEntityType.file) {
      return Err(
        FileFailure('$path is a folder.', problem: FileProblem.wrongType),
      );
    }
    if (exists && mode == WriteMode.createNew) {
      return Err(
        FileFailure('$path already exists.', problem: FileProblem.exists),
      );
    }
    if (exists &&
        expected != null &&
        FileStamp(modified: existing.modified, size: existing.size) !=
            expected) {
      return Err(
        FileFailure(
          '$path changed on disk after it was opened.',
          problem: FileProblem.changedOnDisk,
        ),
      );
    }
    final bytes = encodeText(text, format);
    final temp = File(
      '${target.parent.path}/.${pathBaseName(real)}$reservedTempSuffix',
    );
    try {
      await target.parent.create(recursive: true);
      final handle = await temp.open(mode: FileMode.writeOnly);
      try {
        await handle.writeFrom(bytes);
        // Durable before it becomes the file: flush reaches the device.
        await handle.flush();
      } finally {
        await handle.close();
      }
      await _beforeCommit?.call(real);
      if (mode == WriteMode.createNew && target.existsSync()) {
        await _discard(temp);
        return Err(
          FileFailure('$path already exists.', problem: FileProblem.exists),
        );
      }
      // One rename: the target is the old file or the new one, never part.
      await temp.rename(real);
      final written = target.statSync();
      appLogger.info(
        'files',
        'written',
        fields: {'path': path, 'bytes': bytes.length},
      );
      return Ok(FileStamp(modified: written.modified, size: written.size));
    } on Object catch (error) {
      await _discard(temp);
      appLogger.error(
        'files',
        'write_failed',
        fields: {'path': path, 'error': '$error'},
      );
      return Err(
        FileFailure(
          '$path could not be saved. The file on disk was not changed.',
          problem: FileProblem.io,
          cause: error,
        ),
      );
    }
  }

  /// The canonical (symlink-free) root, creating and seeding the workspace
  /// on first use. Concurrent callers share one attempt; after a failure
  /// the next call tries again.
  Future<Result<String>> _canonicalRoot() async {
    final known = _root;
    if (known != null) {
      return Ok(known);
    }
    final result = await (_opening ??= _openRoot());
    _opening = null;
    if (result case Ok<String>(:final value)) {
      _root = value;
    }
    return result;
  }

  Future<Result<String>> _openRoot() async {
    try {
      final root = Directory(await _rootPath());
      if (!root.existsSync()) {
        await _createSeeded(root);
      }
      return Ok(await root.resolveSymbolicLinks());
    } on Object catch (error) {
      appLogger.error(
        'files',
        'workspace_open_failed',
        fields: {'error': '$error'},
      );
      return Err(
        FileFailure(
          'The workspace folder could not be opened.',
          problem: FileProblem.io,
          cause: error,
        ),
      );
    }
  }

  /// Writes the seed into a staging folder and renames it into place, so an
  /// interrupted first run never leaves a half-written workspace behind.
  Future<void> _createSeeded(Directory root) async {
    final staging = Directory('${root.path}.seeding');
    if (staging.existsSync()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    for (final MapEntry(:key, :value) in _seed.entries) {
      final file = File('${staging.path}/$key');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        encodeText(value, TextFormat.standard),
        flush: true,
      );
    }
    await staging.rename(root.path);
    appLogger.info(
      'files',
      'workspace_seeded',
      fields: {'files': _seed.length},
    );
  }

  /// The real location of workspace path [path], or why there is none. The
  /// deepest part of the path that exists is resolved through symbolic
  /// links and must stay inside the root; the rest does not exist yet.
  Future<Result<String>> _resolve(String path, {bool allowRoot = false}) async {
    final invalid = workspacePathProblem(path, allowRoot: allowRoot);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    final String root;
    switch (await _canonicalRoot()) {
      case Ok<String>(:final value):
        root = value;
      case Err<String>(:final failure):
        return Err(failure);
    }
    final absolute = path.isEmpty ? root : '$root/$path';
    var existing = absolute;
    while (existing.length > root.length &&
        FileSystemEntity.typeSync(existing, followLinks: false) ==
            FileSystemEntityType.notFound) {
      existing = existing.substring(0, existing.lastIndexOf('/'));
    }
    final String real;
    try {
      real = await File(existing).resolveSymbolicLinks();
    } on FileSystemException catch (error) {
      return Err(
        FileFailure(
          '${_label(path)} could not be reached.',
          problem: FileProblem.io,
          cause: error,
        ),
      );
    }
    if (real != root && !real.startsWith('$root/')) {
      appLogger.warn('files', 'path_outside_workspace', fields: {'path': path});
      return Err(
        FileFailure(
          '${_label(path)} leads outside the workspace.',
          problem: FileProblem.outsideWorkspace,
        ),
      );
    }
    return Ok(real + absolute.substring(existing.length));
  }

  Future<void> _discard(File temp) async {
    try {
      if (temp.existsSync()) {
        await temp.delete();
      }
    } on FileSystemException catch (error) {
      appLogger.warn(
        'files',
        'temp_cleanup_failed',
        fields: {'error': '$error'},
      );
    }
  }

  static String _label(String path) =>
      path.isEmpty ? 'The workspace folder' : path;
}
