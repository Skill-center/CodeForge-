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

/// How a folder's run copy, or its import as a project, went (Phase 5 W4,
/// ADR-0013), and what it left out.
final class CopySummary {
  const CopySummary({
    required this.files,
    required this.bytes,
    this.copied = 0,
    this.bytesCopied = 0,
    this.unchanged = 0,
    this.removed = 0,
    this.leftOutLarge = 0,
    this.leftOutFull = 0,
    this.leftOutVirtual = 0,
    this.leftOutDeep = 0,
    this.skipped = 0,
    this.unreadable = 0,
    this.capped = false,
    this.stopped = false,
    this.elapsed = Duration.zero,
  });

  /// Files in the copy from the folder, and their bytes, once it is done.
  final int files;
  final int bytes;

  /// Files copied this time (new, changed in the folder, or changed in
  /// the copy by a run), and their bytes.
  final int copied;
  final int bytesCopied;

  /// Files the copy already had as the folder has them.
  final int unchanged;

  /// Files gone from the folder, removed from the copy.
  final int removed;

  /// Files over the size cap (64 MB).
  final int leftOutLarge;

  /// Files left out once the copy was full (10,000 files or 512 MB).
  final int leftOutFull;

  /// Virtual documents (Google Docs and the like): they have no bytes.
  final int leftOutVirtual;

  /// Folders nested too deep.
  final int leftOutDeep;

  /// Entries left out by name: `.git` in a run's copy.
  final int skipped;

  /// Files and folders that could not be read.
  final int unreadable;

  /// The copy filled up and stopped walking: more may be left out.
  final bool capped;

  /// The copy was cancelled; what it copied by then stays.
  final bool stopped;
  final Duration elapsed;

  /// Everything left out but `.git`, which is left out on purpose.
  int get leftOut => leftOutLarge + leftOutFull + leftOutVirtual + leftOutDeep;
}

/// A file a run created (only the copy has it) or changed in its copy.
final class CopyChange {
  const CopyChange({
    required this.path,
    required this.created,
    required this.size,
  });

  final String path;
  final bool created;
  final int size;
}

/// The files runs created or changed in a folder's copy, at most 500.
final class CopyChanges {
  const CopyChanges({
    this.changes = const [],
    this.more = 0,
    this.unexportable = 0,
    this.skippedFolders = 0,
  });

  final List<CopyChange> changes;

  /// Changed files beyond those listed.
  final int more;

  /// Files whose names a documents provider can't take.
  final int unexportable;

  /// Dependency folders (node_modules and the like) not looked into.
  final int skippedFolders;
}

/// What an export wrote, and each file it could not.
final class ExportResult {
  const ExportResult({required this.exported, this.failures = const []});

  final int exported;
  final List<({String path, FileFailure failure})> failures;
}

/// How far a copy or an import is: files and bytes in place.
final class CopyProgress {
  const CopyProgress({
    required this.copyId,
    required this.files,
    required this.bytes,
  });

  /// The copy's id, or [importCopyId] for an import.
  final String copyId;
  final int files;
  final int bytes;
}

/// The copy id an import's progress and cancel use.
const String importCopyId = 'import';

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

  /// Change notices for the folder at [path] while listened to (Phase 3
  /// W5): its provider says when the folder's entries change, as Android's
  /// own does; a provider that does not leaves the stream silent. A folder
  /// that can't be watched gives a [FileFailure] error. Cancelling stops
  /// the watch.
  Stream<void> watch(String treeUri, String path);

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

  /// Brings the run copy [copyId] (the folder workspace's id) of the
  /// folder up to date (Phase 5 W4, ADR-0013): one way, incremental,
  /// `.git` left out. How far it is goes to [copyProgress].
  Future<Result<CopySummary>> syncCopy(String treeUri, String copyId);

  /// Stops copy [copyId] (or an import, [importCopyId]) between files.
  Future<void> cancelCopy(String copyId);

  /// The files runs created or changed in copy [copyId].
  Future<Result<CopyChanges>> copyChanges(String copyId);

  /// Writes copy [copyId]'s files at [paths] to the folder, replacing what
  /// is there.
  Future<Result<ExportResult>> exportCopy(
    String treeUri,
    String copyId,
    List<String> paths,
  );

  /// Deletes copy [copyId]: its folder left the recents.
  Future<Result<void>> deleteCopy(String copyId);

  /// Copies the whole folder, git's files included, into a new project's
  /// folder named [folderName] (Import as project). [FileProblem.exists]
  /// when a project of that name, case ignored, is there.
  Future<Result<CopySummary>> importFolder(String treeUri, String folderName);

  /// How far copies and imports are, while they run.
  Stream<CopyProgress> get copyProgress;
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
