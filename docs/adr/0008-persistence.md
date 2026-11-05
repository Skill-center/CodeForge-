# ADR-0008: Persistence — shared_preferences for settings, Drift/SQLite for structured state

**Status:** Accepted · 2026-11-05

## Context
Spec allows SharedPreferences or DataStore for settings and SQLite/Drift for local data. Needs: trivial prefs (theme, font size) in Phase 1; versioned, queryable, migratable workspace/editor/session state from Phase 2; crash-safe dirty buffers; future extension/credential records.

## Decision
- **shared_preferences 2.5.6** behind a typed `SettingsStore` wrapper with a schema-version key — app/user preferences only.
- **Drift 2.35.3** (SQLite) introduced in Phase 2 for: workspace registry, open tabs, layout state, terminal session metadata, buffer journal metadata, (later) extension grants. One database, workspace-scoped rows, reactive queries into Riverpod.
- **Files** for buffer journals and runtime markers (t1 layout stays authoritative for runtime state; dpkg/manifest is the source of truth there, mirrored into RuntimeService).
- Every schema change ships a migration + fixture-based migration test (spec rule 19: stored workspace data must survive upgrades).
- DataStore (native) rejected: adds a second platform bridge for no benefit over the typed prefs wrapper.

## Consequences
- Phase 1 stays codegen-free; Drift's build_runner enters with the data layer only.
- Clear ownership: prefs = user intent, Drift = workspace truth, files = bytes, runtime markers = runtime truth.
- Backup/restore (Phase 10) exports prefs + Drift DB + workspace manifest — one documented format.
