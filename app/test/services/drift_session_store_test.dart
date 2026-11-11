/// DriftSessionStore over real SQLite (Phase 2 W5, ADR-0008): tabs with
/// their cursor and scroll, the hot-exit journal's snapshots and changes,
/// and randomized edit sessions that replay to the live text after the
/// database file is closed and opened again (G4). Plain tests: drift's
/// isolate and file work never completes inside FakeAsync.
library;

import 'dart:io';
import 'dart:math';

import 'package:codeforge/core/editor/change_set.dart';
import 'package:codeforge/core/editor/journal.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/storage/app_database.dart';
import 'package:codeforge/services/storage/drift_session_store.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/random_edits.dart';

DriftSessionStore _memoryStore() {
  final store = DriftSessionStore(AppDatabase(NativeDatabase.memory()));
  addTearDown(store.close);
  return store;
}

JournalSnapshot _snapshot(
  String path,
  String text,
  int version, {
  String workspaceId = 'demo',
  String? baseDigest = 'base',
  TextFormat format = TextFormat.standard,
  String language = 'javascript',
}) {
  return JournalSnapshot(
    workspaceId: workspaceId,
    path: path,
    text: text,
    version: version,
    baseDigest: baseDigest,
    format: format,
    language: language,
  );
}

/// [insert] typed at the end of [text], which is at [version].
JournalChange _append(String text, int version, String insert) {
  return JournalChange(
    baseVersion: version,
    version: version + 1,
    lengthBefore: text.length,
    lengthAfter: text.length + insert.length,
    changes: [
      text.length,
      [0, ...insert.split('\n')],
    ],
  );
}

String _replay(JournalEntry entry) {
  final replay = replayJournal(
    text: entry.snapshot.text,
    version: entry.snapshot.version,
    changes: entry.changes,
  );
  expect(replay.problem, isNull);
  return replay.text;
}

Future<List<JournalEntry>> _journal(
  SessionStore store, [
  String workspaceId = 'demo',
]) async {
  return (await store.loadJournal(workspaceId)).valueOrNull!;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('tabs', () {
    test(
      'come back in order, with the active one, cursor and scroll',
      () async {
        final store = _memoryStore();
        expect((await store.loadTabs('demo')).valueOrNull, isEmpty);
        final saved = await store.saveTabs('demo', const [
          SavedTab(
            path: 'main.js',
            selectionAnchor: 4,
            selectionHead: 9,
            scrollTop: 120.5,
          ),
          SavedTab(path: 'src/app.py', active: true),
          SavedTab(path: 'README.md', selectionAnchor: 0, selectionHead: 0),
        ]);
        expect(saved.isOk, isTrue);

        final tabs = (await store.loadTabs('demo')).valueOrNull!;
        expect(
          [for (final tab in tabs) tab.path],
          ['main.js', 'src/app.py', 'README.md'],
        );
        expect([for (final tab in tabs) tab.active], [false, true, false]);
        expect(
          [tabs[0].selectionAnchor, tabs[0].selectionHead, tabs[0].scrollTop],
          [4, 9, 120.5],
        );
        expect(tabs[1].selectionAnchor, isNull);
        expect(tabs[1].scrollTop, 0);
      },
    );

    test('saving replaces the list; each workspace has its own', () async {
      final store = _memoryStore();
      await store.saveTabs('demo', const [
        SavedTab(path: 'main.js'),
        SavedTab(path: 'app.py', active: true),
      ]);
      await store.saveTabs('other', const [SavedTab(path: 'x.js')]);
      await store.saveTabs('demo', const [
        SavedTab(path: 'app.py', active: true),
      ]);
      Future<List<String>> paths(String workspaceId) async => [
        for (final tab in (await store.loadTabs(workspaceId)).valueOrNull!)
          tab.path,
      ];
      expect(await paths('demo'), ['app.py']);
      expect(await paths('other'), ['x.js']);
      await store.saveTabs('demo', const []);
      expect(await paths('demo'), isEmpty);
    });

    test('a workspace is recorded once and renamed in place', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = DriftSessionStore(db);
      const first = ProjectLocation(
        id: 'project-1',
        name: 'Demo',
        folder: 'Demo',
      );
      expect(
        (await store.touchWorkspace(first, displayPath: 'p/Demo')).isOk,
        isTrue,
      );
      expect(
        (await store.touchWorkspace(
          const DemoProjectLocation(),
          displayPath: 'CodeForge projects/demo',
        )).isOk,
        isTrue,
      );
      expect(
        (await store.touchWorkspace(
          const ProjectLocation(
            id: 'project-1',
            name: 'Renamed',
            folder: 'Renamed',
          ),
          displayPath: 'p/Renamed',
        )).isOk,
        isTrue,
      );
      final rows = await db.select(db.workspaces).get();
      expect([for (final row in rows) row.id]..sort(), ['demo', 'project-1']);
      final renamed = rows.singleWhere((row) => row.id == 'project-1');
      expect(renamed.name, 'Renamed');
      expect(renamed.kind, 'project');
      expect(renamed.location, 'Renamed');
      expect(renamed.displayPath, 'p/Renamed');
    });
  });

  group('recents (schema v2)', () {
    const uri =
        'content://com.android.externalstorage.documents/tree/primary%3Acf';
    const folder = FolderLocation(treeUri: uri, name: 'cf');

    test('most recently opened first, with kind and place', () async {
      final store = _memoryStore();
      await store.touchWorkspace(folder, displayPath: 'Internal storage/cf');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.touchWorkspace(
        const DemoProjectLocation(),
        displayPath: 'CodeForge projects/demo',
      );
      final records = (await store.loadWorkspaces()).orThrow;
      expect([for (final r in records) r.id], ['demo', folder.id]);
      final cf = records.last;
      expect(cf.kind, WorkspaceKind.folder);
      expect(cf.name, 'cf');
      expect(cf.location, uri);
      expect(cf.displayPath, 'Internal storage/cf');
      expect(records.first.kind, WorkspaceKind.project);
      expect(records.first.location, 'demo');
    });

    test('a moved workspace keeps its id, time and kind', () async {
      final store = _memoryStore();
      await store.touchWorkspace(folder, displayPath: 'Internal storage/cf');
      final before = (await store.loadWorkspaces()).orThrow.single;
      await store.moveWorkspace(
        folder.id,
        name: 'cf2',
        location: '${uri}2',
        displayPath: 'Internal storage/cf2',
      );
      final after = (await store.loadWorkspaces()).orThrow.single;
      expect(after.id, folder.id);
      expect(after.kind, WorkspaceKind.folder);
      expect(after.name, 'cf2');
      expect(after.location, '${uri}2');
      expect(after.displayPath, 'Internal storage/cf2');
      expect(after.lastOpenedAt, before.lastOpenedAt);
    });

    test('forgetting a workspace removes everything kept for it, in every '
        'table, and nothing of the others', () async {
      final store = _memoryStore();
      for (final id in ['gone', 'kept']) {
        await store.touchWorkspace(
          ProjectLocation(id: id, name: id, folder: id),
          displayPath: id,
        );
        await store.saveTabs(id, const [SavedTab(path: 'a.js', active: true)]);
        await store.writeSnapshot(
          _snapshot('a.js', 'ab', 2, workspaceId: id),
          restart: true,
        );
        await store.appendChange(id, 'a.js', _append('ab', 2, 'c'));
        await store.saveView(id, const ExplorerView(expanded: {'src'}));
      }
      expect((await store.forgetWorkspace('gone')).isOk, isTrue);
      expect(
        [for (final r in (await store.loadWorkspaces()).orThrow) r.id],
        ['kept'],
      );
      expect((await store.loadTabs('gone')).orThrow, isEmpty);
      expect(await _journal(store, 'gone'), isEmpty);
      expect((await store.loadView('gone')).orThrow, isNull);
      expect((await store.loadTabs('kept')).orThrow, hasLength(1));
      expect(_replay((await _journal(store, 'kept')).single), 'abc');
      expect((await store.loadView('kept')).orThrow?.expanded, {'src'});
    });

    test(
      'the explorer view round trips; what does not read is dropped',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final store = DriftSessionStore(db);
        expect((await store.loadView('demo')).orThrow, isNull);
        await store.saveView(
          'demo',
          const ExplorerView(expanded: {'src', 'src/lib'}, scrollOffset: 120.5),
        );
        final view = (await store.loadView('demo')).orThrow!;
        expect(view.expanded, {'src', 'src/lib'});
        expect(view.scrollOffset, 120.5);
        // Another version, or another hand, wrote paths that are not valid.
        await db.customStatement(
          "UPDATE workspace_views SET expanded = '[\"src\", \"../up\", 7, "
          "\"/abs\"]' WHERE workspace_id = 'demo'",
        );
        expect((await store.loadView('demo')).orThrow!.expanded, {'src'});
        await db.customStatement(
          "UPDATE workspace_views SET expanded = 'not json' "
          "WHERE workspace_id = 'demo'",
        );
        expect((await store.loadView('demo')).orThrow!.expanded, isEmpty);
      },
    );
  });

  group('journal', () {
    test('snapshots and their changes come back, per document', () async {
      final store = _memoryStore();
      const crlfBom = TextFormat(lineEnding: LineEnding.crlf, bom: true);
      await store.writeSnapshot(
        _snapshot('main.js', 'ab', 2, format: crlfBom),
        restart: true,
      );
      await store.appendChange('demo', 'main.js', _append('ab', 2, 'c'));
      await store.appendChange('demo', 'main.js', _append('abc', 3, '\nd'));
      await store.writeSnapshot(
        _snapshot('app.py', 'x', 7, baseDigest: null, language: 'python'),
      );
      await store.writeSnapshot(
        _snapshot('main.js', 'elsewhere', 1, workspaceId: 'other'),
      );

      final entries = {
        for (final entry in await _journal(store)) entry.path: entry,
      };
      expect(entries.keys, unorderedEquals(['main.js', 'app.py']));
      final main = entries['main.js']!;
      expect(main.snapshot.format, crlfBom);
      expect(main.snapshot.baseDigest, 'base');
      expect(main.snapshot.language, 'javascript');
      expect([for (final c in main.changes) c.version], [3, 4]);
      expect(_replay(main), 'abc\nd');
      final app = entries['app.py']!;
      expect(app.snapshot.baseDigest, isNull);
      expect(app.snapshot.language, 'python');
      expect(app.changes, isEmpty);
      expect(
        [for (final entry in await _journal(store, 'other')) entry.path],
        ['main.js'],
      );
    });

    test('a snapshot drops the changes it covers; a restart, all', () async {
      final store = _memoryStore();
      await store.writeSnapshot(_snapshot('main.js', '', 0), restart: true);
      var text = '';
      for (var version = 0; version < 5; version++) {
        await store.appendChange(
          'demo',
          'main.js',
          _append(text, version, '$version'),
        );
        text += '$version';
      }
      await store.writeSnapshot(_snapshot('main.js', '012', 3));
      var entry = (await _journal(store)).single;
      expect([for (final c in entry.changes) c.version], [4, 5]);
      expect(_replay(entry), '01234');

      // A new journal for the same file (a later run's first snapshot).
      await store.writeSnapshot(_snapshot('main.js', 'new', 0), restart: true);
      entry = (await _journal(store)).single;
      expect(entry.snapshot.text, 'new');
      expect(entry.changes, isEmpty);
    });

    test('discarding removes that document only', () async {
      final store = _memoryStore();
      await store.writeSnapshot(_snapshot('main.js', 'a', 1));
      await store.appendChange('demo', 'main.js', _append('a', 1, 'b'));
      await store.writeSnapshot(_snapshot('app.py', 'z', 1));
      await store.writeSnapshot(
        _snapshot('main.js', 'kept', 1, workspaceId: 'other'),
      );
      expect((await store.discardJournal('demo', 'main.js')).isOk, isTrue);
      expect((await store.discardJournal('demo', 'ghost.js')).isOk, isTrue);
      expect([for (final e in await _journal(store)) e.path], ['app.py']);
      expect(
        [for (final e in await _journal(store, 'other')) e.snapshot.text],
        ['kept'],
      );
    });

    test('an unreadable change row ends replay there', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = DriftSessionStore(db);
      await store.writeSnapshot(_snapshot('main.js', 'a', 1));
      await store.appendChange('demo', 'main.js', _append('a', 1, 'b'));
      await db
          .into(db.journalChanges)
          .insert(
            JournalChangesCompanion.insert(
              workspaceId: 'demo',
              path: 'main.js',
              baseVersion: 2,
              version: 3,
              lengthBefore: 2,
              lengthAfter: 3,
              changes: '[2, [0, "c"',
            ),
          );
      await store.appendChange('demo', 'main.js', _append('abc', 3, 'd'));

      final entry = (await _journal(store)).single;
      expect(entry.changes, hasLength(2), reason: 'the broken row is skipped');
      final replay = replayJournal(
        text: entry.snapshot.text,
        version: entry.snapshot.version,
        changes: entry.changes,
      );
      expect(replay.text, 'ab');
      expect(replay.problem, contains('version gap'));
    });
  });

  group('the database file', () {
    late Directory folder;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('codeforge_db_');
      addTearDown(() => folder.delete(recursive: true));
    });

    test('opens on first use, in write-ahead-log mode', () async {
      final db = AppDatabase(openAppDatabase(() async => folder.path));
      final file = File('${folder.path}/$appDatabaseFileName');
      expect(file.existsSync(), isFalse, reason: 'nothing opened yet');
      final mode = await db.customSelect('PRAGMA journal_mode').getSingle();
      expect(mode.data.values.single, 'wal');
      await db.close();
      expect(file.existsSync(), isTrue);
    });

    test('randomized edit sessions replay to the live text after a '
        'restart (G4)', () async {
      for (var seed = 0; seed < 8; seed++) {
        final random = Random(seed);
        var store = DriftSessionStore(
          AppDatabase(openAppDatabase(() async => folder.path)),
        );
        // What the controller does for a dirty document: a snapshot, then
        // each change, with a fresh snapshot now and then.
        var live = randomText(random, 200, astral: false);
        var version = random.nextInt(10);
        await store.writeSnapshot(
          _snapshot('main.js', live, version),
          restart: true,
        );
        for (var step = 0, n = 50 + random.nextInt(150); step < n; step++) {
          final changes = randomChanges(random, live, astral: false);
          final lengths = changeLengths(changes);
          final appended = await store.appendChange(
            'demo',
            'main.js',
            JournalChange(
              baseVersion: version,
              version: version + 1,
              lengthBefore: lengths.before,
              lengthAfter: lengths.after,
              changes: changes,
            ),
          );
          expect(appended.isOk, isTrue);
          live = applyChanges(live, changes);
          version += 1;
          if (random.nextInt(30) == 0) {
            await store.writeSnapshot(_snapshot('main.js', live, version));
          }
        }
        await store.close();

        // The next run opens the same file.
        store = DriftSessionStore(
          AppDatabase(openAppDatabase(() async => folder.path)),
        );
        final entry = (await _journal(store)).single;
        final replay = replayJournal(
          text: entry.snapshot.text,
          version: entry.snapshot.version,
          changes: entry.changes,
        );
        expect(replay.problem, isNull, reason: 'seed $seed');
        expect(replay.text, live, reason: 'seed $seed');
        expect(replay.version, version, reason: 'seed $seed');
        await store.discardJournal('demo', 'main.js');
        await store.close();
      }
    });
  });
}
