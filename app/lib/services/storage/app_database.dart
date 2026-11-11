/// The app database (ADR-0008): one SQLite file, `codeforge.sqlite` in the
/// app's private files directory.
///
/// Schema version 2 (Phase 3 W3): version 1 (Phase 2 W5) and the
/// workspaces' kind, place and display path, and each workspace's explorer
/// view. Every schema change raises [AppDatabase.schemaVersion], adds a
/// migration step, and ships with the schema dump CI generates
/// (drift_schemas/app/) and a migration test (test/drift/app/): AGENTS.md,
/// ADR-0008. CI fails a schema change that keeps the old version number
/// ("Generated code check").
///
/// The generated half, app_database.g.dart, is written by CI's build_runner
/// run and committed back: the authoring sandbox has no Dart SDK.
library;

import 'package:drift/drift.dart';

part 'app_database.g.dart';

/// Workspaces the app has opened: Home's recents.
@DataClassName('WorkspaceRow')
class Workspaces extends Table {
  /// Stable id: `demo` for the built-in project, `project-…` for the
  /// others, `folder-…` for folders from shared storage. It never changes.
  TextColumn get id => text()();

  /// What the user sees.
  TextColumn get name => text()();

  /// When it was last opened, milliseconds since the epoch (UTC).
  IntColumn get lastOpenedAt => integer()();

  /// `project` or `folder` (schema v2).
  TextColumn get kind => text().withDefault(const Constant('project'))();

  /// A project's folder name, or a folder's tree URI; empty for a folder
  /// whose place was never recorded (schema v2).
  TextColumn get location => text().withDefault(const Constant(''))();

  /// The place as the recents show it (schema v2).
  TextColumn get displayPath => text().withDefault(const Constant(''))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// What each workspace's explorer showed (schema v2): the expanded folders
/// and how far the tree was scrolled.
@DataClassName('WorkspaceViewRow')
class WorkspaceViews extends Table {
  TextColumn get workspaceId => text()();

  /// The expanded folders' workspace paths, as a JSON list.
  TextColumn get expanded => text().withDefault(const Constant('[]'))();

  /// The tree's scroll offset in logical pixels.
  RealColumn get scrollOffset => real().withDefault(const Constant(0.0))();

  /// When the view was written, milliseconds since the epoch (UTC).
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId};
}

/// Each workspace's tabs, in order, with the cursor and scroll position
/// they had.
@DataClassName('OpenTabRow')
class OpenTabs extends Table {
  TextColumn get workspaceId => text()();

  /// Workspace-relative path.
  TextColumn get path => text()();

  /// Place in the tab strip, from 0.
  IntColumn get position => integer()();

  /// The tab that was showing.
  BoolColumn get active => boolean().withDefault(const Constant(false))();

  /// Selection in UTF-16 offsets; null when the editor never reported one.
  IntColumn get selectionAnchor => integer().nullable()();
  IntColumn get selectionHead => integer().nullable()();

  /// Vertical scroll offset in CSS pixels.
  RealColumn get scrollTop => real().withDefault(const Constant(0.0))();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId, path};
}

/// The hot-exit journal's head: one row per document with unsaved changes,
/// holding its whole text at one version.
@DataClassName('JournalDocumentRow')
class JournalDocuments extends Table {
  TextColumn get workspaceId => text()();

  /// Workspace-relative path.
  TextColumn get path => text()();

  /// The document's text ("\n" line breaks) at [snapshotVersion].
  TextColumn get snapshotText => text()();

  /// The editor's version of [snapshotText]; recorded changes continue
  /// from it.
  IntColumn get snapshotVersion => integer()();

  /// SHA-256 (hex) of the saved text the edits were made against; null
  /// when the file was gone.
  TextColumn get baseDigest => text().nullable()();

  /// `lf` or `crlf`: how the document is saved.
  TextColumn get lineEnding => text()();

  /// Whether the document is saved with a UTF-8 byte-order mark.
  BoolColumn get bom => boolean()();

  /// One of `editorLanguageIds`.
  TextColumn get language => text()();

  /// When the snapshot was written, milliseconds since the epoch (UTC).
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {workspaceId, path};
}

/// The hot-exit journal's tail: the change sets the editor sent after each
/// document's snapshot, in arrival order ([id]).
@DataClassName('JournalChangeRow')
@TableIndex(
  name: 'journal_changes_document',
  columns: {#workspaceId, #path, #version},
)
class JournalChanges extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get workspaceId => text()();

  /// Workspace-relative path.
  TextColumn get path => text()();

  /// The version this change applies to, and the version it makes.
  IntColumn get baseVersion => integer()();
  IntColumn get version => integer()();

  /// Text lengths before and after, checked on replay.
  IntColumn get lengthBefore => integer()();
  IntColumn get lengthAfter => integer()();

  /// CodeMirror change-set JSON (core/editor/change_set.dart).
  TextColumn get changes => text()();
}

@DriftDatabase(
  tables: [
    Workspaces,
    OpenTabs,
    JournalDocuments,
    JournalChanges,
    WorkspaceViews,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// Over [executor]: the app's file (drift_session_store.dart) or, in
  /// tests, an in-memory database.
  AppDatabase(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        // Version 1 knew the demo project and, from Phase 3 W2, folders by
        // a hash of their URI ("folder-…"), but not where a folder is:
        // Home's recents find the places again, among the app's grants and
        // in the shell's open folder (recents_controller.dart), and a
        // folder found in neither can be reconnected.
        await migrator.addColumn(workspaces, workspaces.kind);
        await migrator.addColumn(workspaces, workspaces.location);
        await migrator.addColumn(workspaces, workspaces.displayPath);
        await migrator.createTable(workspaceViews);
        await customStatement(
          "UPDATE workspaces SET kind = 'folder' WHERE id LIKE 'folder-%'",
        );
        await customStatement(
          "UPDATE workspaces SET location = id WHERE kind = 'project'",
        );
      }
    },
    beforeOpen: (details) async {
      // Write-ahead logging: appending a change is one short write, and a
      // killed process loses nothing that was committed. NORMAL sync is
      // durable against process death, which is what the journal is for.
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA synchronous = NORMAL');
    },
  );
}
