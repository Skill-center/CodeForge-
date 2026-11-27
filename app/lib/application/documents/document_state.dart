/// State of the open documents and their tabs.
library;

import '../../core/editor/shadow_document.dart';
import '../../core/files/file_stamp.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_path.dart';

/// A file as some commit left it (Phase 7 W5): a tab showing one is
/// read-only, has nothing to save and no file to watch, and is not
/// restored at the next start — the repository is where it lives.
final class DocumentRevision {
  const DocumentRevision({
    required this.filePath,
    required this.revision,
    required this.label,
  });

  /// The file's own workspace path. A revision tab is keyed by [tabKey],
  /// so it sits beside the tab of the file itself.
  final String filePath;

  /// What git was asked for: a commit's hash.
  final String revision;

  /// The revision as the user reads it: a short hash.
  final String label;

  /// The key its tab is open under.
  String get tabKey => tabKeyFor(filePath, revision);

  /// A revision tab's key: not a path any file has, so nothing that works
  /// on files touches it.
  static String tabKeyFor(String filePath, String revision) =>
      '$filePath@$revision';
}

/// The older text a document is shown against (Phase 7 W5,
/// docs/EDITOR_ARCHITECTURE.md §11). The texts themselves live in the
/// editor host's shadow; this is what the pane says about them.
final class DocumentDiff {
  const DocumentDiff({
    required this.against,
    required this.mode,
    this.chunks = 0,
    this.tooLarge = false,
  });

  /// What the document is being compared with, in words: 'the staged
  /// version', 'the last commit', 'the commit before it'.
  final String against;

  final EditorDiffMode mode;

  /// How many changes the editor found between the two texts.
  final int chunks;

  /// One of the texts is past [maxDiffChars]: nothing was compared, and
  /// the document is shown on its own.
  final bool tooLarge;
}

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
    this.largeFile = false,
    this.largeFileNotice = false,
    this.revision,
    this.diff,
  });

  /// Workspace-relative path, or for a revision tab its
  /// [DocumentRevision.tabKey].
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

  /// Set when unsaved changes no longer match the file: restored from the
  /// hot-exit journal after the file changed, or kept while the file
  /// changed outside the app (Phase 3 W5). The user decides which to keep
  /// (the workbench asks); both stay as they are until then. [savedText]
  /// and [stamp] already describe the file as it is now.
  final DocumentConflict? conflict;

  /// Opened as plain text because of its size (core/editor/large_files.dart)
  /// rather than for want of a language: highlighting stays off until the
  /// user switches it on.
  final bool largeFile;

  /// The banner saying what [largeFile] switched off is up, until the user
  /// dismisses it or switches highlighting on.
  final bool largeFileNotice;

  /// Set when the tab shows a file as a commit left it rather than the
  /// file itself (Phase 7 W5): read-only, and none of the file machinery
  /// applies to it.
  final DocumentRevision? revision;

  /// The older text the editor is showing this document against (Phase 7
  /// W5), or null when it is shown on its own.
  final DocumentDiff? diff;

  /// The tab label.
  String get name {
    final revision = this.revision;
    return revision == null
        ? pathBaseName(path)
        : '${pathBaseName(revision.filePath)} at ${revision.label}';
  }

  /// Nothing here can be typed into or saved: it is a commit's text.
  bool get readOnly => revision != null;

  /// There is no file behind it: it was deleted while the document had
  /// unsaved changes (from the explorer, Phase 3 W4, or before a restart).
  /// Save or Save As writes it again. A revision has no file by nature,
  /// which is not the same thing.
  bool get deletedOnDisk => stamp == null && revision == null;

  OpenDocument copyWith({
    String? path,
    String? language,
    TextFormat? format,
    String? savedText,
    FileStamp? stamp,
    bool? dirty,
    bool? mixedLineEndings,
    DocumentConflict? conflict,
    bool clearConflict = false,
    bool? largeFile,
    bool? largeFileNotice,
    DocumentDiff? diff,
    bool clearDiff = false,
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
      conflict: clearConflict ? null : conflict ?? this.conflict,
      largeFile: largeFile ?? this.largeFile,
      largeFileNotice: largeFileNotice ?? this.largeFileNotice,
      revision: revision,
      diff: clearDiff ? null : diff ?? this.diff,
    );
  }
}

/// How unsaved changes disagree with the file.
enum DocumentConflict {
  /// Restored changes: the file changed on disk after the edits were made.
  changedOnDisk,

  /// Restored changes: the file is gone.
  deleted,

  /// Restored changes: the file can no longer be read as text.
  unreadable,

  /// The file changed outside the app while the document had unsaved
  /// changes (Phase 3 W5). The editor pane asks, without a dialog, so
  /// typing can go on; saving first asks whether to overwrite.
  changedWhileOpen;

  /// Restored from the hot-exit journal: the workbench asks about these in
  /// a dialog when the workspace opens.
  bool get restored => this != changedWhileOpen;
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
      if (documents[path]?.conflict?.restored ?? false) {
        return path;
      }
    }
    return null;
  }

  bool isOpen(String path) => documents.containsKey(path);
}
