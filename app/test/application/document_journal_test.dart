/// DocumentJournal (Phase 2 W5): what the hot-exit journal writes, when,
/// and in what order — over the in-memory session store and a scripted
/// table of documents. Plain tests in real time; short timer intervals
/// stand in for the real five seconds.
library;

import 'package:codeforge/application/documents/document_journal.dart';
import 'package:codeforge/core/editor/journal.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/flaky_session_store.dart';

/// One open document as the journal sees it.
final class _Doc {
  _Doc(this.path, this.saved) : text = saved;

  String path;
  String saved;
  String text;
  int version = 0;
  bool hasFile = true;
  String language = 'javascript';
}

void main() {
  late FlakySessionStore store;
  late Map<String, _Doc> docs;
  late List<Result<void>> results;
  late DateTime now;

  setUp(() {
    store = FlakySessionStore();
    docs = {};
    results = [];
    now = DateTime.utc(2026, 11, 7, 12);
  });

  DocumentJournal journalWith({
    Duration interval = const Duration(seconds: 5),
  }) {
    final journal = DocumentJournal(
      store: store,
      describe: (docId) {
        final doc = docs[docId];
        if (doc == null) {
          return null;
        }
        return JournalSubject(
          workspaceId: 'demo',
          path: doc.path,
          savedText: doc.saved,
          hasFile: doc.hasFile,
          format: TextFormat.standard,
          language: doc.language,
          text: doc.text,
          version: doc.version,
        );
      },
      onWrite: results.add,
      snapshotInterval: interval,
      clock: () => now,
    );
    addTearDown(journal.dispose);
    return journal;
  }

  /// Types [text] at the end of [docId] and tells [journal], as the
  /// controller does for each `DocumentEdited`.
  JournalChange type(DocumentJournal journal, String docId, String text) {
    final doc = docs[docId]!;
    final length = doc.text.length;
    final change = JournalChange(
      baseVersion: doc.version,
      version: doc.version + 1,
      lengthBefore: length,
      lengthAfter: length + text.length,
      changes: [
        length,
        [0, ...text.split('\n')],
      ],
    );
    doc
      ..text += text
      ..version += 1;
    journal.edited(docId, dirty: doc.text != doc.saved, change: change);
    return change;
  }

  Future<List<JournalEntry>> stored(DocumentJournal journal) async {
    await journal.idle;
    return (await store.inner.loadJournal('demo')).valueOrNull!;
  }

  String replayed(JournalEntry entry) => replayJournal(
    text: entry.snapshot.text,
    version: entry.snapshot.version,
    changes: entry.changes,
  ).text;

  test('a snapshot first, then each change; clean again drops it', () async {
    final journal = journalWith();
    docs['d1'] = _Doc('main.js', 'let a;\n');
    type(journal, 'd1', 'b');
    var entries = await stored(journal);
    expect(entries.single.snapshot.text, 'let a;\nb');
    expect(entries.single.snapshot.version, 1);
    expect(entries.single.snapshot.baseDigest, textDigest('let a;\n'));
    expect(entries.single.changes, isEmpty);

    type(journal, 'd1', 'c\n');
    type(journal, 'd1', 'd');
    entries = await stored(journal);
    expect(entries.single.changes.map((c) => c.version), [2, 3]);
    expect(replayed(entries.single), docs['d1']!.text);
    expect(journal.pendingChanges('d1'), 2);

    // Deleting back to the saved text.
    final doc = docs['d1']!
      ..text = 'let a;\n'
      ..version += 1;
    journal.edited('d1', dirty: false);
    expect(await stored(journal), isEmpty);
    expect(journal.pendingChanges('d1'), isNull);
    expect(doc.version, 4);
    expect(results.every((r) => r.isOk), isTrue);
  });

  test(
    'a change that does not continue the journal takes a snapshot',
    () async {
      final journal = journalWith();
      docs['d1'] = _Doc('main.js', '');
      type(journal, 'd1', 'a');
      type(journal, 'd1', 'b');
      // The text replaced whole (no change set), then a version gap.
      docs['d1']!
        ..text = 'xyz'
        ..version = 9;
      journal.edited('d1', dirty: true);
      var entries = await stored(journal);
      expect(entries.single.snapshot.text, 'xyz');
      expect(entries.single.changes, isEmpty);

      docs['d1']!.version = 12;
      type(journal, 'd1', '!');
      entries = await stored(journal);
      expect(entries.single.snapshot.version, 13);
      expect(entries.single.snapshot.text, 'xyz!');
      expect(entries.single.changes, isEmpty);
    },
  );

  test('replay stays short: a snapshot every 200 changes', () async {
    final journal = journalWith();
    docs['d1'] = _Doc('main.js', '');
    // The first edit is the snapshot; 200 changes later comes the next.
    for (var i = 0; i < 1 + DocumentJournal.changesPerSnapshot + 4; i++) {
      type(journal, 'd1', 'x');
    }
    final entries = await stored(journal);
    expect(entries.single.changes, hasLength(4));
    expect(
      entries.single.snapshot.version,
      1 + DocumentJournal.changesPerSnapshot,
    );
    expect(replayed(entries.single), docs['d1']!.text);
  });

  test('the timer snapshots documents with new changes, then stops', () async {
    final journal = journalWith(interval: const Duration(milliseconds: 20));
    docs['d1'] = _Doc('main.js', '');
    type(journal, 'd1', 'a');
    type(journal, 'd1', 'b');
    expect(journal.pendingChanges('d1'), 1);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final entries = await stored(journal);
    expect(entries.single.snapshot.text, 'ab');
    expect(entries.single.changes, isEmpty);
    expect(journal.pendingChanges('d1'), 0);
    final writes = store.inner.writes;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(store.inner.writes, writes, reason: 'nothing new, nothing written');
  });

  test('large documents get a timed snapshot at most once a minute', () async {
    final journal = journalWith(interval: const Duration(milliseconds: 20));
    docs['d1'] = _Doc(
      'big.txt',
      'x' * (DocumentJournal.smallDocumentLength + 1),
    );
    type(journal, 'd1', 'a');
    type(journal, 'd1', 'b');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(journal.pendingChanges('d1'), 1, reason: 'not due yet');

    now = now.add(DocumentJournal.largeSnapshotInterval);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(journal.pendingChanges('d1'), 0);
    expect(replayed((await stored(journal)).single), docs['d1']!.text);
  });

  test('a checkpoint snapshots only documents with new changes', () async {
    final journal = journalWith();
    docs['d1'] = _Doc('main.js', '');
    docs['d2'] = _Doc('app.py', '');
    type(journal, 'd1', 'a');
    type(journal, 'd1', 'b');
    type(journal, 'd2', 'z');
    await journal.idle;
    final writes = store.inner.writes;
    journal.checkpoint();
    final entries = await stored(journal);
    expect(store.inner.writes, writes + 1, reason: 'app.py had no new changes');
    expect(entries.every((e) => e.changes.isEmpty), isTrue);
    expect(
      {for (final e in entries) e.path: e.snapshot.text},
      {'main.js': 'ab', 'app.py': 'z'},
    );
  });

  test('saving rebases the journal, or drops it when clean', () async {
    final journal = journalWith();
    docs['d1'] = _Doc('main.js', 'a');
    type(journal, 'd1', 'b');
    type(journal, 'd1', 'c');
    // Saved while "d" was being typed: still dirty against the new base.
    docs['d1']!.saved = 'abc';
    type(journal, 'd1', 'd');
    journal.rebase('d1', dirty: true);
    var entries = await stored(journal);
    expect(entries.single.snapshot.baseDigest, textDigest('abc'));
    expect(entries.single.snapshot.text, 'abcd');
    expect(entries.single.changes, isEmpty);

    docs['d1']!.saved = 'abcd';
    journal.rebase('d1', dirty: false);
    entries = await stored(journal);
    expect(entries, isEmpty);
  });

  test('save as moves the journal to the new name', () async {
    final journal = journalWith();
    docs['d1'] = _Doc('notes.txt', '');
    type(journal, 'd1', 'draft');
    docs['d1']!
      ..path = 'notes.md'
      ..saved = 'dra';
    journal.rebase('d1', dirty: true);
    final entries = await stored(journal);
    expect(entries.map((e) => e.path), ['notes.md']);
    expect(entries.single.snapshot.baseDigest, textDigest('dra'));
  });

  test('an adopted journal keeps its base until rebased', () async {
    final journal = journalWith();
    // Left by the last run: a snapshot and changes past what replayed.
    await store.inner.writeSnapshot(
      const JournalSnapshot(
        workspaceId: 'demo',
        path: 'main.js',
        text: 'old',
        version: 3,
        baseDigest: 'base-of-last-run',
        format: TextFormat.standard,
        language: 'javascript',
      ),
    );
    await store.inner.appendChange(
      'demo',
      'main.js',
      const JournalChange(
        baseVersion: 3,
        version: 4,
        lengthBefore: 99,
        lengthAfter: 100,
        changes: [
          99,
          [0, 'x'],
        ],
      ),
    );
    docs['d1'] = _Doc('main.js', 'on disk now')
      ..text = 'old'
      ..version = 3;
    journal.adopt('d1', baseDigest: 'base-of-last-run');
    var entries = await stored(journal);
    expect(entries.single.changes, isEmpty, reason: 'the damaged tail goes');
    expect(entries.single.snapshot.baseDigest, 'base-of-last-run');

    type(journal, 'd1', '!');
    await journal.idle;
    journal.checkpoint();
    entries = await stored(journal);
    expect(entries.single.snapshot.baseDigest, 'base-of-last-run');

    journal.rebase('d1', dirty: true);
    entries = await stored(journal);
    expect(entries.single.snapshot.baseDigest, textDigest('on disk now'));
  });

  test(
    'failed writes are reported, in order, and later ones still run',
    () async {
      final journal = journalWith();
      docs['d1'] = _Doc('main.js', '');
      store.failing = true;
      type(journal, 'd1', 'a');
      await journal.idle;
      expect(results.last.failureOrNull, isA<StorageFailure>());

      store
        ..failing = false
        ..throwing = true;
      type(journal, 'd1', 'b');
      await journal.idle;
      expect(results.last.failureOrNull, isA<StorageFailure>());

      store.throwing = false;
      journal.checkpoint();
      final entries = await stored(journal);
      expect(results.last.isOk, isTrue);
      expect(entries.single.snapshot.text, 'ab');
    },
  );

  test(
    'after a failed write the next edit starts over with a snapshot',
    () async {
      final journal = journalWith();
      docs['d1'] = _Doc('main.js', '');
      type(journal, 'd1', 'a');
      await journal.idle;
      store.failing = true;
      type(journal, 'd1', 'b');
      await journal.idle;
      store.failing = false;
      type(journal, 'd1', 'c');
      final entries = await stored(journal);
      expect(entries.single.snapshot.text, 'abc');
      expect(entries.single.changes, isEmpty);
    },
  );

  test('a failed write is retried on the timer, without new edits', () async {
    final journal = journalWith(interval: const Duration(milliseconds: 20));
    docs['d1'] = _Doc('main.js', '');
    store.failing = true;
    type(journal, 'd1', 'a');
    await journal.idle;
    expect(await stored(journal), isEmpty);
    store.failing = false;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect((await stored(journal)).single.snapshot.text, 'a');
    expect(results.last.isOk, isTrue);
  });

  test('nothing is written after dispose', () async {
    final journal = journalWith();
    docs['d1'] = _Doc('main.js', '');
    journal.dispose();
    type(journal, 'd1', 'a');
    await journal.idle;
    expect(store.inner.writes, 0);
    expect(results, isEmpty);
  });
}
