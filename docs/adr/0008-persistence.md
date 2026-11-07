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
- Backup/restore (Phase 10) exports prefs + Drift DB + workspace manifest — one documented format.

## Amendment — Phase 2 W5 (2026-11-07): buffer journals in SQLite, not files

**Status:** Accepted · 2026-11-07

The decision above put buffer journals in files, with only their metadata in Drift. As built, the whole journal is in the database:

- `journal_documents` has one row per document with unsaved changes. Each row holds the last full snapshot of the text and the editor version it was taken at. It also holds `base_digest`, the SHA-256 of the saved text the edits were made against (null for a file that did not exist yet), plus the line ending, BOM and language.
- `journal_changes` holds the editor's change sets appended since that snapshot, in order.

**Why.** Each snapshot must replace, in one step, every change it covers. With files, that needs a rename protocol spanning a text file and a change log, plus recovery for each crash point between them. In SQLite it is one transaction (WAL mode, `synchronous = NORMAL`). A process death leaves either the old journal or the new one, and both replay to text the user had. `NORMAL` keeps every committed write through an app crash. An operating-system crash or power cut can roll back the last few commits, losing the last moments of typing, but cannot corrupt the database. `FULL` would close that gap by syncing to storage on every keystroke batch, a cost to measure in W7 before paying it. One store also means one backup format (Phase 10) and migration tests that cover the journal.

**Cost.** Each snapshot writes the document's whole text into SQLite. Timed snapshots of documents over 512 KiB happen at most once a minute; tab switches and pauses still take one. W7 measures this with large files. Runtime markers stay in files, as decided.

**Schema and migrations.** The schema starts at v1 (`app/lib/services/storage/app_database.dart`), with its dump in `app/drift_schemas/app/drift_schema_v1.json`. The migration harness is `app/test/drift/app/`: a v1 fixture goes through drift_dev's `SchemaVerifier` there. Each later version adds its dump, its migration step and a fixture test from the previous version. The code generated from the schema (`*.g.dart`, `*.steps.dart`, the test helpers) is produced by CI's bootstrap mode, committed, and checked as current on every run (TESTING.md §1.2).
