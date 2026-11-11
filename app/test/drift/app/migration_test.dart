/// The app database's migrations (ADR-0008), against the schema versions
/// CI dumps (drift_schemas/app/, test/drift/app/generated/). Written by
/// hand rather than from drift_dev's template, so `make-migrations` leaves
/// it alone.
///
/// Version 1 (Phase 2 W5) → version 2 (Phase 3 W3): the workspaces gain
/// their kind, place and display path, and the explorer's view gets a
/// table. drift_dev's verifier checks every migration's resulting schema,
/// and a v1 file with data in every table, as a v1 build wrote it, opens
/// in v2 with nothing lost (spec §12.19, ARCHITECTURE: "workspace data
/// written by version N must open in N+1").
library;

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/storage/app_database.dart';
import 'package:codeforge/services/storage/drift_session_store.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generated/schema.dart';

/// The folder Phase 3 W2 opened, by the id W2 gave it (a hash of its URI).
const String _w2FolderUri =
    'content://com.android.externalstorage.documents/tree/'
    'primary%3ADocuments%2Fcf-gate';

/// One row per table, written with v1's own SQL as a v1 build would have:
/// the demo project and a folder W2 opened, each with tabs, and unsaved
/// changes in the folder.
void _writeV1Fixture(InitializedSchema schema) {
  final folderId = folderWorkspaceId(_w2FolderUri);
  schema.rawDatabase
    ..execute(
      'INSERT INTO workspaces (id, name, last_opened_at) VALUES (?, ?, ?)',
      ['demo', 'Demo Workspace', 1794000000000],
    )
    ..execute(
      'INSERT INTO workspaces (id, name, last_opened_at) VALUES (?, ?, ?)',
      [folderId, 'cf-gate', 1794000005000],
    )
    ..execute(
      'INSERT INTO open_tabs (workspace_id, path, position, active, '
      'selection_anchor, selection_head, scroll_top) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      ['demo', 'main.js', 0, 0, 3, 5, 42.5],
    )
    // A second tab, active, that never reported a cursor.
    ..execute(
      'INSERT INTO open_tabs (workspace_id, path, position, active, '
      'selection_anchor, selection_head, scroll_top) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      ['demo', 'app.py', 1, 1, null, null, 0.0],
    )
    ..execute(
      'INSERT INTO open_tabs (workspace_id, path, position, active, '
      'selection_anchor, selection_head, scroll_top) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [folderId, 'src/app.js', 0, 1, 7, 7, 0.0],
    )
    ..execute(
      'INSERT INTO journal_documents (workspace_id, path, snapshot_text, '
      'snapshot_version, base_digest, line_ending, bom, language, '
      'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [folderId, 'src/app.js', 'print(1)', 4, 'abc123', 'crlf', 1, 'python', 1],
    )
    ..execute(
      'INSERT INTO journal_changes (workspace_id, path, base_version, '
      'version, length_before, length_after, changes) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [folderId, 'src/app.js', 4, 5, 8, 9, '[8,[0,"",""]]'],
    );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('every version migrates to every later one', () {
    const versions = GeneratedHelper.versions;
    for (final (i, from) in versions.indexed) {
      for (final to in versions.skip(i + 1)) {
        test('$from → $to', () async {
          final schema = await verifier.schemaAt(from);
          final db = AppDatabase(schema.newConnection());
          addTearDown(db.close);
          await verifier.migrateAndValidate(db, to);
        });
      }
    }
  });

  test('a v1 file with data in every table opens in v2 with nothing lost', () async {
    final schema = await verifier.schemaAt(1);
    _writeV1Fixture(schema);
    final db = AppDatabase(schema.newConnection());
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 2);
    final store = DriftSessionStore(db);
    final folderId = folderWorkspaceId(_w2FolderUri);

    // The recents: the demo row became a project in its own folder; W2's
    // folder kept its id and name, and its place, which v1 never stored,
    // is left for the app to find (its grant, or the shell).
    final records = (await store.loadWorkspaces()).orThrow;
    expect([for (final r in records) r.id], [folderId, 'demo']);
    final folder = records.first;
    expect(folder.kind, WorkspaceKind.folder);
    expect(folder.name, 'cf-gate');
    expect(folder.location, isEmpty);
    expect(folder.displayPath, isEmpty);
    expect(folder.lastOpenedAt.millisecondsSinceEpoch, 1794000005000);
    final demo = records.last;
    expect(demo.kind, WorkspaceKind.project);
    expect(demo.name, 'Demo Workspace');
    expect(demo.location, 'demo');
    expect(
      workspaceFromParts(
        kind: demo.kind.name,
        id: demo.id,
        name: demo.name,
        location: demo.location,
      ),
      const DemoProjectLocation(),
    );

    // The tabs, unchanged.
    final tabs = (await store.loadTabs('demo')).orThrow;
    expect([for (final tab in tabs) tab.path], ['main.js', 'app.py']);
    expect([for (final tab in tabs) tab.active], [false, true]);
    expect([tabs[0].selectionAnchor, tabs[0].selectionHead], [3, 5]);
    expect(tabs[0].scrollTop, 42.5);
    expect(
      (await store.loadTabs(folderId)).orThrow.single.path,
      'src/app.js',
    );

    // The unsaved changes, unchanged.
    final entry = (await store.loadJournal(folderId)).orThrow.single;
    expect(entry.path, 'src/app.js');
    expect(entry.snapshot.text, 'print(1)');
    expect(entry.snapshot.version, 4);
    expect(entry.snapshot.baseDigest, 'abc123');
    expect(entry.snapshot.format.bom, isTrue);
    expect(entry.snapshot.format.lineEnding.name, 'crlf');
    expect(entry.changes.single.changes, [
      8,
      [0, '', ''],
    ]);

    // The new table: empty, and it takes a view.
    expect((await store.loadView('demo')).orThrow, isNull);
    await store.saveView('demo', const ExplorerView(expanded: {'src'}));
    expect((await store.loadView('demo')).orThrow?.expanded, {'src'});

    // A place found later reaches the record, which keeps its id.
    await store.moveWorkspace(
      folderId,
      name: 'cf-gate',
      location: _w2FolderUri,
      displayPath: folderDisplayPath(_w2FolderUri, 'cf-gate'),
    );
    final placed = (await store.loadWorkspaces()).orThrow.first;
    expect(placed.id, folderId);
    expect(placed.location, _w2FolderUri);
    expect(placed.displayPath, 'Internal storage/Documents/cf-gate');
  });
}
