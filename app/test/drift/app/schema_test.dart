/// The app database's schema against the versions CI dumps
/// (drift_schemas/app/drift_schema_vN.json, test/drift/app/generated/),
/// per ADR-0008: every schema version ships with a migration test over
/// fixture data. Version 1 (Phase 2 W5) has nothing to migrate from yet;
/// these pin what v1 is and that a v1 file with data in every table opens
/// and reads back unchanged. The next version adds `migration_test.dart`
/// here (drift_dev make-migrations writes its skeleton) with v1 → v2 over
/// the same fixtures.
library;

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/storage/app_database.dart';
import 'package:codeforge/services/storage/drift_session_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generated/schema.dart';

/// One row per table, written with v1's own SQL as a v1 build would have.
void _writeV1Fixture(InitializedSchema schema) {
  schema.rawDatabase
    ..execute(
      'INSERT INTO workspaces (id, name, last_opened_at) VALUES (?, ?, ?)',
      ['demo', 'Demo Workspace', 1794000000000],
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
      'INSERT INTO journal_documents (workspace_id, path, snapshot_text, '
      'snapshot_version, base_digest, line_ending, bom, language, '
      'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ['demo', 'app.py', 'print(1)', 4, 'abc123', 'crlf', 1, 'python', 1],
    )
    ..execute(
      'INSERT INTO journal_changes (workspace_id, path, base_version, '
      'version, length_before, length_after, changes) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      ['demo', 'app.py', 4, 5, 8, 9, '[8,[0,"",""]]'],
    );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('a new database is exactly schema v1', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 1);
  });

  test('a v1 file with data in every table opens and reads back', () async {
    final schema = await verifier.schemaAt(1);
    _writeV1Fixture(schema);
    final db = AppDatabase(schema.newConnection());
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 1);

    final store = DriftSessionStore(db);
    final tabs = (await store.loadTabs('demo')).valueOrNull!;
    expect([for (final tab in tabs) tab.path], ['main.js', 'app.py']);
    expect([for (final tab in tabs) tab.active], [false, true]);
    expect([tabs[0].selectionAnchor, tabs[0].selectionHead], [3, 5]);
    expect(tabs[0].scrollTop, 42.5);

    final entry = (await store.loadJournal('demo')).valueOrNull!.single;
    expect(entry.path, 'app.py');
    expect(entry.snapshot.text, 'print(1)');
    expect(entry.snapshot.version, 4);
    expect(entry.snapshot.baseDigest, 'abc123');
    expect(entry.snapshot.format.bom, isTrue);
    expect(entry.snapshot.format.lineEnding.name, 'crlf');
    expect(entry.changes.single.changes, [
      8,
      [0, '', ''],
    ]);
  });
}
