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

  @override
  Future<Result<WorkspaceRef>> openWorkspace() async {
    switch (await _broker.checkFolder(_uri)) {
      case Err<FolderInfo>(:final failure):
        return Err(_explain(failure, '', _Doing.open));
      case Ok<FolderInfo>(:final value):
        switch (value.status) {
          case FolderStatus.available:
            return Ok(
              WorkspaceRef(
                id: folder.id,
                displayName: value.name.isEmpty ? folder.name : value.name,
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
    'CodeForge no longer has access to "${folder.name}". Open the folder '
    'again from Home to give it access.',
    problem: FileProblem.accessLost,
  );

  /// [failure] from the broker, worded for the user with [path].
  FileFailure _explain(Failure failure, String path, _Doing doing) {
    if (failure is! FileFailure) {
      return FileFailure(failure.message, problem: FileProblem.io);
    }
    final label = path.isEmpty ? 'The folder' : path;
    final message = switch (failure.problem) {
      FileProblem.folderMissing => _missing().message,
      FileProblem.accessLost => _accessLost().message,
      FileProblem.notFound => '$label does not exist.',
      FileProblem.exists => '$path already exists.',
      FileProblem.wrongType => switch (doing) {
        _Doing.list => '$label is not a folder.',
        _Doing.read => '$path is not a file.',
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
        "The folder's storage would have named $path differently, so it "
            'was left as it was.',
      FileProblem.io when doing == _Doing.write =>
        '$path could not be saved, and the file on disk may be incomplete. '
            'Your text is still here, unsaved.',
      FileProblem.io => switch (doing) {
        _Doing.list => '$label could not be listed.',
        _Doing.read => '$path could not be read.',
        _ => "The folder's storage failed.",
      },
      _ => failure.message,
    };
    return FileFailure(message, problem: failure.problem, cause: failure.cause);
  }
}

enum _Doing { open, list, read, write }
