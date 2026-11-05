/// Editor tab state for the demo workspace: real open/activate/close/save
/// over the in-memory fake editor (gate G7 exercises these paths).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/logging/logger.dart';
import '../services/contracts.dart';
import 'providers.dart';

@immutable
final class EditorTabsState {
  const EditorTabsState({
    this.openPaths = const [],
    this.activePath,
    this.documents = const {},
  });

  final List<String> openPaths;
  final String? activePath;
  final Map<String, EditorDocument> documents;

  EditorTabsState copyWith({
    List<String>? openPaths,
    String? activePath,
    Map<String, EditorDocument>? documents,
    bool clearActive = false,
  }) {
    return EditorTabsState(
      openPaths: openPaths ?? this.openPaths,
      activePath: clearActive ? null : (activePath ?? this.activePath),
      documents: documents ?? this.documents,
    );
  }
}

final class EditorTabsController extends Notifier<EditorTabsState> {
  @override
  EditorTabsState build() {
    // Tabs survive navigation to Settings and back.
    ref.keepAlive();
    return const EditorTabsState();
  }

  Future<void> open(String path) async {
    if (state.openPaths.contains(path)) {
      state = state.copyWith(activePath: path);
      return;
    }
    final editor = ref.read(editorServiceProvider);
    final result = await editor.openDocument(path);
    switch (result) {
      case Ok<EditorDocument>(:final value):
        state = state.copyWith(
          openPaths: [...state.openPaths, path],
          activePath: path,
          documents: {...state.documents, path: value},
        );
      case Err<EditorDocument>(:final failure):
        appLogger.warn('editor', 'open_failed', fields: {
          'path': path,
          'error': failure.message,
        });
    }
  }

  void activate(String path) {
    if (state.openPaths.contains(path)) {
      state = state.copyWith(activePath: path);
    }
  }

  void close(String path) {
    if (!state.openPaths.contains(path)) {
      return;
    }
    final remaining = state.openPaths.where((p) => p != path).toList();
    final documents = Map.of(state.documents)..remove(path);
    final wasActive = state.activePath == path;
    state = state.copyWith(
      openPaths: remaining,
      documents: documents,
      activePath: wasActive ? null : state.activePath,
      clearActive: wasActive && remaining.isEmpty,
    );
    if (wasActive && remaining.isNotEmpty) {
      state = state.copyWith(activePath: remaining.last);
    }
  }

  /// Demo-only: marks the active document dirty so the tab dot is real.
  void simulateEdit() {
    final path = state.activePath;
    if (path == null) {
      return;
    }
    final editor = ref.read(editorServiceProvider);
    editor.markDirty(path);
    final doc = editor.document(path);
    if (doc != null) {
      state = state.copyWith(documents: {...state.documents, path: doc});
    }
  }

  /// Demo-only save: writes through the fake file service, clears dirty.
  Future<void> saveActive() async {
    final path = state.activePath;
    if (path == null) {
      return;
    }
    final editor = ref.read(editorServiceProvider);
    final result = await editor.saveDocument(path);
    switch (result) {
      case Ok<void>():
        final doc = editor.document(path);
        if (doc != null) {
          state = state.copyWith(documents: {...state.documents, path: doc});
        }
        appLogger.info('editor', 'demo_save', fields: {'path': path});
      case Err<void>(:final failure):
        appLogger.warn('editor', 'save_failed', fields: {
          'path': path,
          'error': failure.message,
        });
    }
  }
}

final editorTabsProvider =
    NotifierProvider<EditorTabsController, EditorTabsState>(
      EditorTabsController.new,
    );
