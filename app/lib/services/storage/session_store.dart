/// What the app keeps between runs besides settings and the shell envelope
/// (ADR-0008): the workspaces it opened, each workspace's tabs with their
/// cursor and scroll, and the hot-exit journal that holds unsaved edits
/// until they are saved or discarded.
///
/// The app's store is the database (drift_session_store.dart). The memory
/// store below is the same contract for tests, which share one between
/// "runs" of the app to stand in for process death.
library;

import '../../core/editor/journal.dart';
import '../../core/errors/failure.dart';
import '../../core/files/text_codec.dart';

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
  /// Records that [workspaceId] was opened now.
  Future<Result<void>> touchWorkspace(
    String workspaceId, {
    required String name,
  });

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
  final Map<String, String> workspaces = {};
  final Map<String, List<SavedTab>> _tabs = {};
  final Map<String, JournalSnapshot> _snapshots = {};
  final Map<String, List<JournalChange>> _changes = {};

  /// Calls that changed the store, for tests that wait for a write.
  int writes = 0;

  static String _key(String workspaceId, String path) => '$workspaceId\n$path';

  @override
  Future<Result<void>> touchWorkspace(
    String workspaceId, {
    required String name,
  }) async {
    workspaces[workspaceId] = name;
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
