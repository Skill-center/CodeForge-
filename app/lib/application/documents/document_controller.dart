/// Open documents and their tabs (docs/EDITOR_ARCHITECTURE.md, "Documents
/// and tabs").
///
/// One [OpenDocument] per tab, keyed by workspace path. The editor host's
/// shadow holds each document's live text, kept up to date from the page's
/// change sets; this controller knows where that text came from (the file's
/// format and stamp) and what was last saved. "Dirty" is therefore a
/// comparison rather than a flag, so undoing back to the saved text makes a
/// tab clean again. Asking about unsaved changes is the workbench's job
/// (features/workbench/file_actions.dart): methods here do what they are
/// told.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/editor/languages.dart';
import '../../core/errors/failure.dart';
import '../../core/files/file_stamp.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_path.dart';
import '../../core/logging/logger.dart';
import '../../services/contracts.dart';
import '../editor/editor_host.dart';
import '../editor/editor_providers.dart';
import '../providers.dart';
import '../shell_controller.dart';
import '../workspace_controller.dart';
import 'document_state.dart';

final class DocumentController extends Notifier<DocumentsState> {
  int _nextDocId = 0;
  bool _restored = false;
  final Map<String, Future<Result<void>>> _opening = {};
  final Map<String, Future<Result<void>>> _saving = {};

  @override
  DocumentsState build() {
    // Not auto-disposed: tabs survive navigation to Settings and back.
    final subscription = ref
        .watch(editorHostProvider)
        .events
        .listen(_onEditorEvent);
    ref.onDispose(() => unawaited(subscription.cancel()));
    return const DocumentsState();
  }

  EditorHost get _host => ref.read(editorHostProvider);

  FileService get _files => ref.read(fileServiceProvider);

  /// Opens [path] in a new tab, or activates its tab when it is open. With
  /// [background] the tab opens behind the active one (restoring a session).
  Future<Result<void>> open(String path, {bool background = false}) async {
    if (state.isOpen(path)) {
      if (!background) {
        activate(path);
      }
      return const Ok(null);
    }
    final pending = _opening[path];
    if (pending != null) {
      // Opened twice at once (a double tap): share the first attempt.
      final result = await pending;
      if (!background && state.isOpen(path)) {
        activate(path);
      }
      return result;
    }
    final opening = _open(path, background: background);
    _opening[path] = opening;
    try {
      return await opening;
    } finally {
      _opening.remove(path);
    }
  }

  Future<Result<void>> _open(String path, {required bool background}) async {
    final TextFile file;
    switch (await _files.readText(path)) {
      case Ok<TextFile>(:final value):
        file = value;
      case Err<TextFile>(:final failure):
        appLogger.warn(
          'documents',
          'open_failed',
          fields: {'path': path, 'error': failure.message},
        );
        return Err(failure);
    }
    _nextDocId += 1;
    final doc = OpenDocument(
      path: path,
      docId: 'd$_nextDocId',
      language: languageForPath(path, firstLine: firstLineOf(file.text)),
      format: file.format,
      savedText: file.text,
      stamp: file.stamp,
      mixedLineEndings: file.mixedLineEndings,
    );
    state = DocumentsState(
      openPaths: [...state.openPaths, path],
      documents: {...state.documents, path: doc},
      activePath: background ? state.activePath : path,
      recent: background ? [path, ...state.recent] : [...state.recent, path],
    );
    _rememberTabs();
    unawaited(
      _report(
        'editor_open_failed',
        path,
        _host.openDocument(
          docId: doc.docId,
          text: doc.savedText,
          language: doc.language,
          activate: !background,
        ),
      ),
    );
    return const Ok(null);
  }

  /// Shows [path]'s tab in the editor.
  void activate(String path) {
    final doc = state.documents[path];
    if (doc == null) {
      return;
    }
    if (state.activePath != path) {
      state = DocumentsState(
        openPaths: state.openPaths,
        documents: state.documents,
        activePath: path,
        recent: [...state.recent.where((p) => p != path), path],
      );
      _rememberTabs();
    }
    if (_host.activeDocId != doc.docId) {
      unawaited(
        _report('editor_activate_failed', path, _host.activate(doc.docId)),
      );
    }
  }

  /// Activates the tab after (or with [forward] false, before) the active
  /// one, wrapping around.
  void activateNeighbour({required bool forward}) {
    final paths = state.openPaths;
    final active = state.activePath;
    if (paths.length < 2 || active == null) {
      return;
    }
    final index = paths.indexOf(active);
    activate(paths[(index + (forward ? 1 : -1)) % paths.length]);
  }

  /// Closes [path]'s tab, unsaved changes included: callers ask first. The
  /// active tab falls back to the most recently used other tab.
  void close(String path) {
    final doc = state.documents[path];
    if (doc == null) {
      return;
    }
    final documents = {...state.documents}..remove(path);
    final recent = [...state.recent.where((p) => p != path)];
    final wasActive = state.activePath == path;
    final fallback = wasActive ? recent.lastOrNull : state.activePath;
    state = DocumentsState(
      openPaths: [...state.openPaths.where((p) => p != path)],
      documents: documents,
      activePath: fallback,
      recent: recent,
    );
    _rememberTabs();
    // Close before activating the fallback: the page sees them in order.
    unawaited(
      _report('editor_close_failed', path, _host.closeDocument(doc.docId)),
    );
    final next = fallback == null ? null : documents[fallback];
    if (wasActive && next != null && fallback != null) {
      unawaited(
        _report('editor_activate_failed', fallback, _host.activate(next.docId)),
      );
    }
  }

  /// Saves [path]: the editor's text, pending edits flushed first, written
  /// atomically in the file's own format. A file that changed on disk since
  /// it was read is not overwritten unless [overwrite] is set; the failure's
  /// problem is then [FileProblem.changedOnDisk] and the caller asks.
  Future<Result<void>> save(String path, {bool overwrite = false}) async {
    // One save per file at a time, in the order they were asked for.
    final previous = _saving[path];
    if (previous != null) {
      await previous;
    }
    final saving = _save(path, overwrite: overwrite);
    _saving[path] = saving;
    try {
      return await saving;
    } finally {
      if (identical(_saving[path], saving)) {
        _saving.remove(path);
      }
    }
  }

  Future<Result<void>> _save(String path, {required bool overwrite}) async {
    final doc = state.documents[path];
    if (doc == null) {
      return Err(
        FileFailure('$path is not open.', problem: FileProblem.notFound),
      );
    }
    final String text;
    switch (await _host.snapshot(doc.docId)) {
      case Ok<EditorSnapshot>(:final value):
        text = value.text;
      case Err<EditorSnapshot>(:final failure):
        appLogger.warn(
          'documents',
          'save_failed',
          fields: {'path': path, 'error': failure.message},
        );
        return Err(failure);
    }
    final written = await _files.writeText(
      path,
      text,
      format: doc.format,
      expected: overwrite ? null : doc.stamp,
    );
    switch (written) {
      case Err<FileStamp>(:final failure):
        appLogger.warn(
          'documents',
          'save_failed',
          fields: {'path': path, 'error': failure.message},
        );
        return Err(failure);
      case Ok<FileStamp>(:final value):
        appLogger.info(
          'documents',
          'saved',
          fields: {'path': path, 'bytes': value.size},
        );
        final current = state.documents[path];
        if (current != null && current.docId == doc.docId) {
          // Typing that landed while the file was written is not on disk:
          // the tab stays dirty and says so.
          _replace(
            current.copyWith(
              savedText: text,
              stamp: value,
              mixedLineEndings: false,
              dirty: _differs(doc.docId, text),
            ),
          );
        }
        return const Ok(null);
    }
  }

  /// Saves [path]'s document as [newPath] and moves its tab there; the
  /// original file stays as it was. The document keeps its text, cursor
  /// and undo history, and is highlighted for its new name. Refuses a
  /// [newPath] open in another tab ([FileProblem.inUse]) and an existing
  /// file unless [overwrite] is set ([FileProblem.exists]: the caller asks).
  Future<Result<void>> saveAs(
    String path,
    String newPath, {
    bool overwrite = false,
  }) async {
    final invalid = workspacePathProblem(newPath);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    if (newPath == path) {
      return save(path, overwrite: overwrite);
    }
    final doc = state.documents[path];
    if (doc == null) {
      return Err(
        FileFailure('$path is not open.', problem: FileProblem.notFound),
      );
    }
    if (state.isOpen(newPath)) {
      return Err(
        FileFailure(
          '$newPath is open in another tab. Close it first.',
          problem: FileProblem.inUse,
        ),
      );
    }
    final String text;
    switch (await _host.snapshot(doc.docId)) {
      case Ok<EditorSnapshot>(:final value):
        text = value.text;
      case Err<EditorSnapshot>(:final failure):
        return Err(failure);
    }
    final written = await _files.writeText(
      newPath,
      text,
      format: doc.format,
      mode: overwrite ? WriteMode.replace : WriteMode.createNew,
    );
    final FileStamp stamp;
    switch (written) {
      case Ok<FileStamp>(:final value):
        stamp = value;
      case Err<FileStamp>(:final failure):
        appLogger.warn(
          'documents',
          'save_as_failed',
          fields: {'path': newPath, 'error': failure.message},
        );
        return Err(failure);
    }
    appLogger.info(
      'documents',
      'saved_as',
      fields: {'from': path, 'to': newPath},
    );
    unawaited(ref.read(workspaceControllerProvider.notifier).refresh());
    final current = state.documents[path];
    if (current == null ||
        current.docId != doc.docId ||
        state.isOpen(newPath)) {
      // Closed, or the new name opened in another tab, while saving: the
      // file is written, and the tabs stay as they are.
      return const Ok(null);
    }
    final language = languageForPath(newPath, firstLine: firstLineOf(text));
    final moved = current.copyWith(
      path: newPath,
      language: language,
      savedText: text,
      stamp: stamp,
      mixedLineEndings: false,
      dirty: _differs(doc.docId, text),
    );
    String rename(String p) => p == path ? newPath : p;
    final active = state.activePath;
    state = DocumentsState(
      openPaths: [for (final p in state.openPaths) rename(p)],
      documents: {
        for (final entry in state.documents.entries)
          rename(entry.key): entry.key == path ? moved : entry.value,
      },
      activePath: active == null ? null : rename(active),
      recent: [for (final p in state.recent) rename(p)],
    );
    _rememberTabs();
    if (language != current.language) {
      unawaited(
        _report(
          'editor_language_failed',
          newPath,
          _host.setLanguage(doc.docId, language),
        ),
      );
    }
    return const Ok(null);
  }

  /// Creates an empty file at [path] and opens it. Refuses a path where
  /// something exists ([FileProblem.exists]).
  Future<Result<void>> createFile(String path) async {
    final invalid = workspacePathProblem(path);
    if (invalid != null) {
      return Err(FileFailure(invalid, problem: FileProblem.invalidPath));
    }
    final created = await _files.writeText(
      path,
      '',
      mode: WriteMode.createNew,
    );
    if (created case Err<FileStamp>(:final failure)) {
      return Err(failure);
    }
    appLogger.info('documents', 'created', fields: {'path': path});
    unawaited(ref.read(workspaceControllerProvider.notifier).refresh());
    return open(path);
  }

  /// Reopens the last session's tabs once per app run, or opens [fallback]
  /// when there were none. Files that are gone or unreadable are skipped.
  Future<void> restoreTabs({String? fallback}) async {
    if (_restored) {
      return;
    }
    _restored = true;
    final shell = ref.read(shellControllerProvider);
    final active = shell.activeTab;
    for (final path in shell.openTabs) {
      await open(path, background: true);
    }
    if (active != null && state.isOpen(active)) {
      activate(active);
    } else if (state.openPaths.isNotEmpty) {
      activate(state.openPaths.first);
    } else if (fallback != null) {
      await open(fallback);
    }
    appLogger.info(
      'documents',
      'tabs_restored',
      fields: {'asked': shell.openTabs.length, 'open': state.openPaths.length},
    );
  }

  void _onEditorEvent(EditorHostEvent event) {
    if (event is DocumentEdited) {
      _onDocumentEdited(event.docId);
    }
  }

  void _onDocumentEdited(String docId) {
    for (final doc in state.documents.values) {
      if (doc.docId == docId) {
        final dirty = _differs(docId, doc.savedText);
        if (dirty != doc.dirty) {
          _replace(doc.copyWith(dirty: dirty));
        }
        return;
      }
    }
  }

  /// Whether the editor's text for [docId] differs from [saved]. Lengths
  /// first: typing changes them, and only equal lengths need a full look.
  bool _differs(String docId, String saved) {
    final live = _host.textOf(docId);
    return live != null && (live.length != saved.length || live != saved);
  }

  void _replace(OpenDocument doc) {
    state = DocumentsState(
      openPaths: state.openPaths,
      documents: {...state.documents, doc.path: doc},
      activePath: state.activePath,
      recent: state.recent,
    );
  }

  void _rememberTabs() {
    ref
        .read(shellControllerProvider.notifier)
        .setOpenTabs(state.openPaths, state.activePath);
  }

  Future<void> _report(
    String event,
    String path,
    Future<Result<void>> pending,
  ) async {
    if (await pending case Err<void>(:final failure)) {
      appLogger.warn(
        'documents',
        event,
        fields: {'path': path, 'error': failure.message},
      );
    }
  }
}

final documentControllerProvider =
    NotifierProvider<DocumentController, DocumentsState>(
      DocumentController.new,
    );
