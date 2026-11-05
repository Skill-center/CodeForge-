# ADR-0009: GitHub Actions as the build authority; evidence-gate CI philosophy from t1

**Status:** Accepted · 2026-11-05

## Context
The development sandbox cannot build Android (no Flutter/Java/Android SDK; dl.google.com unreachable). The user explicitly wants GitHub Actions for builds. The audited t1 project demonstrates a rigorous CI discipline: JVM gates, emulator E2E on TCG `aosp_atd` images, exec-model publishability gates, size/alignment checks, fail-closed signing — with evidence published per run.

## Decision
- **GitHub Actions is the build authority from Phase 1.** No local-only "it builds on my machine" claims; phase reports cite run ids (spec rules 15/16).
- Pipelines per BUILD_AND_RELEASE.md: `ci.yml` (PR, <15 min), `phase-gate.yml`, `runtime-gates.yml` (Phase 4+), `release.yml` (tags), `deps.yml` (monthly).
- Adopt t1 patterns: pinned toolchains, SHA-verified payloads, `assert-gate-results.py`-style evidence files, generous adb timeouts for TCG emulators, fail-closed signing, per-device bundle-size arithmetic.
- **Artifacts + job summaries instead of t1's hundreds of diagnostics branches** (repo hygiene); optional single orphan branch for gate JSON history.
- arm64 hardware gates via self-hosted runner when available; until then, explicit manual-checklist artifacts (device, build hash, operator) — never silent skips.
- Least-privilege tokens; no secrets on fork PRs.

## Consequences
- Every claim is reproducible from a run id; CI minutes are the cost of honesty (heavy gates nightly/phase-bounded, not per-PR).
- The repo stays clean; evidence retention 90 days via artifacts.
- Owner action eventually needed: arm64 device runner or manual gate sessions (tracked in ROADMAP decision queue).
