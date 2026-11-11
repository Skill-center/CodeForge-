/// The file service of a folder from shared storage (Phase 3 W2,
/// docs/SECURITY.md §4.1), over the storage broker.
///
/// The same strict codec as projects (core/files/text_codec.dart): UTF-8
/// only, byte-order mark and CRLF kept, binary refused, and nothing larger
/// than [maxTextFileBytes], which the broker checks from the listed size
/// before it reads.
///
/// **Saves are not atomic here.** DocumentsContract cannot replace a file
/// by renaming over it, so the broker writes the file in place (mode "wt")
/// and reads its new stamp back. A document therefore stays unsaved, with
/// its text in the journal, until the write has completed and the stamp
/// was read back; a failed or interrupted save may leave the file
/// incomplete, and says so, but never marks the document saved.
///
/// **Stamps** are the modification time and the size. A provider that
/// reports no time gets a SHA-256 of the content instead, so a save still
/// notices that the file changed.
///
/// **The explorer's operations** (Phase 3 W4) go to the broker, which
/// checks a new name against its folder without case, renames through a
/// temporary name when only the case changes, moves by copying and
/// deleting where the provider cannot move, and undoes a change the
/// provider named otherwise. Each item offers what its provider declares
/// for it, and nothing that changes it when the folder was granted for
/// reading only. A delete is permanent: shared storage keeps no bin.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/editor/large_files.dart';
import '../../core/errors/failure.dart';
import '../../core/files/file_stamp.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_location.dart';
import '../../core/files/workspace_path.dart';
import '../../core/logging/logger.dart';
import '../contracts.dart';
import 'storage_broker.dart';

final class SafFileService implements FileService {
  SafFileService({required StorageBroker broker, required this.folder})
    : _broker = broker;

  final StorageBroker _broker;

  /// The workspace's folder.
  final FolderLocation folder;

  String get _uri => folder.treeUri;

  /// Whether the grant and the provider allow changes, as the last check
  /// of the folder found.
  bool _writable = true;

  @override
  Future<Result<WorkspaceRef>> openWorkspace() async {
    switch (await _broker.checkFolder(_uri)) {
      case Err<FolderInfo>(:final failure):
        return Err(_explain(failure, '', _Doing.open));
      case Ok<FolderInfo>(:final value):
        switch (value.status) {
          case FolderStatus.available:
            _writable = value.writable;
            return Ok(
              WorkspaceRef(
                id: folder.id,
                displayName: value.name.isEmpty ? folder.name : value.name,
                capabilities: value.writable
                    ? FileCapabilities.all
                    : FileCapabilities.none,
              ),
            );
          case FolderStatus.missing:
            return Err(_missing());
          case FolderStatus.accessLost:
            return Err(_accessLost());
        }
    }
  }

  @override
  Future<Result<List<FileEntry>>> listDirectory(String path) async {
    final invalid = workspacePathProblem(path, allowRoot: true);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    switch (await _broker.list(_uri, path)) {
      case Err<List<BrokerEntry>>(:final failure):
        return Err(_explain(failure, path, _Doing.list));
      case Ok<List<BrokerEntry>>(:final value):
        final entries = [
          for (final entry in value)
            FileEntry(
              path: pathJoin(path, entry.name),
              name: entry.name,
              isDirectory: entry.isDirectory,
              hidden: entry.name.startsWith('.'),
              sizeBytes: entry.isDirectory ? null : entry.size,
              capabilities: _capabilitiesOf(entry),
            ),
        ]..sort(compareFileEntries);
        return Ok(entries);
    }
  }

  @override
  Future<Result<TextFile>> readText(String path) async {
    final invalid = workspacePathProblem(path);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    switch (await _broker.read(_uri, path, maxBytes: maxTextFileBytes)) {
      case Err<BrokerRead>(:final failure):
        return Err(_explain(failure, path, _Doing.read));
      case Ok<BrokerRead>(:final value):
        final stamp = stampOf(value.entry, value.bytes);
        return switch (decodeText(value.bytes)) {
          Ok<DecodedText>(value: final decoded) => Ok(
            TextFile(
              path: path,
              text: decoded.text,
              format: decoded.format,
              stamp: stamp,
              mixedLineEndings: decoded.mixedLineEndings,
            ),
          ),
          Err<DecodedText>(:final failure) => Err(failure),
        };
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
    final invalid = workspacePathProblem(path);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    final bytes = encodeText(text, format);
    final written = await _broker.write(
      _uri,
      path,
      bytes,
      createNew: mode == WriteMode.createNew,
      expect: expected == null
          ? null
          : BrokerExpectation(
              size: expected.size,
              modified: expected.digest == null ? expected.modified : null,
              sha256: expected.digest,
            ),
    );
    switch (written) {
      case Err<BrokerEntry>(:final failure):
        appLogger.warn(
          'files',
          'folder_write_failed',
          fields: {'path': path, 'error': failure.message},
        );
        return Err(_explain(failure, path, _Doing.write));
      case Ok<BrokerEntry>(:final value):
        appLogger.info(
          'files',
          'written',
          fields: {'path': path, 'bytes': bytes.length},
        );
        return Ok(stampOf(value, bytes));
    }
  }

  /// What the explorer may do to [entry]: what its provider declares, and
  /// nothing that changes it under a grant for reading only.
  FileCapabilities _capabilitiesOf(BrokerEntry entry) {
    if (!_writable) {
      return FileCapabilities.none;
    }
    return FileCapabilities(
      write: entry.canWrite,
      rename: entry.canRename,
      // Where the provider cannot move it, the broker copies it and
      // deletes the original.
      move: entry.canMove || entry.canDelete,
      delete: entry.canDelete,
    );
  }

  @override
  Future<Result<void>> createFolder(String path) async {
    final invalid = workspacePathProblem(path);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    // The folders on the way are created when missing; the last one must
    // be new.
    final names = path.split('/');
    var parent = '';
    for (var index = 0; index < names.length; index++) {
      final current = pathJoin(parent, names[index]);
      var create = true;
      if (index < names.length - 1) {
        switch (await _folderExists(current)) {
          case Ok<bool>(:final value):
            create = !value;
          case Err<bool>(:final failure):
            return Err(failure);
        }
      }
      if (create) {
        final created = await _broker.create(
          _uri,
          parent,
          names[index],
          directory: true,
        );
        if (created case Err<BrokerEntry>(:final failure)) {
          return Err(_explain(failure, current, _Doing.create));
        }
      }
      parent = current;
    }
    appLogger.info('files', 'folder_created', fields: {'path': path});
    return const Ok(null);
  }

  /// Whether [path] is a folder (true) or is missing (false); a file there
  /// fails.
  Future<Result<bool>> _folderExists(String path) async {
    switch (await _broker.stat(_uri, path)) {
      case Ok<BrokerEntry>(:final value):
        return value.isDirectory
            ? const Ok(true)
            : Err(
                FileFailure(
                  '$path is a file, not a folder.',
                  problem: FileProblem.wrongType,
                ),
              );
      case Err<BrokerEntry>(:final failure):
        if (failure is FileFailure && failure.problem == FileProblem.notFound) {
          return const Ok(false);
        }
        return Err(_explain(failure, path, _Doing.create));
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
    switch (await _broker.rename(_uri, path, newName)) {
      case Err<BrokerEntry>(:final failure):
        return Err(_explain(failure, path, _Doing.rename, target: newPath));
      case Ok<BrokerEntry>():
        appLogger.info(
          'files',
          'renamed',
          fields: {'from': path, 'to': newPath},
        );
        return Ok(newPath);
    }
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
    switch (await _broker.move(_uri, path, folder)) {
      case Err<BrokerEntry>(:final failure):
        return Err(_explain(failure, path, _Doing.move, target: newPath));
      case Ok<BrokerEntry>():
        appLogger.info('files', 'moved', fields: {'from': path, 'to': newPath});
        return Ok(newPath);
    }
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
    final copied = await _broker.copy(
      _uri,
      path,
      pathParent(newPath),
      pathBaseName(newPath),
    );
    switch (copied) {
      case Err<BrokerEntry>(:final failure):
        return Err(_explain(failure, path, _Doing.copy, target: newPath));
      case Ok<BrokerEntry>():
        appLogger.info('files', 'copied', fields: {'from': path, 'to': newPath});
        return const Ok(null);
    }
  }

  @override
  Future<Result<void>> delete(String path) async {
    final invalid = workspacePathProblem(path);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    switch (await _broker.delete(_uri, path)) {
      case Err<void>(:final failure):
        return Err(_explain(failure, path, _Doing.delete));
      case Ok<void>():
        appLogger.info('files', 'deleted', fields: {'path': path});
        return const Ok(null);
    }
  }

  /// The stamp of a file the broker reported as [entry] holding [bytes].
  static FileStamp stampOf(BrokerEntry entry, Uint8List bytes) {
    final modified = entry.modified;
    if (modified == null) {
      return FileStamp(
        modified: FileStamp.unknownTime,
        size: bytes.length,
        digest: sha256.convert(bytes).toString(),
      );
    }
    return FileStamp(modified: modified, size: entry.size ?? bytes.length);
  }

  FileFailure _missing() => FileFailure(
    'The folder "${folder.name}" is missing. It may have been moved, '
    'renamed or deleted, or its storage removed.',
    problem: FileProblem.folderMissing,
  );

  FileFailure _accessLost() => FileFailure(
    'CodeForge no longer has access to "${folder.name}". Reconnect it '
    'from Home to give it access again.',
    problem: FileProblem.accessLost,
  );

  /// [failure] from the broker, worded for the user with [path] (and
  /// [target], the new path of a rename, move or copy).
  FileFailure _explain(
    Failure failure,
    String path,
    _Doing doing, {
    String? target,
  }) {
    if (failure is! FileFailure) {
      return FileFailure(failure.message, problem: FileProblem.io);
    }
    final label = path.isEmpty ? 'The folder' : path;
    final message = switch (failure.problem) {
      FileProblem.folderMissing => _missing().message,
      FileProblem.accessLost => _accessLost().message,
      FileProblem.notFound => '$label does not exist.',
      FileProblem.exists => '${target ?? path} already exists.',
      FileProblem.wrongType => switch (doing) {
        _Doing.list => '$label is not a folder.',
        _Doing.read => '$path is not a file.',
        _Doing.create => 'A file is in the way of $path.',
        _Doing.move || _Doing.copy => 'The place for ${target ?? path} is not '
            'a folder.',
        _ => '$path is a folder.',
      },
      FileProblem.changedOnDisk => '$path changed on disk after it was opened.',
      FileProblem.tooLarge =>
        '$path is larger than ${formatMegabytes(maxTextFileBytes)}: the '
            'editor opens files up to that size.',
      FileProblem.outsideWorkspace => '$label leads outside the folder.',
      FileProblem.timeout =>
        "The folder's storage did not answer in time. Try again.",
      FileProblem.nameChanged =>
        "The folder's storage would have named ${target ?? path} "
            'differently, so nothing was changed.',
      FileProblem.unsupported => switch (doing) {
        _Doing.rename => "The folder's storage can't rename $path.",
        _Doing.move => "The folder's storage can't move $path.",
        _Doing.delete => "The folder's storage can't delete $path.",
        _Doing.create || _Doing.copy || _Doing.write =>
          "The folder's storage does not allow changes here.",
        _ => failure.message,
      },
      FileProblem.io when doing == _Doing.write =>
        '$path could not be saved, and the file on disk may be incomplete. '
            'Your text is still here, unsaved.',
      FileProblem.io => switch (doing) {
        _Doing.list => '$label could not be listed.',
        _Doing.read => '$path could not be read.',
        _Doing.create => '$path could not be created.',
        _Doing.rename => '$path could not be renamed.',
        _Doing.move => '$path could not be moved.',
        _Doing.copy => '$path could not be copied.',
        _Doing.delete => '$path could not be deleted completely.',
        _ => "The folder's storage failed.",
      },
      _ => failure.message,
    };
    return FileFailure(message, problem: failure.problem, cause: failure.cause);
  }
}

enum _Doing { open, list, read, write, create, rename, move, copy, delete }
