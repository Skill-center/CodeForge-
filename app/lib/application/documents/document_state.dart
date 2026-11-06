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

  /// The file's stamp as of the last read or save.
  final FileStamp stamp;

  /// The editor's text differs from [savedText]. Undoing back to the saved
  /// text makes the document clean again.
  final bool dirty;

  /// The file mixed line-ending styles when it was read; the next save
  /// writes [format]'s style throughout.
  final bool mixedLineEndings;

  /// The tab label.
  String get name => pathBaseName(path);

  OpenDocument copyWith({
    String? path,
    String? language,
    String? savedText,
    FileStamp? stamp,
    bool? dirty,
    bool? mixedLineEndings,
  }) {
    return OpenDocument(
      path: path ?? this.path,
      docId: docId,
      language: language ?? this.language,
      format: format,
      savedText: savedText ?? this.savedText,
      stamp: stamp ?? this.stamp,
      dirty: dirty ?? this.dirty,
      mixedLineEndings: mixedLineEndings ?? this.mixedLineEndings,
    );
  }
}

/// All open documents. Every open path has one tab, one document and one
/// place in [recent].
final class DocumentsState {
  const DocumentsState({
    this.openPaths = const [],
    this.activePath,
    this.documents = const {},
    this.recent = const [],
  });

  /// Tab order.
  final List<String> openPaths;

  /// The tab showing in the editor, or null when none is.
  final String? activePath;

  final Map<String, OpenDocument> documents;

  /// Open paths from least to most recently active: closing the active tab
  /// falls back to the one used before it.
  final List<String> recent;

  OpenDocument? get active {
    final path = activePath;
    return path == null ? null : documents[path];
  }

  /// Open paths with unsaved changes, in tab order.
  List<String> get dirtyPaths => [
    for (final path in openPaths)
      if (documents[path]?.dirty ?? false) path,
  ];

  bool isOpen(String path) => documents.containsKey(path);
}
