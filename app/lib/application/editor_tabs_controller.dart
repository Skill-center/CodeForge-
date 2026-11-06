/// Editor tabs over the demo workspace, wired to the editor host: opening a
/// tab opens the document in the editor page, edits there mark the tab
/// dirty, and save writes the editor's text through the file service.
///
/// Real files, new/save-as and close prompts arrive with Phase 2 W4; the
/// edit journal that survives process death with W5.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/editor/languages.dart';
import '../core/errors/failure.dart';
import '../core/logging/logger.dart';
import '../services/contracts.dart';
import 'editor/editor_host.dart';
import 'editor/editor_providers.dart';
import 'providers.dart';

@immutable
final class EditorTabsState {
  const EditorTabsState({
    this.openPaths = const [],
    this.activePath,
    this.documents = const {},
    this.docIds = const {},
  });

  final List<String> openPaths;
  final String? activePath;
  final Map<String, EditorDocument> documents;

  /// Path → the opaque id the editor knows the document by (protocol
  /// document ids cannot contain "/").
  final Map<String, String> docIds;

  EditorTabsState copyWith({
    List<String>? openPaths,
    String? activePath,
    Map<String, EditorDocument>? documents,
    Map<String, String>? docIds,
    bool clearActive = false,
  }) {
    return EditorTabsState(
      openPaths: openPaths ?? this.openPaths,
      activePath: clearActive ? null : (activePath ?? this.activePath),
      documents: documents ?? this.documents,
      docIds: docIds ?? this.docIds,
    );
  }
}

final class EditorTabsController extends Notifier<EditorTabsState> {
  int _nextDocId = 0;

  @override
  EditorTabsState build() {
    // Tabs survive navigation to Settings and back.
    ref.keepAlive();
    final subscription = ref
        .watch(editorHostProvider)
        .events
        .listen(_onEditorEvent);
    ref.onDispose(() => unawaited(subscription.cancel()));
    return const EditorTabsState();
  }

  EditorHost get _host => ref.read(editorHostProvider);

  Future<void> open(String path) async {
    if (state.openPaths.contains(path)) {
      activate(path);
      return;
    }
    final editor = ref.read(editorServiceProvider);
    final result = await editor.openDocument(path);
    switch (result) {
      case Ok<EditorDocument>(:final value):
        if (state.openPaths.contains(path)) {
          // Opened twice at once (a double tap): the first one won.
          activate(path);
          return;
        }
        _nextDocId += 1;
        final docId = 'd$_nextDocId';
        state = state.copyWith(
          openPaths: [...state.openPaths, path],
          activePath: path,
          documents: {...state.documents, path: value},
          docIds: {...state.docIds, path: docId},
        );
        _report(
          'editor_open_failed',
          path,
          await _host.openDocument(
            docId: docId,
            text: value.content,
            language: languageForPath(path),
          ),
        );
      case Err<EditorDocument>(:final failure):
        appLogger.warn(
          'editor',
          'open_failed',
          fields: {'path': path, 'error': failure.message},
        );
    }
  }

  void activate(String path) {
    if (!state.openPaths.contains(path)) {
      return;
    }
    state = state.copyWith(activePath: path);
    final docId = state.docIds[path];
    if (docId != null) {
      unawaited(_activateInEditor(docId, path));
    }
  }

  void close(String path) {
    if (!state.openPaths.contains(path)) {
      return;
    }
    final remaining = state.openPaths.where((p) => p != path).toList();
    final documents = Map.of(state.documents)..remove(path);
    final docIds = Map.of(state.docIds);
    final docId = docIds.remove(path);
    final wasActive = state.activePath == path;
    state = state.copyWith(
      openPaths: remaining,
      documents: documents,
      docIds: docIds,
      activePath: wasActive ? null : state.activePath,
      clearActive: wasActive && remaining.isEmpty,
    );
    // Close before activating the fallback: the page sees them in order.
    if (docId != null) {
      unawaited(_closeInEditor(docId, path));
    }
    if (wasActive && remaining.isNotEmpty) {
      activate(remaining.last);
    }
  }

  /// Saves the active document: the editor's text, pending edits flushed,
  /// written through the file service.
  Future<void> saveActive() async {
    final path = state.activePath;
    if (path == null) {
      return;
    }
    final editor = ref.read(editorServiceProvider);
    final docId = state.docIds[path];
    if (docId != null) {
      final snapshot = await _host.snapshot(docId);
      switch (snapshot) {
        case Ok<EditorSnapshot>(:final value):
          editor.updateContent(path, value.text);
        case Err<EditorSnapshot>(:final failure):
          appLogger.warn(
            'editor',
            'save_failed',
            fields: {'path': path, 'error': failure.message},
          );
          return;
      }
    }
    final result = await editor.saveDocument(path);
    switch (result) {
      case Ok<void>():
        appLogger.info('editor', 'saved', fields: {'path': path});
        final saved = editor.document(path);
        if (saved == null || !state.openPaths.contains(path)) {
          return;
        }
        // Typing that landed while the file was written is not on disk:
        // it stays unsaved, and the tab says so.
        final latest = docId == null ? null : _host.textOf(docId);
        final doc = latest != null && latest != saved.content
            ? saved.copyWith(content: latest, dirty: true)
            : saved;
        if (!identical(doc, saved)) {
          editor.updateContent(path, doc.content);
        }
        state = state.copyWith(documents: {...state.documents, path: doc});
      case Err<void>(:final failure):
        appLogger.warn(
          'editor',
          'save_failed',
          fields: {'path': path, 'error': failure.message},
        );
    }
  }

  void _onEditorEvent(EditorHostEvent event) {
    if (event is DocumentEdited) {
      _onDocumentEdited(event.docId);
    } else if (event is ShortcutPressed && event.shortcut == 'save') {
      unawaited(saveActive());
    }
  }

  void _onDocumentEdited(String docId) {
    final path = _pathOf(docId);
    if (path == null) {
      return;
    }
    final text = _host.textOf(docId);
    final current = state.documents[path];
    if (text == null || current == null) {
      return;
    }
    ref.read(editorServiceProvider).updateContent(path, text);
    state = state.copyWith(
      documents: {
        ...state.documents,
        path: current.copyWith(content: text, dirty: true),
      },
    );
  }

  String? _pathOf(String docId) {
    for (final MapEntry(:key, :value) in state.docIds.entries) {
      if (value == docId) {
        return key;
      }
    }
    return null;
  }

  Future<void> _activateInEditor(String docId, String path) async {
    _report('editor_activate_failed', path, await _host.activate(docId));
  }

  Future<void> _closeInEditor(String docId, String path) async {
    _report('editor_close_failed', path, await _host.closeDocument(docId));
  }

  void _report(String event, String path, Result<void> result) {
    if (result case Err<void>(:final failure)) {
      appLogger.warn(
        'editor',
        event,
        fields: {'path': path, 'error': failure.message},
      );
    }
  }
}

final editorTabsProvider =
    NotifierProvider<EditorTabsController, EditorTabsState>(
      EditorTabsController.new,
    );
