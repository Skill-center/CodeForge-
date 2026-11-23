/// A rename across files, all or nothing (Phase 6 W5, PHASE_6_PLAN W5).
///
/// 1. The server computes the edit (`textDocument/rename`) at the version
///    the user asked in.
/// 2. Every file's new text is worked out before anything is written. Open
///    documents take the editor's text: the server must have computed them
///    at the version they are at, and none may have changed while it did. Closed files are read from disk: one
///    changed after the request was sent is refused. Every edit must fit its
///    file exactly, and replace the old name (core/lsp/workspace_edit.dart).
///    Any problem anywhere: nothing is written, and the user is told why.
/// 3. Closed files are written, each only if it is still as read (atomic in
///    a project; through the broker in a folder). Then the open documents
///    change together, each as one undoable change (`doc.applyEdits`). If
///    either step fails, the files already written get their old text back.
/// 4. The servers read the written files again (through the copy, in a
///    folder), and the summary lists the files changed.
library;

import '../../core/errors/failure.dart';
import '../../core/files/file_stamp.dart';
import '../../core/logging/logger.dart';
import '../../core/lsp/lsp_models.dart';
import '../../core/lsp/text_sync.dart';
import '../../core/lsp/workspace_edit.dart';
import '../../services/contracts.dart';
import '../documents/document_state.dart';
import '../editor/editor_host.dart';
import 'language_client.dart';

const String _tag = 'lsp.rename';

/// How long a server may take to compute a rename across a project.
const Duration renameTimeout = Duration(seconds: 15);

/// A rename the page asked for, checked with the server, waiting for its
/// new name.
final class RenameRequest {
  const RenameRequest({
    required this.server,
    required this.docId,
    required this.path,
    required this.version,
    required this.pos,
    required this.oldName,
    required this.placeholder,
  });

  final LspServerId server;
  final String docId;
  final String path;

  /// The document's version the rename was asked at.
  final int version;

  /// Where, as an offset into the document at [version].
  final int pos;

  /// The text that would change: every edit must replace exactly this.
  final String oldName;

  /// The name the dialog starts with.
  final String placeholder;
}

/// What a rename changed.
final class RenameSummary {
  const RenameSummary({
    required this.oldName,
    required this.newName,
    required this.paths,
    required this.written,
    required this.edits,
  });

  final String oldName;
  final String newName;

  /// Every file changed, in the server's order.
  final List<String> paths;

  /// The files that were closed, written to disk; the others are open
  /// documents, changed in the editor and not saved yet.
  final List<String> written;
  final int edits;

  /// The summary the user reads.
  String get message {
    final names = [for (final path in paths) path.split('/').last];
    final shown = names.length <= 5
        ? names.join(', ')
        : '${names.take(5).join(', ')} and ${names.length - 5} more';
    final files = paths.length == 1 ? '1 file' : '${paths.length} files';
    return 'Renamed $oldName to $newName in $files: $shown';
  }
}

/// Renames [request]'s symbol to [newName] through [client], all or
/// nothing; [written] tells the servers about the files written to disk.
Future<Result<RenameSummary>> runRename({
  required RenameRequest request,
  required String newName,
  required LanguageClient client,
  required EditorHost host,
  required FileService files,
  required DocumentsState Function() documents,
  required void Function(List<String> paths) written,
  DateTime Function()? now,
}) async {
  final name = newName.trim();
  if (name.isEmpty || name == request.oldName) {
    return const Err(
      LspFailure('Nothing was renamed.', problem: LspProblem.cancelled),
    );
  }
  final text = host.textOf(request.docId);
  if (text == null || host.versionOf(request.docId) != request.version) {
    return const Err(
      LspFailure(
        'Nothing was renamed: the file changed meanwhile. Try again.',
        problem: LspProblem.cancelled,
      ),
    );
  }
  final uri = client.uriOf(request.path);
  if (uri == null) {
    return Err(
      LspFailure(
        'Nothing was renamed: ${request.server.title} is not running.',
        problem: LspProblem.stopped,
      ),
    );
  }
  final asked = (now ?? DateTime.now)();
  // The open documents as the server has them now: one that moves on while
  // the rename is computed is refused below.
  final shown = {
    for (final path in client.openPaths) path: client.versionOf(path),
  };
  final answer = await client.request(
    'textDocument/rename',
    {
      'textDocument': {'uri': uri},
      'position': LineIndex(text).positionAt(request.pos).toJson(),
      'newName': name,
    },
    path: request.path,
    atVersion: request.version,
    timeout: renameTimeout,
  );
  final Object? edit;
  switch (answer) {
    case Err<Object?>(:final failure):
      return Err(_nothing(failure.message, failure));
    case Ok<Object?>(:final value):
      edit = value;
  }
  final parsed = parseWorkspaceEdit(edit);
  final problem = parsed.problem;
  if (problem != null) {
    return Err(_nothing(problem));
  }
  if (parsed.files.isEmpty) {
    return Err(_nothing('the server found nothing to change.'));
  }

  // Every file's new text, before anything is written.
  final state = documents();
  final open = <DocumentEditsSpec>[];
  final openPaths = <String>[];
  final closed = <({String path, TextFile file, String text})>[];
  final paths = <String>[];
  var edits = 0;
  for (final file in parsed.files) {
    final path = client.pathOf(file.uri);
    if (path == null || path.isEmpty) {
      return Err(_nothing('it would change files outside the workspace.'));
    }
    paths.add(path);
    edits += file.edits.length;
    final doc = state.documents[path];
    if (doc != null) {
      final docText = host.textOf(doc.docId);
      final docVersion = host.versionOf(doc.docId);
      if (docText == null || docVersion == null) {
        return Err(_nothing('$path is not open in the editor any more.'));
      }
      final serverVersion = client.versionOf(path);
      if ((file.version != null && serverVersion != file.version) ||
          (shown.containsKey(path) && shown[path] != serverVersion)) {
        return Err(_changed(path));
      }
      final applied = applyTextEdits(
        docText,
        file.edits,
        expected: request.oldName,
      );
      if (applied.problem != null) {
        return Err(_changed(path, applied.problem));
      }
      open.add((
        docId: doc.docId,
        baseVersion: docVersion,
        edits: applied.offsets,
      ));
      openPaths.add(path);
    } else {
      final read = await files.readText(path);
      final TextFile current;
      switch (read) {
        case Err<TextFile>(:final failure):
          return Err(_nothing('$path could not be read: ${failure.message}'));
        case Ok<TextFile>(:final value):
          current = value;
      }
      if (current.stamp.modified.isAfter(asked)) {
        return Err(_changed(path));
      }
      final applied = applyTextEdits(
        current.text,
        file.edits,
        expected: request.oldName,
      );
      final next = applied.text;
      if (applied.problem != null || next == null) {
        return Err(_changed(path, applied.problem));
      }
      closed.add((path: path, file: current, text: next));
    }
  }

  // The closed files, each only if it is still as read.
  final done = <({String path, TextFile file, FileStamp stamp})>[];
  for (final file in closed) {
    final wrote = await files.writeText(
      file.path,
      file.text,
      format: file.file.format,
      expected: file.file.stamp,
    );
    switch (wrote) {
      case Err<FileStamp>(:final failure):
        await _restore(files, done);
        return Err(
          _nothing('${file.path} could not be written: ${failure.message}'),
        );
      case Ok<FileStamp>(:final value):
        done.add((path: file.path, file: file.file, stamp: value));
    }
  }
  // The open documents, together, each as one undoable change.
  if (open.isNotEmpty) {
    final applied = await host.applyEdits(open);
    if (applied case Err<void>(:final failure)) {
      await _restore(files, done);
      return Err(
        _nothing(
          failure is BridgeFailure && failure.cause == 'stale'
              ? 'a file changed while it was being renamed.'
              : failure.message,
        ),
      );
    }
  }
  final writtenPaths = [for (final file in done) file.path];
  written(writtenPaths);
  appLogger.info(
    _tag,
    'renamed',
    fields: {
      'server': request.server.id,
      'files': paths.length,
      'open': openPaths.length,
      'written': writtenPaths.length,
      'edits': edits,
    },
  );
  return Ok(
    RenameSummary(
      oldName: request.oldName,
      newName: name,
      paths: paths,
      written: writtenPaths,
      edits: edits,
    ),
  );
}

/// Gives the files already written their old text back.
Future<void> _restore(
  FileService files,
  List<({String path, TextFile file, FileStamp stamp})> done,
) async {
  for (final file in done.reversed) {
    final restored = await files.writeText(
      file.path,
      file.file.text,
      format: file.file.format,
      expected: file.stamp,
    );
    if (restored case Err<FileStamp>(:final failure)) {
      appLogger.error(
        _tag,
        'restore_failed',
        fields: {'path': file.path, 'error': failure.message},
      );
    }
  }
}

LspFailure _nothing(String why, [Failure? cause]) {
  final problem = cause is LspFailure ? cause.problem : LspProblem.serverError;
  final reason = why.endsWith('.') ? why : '$why.';
  return LspFailure('Nothing was renamed: $reason', problem: problem);
}

LspFailure _changed(String path, [EditProblem? problem]) => _nothing(
  problem == EditProblem.overlapping
      ? "the server's edits for $path overlap"
      : '$path changed after the rename was computed',
);
