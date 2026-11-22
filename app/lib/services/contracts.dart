/// Service interfaces (docs/ARCHITECTURE.md §2).
///
/// Contracts never leak platform types. Files are real since Phase 2 W4
/// (services/files/local_file_service.dart), the sealed runtime since
/// Phase 4 W3 (services/runtime/runtime_service.dart), terminal sessions
/// since Phase 5 W2 (services/terminal/native/), and the language servers'
/// host since Phase 6 W4 (services/lsp/native/); the other services stay
/// honest fakes until their phase, behind these exact contracts.
library;

import 'dart:typed_data';

import '../core/errors/failure.dart';
import '../core/files/file_stamp.dart';
import '../core/files/text_codec.dart';
import '../core/lsp/lsp_models.dart';
import '../core/terminal/terminal_models.dart';

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

  /// The file's stamp now, as [readText] would report it (Phase 3 W5): an
  /// open document compares it with the stamp it was read or saved with to
  /// see whether something else changed the file. [FileProblem.notFound]
  /// when the file is gone, [FileProblem.wrongType] for a folder.
  Future<Result<FileStamp>> stat(String path);

  /// Notices that the folder [path] ('' is the workspace root) changed,
  /// while listened to (Phase 3 W5): an entry directly inside it was
  /// created, written, renamed or deleted. Not recursive: each folder is
  /// watched on its own. A notice says only that something changed, and
  /// the app's own writes cause notices too. Storage that sends no notices
  /// gives a stream that never emits; a folder that can't be watched gives
  /// an error. Cancelling the subscription stops the watch.
  Stream<void> watchFolder(String path);

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

/// Whether terminal sessions can run here: on Android, through the
/// terminal host (Phase 5 W2); not in tests or the honest fake.
enum TerminalAvailability { unavailable, available }

/// Terminal sessions on the sealed runtime (Phase 5 W2;
/// docs/TERMINAL_ARCHITECTURE.md). The host starts and holds them; this
/// contract never sees a process or a path. Every failure is a
/// [TerminalFailure].
abstract interface class TerminalService {
  TerminalAvailability get availability;

  /// Why sessions can't run here, when they can't.
  String get unavailableReason;

  /// Every session's output, in batches, in order for each session. The
  /// view acknowledges what it has drawn ([acknowledge]): a session whose
  /// view stops acknowledging stops being read, so nothing is lost.
  Stream<TerminalOutput> get output;

  /// Every session's start and exit.
  Stream<TerminalInfo> get changes;

  /// Starts a session with this client as its view from its first byte.
  Future<Result<TerminalInfo>> start(TerminalSpec spec);

  /// The sessions, running and exited, oldest first.
  Future<Result<List<TerminalInfo>>> sessions();

  /// Sends [bytes] to session [id], as typed.
  Future<Result<void>> write(int id, Uint8List bytes);

  /// Tells session [id] its window's new size.
  Future<Result<void>> resize(
    int id, {
    required int rows,
    required int columns,
  });

  /// The view has drawn session [id]'s output before [offset].
  Future<void> acknowledge(int id, int offset);

  /// Makes this client session [id]'s view: its buffer now, its output
  /// from there on.
  Future<Result<TerminalReplay>> attach(int id);

  /// Session [id] keeps its output in its buffer, without a view.
  Future<void> detach(int id);

  /// Ends session [id] with everything it started.
  Future<Result<void>> end(int id);

  /// The user's End all: ends every session; answers how many still run.
  Future<Result<int>> endAll();

  /// Forgets exited session [id] and its buffer.
  Future<Result<void>> remove(int id);
}

/// The language servers' host (Phase 6 W3, W4; pigeons/lsp_api.dart): a
/// supervised pipe to each server. It starts a server in a workspace named,
/// never a path; carries whole JSON-RPC messages both ways; stops it; and
/// says how it ended. The protocol is the client's (application/lsp/).
/// Every failure is an [LspFailure].
abstract interface class LspService {
  /// False where no host can run servers (the honest fake, `flutter test`).
  bool get available;

  /// Every server's messages, in order for each server.
  Stream<LspIncoming> get messages;

  /// Every server's end; nothing more comes from it after.
  Stream<LspExit> get exits;

  /// Starts [server] in [workspace], installing it first the first time
  /// (seconds, once).
  Future<Result<LspStarted>> start(LspServerId server, LspWorkspace workspace);

  /// Sends [message], one JSON-RPC message, to server [handle]: done once
  /// the host has written it to the server's stdin.
  Future<Result<LspWritten>> send(int handle, String message);

  /// Stops server [handle] with its whole tree; its exit follows.
  Future<Result<void>> stop(int handle);

  /// The servers that run, oldest first, with their memory.
  Future<Result<List<LspServerInfo>>> servers();
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
