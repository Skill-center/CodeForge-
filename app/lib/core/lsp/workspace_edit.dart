/// A rename's edits (Phase 6 W5, PHASE_6_PLAN W5): the WorkspaceEdit a
/// server answers `textDocument/rename` with, read, and each file's edits
/// applied to its text, exactly or not at all.
///
/// A rename is applied all or nothing (application/lsp/rename.dart): every
/// file's edits are worked out here first, and a single problem in any file
/// means nothing is written anywhere. An edit outside a file's text, edits
/// that overlap, or a replaced span that is not the old name all mean the
/// file changed after the server read it.
library;

import 'lsp_models.dart';
import 'text_sync.dart';

/// One edit: the text at [range] becomes [newText].
final class LspTextEdit {
  const LspTextEdit(this.range, this.newText);

  final LspRange range;
  final String newText;
}

/// One file's edits in a WorkspaceEdit.
final class FileTextEdits {
  const FileTextEdits(this.uri, this.edits, {this.version});

  final String uri;

  /// The document's version the server computed them for (an open
  /// document's TextDocumentEdit), when it says.
  final int? version;
  final List<LspTextEdit> edits;
}

/// The files [edit], a WorkspaceEdit, changes, in the server's order; or
/// why the app can't apply it: it would create, rename or delete files, or
/// it is malformed.
({List<FileTextEdits> files, String? problem}) parseWorkspaceEdit(
  Object? edit,
) {
  if (edit is! Map<String, Object?>) {
    return (files: const [], problem: 'The server proposed no changes.');
  }
  final order = <String>[];
  final edits = <String, List<LspTextEdit>>{};
  final versions = <String, int?>{};

  String? add(String uri, Object? list, int? version) {
    if (list is! List<Object?>) {
      return 'The server sent edits in a form CodeForge does not read.';
    }
    final parsed = <LspTextEdit>[];
    for (final item in list) {
      if (item is! Map<String, Object?> || item['newText'] is! String) {
        return 'The server sent edits in a form CodeForge does not read.';
      }
      final range = LspRange.fromJson(item['range']);
      if (range == null) {
        return 'The server sent edits in a form CodeForge does not read.';
      }
      parsed.add(LspTextEdit(range, item['newText']! as String));
    }
    if (!edits.containsKey(uri)) {
      order.add(uri);
      edits[uri] = [];
      versions[uri] = version;
    } else if (versions[uri] != version) {
      return 'The server sent edits for two versions of one file.';
    }
    edits[uri]!.addAll(parsed);
    return null;
  }

  final documentChanges = edit['documentChanges'];
  if (documentChanges is List<Object?>) {
    for (final change in documentChanges) {
      if (change is! Map<String, Object?>) {
        return (files: const [], problem: 'The server sent a malformed edit.');
      }
      if (change.containsKey('kind')) {
        // CreateFile, RenameFile, DeleteFile.
        return (
          files: const [],
          problem:
              'This rename would also create, rename or delete files, which '
              'CodeForge does not do yet.',
        );
      }
      final document = change['textDocument'];
      final uri = document is Map<String, Object?> ? document['uri'] : null;
      if (uri is! String) {
        return (files: const [], problem: 'The server sent a malformed edit.');
      }
      final version = document is Map<String, Object?>
          ? document['version']
          : null;
      final problem = add(
        uri,
        change['edits'],
        version is int ? version : null,
      );
      if (problem != null) {
        return (files: const [], problem: problem);
      }
    }
  } else {
    final changes = edit['changes'];
    if (changes is Map<String, Object?>) {
      for (final MapEntry(key: uri, value: list) in changes.entries) {
        final problem = add(uri, list, null);
        if (problem != null) {
          return (files: const [], problem: problem);
        }
      }
    } else if (changes != null) {
      return (files: const [], problem: 'The server sent a malformed edit.');
    }
  }
  return (
    files: [
      for (final uri in order)
        if (edits[uri]!.isNotEmpty)
          FileTextEdits(uri, edits[uri]!, version: versions[uri]),
    ],
    problem: null,
  );
}

/// Why a file's edits could not be applied.
enum EditProblem {
  /// An edit lies outside the text.
  outside,

  /// Two edits overlap.
  overlapping,

  /// A replaced span is not what the rename expected (the old name).
  changed,
}

/// One edit as offsets into the text it applies to.
typedef OffsetEdit = ({int from, int to, String insert});

/// [text] with [edits] applied: the new text and the edits as offsets,
/// sorted; or the problem that stops them. With [expected] (a rename's old
/// name), every replaced span must be exactly that.
({String? text, List<OffsetEdit> offsets, EditProblem? problem}) applyTextEdits(
  String text,
  List<LspTextEdit> edits, {
  String? expected,
}) {
  final index = LineIndex(text);
  final offsets = <({int order, OffsetEdit edit})>[];
  for (var i = 0; i < edits.length; i++) {
    final edit = edits[i];
    final from = index.exactOffsetAt(edit.range.start);
    final to = index.exactOffsetAt(edit.range.end);
    if (from == null || to == null || to < from) {
      return (text: null, offsets: const [], problem: EditProblem.outside);
    }
    if (expected != null && text.substring(from, to) != expected) {
      return (text: null, offsets: const [], problem: EditProblem.changed);
    }
    final insert = edit.newText.contains('\r')
        ? edit.newText.replaceAll('\r\n', '\n').replaceAll('\r', '\n')
        : edit.newText;
    offsets.add((order: i, edit: (from: from, to: to, insert: insert)));
  }
  // LSP: edits that start at the same place apply in the order sent.
  offsets.sort((a, b) {
    final byStart = a.edit.from.compareTo(b.edit.from);
    return byStart != 0 ? byStart : a.order.compareTo(b.order);
  });
  final out = StringBuffer();
  var at = 0;
  for (final (order: _, :edit) in offsets) {
    if (edit.from < at) {
      return (text: null, offsets: const [], problem: EditProblem.overlapping);
    }
    out
      ..write(text.substring(at, edit.from))
      ..write(edit.insert);
    at = edit.to;
  }
  out.write(text.substring(at));
  return (
    text: out.toString(),
    offsets: [for (final entry in offsets) entry.edit],
    problem: null,
  );
}
