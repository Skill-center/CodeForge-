/// [SessionStore] over the app database (ADR-0008).
///
/// Every call is one statement or one transaction on drift's background
/// isolate, so the UI isolate never waits on SQLite. Calls run in the order
/// they are made (drift queues them on its single connection), which the
/// journal relies on: a change appended after a snapshot is stored after
/// it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../../core/editor/journal.dart';
import '../../core/errors/failure.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_location.dart';
import '../../core/files/workspace_path.dart';
import '../../core/logging/logger.dart';
import 'app_database.dart';
import 'session_store.dart';

/// The database file's name inside the app's files directory.
const String appDatabaseFileName = 'codeforge.sqlite';

/// The app database file inside the folder [directory] gives, opened on a
/// background isolate the first time it is used — never at bootstrap, so it
/// cannot delay the first frame.
QueryExecutor openAppDatabase(Future<String> Function() directory) {
  return LazyDatabase(() async {
    final folder = await directory();
    return NativeDatabase.createInBackground(
      File('$folder/$appDatabaseFileName'),
    );
  });
}

final class DriftSessionStore implements SessionStore {
  DriftSessionStore(this._db);

  final AppDatabase _db;

  static int _now() => DateTime.now().toUtc().millisecondsSinceEpoch;

  /// Runs [body], turning any failure into a logged [StorageFailure].
  Future<Result<T>> _guard<T>(String what, Future<T> Function() body) async {
    try {
      return Ok(await body());
    } on Object catch (error) {
      appLogger.error(
        'storage',
        'session_store_failed',
        fields: {'op': what, 'error': '$error'},
      );
      return Err(StorageFailure('Could not $what.', cause: error));
    }
  }

  @override
  Future<Result<void>> touchWorkspace(
    WorkspaceLocation workspace, {
    required String displayPath,
  }) {
    return _guard('record the workspace', () async {
      await _db
          .into(_db.workspaces)
          .insertOnConflictUpdate(
            WorkspacesCompanion.insert(
              id: workspace.id,
              name: workspace.name,
              lastOpenedAt: _now(),
              kind: Value(workspace.kind.name),
              location: Value(workspace.location),
              displayPath: Value(displayPath),
            ),
          );
    });
  }

  @override
  Future<Result<List<WorkspaceRecord>>> loadWorkspaces() {
    return _guard('read the recent workspaces', () async {
      final query = _db.select(_db.workspaces)
        ..orderBy([(t) => OrderingTerm.desc(t.lastOpenedAt)]);
      final rows = await query.get();
      final kinds = WorkspaceKind.values.asNameMap();
      return [
        for (final row in rows)
          if (kinds[row.kind] case final kind?)
            WorkspaceRecord(
              id: row.id,
              kind: kind,
              name: row.name,
              location: row.location,
              displayPath: row.displayPath,
              lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(
                row.lastOpenedAt,
                isUtc: true,
              ),
            ),
      ];
    });
  }

  @override
  Future<Result<void>> moveWorkspace(
    String id, {
    required String name,
    required String location,
    required String displayPath,
  }) {
    return _guard('update the workspace', () async {
      final update = _db.update(_db.workspaces)..where((t) => t.id.equals(id));
      await update.write(
        WorkspacesCompanion(
          name: Value(name),
          location: Value(location),
          displayPath: Value(displayPath),
        ),
      );
    });
  }

  @override
  Future<Result<void>> forgetWorkspace(String id) {
    return _guard('forget the workspace', () async {
      await _db.transaction(() async {
        await (_db.delete(_db.workspaces)..where((t) => t.id.equals(id))).go();
        await (_db.delete(
          _db.openTabs,
        )..where((t) => t.workspaceId.equals(id))).go();
        await (_db.delete(
          _db.journalDocuments,
        )..where((t) => t.workspaceId.equals(id))).go();
        await (_db.delete(
          _db.journalChanges,
        )..where((t) => t.workspaceId.equals(id))).go();
        await (_db.delete(
          _db.workspaceViews,
        )..where((t) => t.workspaceId.equals(id))).go();
      });
    });
  }

  @override
  Future<Result<ExplorerView?>> loadView(String workspaceId) {
    return _guard('read the explorer view', () async {
      final query = _db.select(_db.workspaceViews)
        ..where((t) => t.workspaceId.equals(workspaceId));
      final row = await query.getSingleOrNull();
      if (row == null) {
        return null;
      }
      return ExplorerView(
        expanded: _decodeExpanded(row.expanded),
        scrollOffset: row.scrollOffset,
      );
    });
  }

  @override
  Future<Result<void>> saveView(String workspaceId, ExplorerView view) {
    return _guard('save the explorer view', () async {
      final expanded = view.expanded.take(maxExpandedFolders).toList()..sort();
      await _db
          .into(_db.workspaceViews)
          .insertOnConflictUpdate(
            WorkspaceViewsCompanion.insert(
              workspaceId: workspaceId,
              expanded: Value(jsonEncode(expanded)),
              scrollOffset: Value(view.scrollOffset),
              updatedAt: _now(),
            ),
          );
    });
  }

  /// The expanded folders written as [json]: valid workspace paths only, at
  /// most [maxExpandedFolders]; nothing when it does not read.
  static Set<String> _decodeExpanded(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List<Object?>) {
        return const {};
      }
      return {
        for (final path in decoded.take(maxExpandedFolders))
          if (path is String && isWorkspacePath(path)) path,
      };
    } on FormatException {
      return const {};
    }
  }

  @override
  Future<Result<List<SavedTab>>> loadTabs(String workspaceId) {
    return _guard('read the open tabs', () async {
      final query = _db.select(_db.openTabs)
        ..where((t) => t.workspaceId.equals(workspaceId))
        ..orderBy([(t) => OrderingTerm.asc(t.position)]);
      final rows = await query.get();
      return [
        for (final row in rows)
          SavedTab(
            path: row.path,
            active: row.active,
            selectionAnchor: row.selectionAnchor,
            selectionHead: row.selectionHead,
            scrollTop: row.scrollTop,
          ),
      ];
    });
  }

  @override
  Future<Result<void>> saveTabs(String workspaceId, List<SavedTab> tabs) {
    return _guard('save the open tabs', () async {
      await _db.transaction(() async {
        final clear = _db.delete(_db.openTabs)
          ..where((t) => t.workspaceId.equals(workspaceId));
        await clear.go();
        await _db.batch((batch) {
          batch.insertAll(_db.openTabs, [
            for (final (index, tab) in tabs.indexed)
              OpenTabsCompanion.insert(
                workspaceId: workspaceId,
                path: tab.path,
                position: index,
                active: Value(tab.active),
                selectionAnchor: Value(tab.selectionAnchor),
                selectionHead: Value(tab.selectionHead),
                scrollTop: Value(tab.scrollTop),
              ),
          ], mode: InsertMode.insertOrReplace);
        });
      });
    });
  }

  @override
  Future<Result<List<JournalEntry>>> loadJournal(String workspaceId) {
    return _guard('read the unsaved-changes journal', () async {
      // One transaction: the heads and their changes as of one moment.
      return _db.transaction(() async {
        final heads = _db.select(_db.journalDocuments)
          ..where((t) => t.workspaceId.equals(workspaceId))
          ..orderBy([(t) => OrderingTerm.asc(t.updatedAt)]);
        final tail = _db.select(_db.journalChanges)
          ..where((t) => t.workspaceId.equals(workspaceId))
          ..orderBy([(t) => OrderingTerm.asc(t.id)]);
        final documents = await heads.get();
        final changeRows = await tail.get();
        final changes = <String, List<JournalChange>>{};
        for (final row in changeRows) {
          final decoded = JournalChange.decodeChanges(row.changes);
          if (decoded == null) {
            // Replay stops at the gap this leaves, keeping what came before.
            appLogger.warn(
              'storage',
              'journal_change_unreadable',
              fields: {'path': row.path, 'version': row.version},
            );
            continue;
          }
          (changes[row.path] ??= []).add(
            JournalChange(
              baseVersion: row.baseVersion,
              version: row.version,
              lengthBefore: row.lengthBefore,
              lengthAfter: row.lengthAfter,
              changes: decoded,
            ),
          );
        }
        return [
          for (final row in documents)
            JournalEntry(
              snapshot: JournalSnapshot(
                workspaceId: row.workspaceId,
                path: row.path,
                text: row.snapshotText,
                version: row.snapshotVersion,
                baseDigest: row.baseDigest,
                format: TextFormat(
                  lineEnding:
                      LineEnding.values.asNameMap()[row.lineEnding] ??
                      LineEnding.lf,
                  bom: row.bom,
                ),
                language: row.language,
              ),
              changes: changes[row.path] ?? const [],
            ),
        ];
      });
    });
  }

  @override
  Future<Result<void>> writeSnapshot(
    JournalSnapshot snapshot, {
    bool restart = false,
  }) {
    return _guard('write the unsaved-changes journal', () async {
      await _db.transaction(() async {
        await _db
            .into(_db.journalDocuments)
            .insertOnConflictUpdate(
              JournalDocumentsCompanion.insert(
                workspaceId: snapshot.workspaceId,
                path: snapshot.path,
                snapshotText: snapshot.text,
                snapshotVersion: snapshot.version,
                baseDigest: Value(snapshot.baseDigest),
                lineEnding: snapshot.format.lineEnding.name,
                bom: snapshot.format.bom,
                language: snapshot.language,
                updatedAt: _now(),
              ),
            );
        final covered = _db.delete(_db.journalChanges)
          ..where(
            (t) =>
                t.workspaceId.equals(snapshot.workspaceId) &
                t.path.equals(snapshot.path),
          );
        if (!restart) {
          covered.where(
            (t) => t.version.isSmallerOrEqualValue(snapshot.version),
          );
        }
        await covered.go();
      });
    });
  }

  @override
  Future<Result<void>> appendChange(
    String workspaceId,
    String path,
    JournalChange change,
  ) {
    return _guard('record an edit in the unsaved-changes journal', () async {
      await _db
          .into(_db.journalChanges)
          .insert(
            JournalChangesCompanion.insert(
              workspaceId: workspaceId,
              path: path,
              baseVersion: change.baseVersion,
              version: change.version,
              lengthBefore: change.lengthBefore,
              lengthAfter: change.lengthAfter,
              changes: change.encodeChanges(),
            ),
          );
    });
  }

  @override
  Future<Result<void>> discardJournal(String workspaceId, String path) {
    return _guard('clear the unsaved-changes journal', () async {
      await _db.transaction(() async {
        final head = _db.delete(_db.journalDocuments)
          ..where(
            (t) => t.workspaceId.equals(workspaceId) & t.path.equals(path),
          );
        final tail = _db.delete(_db.journalChanges)
          ..where(
            (t) => t.workspaceId.equals(workspaceId) & t.path.equals(path),
          );
        await head.go();
        await tail.go();
      });
    });
  }

  @override
  Future<void> close() => _db.close();
}
