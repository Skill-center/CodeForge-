/// The file service on real storage (docs/EDITOR_ARCHITECTURE.md, "Files").
///
/// One workspace folder, app-private in Phase 2. Every path is checked
/// twice: as text (core/files/workspace_path.dart) and again after
/// resolving symbolic links against the canonical root, so nothing outside
/// the workspace is read or written. Writes are atomic: the bytes go to a
/// temporary file beside the target, are flushed to the device, and one
/// rename replaces the target, so an interrupted save leaves the old file
/// as it was.
///
/// The explorer's operations (Phase 3 W4) never replace anything: a taken
/// name is refused just before the change. Between that check and the
/// change another writer could take the name, but a project lives in the
/// app's private storage, which nothing else writes until the runtime
/// arrives (Phase 4). A copy keeps each file's permission bits, stops at
/// [LocalFileService.maxCopyItems] items or [LocalFileService.maxCopyDepth]
/// levels, as the storage broker's do, and leaves no partial copy behind.
library;

import 'dart:io';

import '../../core/editor/large_files.dart';
import '../../core/errors/failure.dart';
import '../../core/files/file_stamp.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_path.dart';
import '../../core/logging/logger.dart';
import '../contracts.dart';
import 'demo_workspace.dart';
import 'file_mode.dart';

/// Runs after a save's temporary file is complete, just before it replaces
/// the target. A test seam: throwing here is a save interrupted at the
/// worst moment.
typedef BeforeCommit = Future<void> Function(String path);

final class LocalFileService implements FileService {
  /// The most items a copy takes, and the deepest it goes: the storage
  /// broker's limits for folders from shared storage (StorageBroker.kt).
  static const int maxCopyItems = 10000;
  static const int maxCopyDepth = 64;

  LocalFileService({
    required Future<String> Function() rootPath,
    Map<String, String> seed = DemoWorkspace.files,
    WorkspaceRef workspace = const WorkspaceRef(
      id: DemoWorkspace.id,
      displayName: DemoWorkspace.displayName,
    ),
    BeforeCommit? beforeCommit,
    bool createIfMissing = true,
  }) : _rootPath = rootPath,
       _seed = seed,
       _workspace = workspace,
       _beforeCommit = beforeCommit,
       _createIfMissing = createIfMissing;

  /// Where the workspace folder is (or will be created).
  final Future<String> Function() _rootPath;
  final Map<String, String> _seed;
  final WorkspaceRef _workspace;
  final BeforeCommit? _beforeCommit;

  /// Whether a missing workspace folder is created with [_seed] (the demo
  /// project) or reported missing (every other project, Phase 3 W3).
  final bool _createIfMissing;

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
              '$path is ${formatMegabytes(before.size)}: the editor opens '
              'files up to ${formatMegabytes(maxTextFileBytes)}.',
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
      if (exists) {
        _keepMode(temp.path, existing.mode, path);
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

  @override
  Future<Result<void>> createFolder(String path) async {
    final String real;
    switch (await _resolveEntry(path)) {
      case Ok<String>(:final value):
        real = value;
      case Err<String>(:final failure):
        return Err(failure);
    }
    if (_typeOf(real) != FileSystemEntityType.notFound) {
      return Err(
        FileFailure('$path already exists.', problem: FileProblem.exists),
      );
    }
    final blocked = await _fileInTheWay(pathParent(path));
    if (blocked != null) {
      return Err(blocked);
    }
    try {
      await Directory(real).create(recursive: true);
      appLogger.info('files', 'folder_created', fields: {'path': path});
      return const Ok(null);
    } on FileSystemException catch (error) {
      return Err(
        FileFailure(
          '$path could not be created.',
          problem: FileProblem.io,
          cause: error,
        ),
      );
    }
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
    return _relocate(path, newPath, 'renamed');
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
    final newPath = pathJoin(folder, pathBaseName(path));
    if (newPath == path) {
      return Ok(path);
    }
    return _relocate(path, newPath, 'moved');
  }

  /// Renames [path] to [newPath]: one rename(2), so the file or folder is
  /// at one place or the other, never both or neither.
  Future<Result<String>> _relocate(
    String path,
    String newPath,
    String done,
  ) async {
    final String from;
    final String to;
    switch ((await _resolveEntry(path), await _resolveEntry(newPath))) {
      case (Ok<String>(value: final a), Ok<String>(value: final b)):
        from = a;
        to = b;
      case (Err<String>(:final failure), _):
      case (_, Err<String>(:final failure)):
        return Err(failure);
    }
    final type = _typeOf(from);
    if (type == FileSystemEntityType.notFound) {
      return Err(
        FileFailure('$path does not exist.', problem: FileProblem.notFound),
      );
    }
    if (_typeOf(to) != FileSystemEntityType.notFound && !_same(from, to)) {
      return Err(
        FileFailure('$newPath already exists.', problem: FileProblem.exists),
      );
    }
    final missing = await _missingFolder(pathParent(newPath));
    if (missing != null) {
      return Err(missing);
    }
    try {
      if (type == FileSystemEntityType.directory) {
        await Directory(from).rename(to);
      } else if (type == FileSystemEntityType.link) {
        await Link(from).rename(to);
      } else {
        await File(from).rename(to);
      }
    } on FileSystemException catch (error) {
      return Err(
        FileFailure(
          '$path could not be $done.',
          problem: FileProblem.io,
          cause: error,
        ),
      );
    }
    appLogger.info('files', done, fields: {'from': path, 'to': newPath});
    return Ok(newPath);
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
    final String from;
    final String to;
    switch ((await _resolveEntry(path), await _resolveEntry(newPath))) {
      case (Ok<String>(value: final a), Ok<String>(value: final b)):
        from = a;
        to = b;
      case (Err<String>(:final failure), _):
      case (_, Err<String>(:final failure)):
        return Err(failure);
    }
    final type = _typeOf(from);
    if (type == FileSystemEntityType.notFound) {
      return Err(
        FileFailure('$path does not exist.', problem: FileProblem.notFound),
      );
    }
    if (type == FileSystemEntityType.link) {
      return Err(
        FileFailure(
          '$path is a symbolic link, which the explorer does not copy.',
          problem: FileProblem.unsupported,
        ),
      );
    }
    if (_typeOf(to) != FileSystemEntityType.notFound) {
      return Err(
        FileFailure('$newPath already exists.', problem: FileProblem.exists),
      );
    }
    final missing = await _missingFolder(pathParent(newPath));
    if (missing != null) {
      return Err(missing);
    }
    final List<(String, bool)> items;
    if (type == FileSystemEntityType.directory) {
      final planned = await _copyPlan(from);
      if (planned == null) {
        return Err(
          FileFailure(
            '$path holds more than $maxCopyItems items, or folders more '
            'than $maxCopyDepth deep: too many to copy at once.',
            problem: FileProblem.tooLarge,
          ),
        );
      }
      items = planned;
    } else {
      items = const [('', false)];
    }
    try {
      for (final (relative, isDirectory) in items) {
        final source = relative.isEmpty ? from : '$from/$relative';
        final target = relative.isEmpty ? to : '$to/$relative';
        if (isDirectory) {
          await Directory(target).create();
        } else {
          final mode = File(source).statSync().mode;
          await File(source).copy(target);
          _keepMode(target, mode, newPath);
        }
      }
    } on Object catch (error) {
      await _removePartial(to);
      appLogger.error(
        'files',
        'copy_failed',
        fields: {'path': path, 'error': '$error'},
      );
      return Err(
        FileFailure(
          '$path could not be copied, and no partial copy was left.',
          problem: FileProblem.io,
          cause: error,
        ),
      );
    }
    appLogger.info(
      'files',
      'copied',
      fields: {'from': path, 'to': newPath, 'items': items.length},
    );
    return const Ok(null);
  }

  /// What copying the folder [root] creates, parents first: '' (the folder
  /// itself) and each item's path below it, and whether it is a folder.
  /// Symbolic links stay behind, as listings hide them, and so do a save's
  /// temporary files. Null past [maxCopyItems] or [maxCopyDepth].
  Future<List<(String, bool)>?> _copyPlan(String root) async {
    final items = <(String, bool)>[('', true)];
    final pending = <(String, int)>[('', 0)];
    while (pending.isNotEmpty) {
      final (folder, depth) = pending.removeLast();
      final real = folder.isEmpty ? root : '$root/$folder';
      await for (final entity in Directory(real).list(followLinks: false)) {
        final name = pathBaseName(entity.path);
        if (entity is Link || name.endsWith(reservedTempSuffix)) {
          continue;
        }
        final relative = folder.isEmpty ? name : '$folder/$name';
        final isDirectory = entity is Directory;
        items.add((relative, isDirectory));
        if (items.length > maxCopyItems + 1) {
          return null;
        }
        if (isDirectory) {
          if (depth + 1 >= maxCopyDepth) {
            return null;
          }
          pending.add((relative, depth + 1));
        }
      }
    }
    return items;
  }

  Future<void> _removePartial(String real) async {
    try {
      final type = _typeOf(real);
      if (type == FileSystemEntityType.directory) {
        await Directory(real).delete(recursive: true);
      } else if (type != FileSystemEntityType.notFound) {
        await File(real).delete();
      }
    } on FileSystemException catch (error) {
      appLogger.warn('files', 'partial_copy_left', fields: {'error': '$error'});
    }
  }

  @override
  Future<Result<void>> delete(String path) async {
    final String real;
    switch (await _resolveEntry(path)) {
      case Ok<String>(:final value):
        real = value;
      case Err<String>(:final failure):
        return Err(failure);
    }
    final type = _typeOf(real);
    try {
      switch (type) {
        case FileSystemEntityType.notFound:
          return Err(
            FileFailure('$path does not exist.', problem: FileProblem.notFound),
          );
        case FileSystemEntityType.directory:
          // Links inside are deleted, never followed.
          await Directory(real).delete(recursive: true);
        case FileSystemEntityType.link:
          await Link(real).delete();
        default:
          await File(real).delete();
      }
    } on FileSystemException catch (error) {
      return Err(
        FileFailure(
          '$path could not be deleted completely.',
          problem: FileProblem.io,
          cause: error,
        ),
      );
    }
    appLogger.info('files', 'deleted', fields: {'path': path});
    return const Ok(null);
  }

  /// What is at the real path [real], not following a link there.
  static FileSystemEntityType _typeOf(String real) =>
      FileSystemEntity.typeSync(real, followLinks: false);

  /// Whether [a] and [b] are one file: a rename that only changes the case
  /// on storage that ignores case.
  static bool _same(String a, String b) {
    try {
      return a.toLowerCase() == b.toLowerCase() &&
          FileSystemEntity.identicalSync(a, b);
    } on FileSystemException {
      return false;
    }
  }

  /// Why [folder] cannot take an item: it is missing or not a folder.
  Future<FileFailure?> _missingFolder(String folder) async {
    switch (await _resolve(folder, allowRoot: true)) {
      case Err<String>(:final failure):
        return failure is FileFailure
            ? failure
            : FileFailure(failure.message, problem: FileProblem.io);
      case Ok<String>(:final value):
        return switch (FileSystemEntity.typeSync(value)) {
          FileSystemEntityType.directory => null,
          FileSystemEntityType.notFound => FileFailure(
            '${_label(folder)} does not exist.',
            problem: FileProblem.notFound,
          ),
          _ => FileFailure(
            '${_label(folder)} is not a folder.',
            problem: FileProblem.wrongType,
          ),
        };
    }
  }

  /// A file where [folder] or a folder above it should be, if there is
  /// one: a new folder cannot go there.
  Future<FileFailure?> _fileInTheWay(String folder) async {
    for (var path = folder; path.isNotEmpty; path = pathParent(path)) {
      final resolved = await _resolve(path);
      final real = resolved.valueOrNull;
      if (real == null) {
        return null;
      }
      final type = FileSystemEntity.typeSync(real);
      if (type == FileSystemEntityType.directory) {
        return null;
      }
      if (type != FileSystemEntityType.notFound) {
        return FileFailure(
          '$path is a file, not a folder.',
          problem: FileProblem.wrongType,
        );
      }
    }
    return null;
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
        if (!_createIfMissing) {
          return Err(
            FileFailure(
              'The project "${_workspace.displayName}" is missing: its '
              'folder is gone.',
              problem: FileProblem.folderMissing,
            ),
          );
        }
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

  /// The real location of the file or folder [path] itself (Phase 3 W4):
  /// its folder resolved through symbolic links, which must stay inside
  /// the workspace, and its own name not followed, so that renaming,
  /// moving or deleting a link changes the link and never its target.
  Future<Result<String>> _resolveEntry(String path) async {
    final invalid = workspacePathProblem(path);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    switch (await _resolve(pathParent(path), allowRoot: true)) {
      case Ok<String>(:final value):
        return Ok('$value/${pathBaseName(path)}');
      case Err<String>(:final failure):
        return Err(failure);
    }
  }

  /// The new file takes the old one's permission bits before it replaces
  /// it (Phase 3 W1): an executable script stays executable, a private file
  /// stays private. A file whose bits cannot be set is still saved.
  void _keepMode(String tempPath, int mode, String path) {
    if (Platform.isWindows || setFileMode(tempPath, mode)) {
      return;
    }
    appLogger.warn(
      'files',
      'mode_not_kept',
      fields: {'path': path, 'mode': (mode & fileModeBits).toRadixString(8)},
    );
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
