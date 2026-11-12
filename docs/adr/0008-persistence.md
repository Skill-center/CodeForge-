# ADR-0008: Persistence — shared_preferences for settings, Drift/SQLite for structured state

**Status:** Accepted · 2026-11-05

## Context
Spec allows SharedPreferences or DataStore for settings and SQLite/Drift for local data. Needs: trivial prefs (theme, font size) in Phase 1; versioned, queryable, migratable workspace/editor/session state from Phase 2; crash-safe dirty buffers; future extension/credential records.

## Decision
- **shared_preferences 2.5.6** behind a typed `SettingsStore` wrapper with a schema-version key — app/user preferences only.
- **Drift 2.35.3** (SQLite) introduced in Phase 2 for: workspace registry, open tabs, layout state, terminal session metadata, buffer journal metadata, (later) extension grants. One database, workspace-scoped rows, reactive queries into Riverpod.
- **Files** for buffer journals and runtime markers (t1 layout stays authoritative for runtime state; dpkg/manifest is the source of truth there, mirrored into RuntimeService). *Amended in Phase 2 W5: buffer journals live in SQLite. See the amendment below.*
- Every schema change ships a migration + fixture-based migration test (spec rule 19: stored workspace data must survive upgrades).
- DataStore (native) rejected: adds a second platform bridge for no benefit over the typed prefs wrapper.

## Consequences
- Phase 1 stays codegen-free; Drift's build_runner enters with the data layer only.
- Clear ownership: prefs = user intent, Drift = workspace truth, files = bytes, runtime markers = runtime truth.
- Backup/restore (Phase 10) exports prefs + Drift DB + workspace manifest — one documented format. Android's own backup is separate: the user's choice, off by default ([ADR-0012](0012-backup-opt-in.md), Phase 3 W1).

## Amendment — Phase 2 W5 (2026-11-07): buffer journals in SQLite, not files

**Status:** Accepted · 2026-11-07

The decision above put buffer journals in files, with only their metadata in Drift. As built, the whole journal is in the database:

- `journal_documents` has one row per document with unsaved changes. Each row holds the last full snapshot of the text and the editor version it was taken at. It also holds `base_digest`, the SHA-256 of the saved text the edits were made against (null for a file that did not exist yet), plus the line ending, BOM and language.
- `journal_changes` holds the editor's change sets appended since that snapshot, in order.

**Why.** Each snapshot must replace, in one step, every change it covers. With files, that needs a rename protocol spanning a text file and a change log, plus recovery for each crash point between them. In SQLite it is one transaction (WAL mode, `synchronous = NORMAL`). A process death leaves either the old journal or the new one, and both replay to text the user had. `NORMAL` keeps every committed write through an app crash. An operating-system crash or power cut can roll back the last few commits, losing the last moments of typing, but cannot corrupt the database. `FULL` would close that gap by syncing to storage on every keystroke batch, a cost to measure in W7 before paying it. One store also means one backup format (Phase 10) and migration tests that cover the journal.

**Cost.** Each snapshot writes the document's whole text into SQLite. Timed snapshots of documents over 512 KiB happen at most once a minute; tab switches and pauses still take one. W7 measures this with large files. Runtime markers stay in files, as decided.

**Measured in W7.** The phase gate's large-file group times the store on the emulator, with the app's database settings and `synchronous = NORMAL`, then `FULL`. The table gives the median ms per write in four gate runs (42616081317 / 42659207710 / 42665305004 / 42676631509), on hosts of different speed:

| | snapshot, `NORMAL` | snapshot, `FULL` | digest of the saved text |
|---|---|---|---|
| 1 MiB | 15 / 35 / 34 / 23 | 10 / 20 / 43 / 22 | 8 / 25 / 28 / 10 |
| 5 MiB | 85 / 109 / 133 / 87 | 98 / 82 / 127 / 77 | 41 / 67 / 77 / 65 |
| 10 MiB | 144 / 211 / 250 / 137 | 151 / 147 / 233 / 161 | 80 / 184 / 151 / 104 |
| one change | 0.3 / 0.6 / 0.8 / 0.6 | 0.7 / 0.9 / 1.2 / 0.6 | |

- **`NORMAL` stays.** On the emulator, `FULL` cost nothing measurable on snapshots (which mode was faster changed from run to run) and up to 0.4 ms more per change. The emulator's storage is virtual, though, so its syncs say little about a phone's flash, where `FULL` pays a sync on every keystroke batch. What `NORMAL` can lose is the last moments of typing after an operating-system crash or a power cut; an app crash or kill loses no committed write. That does not justify a cost on every keystroke batch that has not been measured on a phone. A phone measurement could reopen it.
- **The digest** (SHA-256 of the saved text, which the journal stores with each document and a restore compares with the file) runs on the UI isolate, once per saved text: at the first edit after an open or a save, and on restore. In a debug build it took up to 28 ms at 1 MiB and 80 to 184 ms at 10 MiB, a pause on the first edit of a very large file. These are debug-build times; if the pause shows on a phone, the digest can move to a background isolate. **Update (Phase 3 W6, owner decision 2026-11-11):** it moved without waiting for a phone. `digestText` (`app/lib/core/editor/journal.dart`) takes texts of 64 KiB and more on a background isolate, and the journal's snapshot waits for it inside its write queue; on the CI emulator, frames kept coming while a 10 MiB text was digested (PHASE_3_PLAN *As built (W6)*).

**Schema and migrations.** The schema starts at v1 (`app/lib/services/storage/app_database.dart`), with its dump in `app/drift_schemas/app/drift_schema_v1.json`. The migration harness is `app/test/drift/app/`: a v1 fixture goes through drift_dev's `SchemaVerifier` there. Each later version adds its dump, its migration step and a fixture test from the previous version. The code generated from the schema (`*.g.dart`, `*.steps.dart`, the test helpers) is produced by CI's bootstrap mode, committed, and checked as current on every run (TESTING.md §1.2).

**v2 (Phase 3 W3), the first migration.** Home's recents and the explorer's view need two changes:

- `workspaces` gains `kind` (`project` or `folder`), `location` (a project's folder name, or a folder's tree URI) and `display_path` (the place as the recents show it).
- A new table, `workspace_views`, keeps each workspace's expanded folders (a JSON list) and the explorer's scroll offset.

The step adds the columns and the table. It marks W2's `folder-…` rows as folders, and gives each project its id as its folder: v1's only project was the demo, in `demo`. v1 never recorded where a folder is, so its rows arrive without a place. Home's recents find it again among the app's grants, whose URIs hash to the same ids, or in the shell envelope's open folder, and store it. A folder found in neither shows *access lost* and can be reconnected.

The dump `drift_schema_v2.json`, the test helper `schema_v2.dart` and `app_database.steps.dart` are generated by CI. `test/drift/app/migration_test.dart` is written by hand, so drift_dev's `make-migrations` leaves it alone. drift_dev's verifier checks the 1 → 2 step, and a v1 file with a row in every table, written with v1's own SQL, opens in v2 with nothing lost (CI 43069846481).
