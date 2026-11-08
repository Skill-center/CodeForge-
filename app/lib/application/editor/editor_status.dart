/// What the editor page reports about itself that the workbench shows
/// (Phase 2 W6): whether it has the keyboard, and whether each document
/// can undo or redo. The symbol toolbar enables its keys from it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'editor_host.dart';
import 'editor_providers.dart';

/// Whether a document can undo and redo, as its page last said.
typedef UndoAvailability = ({bool canUndo, bool canRedo});

@immutable
final class EditorStatus {
  const EditorStatus({this.focused = false, this.history = const {}});

  /// The page has keyboard focus: typing and toolbar keys reach it.
  final bool focused;

  /// Each open document's undo and redo, by docId.
  final Map<String, UndoAvailability> history;

  bool canUndo(String? docId) => history[docId]?.canUndo ?? false;
  bool canRedo(String? docId) => history[docId]?.canRedo ?? false;

  EditorStatus copyWith({
    bool? focused,
    Map<String, UndoAvailability>? history,
  }) => EditorStatus(
    focused: focused ?? this.focused,
    history: history ?? this.history,
  );

  @override
  bool operator ==(Object other) =>
      other is EditorStatus &&
      other.focused == focused &&
      mapEquals(other.history, history);

  @override
  int get hashCode => Object.hash(
    focused,
    Object.hashAllUnordered(
      history.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );
}

final editorStatusProvider =
    NotifierProvider<EditorStatusController, EditorStatus>(
      EditorStatusController.new,
    );

final class EditorStatusController extends Notifier<EditorStatus> {
  @override
  EditorStatus build() {
    final host = ref.watch(editorHostProvider);
    final events = host.events.listen(_onEditorEvent);
    final status = host.statusChanges.listen(_onStatus);
    ref.onDispose(() {
      unawaited(events.cancel());
      unawaited(status.cancel());
    });
    return const EditorStatus();
  }

  void _onEditorEvent(EditorHostEvent event) {
    if (event is FocusChanged) {
      state = state.copyWith(focused: event.focused);
    } else if (event is HistoryChanged) {
      state = state.copyWith(
        history: {
          ...state.history,
          event.docId: (canUndo: event.canUndo, canRedo: event.canRedo),
        },
      );
    }
  }

  // A page that stopped has no focus, and the restarted one reopens its
  // documents with fresh histories, reporting each.
  void _onStatus(EditorHostStatus status) {
    if (status.phase != EditorHostPhase.ready) {
      state = const EditorStatus();
    }
  }
}
