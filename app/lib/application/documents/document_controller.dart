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
///
/// Nothing typed is lost when the process dies (ADR-0008,
/// docs/EDITOR_ARCHITECTURE.md §7): a dirty document's edits reach the
/// hot-exit journal as they arrive (document_journal.dart), the tabs and
/// their cursor and scroll reach the session store, and [restoreTabs]
/// reopens both on the next start. A restored document whose file changed
/// meanwhile keeps both texts until the user picks one
/// ([OpenDocument.conflict]).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/editor/journal.dart';
import '../../core/editor/languages.dart';
import '../../core/editor/shadow_document.dart';
import '../../core/errors/failure.dart';
import '../../core/files/file_stamp.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_path.dart';
import '../../core/logging/logger.dart';
import '../../services/contracts.dart';
import '../../services/files/demo_workspace.dart';
import '../../services/storage/session_store.dart';
import '../editor/editor_host.dart';
import '../editor/editor_providers.dart';
import '../providers.dart';
import '../shell_controller.dart';
import '../workspace_controller.dart';
import 'document_journal.dart';
import 'document_state.dart';

final class DocumentController extends Notifier<DocumentsState> {
  /// How long cursor and scroll reports gather before the tabs are saved.
  static const Duration viewStateSaveDelay = Duration(seconds: 1);

  int _nextDocId = 0;
  bool _restored = false;
  bool _restoring = false;
  final Map<String, Future<Result<void>>> _opening = {};
  final Map<String, Future<Result<void>>> _saving = {};
  late DocumentJournal _journal;
  Timer? _tabSave;

  @override
  DocumentsState build() {
    // Not auto-disposed: tabs survive navigation to Settings and back.
    final subscription = ref
        .watch(editorHostProvider)
        .events
        .listen(_onEditorEvent);
    final journal = DocumentJournal(
      store: ref.read(sessionStoreProvider),
      describe: _describe,
      onWrite: _onJournalWrite,
    );
    _journal = journal;
    ref.onDispose(() {
      unawaited(subscription.cancel());
      journal.dispose();
      _tabSave?.cancel();
      _tabSave = null;
    });
    return const DocumentsState();
  }

  EditorHost get _host => ref.read(editorHostProvider);

  FileService get _files => ref.read(fileServiceProvider);

  SessionStore get _store => ref.read(sessionStoreProvider);

  /// The open workspace's id; the built-in workspace's before one opened.
  String get _workspaceId =>
      ref.read(workspaceControllerProvider).workspace?.id ?? DemoWorkspace.id;

  /// Completes when every journal and tab write asked for so far is
  /// stored.
  Future<void> get persisted => _journal.idle;

  /// Opens [path] in a new tab, or activates its tab when it is open. With
  /// [background] the tab opens behind the active one (restoring a session),
  /// with [view]'s cursor and scroll when given.
  Future<Result<void>> open(
    String path, {
    bool background = false,
    SavedTab? view,
  }) async {
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
    final opening = _open(path, background: background, view: view);
    _opening[path] = opening;
    try {
      return await opening;
    } finally {
      // Already complete: it was awaited just above.
      unawaited(_opening.remove(path));
    }
  }

  Future<Result<void>> _open(
    String path, {
    required bool background,
    SavedTab? view,
  }) async {
    switch (await _files.readText(path)) {
      case Ok<TextFile>(:final value):
        _openFile(path, value, background: background, view: view);
        return const Ok(null);
      case Err<TextFile>(:final failure):
        appLogger.warn(
          'documents',
          'open_failed',
          fields: {'path': path, 'error': failure.message},
        );
        return Err(failure);
    }
  }

  void _openFile(
    String path,
    TextFile file, {
    required bool background,
    SavedTab? view,
  }) {
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
    _addTab(doc, background: background);
    unawaited(
      _report(
        'editor_open_failed',
        path,
        _host.openDocument(
          docId: doc.docId,
          text: doc.savedText,
          language: doc.language,
          activate: !background,
          selection: _selectionOf(view),
          scrollTop: view?.scrollTop ?? 0,
        ),
      ),
    );
  }

  void _addTab(OpenDocument doc, {required bool background}) {
    final path = doc.path;
    state = state.copyWith(
      openPaths: [...state.openPaths, path],
      documents: {...state.documents, path: doc},
      activePath: background ? state.activePath : path,
      recent: background ? [path, ...state.recent] : [...state.recent, path],
    );
    _saveTabs();
  }

  /// Shows [path]'s tab in the editor.
  void activate(String path) {
    final doc = state.documents[path];
    if (doc == null) {
      return;
    }
    if (state.activePath != path) {
      final previous = state.active;
      if (previous != null) {
        // A tab switch is a quiet moment for a fresh snapshot.
        _journal.checkpoint(previous.docId);
      }
      state = state.copyWith(
        activePath: path,
        recent: [...state.recent.where((p) => p != path), path],
      );
      _saveTabs();
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
    // Saved, or the user chose to drop the changes: either way, done.
    _journal.discard(doc.docId);
    final documents = {...state.documents}..remove(path);
    final recent = [...state.recent.where((p) => p != path)];
    final wasActive = state.activePath == path;
    final fallback = wasActive ? recent.lastOrNull : state.activePath;
    state = state.copyWith(
      openPaths: [...state.openPaths.where((p) => p != path)],
      documents: documents,
      activePath: fallback,
      recent: recent,
    );
    _saveTabs();
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
        // Already complete: it was awaited just above.
        unawaited(_saving.remove(path));
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
          // the tab stays dirty and says so, and its journal starts over
          // against what is on disk now.
          final dirty = _differs(doc.docId, text);
          _replace(
            current.copyWith(
              savedText: text,
              stamp: value,
              mixedLineEndings: false,
              dirty: dirty,
              clearConflict: true,
            ),
          );
          _journal.rebase(doc.docId, dirty: dirty);
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
      clearConflict: true,
    );
    String rename(String p) => p == path ? newPath : p;
    final active = state.activePath;
    state = state.copyWith(
      openPaths: [for (final p in state.openPaths) rename(p)],
      documents: {
        for (final entry in state.documents.entries)
          rename(entry.key): entry.key == path ? moved : entry.value,
      },
      activePath: active == null ? null : rename(active),
      recent: [for (final p in state.recent) rename(p)],
    );
    _saveTabs();
    // The journal follows the new name, or goes when nothing is unsaved.
    _journal.rebase(doc.docId, dirty: moved.dirty);
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
    final created = await _files.writeText(path, '', mode: WriteMode.createNew);
    if (created case Err<FileStamp>(:final failure)) {
      return Err(failure);
    }
    appLogger.info('documents', 'created', fields: {'path': path});
    unawaited(ref.read(workspaceControllerProvider.notifier).refresh());
    return open(path);
  }

  /// Reopens the last session once per app run: its tabs, in order, with
  /// their cursor and scroll, and every document that had unsaved changes,
  /// with those changes — or opens [fallback] when there was nothing to
  /// reopen. Files that are gone or unreadable are skipped, unless they had
  /// unsaved changes: those reopen with the changes, and the user decides
  /// what to keep ([OpenDocument.conflict]).
  Future<void> restoreTabs({String? fallback}) async {
    if (_restored) {
      return;
    }
    _restored = true;
    final store = _store;
    final workspaceId = _workspaceId;
    final workspace = ref.read(workspaceControllerProvider).workspace;
    if (workspace != null) {
      _journal.enqueue(
        () => store.touchWorkspace(workspace.id, name: workspace.displayName),
      );
    }
    var tabs = switch (await store.loadTabs(workspaceId)) {
      Ok<List<SavedTab>>(:final value) => value,
      Err<List<SavedTab>>() => const <SavedTab>[],
    };
    if (!ref.mounted) {
      return;
    }
    if (tabs.isEmpty) {
      tabs = _importShellTabs();
    }
    final journal = switch (await store.loadJournal(workspaceId)) {
      Ok<List<JournalEntry>>(:final value) => value,
      Err<List<JournalEntry>>() => const <JournalEntry>[],
    };
    if (!ref.mounted) {
      return;
    }
    final views = {for (final tab in tabs) tab.path: tab};
    final journaled = {for (final entry in journal) entry.path: entry};
    // Unsaved changes reopen even when their tab was not saved.
    final paths = [
      ...views.keys,
      for (final entry in journal)
        if (!views.containsKey(entry.path)) entry.path,
    ];
    _restoring = true;
    try {
      for (final path in paths) {
        final entry = journaled[path];
        if (entry == null) {
          await open(path, background: true, view: views[path]);
        } else {
          await _reopenJournaled(entry, views[path]);
        }
        if (!ref.mounted) {
          return;
        }
      }
    } finally {
      _restoring = false;
    }
    final active = tabs.where((tab) => tab.active).firstOrNull?.path;
    if (active != null && state.isOpen(active)) {
      activate(active);
    } else if (state.openPaths.isNotEmpty) {
      activate(state.openPaths.first);
    } else if (fallback != null) {
      await open(fallback);
    }
    if (!ref.mounted) {
      return;
    }
    _saveTabs();
    appLogger.info(
      'documents',
      'tabs_restored',
      fields: {
        'asked': paths.length,
        'open': state.openPaths.length,
        'journaled': journal.length,
      },
    );
  }

  /// Before the app may be killed (it went to the background): takes the
  /// editor's pending edits, snapshots every journal with changes since its
  /// last snapshot, and saves the tabs with their cursor and scroll.
  /// Completes when all of it is stored.
  Future<void> checkpoint() async {
    await _host.flush();
    if (!ref.mounted) {
      return;
    }
    _journal.checkpoint();
    _saveTabs();
    await _journal.idle;
  }

  /// Settles [path]'s conflict for the restored changes: the document stays
  /// as restored, unsaved, and the next save writes it over the file.
  void keepRestoredEdits(String path) {
    final doc = state.documents[path];
    if (doc == null || doc.conflict == null) {
      return;
    }
    _replace(doc.copyWith(clearConflict: true));
    _journal.rebase(doc.docId, dirty: doc.dirty);
    appLogger.info('documents', 'conflict_kept_edits', fields: {'path': path});
  }

  /// Settles [path]'s conflict for the file: the restored changes go and
  /// the document shows the file as it is now. A file that is gone, or can
  /// no longer be read, closes instead.
  Future<Result<void>> useDiskVersion(String path) async {
    final doc = state.documents[path];
    if (doc == null || doc.conflict == null) {
      return const Ok(null);
    }
    final read = await _files.readText(path);
    final current = state.documents[path];
    if (!ref.mounted || current == null || current.docId != doc.docId) {
      return const Ok(null);
    }
    switch (read) {
      case Err<TextFile>():
        appLogger.info(
          'documents',
          'conflict_closed',
          fields: {'path': path},
        );
        close(path);
        return const Ok(null);
      case Ok<TextFile>(:final value):
        appLogger.info(
          'documents',
          'conflict_used_disk',
          fields: {'path': path},
        );
        _replace(
          current.copyWith(
            format: value.format,
            savedText: value.text,
            stamp: value.stamp,
            mixedLineEndings: value.mixedLineEndings,
            clearConflict: true,
          ),
        );
        // The editor reports the new text back: the tab turns clean and
        // its journal goes.
        return _host.replaceText(doc.docId, value.text);
    }
  }

  /// Reopens a document from its journal: the replayed text in the editor,
  /// the file's text as the saved text, and a conflict when the file is
  /// not what the edits were made against.
  Future<void> _reopenJournaled(JournalEntry entry, SavedTab? view) async {
    final path = entry.path;
    final snapshot = entry.snapshot;
    final replay = replayJournal(
      text: snapshot.text,
      version: snapshot.version,
      changes: entry.changes,
    );
    if (replay.problem != null) {
      appLogger.error(
        'documents',
        'journal_replay_stopped',
        fields: {
          'path': path,
          'applied': replay.applied,
          'problem': replay.problem,
        },
      );
    }
    final read = await _files.readText(path);
    if (!ref.mounted || state.isOpen(path)) {
      return;
    }
    var savedText = '';
    FileStamp? stamp;
    var mixedLineEndings = false;
    DocumentConflict? conflict;
    switch (read) {
      case Ok<TextFile>(:final value):
        if (value.text == replay.text) {
          // Back to the saved text before the app died: nothing to keep.
          _journal.discardStored(snapshot.workspaceId, path);
          _openFile(path, value, background: true, view: view);
          return;
        }
        savedText = value.text;
        stamp = value.stamp;
        mixedLineEndings = value.mixedLineEndings;
        if (snapshot.baseDigest != textDigest(value.text)) {
          conflict = DocumentConflict.changedOnDisk;
        }
      case Err<TextFile>(:final failure):
        final gone =
            failure is FileFailure && failure.problem == FileProblem.notFound;
        if (!gone) {
          conflict = DocumentConflict.unreadable;
        } else if (snapshot.baseDigest != null) {
          conflict = DocumentConflict.deleted;
        }
    }
    _nextDocId += 1;
    final doc = OpenDocument(
      path: path,
      docId: 'd$_nextDocId',
      language: snapshot.language,
      format: snapshot.format,
      savedText: savedText,
      stamp: stamp,
      dirty: replay.text != savedText,
      mixedLineEndings: mixedLineEndings,
      conflict: conflict,
    );
    _addTab(doc, background: true);
    // Registers the document at once (the page hears about it when ready),
    // so the journal can rewrite itself from the replayed text right away.
    final opened = _host.openDocument(
      docId: doc.docId,
      text: replay.text,
      language: doc.language,
      activate: false,
      version: replay.version,
      selection: _selectionOf(view),
      scrollTop: view?.scrollTop ?? 0,
    );
    _journal.adopt(doc.docId, baseDigest: snapshot.baseDigest);
    unawaited(_report('editor_open_failed', path, opened));
    appLogger.info(
      'documents',
      'unsaved_restored',
      fields: {
        'path': path,
        'changes': replay.applied,
        'conflict': conflict?.name,
      },
    );
  }

  /// The tabs a Phase 2 W4 build kept in the shell envelope, moved to the
  /// session store once (docs/ARCHITECTURE.md §2.5, migration notes).
  List<SavedTab> _importShellTabs() {
    final shell = ref.read(shellControllerProvider);
    if (shell.openTabs.isEmpty) {
      return const [];
    }
    final tabs = [
      for (final path in shell.openTabs)
        SavedTab(path: path, active: path == shell.activeTab),
    ];
    ref.read(shellControllerProvider.notifier).setOpenTabs(const [], null);
    appLogger.info(
      'documents',
      'tabs_imported',
      fields: {'count': tabs.length},
    );
    return tabs;
  }

  void _onEditorEvent(EditorHostEvent event) {
    if (event is DocumentEdited) {
      _onDocumentEdited(event);
    } else if (event is ViewStateChanged) {
      _scheduleTabSave();
    }
  }

  void _onDocumentEdited(DocumentEdited event) {
    final doc = _byDocId(event.docId);
    if (doc == null) {
      return;
    }
    final dirty = _differs(event.docId, doc.savedText);
    if (dirty != doc.dirty) {
      _replace(doc.copyWith(dirty: dirty));
    }
    _journal.edited(event.docId, dirty: dirty, change: event.change);
  }

  OpenDocument? _byDocId(String docId) {
    for (final doc in state.documents.values) {
      if (doc.docId == docId) {
        return doc;
      }
    }
    return null;
  }

  JournalSubject? _describe(String docId) {
    final doc = _byDocId(docId);
    final text = _host.textOf(docId);
    final version = _host.versionOf(docId);
    if (doc == null || text == null || version == null) {
      return null;
    }
    return JournalSubject(
      workspaceId: _workspaceId,
      path: doc.path,
      savedText: doc.savedText,
      hasFile: doc.stamp != null,
      format: doc.format,
      language: doc.language,
      text: text,
      version: version,
    );
  }

  void _onJournalWrite(Result<void> result) {
    if (!ref.mounted) {
      return;
    }
    final problem = switch (result) {
      Ok<void>() => null,
      Err<void>(:final failure) => failure.message,
    };
    if (problem != state.journalProblem) {
      state = state.copyWith(journalProblem: problem);
    }
  }

  /// Whether the editor's text for [docId] differs from [saved]. Lengths
  /// first: typing changes them, and only equal lengths need a full look.
  bool _differs(String docId, String saved) {
    final live = _host.textOf(docId);
    return live != null && (live.length != saved.length || live != saved);
  }

  void _replace(OpenDocument doc) {
    state = state.copyWith(documents: {...state.documents, doc.path: doc});
  }

  /// Saves the tabs, in order, with each one's cursor and scroll.
  void _saveTabs() {
    if (_restoring) {
      return;
    }
    _tabSave?.cancel();
    _tabSave = null;
    final store = _store;
    final workspaceId = _workspaceId;
    final active = state.activePath;
    final tabs = [
      for (final path in state.openPaths)
        if (state.documents[path] case final doc?)
          _savedTab(doc, active: path == active),
    ];
    _journal.enqueue(() => store.saveTabs(workspaceId, tabs));
  }

  SavedTab _savedTab(OpenDocument doc, {required bool active}) {
    final view = _host.viewStateOf(doc.docId);
    final selection = view?.selection;
    return SavedTab(
      path: doc.path,
      active: active,
      selectionAnchor: selection?.anchor,
      selectionHead: selection?.head,
      scrollTop: view?.scrollTop ?? 0,
    );
  }

  /// Cursor and scroll reports come in bursts: one save covers a burst.
  void _scheduleTabSave() {
    if (_restoring || _tabSave != null) {
      return;
    }
    _tabSave = Timer(viewStateSaveDelay, _saveTabs);
  }

  static EditorSelection? _selectionOf(SavedTab? tab) {
    final anchor = tab?.selectionAnchor;
    final head = tab?.selectionHead;
    return anchor == null || head == null
        ? null
        : EditorSelection(anchor: anchor, head: head);
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
