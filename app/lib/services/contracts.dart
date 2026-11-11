/// Service interfaces (docs/ARCHITECTURE.md §2).
///
/// Contracts never leak platform types. Files are real since Phase 2 W4
/// (services/files/local_file_service.dart); the other services stay
/// honest fakes until their phase, behind these exact contracts.
library;

import '../core/errors/failure.dart';
import '../core/files/file_stamp.dart';
import '../core/files/text_codec.dart';

/// What can be done to a file or folder (Phase 3 W4). A project's items
/// allow everything. In a folder from shared storage each item allows what
/// its provider declares for it (DocumentsContract's flags), and nothing
/// that changes it when the folder was granted for reading only. The
/// explorer offers only what is allowed: a provider that cannot rename
/// hides Rename.
final class FileCapabilities {
  const FileCapabilities({
    this.write = true,
    this.rename = true,
    this.move = true,
    this.delete = true,
  });

  /// Everything: a project's items.
  static const FileCapabilities all = FileCapabilities();

  /// Nothing that changes it: a folder granted for reading only.
  static const FileCapabilities none = FileCapabilities(
    write: false,
    rename: false,
    move: false,
    delete: false,
  );

  /// A file can be written; a folder can take new items (created, moved,
  /// copied or duplicated into it).
  final bool write;
  final bool rename;
  final bool move;
  final bool delete;
}

/// A workspace handle: the built-in project, or since Phase 3 W2 a folder
/// from shared storage (core/files/workspace_location.dart).
final class WorkspaceRef {
  const WorkspaceRef({
    required this.id,
    required this.displayName,
    this.capabilities = FileCapabilities.all,
  });

  final String id;
  final String displayName;

  /// What its top folder allows (Phase 3 W4): [FileCapabilities.none] for
  /// a folder granted for reading only.
  final FileCapabilities capabilities;
}

/// File metadata, independent of any storage backend.
final class FileEntry {
  const FileEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.hidden = false,
    this.sizeBytes,
    this.capabilities = FileCapabilities.all,
  });

  /// Workspace-relative path.
  final String path;
  final String name;
  final bool isDirectory;
  final bool hidden;
  final int? sizeBytes;

  /// What can be done to it (Phase 3 W4).
  final FileCapabilities capabilities;
}

/// Explorer order: folders before files, then by name ignoring case (ties
/// broken by the exact name, so the order is total).
int compareFileEntries(FileEntry a, FileEntry b) {
  if (a.isDirectory != b.isDirectory) {
    return a.isDirectory ? -1 : 1;
  }
  final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return byName != 0 ? byName : a.name.compareTo(b.name);
}

/// A text file as read from the workspace.
final class TextFile {
  const TextFile({
    required this.path,
    required this.text,
    required this.format,
    required this.stamp,
    this.mixedLineEndings = false,
  });

  /// Workspace-relative path.
  final String path;

  /// The content, with "\n" line breaks only.
  final String text;

  /// The line endings and byte-order mark to write it back with.
  final TextFormat format;

  /// The file's stamp when it was read.
  final FileStamp stamp;

  /// The file mixed line-ending styles; saving writes one style.
  final bool mixedLineEndings;
}

/// What a write does when something already exists at its path.
enum WriteMode {
  /// Replace it: Save, or Save As once the user agreed.
  replace,

  /// Refuse with [FileProblem.exists]: New File, and Save As at first.
  createNew,
}

/// The files of the open workspace. Every path is workspace-relative
/// (core/files/workspace_path.dart).
abstract interface class FileService {
  /// Opens the workspace: the project, created with the demo files on
  /// first run, or a folder, which must still be there
  /// ([FileProblem.folderMissing]) and granted ([FileProblem.accessLost]).
  Future<Result<WorkspaceRef>> openWorkspace();

  /// The entries directly inside [path] ('' is the workspace root):
  /// folders first, then files, each by name.
  Future<Result<List<FileEntry>>> listDirectory(String path);

  /// Reads a UTF-8 text file. Binary, malformed and non-UTF-8 files are
  /// refused with [FileProblem.notText].
  Future<Result<TextFile>> readText(String path);

  /// Writes [text] in [format] and returns the file's new stamp. With
  /// [expected], a file whose stamp no longer matches (something else
  /// changed it) is left alone and [FileProblem.changedOnDisk] returned.
  ///
  /// In a project the write is atomic: afterwards the file holds either all
  /// of the new content or, if anything failed, its old content. In a
  /// folder from shared storage it can't be (services/files/
  /// saf_file_service.dart): a failed write may leave the file incomplete,
  /// and its message says so. Either way a failure leaves the caller's text
  /// unsaved, so nothing is marked saved that is not on disk.
  Future<Result<FileStamp>> writeText(
    String path,
    String text, {
    TextFormat format = TextFormat.standard,
    WriteMode mode = WriteMode.replace,
    FileStamp? expected,
  });

  // The explorer's operations (Phase 3 W4). None of them ever replaces
  // anything: a name that is taken is refused with [FileProblem.exists],
  // and the explorer asks for another.

  /// Creates the folder [path], and any missing folders above it. Refuses
  /// a path where something exists ([FileProblem.exists]).
  Future<Result<void>> createFolder(String path);

  /// Gives the file or folder at [path] the name [newName] in the same
  /// folder, and returns its new path. A rename that only changes the case
  /// works too.
  Future<Result<String>> rename(String path, String newName);

  /// Moves the file or folder at [path] into the folder [folder] ('' is the
  /// workspace root), keeping its name, and returns its new path. A folder
  /// cannot go into itself ([FileProblem.invalidPath]).
  Future<Result<String>> move(String path, String folder);

  /// Copies the file at [path], or the folder with everything in it, to
  /// [newPath], which must not exist yet.
  Future<Result<void>> copy(String path, String newPath);

  /// Deletes the file at [path], or the folder with everything in it. In a
  /// folder from shared storage this is permanent: Android keeps no bin
  /// there.
  Future<Result<void>> delete(String path);
}

/// Terminal session state. Phases 4–5 provide the real runtime-backed impl.
enum TerminalAvailability { unavailable, available }

abstract interface class TerminalService {
  TerminalAvailability get availability;
  String get unavailableReason;
}

/// Sealed-runtime install state (docs/RUNTIME_ARCHITECTURE.md).
enum RuntimeState { notInstalled, installing, ready, unhealthy }

abstract interface class RuntimeService {
  Future<Result<RuntimeState>> state();
}

/// Git status for the status strip. Phase 6 provides the real impl.
final class GitSummary {
  const GitSummary({required this.branch, this.dirtyCount = 0});

  final String branch;
  final int dirtyCount;
}

abstract interface class GitService {
  Future<Result<GitSummary>> summary();
}

/// Workspace search. Phase 3 provides the real impl.
abstract interface class SearchService {
  Future<Result<List<String>>> searchFiles(String query);
}
