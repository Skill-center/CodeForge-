/// What the app keeps between runs besides settings and the shell envelope
/// (ADR-0008): the workspaces it opened (Home's recents, with each one's
/// kind and place since Phase 3 W3), each workspace's tabs with their
/// cursor and scroll, the explorer's view of each workspace, and the
/// hot-exit journal that holds unsaved edits until they are saved or
/// discarded.
///
/// The app's store is the database (drift_session_store.dart). The memory
/// store below is the same contract for tests, which share one between
/// "runs" of the app to stand in for process death.
library;

import '../../core/editor/journal.dart';
import '../../core/errors/failure.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_location.dart';

/// A workspace as the recents remember it (Phase 3 W3).
final class WorkspaceRecord {
  const WorkspaceRecord({
    required this.id,
    required this.kind,
    required this.name,
    required this.location,
    required this.displayPath,
    required this.lastOpenedAt,
  });

  final String id;
  final WorkspaceKind kind;
  final String name;

  /// A project's folder name, or a folder's tree URI; empty for a folder
  /// whose place was never recorded (before Phase 3 W3).
  final String location;

  /// The place as the recents show it; empty when not recorded yet.
  final String displayPath;

  final DateTime lastOpenedAt;
}

/// The explorer as a workspace left it (Phase 3 W3).
final class ExplorerView {
  const ExplorerView({this.expanded = const {}, this.scrollOffset = 0});

  /// The expanded folders' workspace paths (the root is always open).
  final Set<String> expanded;

  /// How far the tree was scrolled, in logical pixels.
  final double scrollOffset;
}

/// The most expanded folders a workspace's view keeps.
const int maxExpandedFolders = 500;

/// One open tab as it is remembered.
final class SavedTab {
  const SavedTab({
    required this.path,
    this.active = false,
    this.selectionAnchor,
    this.selectionHead,
    this.scrollTop = 0,
  });

  /// Workspace-relative path.
  final String path;

  /// The tab that was showing.
  final bool active;

  /// The selection (UTF-16 offsets) the tab had; null when never reported.
  final int? selectionAnchor;
  final int? selectionHead;

  /// Vertical scroll offset in CSS pixels.
  final double scrollTop;
}

/// The head of a dirty document's journal: its whole text at [version] and
/// what that text was based on.
final class JournalSnapshot {
  const JournalSnapshot({
    required this.workspaceId,
    required this.path,
    required this.text,
    required this.version,
    required this.baseDigest,
    required this.format,
    required this.language,
  });

  final String workspaceId;

  /// Workspace-relative path.
  final String path;

  /// The document's text ("\n" line breaks) at [version].
  final String text;

  /// The editor's version of [text]. Changes recorded after the snapshot
  /// continue from it.
  final int version;

  /// [textDigest] of the saved text the edits were made against, or null
  /// when there was no file to compare with (it was gone).
  final String? baseDigest;

  /// Line endings and byte-order mark the document is saved with.
  final TextFormat format;

  /// One of `editorLanguageIds`.
  final String language;
}

/// A document's whole journal as read back at startup.
final class JournalEntry {
  const JournalEntry({required this.snapshot, required this.changes});

  final JournalSnapshot snapshot;

  /// The changes recorded after [snapshot], in the order they arrived.
  final List<JournalChange> changes;

  String get path => snapshot.path;
}

abstract interface class SessionStore {
  /// Records that [workspace] was opened now: its name, kind and place,
  /// and [displayPath], how the recents show that place.
  Future<Result<void>> touchWorkspace(
    WorkspaceLocation workspace, {
    required String displayPath,
  });

  /// Every workspace recorded, most recently opened first.
  Future<Result<List<WorkspaceRecord>>> loadWorkspaces();

  /// Gives the workspace [id] another name and place, keeping its id and
  /// so its tabs, unsaved text and view: a renamed project, a reconnected
  /// folder.
  Future<Result<void>> moveWorkspace(
    String id, {
    required String name,
    required String location,
    required String displayPath,
  });

  /// Forgets the workspace [id] entirely, in one transaction: its record,
  /// its tabs, its journal and its view.
  Future<Result<void>> forgetWorkspace(String id);

  /// [workspaceId]'s explorer view; null when none was saved.
  Future<Result<ExplorerView?>> loadView(String workspaceId);

  /// Replaces [workspaceId]'s explorer view with [view].
  Future<Result<void>> saveView(String workspaceId, ExplorerView view);

  /// [workspaceId]'s tabs, in order; empty when none were saved.
  Future<Result<List<SavedTab>>> loadTabs(String workspaceId);

  /// Replaces [workspaceId]'s tabs with [tabs], in order.
  Future<Result<void>> saveTabs(String workspaceId, List<SavedTab> tabs);

  /// The journals of [workspaceId]'s documents with unsaved changes.
  Future<Result<List<JournalEntry>>> loadJournal(String workspaceId);

  /// Makes [snapshot] its document's journal head and drops the changes it
  /// covers, in one transaction. With [restart] every recorded change of
  /// the document goes: the journal starts over from this text.
  Future<Result<void>> writeSnapshot(
    JournalSnapshot snapshot, {
    bool restart = false,
  });

  /// Records [change] after the journal head of [path].
  Future<Result<void>> appendChange(
    String workspaceId,
    String path,
    JournalChange change,
  );

  /// Forgets [path]'s journal: its edits were saved, discarded or closed.
  Future<Result<void>> discardJournal(String workspaceId, String path);

  Future<void> close();
}

/// [SessionStore] in memory: tests, and the store the app falls back to
/// when its database cannot be opened.
final class MemorySessionStore implements SessionStore {
  /// The recorded workspaces, by id.
  final Map<String, WorkspaceRecord> workspaces = {};

  /// The saved explorer views, by workspace id.
  final Map<String, ExplorerView> views = {};
  final Map<String, List<SavedTab>> _tabs = {};
  final Map<String, JournalSnapshot> _snapshots = {};
  final Map<String, List<JournalChange>> _changes = {};

  /// Calls that changed the store, for tests that wait for a write.
  int writes = 0;

  DateTime _lastTouch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  static String _key(String workspaceId, String path) => '$workspaceId\n$path';

  /// Now, or just after the last touch: two workspaces opened in the same
  /// millisecond still have an order.
  DateTime _now() {
    final now = DateTime.now().toUtc();
    _lastTouch = now.isAfter(_lastTouch)
        ? now
        : _lastTouch.add(const Duration(milliseconds: 1));
    return _lastTouch;
  }

  @override
  Future<Result<void>> touchWorkspace(
    WorkspaceLocation workspace, {
    required String displayPath,
  }) async {
    workspaces[workspace.id] = WorkspaceRecord(
      id: workspace.id,
      kind: workspace.kind,
      name: workspace.name,
      location: workspace.location,
      displayPath: displayPath,
      lastOpenedAt: _now(),
    );
    writes += 1;
    return const Ok(null);
  }

  @override
  Future<Result<List<WorkspaceRecord>>> loadWorkspaces() async {
    return Ok(
      workspaces.values.toList()
        ..sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt)),
    );
  }

  @override
  Future<Result<void>> moveWorkspace(
    String id, {
    required String name,
    required String location,
    required String displayPath,
  }) async {
    final record = workspaces[id];
    if (record != null) {
      workspaces[id] = WorkspaceRecord(
        id: id,
        kind: record.kind,
        name: name,
        location: location,
        displayPath: displayPath,
        lastOpenedAt: record.lastOpenedAt,
      );
    }
    writes += 1;
    return const Ok(null);
  }

  @override
  Future<Result<void>> forgetWorkspace(String id) async {
    workspaces.remove(id);
    views.remove(id);
    _tabs.remove(id);
    final keys = [
      for (final MapEntry(:key, :value) in _snapshots.entries)
        if (value.workspaceId == id) key,
    ];
    for (final key in keys) {
      _snapshots.remove(key);
      _changes.remove(key);
    }
    _changes.removeWhere((key, _) => key.startsWith('$id\n'));
    writes += 1;
    return const Ok(null);
  }

  @override
  Future<Result<ExplorerView?>> loadView(String workspaceId) async {
    return Ok(views[workspaceId]);
  }

  @override
  Future<Result<void>> saveView(String workspaceId, ExplorerView view) async {
    views[workspaceId] = ExplorerView(
      expanded: Set.unmodifiable(view.expanded.take(maxExpandedFolders)),
      scrollOffset: view.scrollOffset,
    );
    writes += 1;
    return const Ok(null);
  }

  @override
  Future<Result<List<SavedTab>>> loadTabs(String workspaceId) async {
    return Ok(List.unmodifiable(_tabs[workspaceId] ?? const <SavedTab>[]));
  }

  @override
  Future<Result<void>> saveTabs(String workspaceId, List<SavedTab> tabs) async {
    _tabs[workspaceId] = List.of(tabs);
    writes += 1;
    return const Ok(null);
  }

  @override
  Future<Result<List<JournalEntry>>> loadJournal(String workspaceId) async {
    final entries = <JournalEntry>[];
    for (final MapEntry(:key, :value) in _snapshots.entries) {
      if (value.workspaceId == workspaceId) {
        entries.add(
          JournalEntry(
            snapshot: value,
            changes: List.unmodifiable(_changes[key] ?? const []),
          ),
        );
      }
    }
    return Ok(entries);
  }

  @override
  Future<Result<void>> writeSnapshot(
    JournalSnapshot snapshot, {
    bool restart = false,
  }) async {
    final key = _key(snapshot.workspaceId, snapshot.path);
    _snapshots[key] = snapshot;
    final changes = _changes[key];
    if (changes != null) {
      if (restart) {
        changes.clear();
      } else {
        changes.removeWhere((c) => c.version <= snapshot.version);
      }
    }
    writes += 1;
    return const Ok(null);
  }

  @override
  Future<Result<void>> appendChange(
    String workspaceId,
    String path,
    JournalChange change,
  ) async {
    (_changes[_key(workspaceId, path)] ??= []).add(change);
    writes += 1;
    return const Ok(null);
  }

  @override
  Future<Result<void>> discardJournal(String workspaceId, String path) async {
    final key = _key(workspaceId, path);
    _snapshots.remove(key);
    _changes.remove(key);
    writes += 1;
    return const Ok(null);
  }

  @override
  Future<void> close() async {}
}
