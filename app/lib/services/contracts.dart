/// Service interfaces (docs/ARCHITECTURE.md §2).
///
/// Contracts never leak platform types. Files are real since Phase 2 W4
/// (services/files/local_file_service.dart); the other services stay
/// honest fakes until their phase, behind these exact contracts.
library;

import '../core/errors/failure.dart';
import '../core/files/file_stamp.dart';
import '../core/files/text_codec.dart';

/// A workspace handle. Phase 2 has one app-private workspace.
final class WorkspaceRef {
  const WorkspaceRef({required this.id, required this.displayName});

  final String id;
  final String displayName;
}

/// File metadata, independent of any storage backend.
final class FileEntry {
  const FileEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.hidden = false,
    this.sizeBytes,
  });

  /// Workspace-relative path.
  final String path;
  final String name;
  final bool isDirectory;
  final bool hidden;
  final int? sizeBytes;
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
  /// Opens the workspace, creating it with the demo project on first run.
  Future<Result<WorkspaceRef>> openWorkspace();

  /// The entries directly inside [path] ('' is the workspace root):
  /// folders first, then files, each by name.
  Future<Result<List<FileEntry>>> listDirectory(String path);

  /// Reads a UTF-8 text file. Binary, malformed and non-UTF-8 files are
  /// refused with [FileProblem.notText].
  Future<Result<TextFile>> readText(String path);

  /// Writes [text] in [format], atomically: afterwards the file holds
  /// either all of the new content or, if anything failed, its old content.
  /// With [expected], a file whose stamp no longer matches (something else
  /// changed it) is left alone and [FileProblem.changedOnDisk] returned.
  /// Returns the file's new stamp.
  Future<Result<FileStamp>> writeText(
    String path,
    String text, {
    TextFormat format = TextFormat.standard,
    WriteMode mode = WriteMode.replace,
    FileStamp? expected,
  });
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
