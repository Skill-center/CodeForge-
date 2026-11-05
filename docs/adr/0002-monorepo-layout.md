# ADR-0002: Monorepo — one Flutter package, vendored Gradle modules, TS editor workspace

**Status:** Accepted · 2026-11-05

## Context
CodeForge spans Dart UI, a TypeScript editor bundle, Kotlin/Java native modules, and a Python runtime supply chain. Options: multi-repo, Melos multi-package Flutter monorepo, or a single repo with one Flutter package + sibling toolchains.

## Decision
Single repository (structure: REPOSITORY_STRUCTURE.md):
- `app/` — one Flutter package with enforced internal boundaries (design_system / core / services / features / routing), CI import lint.
- `editor/` — npm workspace building the CM6 (+challenger) bundles with esbuild; artifacts consumed by the Android build, never committed.
- `native/` + `runtime/` — vendored t1 modules and payload scripts (Phase 4), with PROVENANCE.md.
- No Melos, no package extraction until a second consumer exists.

## Consequences
- One PR can change UI + protocol + native coherently; one CI graph; atomic versioning.
- Boundary discipline comes from lint rules + review, not package walls — cheaper now, extractable later (trigger documented).
- Generated payloads/bundles stay out of Git (size, reproducibility); CI is the artifact authority.
