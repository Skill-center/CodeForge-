/// The explorer's view of the open workspace (Phase 3 W3): which folders
/// are expanded and how far the tree is scrolled, kept per workspace in
/// the session store, so a switch and a cold start bring both back.
///
/// Expanded folders are state: the tree rebuilds when they change. The
/// scroll offset is not: the explorer reports it as it scrolls, and it is
/// stored a moment later; [ExplorerViewState.restoreOffset] is where a
/// tree that appears should scroll to.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/files/workspace_path.dart';
import '../services/storage/session_store.dart';
import 'providers.dart';

final class ExplorerViewState {
  const ExplorerViewState({
    required this.workspaceId,
    this.expanded = const {''},
    this.restoreOffset = 0,
    this.loaded = false,
  });

  /// The workspace this view belongs to.
  final String workspaceId;

  /// Workspace paths of the expanded folders; the root ('') always.
  final Set<String> expanded;

  /// Where the tree scrolls when it appears: the stored offset, then the
  /// last one reported.
  final double restoreOffset;

  /// The stored view arrived (or there was none).
  final bool loaded;
}

final class ExplorerViewController extends Notifier<ExplorerViewState> {
  /// How long changes gather before they are stored.
  static const Duration saveDelay = Duration(milliseconds: 400);

  late SessionStore _store;
  late String _workspaceId;
  Set<String> _expanded = const {''};
  double _offset = 0;
  bool _dirty = false;
  bool _touched = false;
  Timer? _save;

  /// Counts the builds, so a stored view that arrives after another
  /// workspace opened is dropped.
  int _generation = 0;

  @override
  ExplorerViewState build() {
    ref.keepAlive();
    // The id alone: a renamed project keeps its view.
    _workspaceId = ref.watch(currentWorkspaceProvider.select((w) => w.id));
    _store = ref.read(sessionStoreProvider);
    // Another workspace: start over. Riverpod keeps this object across
    // rebuilds, and with it the last workspace's fields; what that one had
    // was stored by onDispose below, which runs before this build.
    _generation += 1;
    _expanded = const {''};
    _offset = 0;
    _dirty = false;
    _touched = false;
    _save = null;
    final store = _store;
    final workspaceId = _workspaceId;
    // Another workspace opened: what this one had and did not store yet is
    // stored now, under its own id.
    ref.onDispose(() {
      _save?.cancel();
      if (_dirty) {
        unawaited(store.saveView(workspaceId, _view()));
      }
    });
    unawaited(_load(_generation));
    return ExplorerViewState(workspaceId: workspaceId);
  }

  ExplorerView _view() => ExplorerView(
    expanded: {
      for (final path in _expanded)
        if (path.isNotEmpty) path,
    },
    scrollOffset: _offset,
  );

  /// The tree's live scroll offset.
  double get offset => _offset;

  Future<void> _load(int generation) async {
    final stored = (await _store.loadView(_workspaceId)).valueOrNull;
    if (!ref.mounted || generation != _generation) {
      // Another workspace opened meanwhile: this view is not its.
      return;
    }
    if (_touched) {
      // The user changed the view first: theirs stands.
      state = _state(loaded: true);
      return;
    }
    _expanded = {
      '',
      for (final path in stored?.expanded ?? const <String>{})
        if (isWorkspacePath(path)) path,
    };
    _offset = stored?.scrollOffset ?? 0;
    state = _state(loaded: true);
  }

  ExplorerViewState _state({required bool loaded}) => ExplorerViewState(
    workspaceId: _workspaceId,
    expanded: Set.unmodifiable(_expanded),
    restoreOffset: _offset,
    loaded: loaded,
  );

  /// Expands [path] when collapsed, collapses it when expanded.
  void toggle(String path) {
    _touched = true;
    final next = Set.of(_expanded);
    if (!next.remove(path)) {
      next.add(path);
    }
    next.add('');
    _expanded = next;
    state = _state(loaded: state.loaded);
    _schedule();
  }

  /// The tree scrolled to [offset].
  void setScroll(double offset) {
    if ((offset - _offset).abs() < 1) {
      return;
    }
    _touched = true;
    _offset = offset < 0 ? 0 : offset;
    _schedule();
  }

  void _schedule() {
    _dirty = true;
    _save?.cancel();
    _save = Timer(saveDelay, () => unawaited(flush()));
  }

  /// Stores the view now, when anything changed since it was last stored
  /// (the app goes to the background).
  Future<void> flush() async {
    _save?.cancel();
    _save = null;
    if (!_dirty) {
      return;
    }
    _dirty = false;
    await _store.saveView(_workspaceId, _view());
  }
}

final explorerViewProvider =
    NotifierProvider<ExplorerViewController, ExplorerViewState>(
      ExplorerViewController.new,
    );
