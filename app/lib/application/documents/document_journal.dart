/// The hot-exit journal of documents with unsaved changes (ADR-0008,
/// docs/EDITOR_ARCHITECTURE.md §7).
///
/// When a document first differs from its saved text, its journal starts
/// with a snapshot: the whole text at the editor's current version. Every
/// edit after that is appended as the change set the editor sent. A fresh
/// snapshot (dropping the changes it covers) is written on a tab switch,
/// when the app goes to the background, on a timer while there are new
/// changes, and after [DocumentJournal.changesPerSnapshot] changes, so
/// replay stays short. Saving, discarding, closing or undoing back to the
/// saved text deletes the journal.
///
/// Every write goes through one queue in the order it was asked for, so the
/// store never sees a change before the snapshot it continues — and a
/// snapshot can replace every change stored for its document: anything
/// older is covered by it, or left by an earlier run. When a write fails,
/// what the store holds is unknown, so every journal starts over with a
/// snapshot (retried on the timer until one lands).
library;

import 'dart:async';
import 'dart:math';

import '../../core/editor/journal.dart';
import '../../core/errors/failure.dart';
import '../../core/files/text_codec.dart';
import '../../services/storage/session_store.dart';

/// What the journal needs to know about one open document, right now.
final class JournalSubject {
  const JournalSubject({
    required this.workspaceId,
    required this.path,
    required this.savedText,
    required this.hasFile,
    required this.format,
    required this.language,
    required this.text,
    required this.version,
  });

  final String workspaceId;

  /// Workspace-relative path.
  final String path;

  /// The text on disk as of the last read or save.
  final String savedText;

  /// False when the file is gone: there is no saved text to compare with.
  final bool hasFile;

  final TextFormat format;
  final String language;

  /// The editor's text and version now.
  final String text;
  final int version;
}

final class _Journal {
  _Journal({required this.workspaceId, required this.path});

  final String workspaceId;
  final String path;

  /// The version of the last snapshot or change queued.
  int version = 0;

  /// Changes queued since the last snapshot.
  int pending = 0;

  /// Text length at the last snapshot.
  int length = 0;

  DateTime snapshotAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// A restored journal keeps the base its edits were made against until
  /// the user settles a conflict ([DocumentJournal.rebase]).
  bool baseKept = false;
  String? keptBase;

  /// [textDigest] of [_digestOf], computed once per saved text.
  String? _digestOf;
  String? _digest;

  String digestOf(String savedText) {
    if (!identical(_digestOf, savedText)) {
      _digestOf = savedText;
      _digest = textDigest(savedText);
    }
    return _digest!;
  }
}

final class DocumentJournal {
  DocumentJournal({
    required SessionStore store,
    required JournalSubject? Function(String docId) describe,
    required void Function(Result<void> result) onWrite,
    this.snapshotInterval = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _store = store,
       _describe = describe,
       _onWrite = onWrite,
       _clock = clock ?? DateTime.now;

  /// A snapshot is written after this many changes, between timer ticks too.
  static const int changesPerSnapshot = 200;

  /// Documents up to this length get a snapshot on every tick with new
  /// changes; longer ones at most every [largeSnapshotInterval], since each
  /// snapshot writes the whole text.
  static const int smallDocumentLength = 512 * 1024;
  static const Duration largeSnapshotInterval = Duration(minutes: 1);

  /// How often documents with new changes get a snapshot.
  final Duration snapshotInterval;

  final SessionStore _store;
  final JournalSubject? Function(String docId) _describe;
  final void Function(Result<void> result) _onWrite;
  final DateTime Function() _clock;

  final Map<String, _Journal> _journals = {};
  Future<void> _queue = Future<void>.value();
  Timer? _timer;
  bool _disposed = false;

  /// Documents (editor ids) with a journal.
  Iterable<String> get documents => _journals.keys;

  /// Changes queued for [docId] since its last snapshot; null without a
  /// journal.
  int? pendingChanges(String docId) => _journals[docId]?.pending;

  /// Completes when every write asked for so far has finished.
  Future<void> get idle => _queue;

  /// Runs [write] after every write asked for before it, and reports how it
  /// went.
  void enqueue(Future<Result<void>> Function() write) {
    _queue = _queue.then((_) async {
      if (_disposed) {
        return;
      }
      final result = await _attempt(write);
      if (_disposed) {
        return;
      }
      if (!result.isOk) {
        _invalidate();
      }
      _onWrite(result);
    });
  }

  /// A write failed: the next edit, tick or checkpoint writes a snapshot
  /// of every journal instead of continuing it.
  void _invalidate() {
    for (final journal in _journals.values) {
      journal
        ..version = -1
        ..pending = max(journal.pending, 1);
    }
    if (_journals.isNotEmpty) {
      _startTimer();
    }
  }

  static Future<Result<void>> _attempt(
    Future<Result<void>> Function() write,
  ) async {
    try {
      return await write();
    } on Object catch (error) {
      return Err(StorageFailure('$error', cause: error));
    }
  }

  /// The editor changed [docId] by [change] (null: its text was replaced
  /// whole); [dirty] says whether it now differs from the saved text.
  void edited(String docId, {required bool dirty, JournalChange? change}) {
    final journal = _journals[docId];
    if (!dirty) {
      discard(docId);
      return;
    }
    final subject = _describe(docId);
    if (subject == null) {
      return;
    }
    if (journal == null ||
        change == null ||
        journal.path != subject.path ||
        journal.workspaceId != subject.workspaceId ||
        change.baseVersion != journal.version) {
      // A new journal, a whole-text replacement, or a change that does not
      // continue the last one written: start from the text as it is.
      _snapshot(docId, subject);
      return;
    }
    journal
      ..version = change.version
      ..pending += 1;
    final workspaceId = journal.workspaceId;
    final path = journal.path;
    enqueue(() => _store.appendChange(workspaceId, path, change));
    if (journal.pending >= changesPerSnapshot) {
      _snapshot(docId, subject);
    } else {
      _startTimer();
    }
  }

  /// Writes a snapshot now for [docId] — or for every document — that has
  /// changes since its last one: a tab switch, the app going to the
  /// background.
  void checkpoint([String? docId]) {
    for (final id in docId == null ? [..._journals.keys] : [docId]) {
      final journal = _journals[id];
      if (journal == null || journal.pending == 0) {
        continue;
      }
      final subject = _describe(id);
      if (subject != null) {
        _snapshot(id, subject);
      }
    }
  }

  /// [docId]'s saved text or path changed (a save, Save As, keeping
  /// restored edits over the file): its journal starts over against the
  /// new base, or goes when the document is clean.
  void rebase(String docId, {required bool dirty}) {
    if (!dirty) {
      discard(docId);
      return;
    }
    _journals[docId]
      ?..baseKept = false
      ..keptBase = null;
    final subject = _describe(docId);
    if (subject != null) {
      _snapshot(docId, subject);
    }
  }

  /// [docId] was reopened from its journal: the stored journal is rewritten
  /// as one snapshot of the replayed text (dropping the changes it covers
  /// and anything damaged after them). The snapshot keeps [baseDigest], the
  /// saved text the edits were made against, until [rebase]: a conflict
  /// still unanswered when the app dies is asked again next time.
  void adopt(String docId, {required String? baseDigest}) {
    final subject = _describe(docId);
    if (subject == null) {
      return;
    }
    _journals[docId] =
        _Journal(workspaceId: subject.workspaceId, path: subject.path)
          ..baseKept = true
          ..keptBase = baseDigest;
    _snapshot(docId, subject);
  }

  /// Forgets [docId]'s journal: saved, discarded, closed or clean again.
  void discard(String docId) {
    final journal = _journals.remove(docId);
    if (journal == null) {
      return;
    }
    enqueue(() => _store.discardJournal(journal.workspaceId, journal.path));
    if (_journals.values.every((j) => j.pending == 0)) {
      _stopTimer();
    }
  }

  /// Forgets a stored journal no open document owns.
  void discardStored(String workspaceId, String path) {
    enqueue(() => _store.discardJournal(workspaceId, path));
  }

  /// Stops tracking every document and keeps what is stored: another
  /// workspace opens (Phase 3 W2), and this one's unsaved text waits in the
  /// store for its next opening. Call after a checkpoint, so that every
  /// journal's latest text is stored or queued.
  void forgetAll() {
    _journals.clear();
    _stopTimer();
  }

  void dispose() {
    _disposed = true;
    _stopTimer();
  }

  void _snapshot(String docId, JournalSubject subject) {
    var journal = _journals[docId];
    if (journal == null ||
        journal.path != subject.path ||
        journal.workspaceId != subject.workspaceId) {
      if (journal != null) {
        // Saved under another name: the old name's journal goes.
        final old = journal;
        enqueue(() => _store.discardJournal(old.workspaceId, old.path));
      }
      journal = _Journal(workspaceId: subject.workspaceId, path: subject.path);
      _journals[docId] = journal;
    }
    journal
      ..version = subject.version
      ..pending = 0
      ..length = subject.text.length
      ..snapshotAt = _clock();
    final snapshot = JournalSnapshot(
      workspaceId: subject.workspaceId,
      path: subject.path,
      text: subject.text,
      version: subject.version,
      baseDigest: journal.baseKept
          ? journal.keptBase
          : subject.hasFile
          ? journal.digestOf(subject.savedText)
          : null,
      format: subject.format,
      language: subject.language,
    );
    // Replaces every stored change of the document (see the library doc).
    enqueue(() => _store.writeSnapshot(snapshot, restart: true));
  }

  void _startTimer() {
    if (_timer != null || _disposed) {
      return;
    }
    _timer = Timer.periodic(snapshotInterval, (_) => _tick());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    final now = _clock();
    var waiting = false;
    // A copy: a snapshot can replace a document's journal mid-loop. (A
    // MapEntry pattern here would infer dynamic: its type schema becomes
    // the list literal's context.)
    for (final entry in _journals.entries.toList()) {
      final docId = entry.key;
      final journal = entry.value;
      if (journal.pending == 0) {
        continue;
      }
      final due =
          journal.length <= smallDocumentLength ||
          now.difference(journal.snapshotAt) >= largeSnapshotInterval;
      if (!due) {
        waiting = true;
        continue;
      }
      final subject = _describe(docId);
      if (subject != null) {
        _snapshot(docId, subject);
      }
    }
    if (!waiting) {
      _stopTimer();
    }
  }
}
