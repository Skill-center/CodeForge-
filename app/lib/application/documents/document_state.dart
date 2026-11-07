/// State of the open documents and their tabs.
library;

import '../../core/files/file_stamp.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_path.dart';

/// One open document: where its text came from and what was last saved.
/// The live text is in the editor host's shadow, under [docId].
final class OpenDocument {
  const OpenDocument({
    required this.path,
    required this.docId,
    required this.language,
    required this.format,
    required this.savedText,
    required this.stamp,
    this.dirty = false,
    this.mixedLineEndings = false,
    this.conflict,
  });

  /// Workspace-relative path.
  final String path;

  /// The editor's id for it (`d1`, `d2`, …), stable for the tab's life,
  /// even across Save As.
  final String docId;

  /// One of `editorLanguageIds`.
  final String language;

  /// Line endings and byte-order mark the file is written back with.
  final TextFormat format;

  /// The text on disk as of the last read or save, "\n" line breaks.
  final String savedText;

  /// The file's stamp as of the last read or save; null when there is no
  /// file (it was deleted while the document had unsaved changes). Saving
  /// then creates it again.
  final FileStamp? stamp;

  /// The editor's text differs from [savedText]. Undoing back to the saved
  /// text makes the document clean again.
  final bool dirty;

  /// The file mixed line-ending styles when it was read; the next save
  /// writes [format]'s style throughout.
  final bool mixedLineEndings;

  /// Set when unsaved changes restored from the hot-exit journal no longer
  /// match the file: the user decides which to keep (the workbench asks).
  /// Both stay as they are until then.
  final DocumentConflict? conflict;

  /// The tab label.
  String get name => pathBaseName(path);

  OpenDocument copyWith({
    String? path,
    String? language,
    TextFormat? format,
    String? savedText,
    FileStamp? stamp,
    bool? dirty,
    bool? mixedLineEndings,
    bool clearConflict = false,
  }) {
    return OpenDocument(
      path: path ?? this.path,
      docId: docId,
      language: language ?? this.language,
      format: format ?? this.format,
      savedText: savedText ?? this.savedText,
      stamp: stamp ?? this.stamp,
      dirty: dirty ?? this.dirty,
      mixedLineEndings: mixedLineEndings ?? this.mixedLineEndings,
      conflict: clearConflict ? null : conflict,
    );
  }
}

/// How restored unsaved changes disagree with the file.
enum DocumentConflict {
  /// The file changed on disk after the edits were made.
  changedOnDisk,

  /// The file is gone.
  deleted,

  /// The file can no longer be read as text.
  unreadable,
}

/// All open documents. Every open path has one tab, one document and one
/// place in [recent].
final class DocumentsState {
  const DocumentsState({
    this.openPaths = const [],
    this.activePath,
    this.documents = const {},
    this.recent = const [],
    this.journalProblem,
  });

  /// Tab order.
  final List<String> openPaths;

  /// The tab showing in the editor, or null when none is.
  final String? activePath;

  final Map<String, OpenDocument> documents;

  /// Open paths from least to most recently active: closing the active tab
  /// falls back to the one used before it.
  final List<String> recent;

  /// Why unsaved changes are not reaching the hot-exit journal, while they
  /// are not: the editor pane says so, because a crash would lose them.
  final String? journalProblem;

  static const Object _unchanged = Object();

  DocumentsState copyWith({
    List<String>? openPaths,
    Object? activePath = _unchanged,
    Map<String, OpenDocument>? documents,
    List<String>? recent,
    Object? journalProblem = _unchanged,
  }) {
    return DocumentsState(
      openPaths: openPaths ?? this.openPaths,
      activePath: identical(activePath, _unchanged)
          ? this.activePath
          : activePath as String?,
      documents: documents ?? this.documents,
      recent: recent ?? this.recent,
      journalProblem: identical(journalProblem, _unchanged)
          ? this.journalProblem
          : journalProblem as String?,
    );
  }

  OpenDocument? get active {
    final path = activePath;
    return path == null ? null : documents[path];
  }

  /// Open paths with unsaved changes, in tab order.
  List<String> get dirtyPaths => [
    for (final path in openPaths)
      if (documents[path]?.dirty ?? false) path,
  ];

  /// The first open path whose restored changes disagree with its file, in
  /// tab order.
  String? get firstConflict {
    for (final path in openPaths) {
      if (documents[path]?.conflict != null) {
        return path;
      }
    }
    return null;
  }

  bool isOpen(String path) => documents.containsKey(path);
}
