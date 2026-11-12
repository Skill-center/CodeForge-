/// The storage broker as the app sees it (Phase 3 W2, docs/SECURITY.md
/// §4.1): folders from shared storage, which only Kotlin can reach
/// (android/…/storage/StorageBroker.kt). The Pigeon client implements it
/// (native/pigeon_storage_broker.dart); tests use a fake.
///
/// A folder is named by its grant's tree URI, an opaque token, and a path
/// relative to it ('' is the folder itself). Every call returns a
/// [Result]: failures are [FileFailure]s, worded generally; the file
/// service (saf_file_service.dart) words them for the user.
library;

import 'dart:typed_data';

import '../../core/errors/failure.dart';

/// What the broker found when it looked at a folder.
enum FolderStatus {
  available,

  /// The folder is gone: deleted, moved or renamed, or its storage removed.
  missing,

  /// No grant for it, or its provider refused access.
  accessLost,
}

/// A folder grant and its folder, as found now.
final class FolderInfo {
  const FolderInfo({
    required this.treeUri,
    required this.name,
    required this.status,
    this.writable = false,
  });

  final String treeUri;

  /// The folder's name; empty when it could not be read.
  final String name;
  final FolderStatus status;

  /// Whether the grant and the provider allow changes.
  final bool writable;
}

/// A folder grant the app keeps.
final class FolderGrant {
  const FolderGrant({
    required this.treeUri,
    required this.read,
    required this.write,
    required this.persistedAt,
  });

  final String treeUri;
  final bool read;
  final bool write;
  final DateTime persistedAt;
}

/// One file or folder.
final class BrokerEntry {
  const BrokerEntry({
    required this.name,
    required this.isDirectory,
    this.size,
    this.modified,
    this.flags = 0,
  });

  final String name;
  final bool isDirectory;

  /// Bytes, when the provider says.
  final int? size;

  /// When the provider says: Android's own says nothing for files dated
  /// before 1971.
  final DateTime? modified;

  /// What the provider allows: [canWrite] 1, [canDelete] 2, [canRename] 4,
  /// [canMove] 8.
  final int flags;

  /// A file can be written, or a folder can take new items.
  bool get canWrite => flags & 1 != 0;
  bool get canDelete => flags & 2 != 0;
  bool get canRename => flags & 4 != 0;
  bool get canMove => flags & 8 != 0;
}

/// A file's bytes, and the file as it was right after they were read.
final class BrokerRead {
  const BrokerRead({required this.entry, required this.bytes});

  final BrokerEntry entry;
  final Uint8List bytes;
}

/// What a write must find before it replaces a file: the file as it was
/// read. [sha256] stands in for [modified] when the provider gave no time.
final class BrokerExpectation {
  const BrokerExpectation({required this.size, this.modified, this.sha256});

  final int size;
  final DateTime? modified;
  final String? sha256;
}

abstract interface class StorageBroker {
  /// Shows Android's folder picker, starting at [initialUri] when given,
  /// and keeps the grant. Ok(null) when the user backs out.
  Future<Result<FolderInfo?>> pickFolder({String? initialUri});

  /// Whether the folder is still there and still granted.
  Future<Result<FolderInfo>> checkFolder(String treeUri);

  /// The folder grants the app keeps.
  Future<Result<List<FolderGrant>>> grants();

  /// Gives the folder's grant back to Android.
  Future<Result<void>> releaseGrant(String treeUri);

  Future<Result<List<BrokerEntry>>> list(String treeUri, String path);

  Future<Result<BrokerEntry>> stat(String treeUri, String path);

  /// A file's bytes; [FileProblem.tooLarge] when it holds more than
  /// [maxBytes].
  Future<Result<BrokerRead>> read(
    String treeUri,
    String path, {
    required int maxBytes,
  });

  /// Writes the file in place, creating it and any missing folders above
  /// it; [FileProblem.changedOnDisk] when it no longer matches [expect].
  Future<Result<BrokerEntry>> write(
    String treeUri,
    String path,
    Uint8List bytes, {
    bool createNew = false,
    BrokerExpectation? expect,
  });

  Future<Result<BrokerEntry>> create(
    String treeUri,
    String parentPath,
    String name, {
    required bool directory,
  });

  Future<Result<BrokerEntry>> rename(
    String treeUri,
    String path,
    String newName,
  );

  /// Moves into [newParentPath], keeping the name.
  Future<Result<BrokerEntry>> move(
    String treeUri,
    String path,
    String newParentPath,
  );

  /// Copies into [newParentPath] as [newName], a folder with everything in
  /// it.
  Future<Result<BrokerEntry>> copy(
    String treeUri,
    String path,
    String newParentPath,
    String newName,
  );

  /// Deletes a file, or a folder with everything in it. Permanent: shared
  /// storage has no bin.
  Future<Result<void>> delete(String treeUri, String path);

  /// Shows Android's create-document picker, suggesting [suggestedName] as
  /// a file of [mimeType] and starting at [initialUri] (a document URI)
  /// when given, and writes [bytes] to the file the user makes (Phase 3
  /// W4, About → Recent logs → Save). The app keeps no grant to it. The
  /// file's name as its storage gave it ('' when it does not say), or null
  /// when the user backs out.
  Future<Result<String?>> saveDocument({
    required String suggestedName,
    required String mimeType,
    required Uint8List bytes,
    String? initialUri,
  });
}

/// The general wording of each broker failure, before the file service
/// names the file.
String brokerMessage(FileProblem problem) => switch (problem) {
  FileProblem.invalidPath => 'That path is not valid in this folder.',
  FileProblem.notFound => 'It is not there.',
  FileProblem.exists => 'That name is taken.',
  FileProblem.wrongType => 'It is not the kind of item expected.',
  FileProblem.changedOnDisk => 'It changed on disk after it was opened.',
  FileProblem.tooLarge => 'It is too large to open.',
  FileProblem.accessLost => 'CodeForge no longer has access to this folder.',
  FileProblem.folderMissing => 'The folder is gone.',
  FileProblem.outsideWorkspace => 'That leads outside the folder.',
  FileProblem.timeout => "The folder's storage did not answer in time.",
  FileProblem.unsupported => "The folder's storage can't do that.",
  FileProblem.nameChanged =>
    "The folder's storage would have given it another name, so nothing "
        'was changed.',
  FileProblem.notText => 'It is not UTF-8 text.',
  FileProblem.inUse => 'It is in use.',
  FileProblem.io => "The folder's storage failed.",
};
