/// The app database's schema against the versions CI dumps
/// (drift_schemas/app/drift_schema_vN.json, test/drift/app/generated/),
/// per ADR-0008: every schema version ships with a migration test over
/// fixture data (migration_test.dart, from version 2 on). This pins what
/// the latest version is: a new database is exactly schema v2 (Phase 3
/// W3), and every table takes a row and gives it back.
library;

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/storage/app_database.dart';
import 'package:codeforge/services/storage/drift_session_store.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generated/schema.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('a new database is exactly schema v2', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 2);
    expect(db.schemaVersion, 2);
  });

  test('a new database takes a row in every table', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = DriftSessionStore(db);
    const folder = FolderLocation(
      treeUri:
          'content://com.android.externalstorage.documents/tree/primary%3Acf',
      name: 'cf',
    );
    await store.touchWorkspace(folder, displayPath: 'Internal storage/cf');
    await store.saveTabs(folder.id, const [SavedTab(path: 'a.js')]);
    await store.saveView(
      folder.id,
      const ExplorerView(expanded: {'src'}, scrollOffset: 8),
    );
    final record = (await store.loadWorkspaces()).orThrow.single;
    expect(record.kind, WorkspaceKind.folder);
    expect(record.location, folder.treeUri);
    expect((await store.loadTabs(folder.id)).orThrow.single.path, 'a.js');
    final view = (await store.loadView(folder.id)).orThrow!;
    expect(view.expanded, {'src'});
    expect(view.scrollOffset, 8);
  });
}
