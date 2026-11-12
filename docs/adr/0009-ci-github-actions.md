# ADR-0009: GitHub Actions as the build authority; evidence-gate CI philosophy from t1

**Status:** Accepted · 2026-11-05 · amended 2026-11-11 (owner decisions: arm64 runs on Firebase Test Lab; no nightly run)

## Context
The development sandbox cannot build Android (no Flutter/Java/Android SDK; dl.google.com unreachable). The user explicitly wants GitHub Actions for builds. The audited t1 project demonstrates a rigorous CI discipline: JVM gates, emulator E2E on TCG `aosp_atd` images, exec-model publishability gates, size/alignment checks, fail-closed signing — with evidence published per run.

## Decision
- **GitHub Actions is the build authority from Phase 1.** No local-only "it builds on my machine" claims; phase reports cite run ids (spec rules 15/16).
- Pipelines per BUILD_AND_RELEASE.md: `ci.yml` (PR, <15 min), `phase-gate.yml`, `runtime-gates.yml` (Phase 4+), `release.yml` (tags), `deps.yml` (monthly).
- Adopt t1 patterns: pinned toolchains, SHA-verified payloads, `assert-gate-results.py`-style evidence files, generous adb timeouts for TCG emulators, fail-closed signing, per-device bundle-size arithmetic.
- **Artifacts + job summaries instead of t1's hundreds of diagnostics branches** (repo hygiene); optional single orphan branch for gate JSON history.
- arm64 hardware gates via self-hosted runner when available; until then, explicit manual-checklist artifacts (device, build hash, operator) — never silent skips. *(Superseded on 2026-11-11: see the amendment.)*
- Least-privilege tokens; no secrets on fork PRs.

## Consequences
- Every claim is reproducible from a run id; CI minutes are the cost of honesty (heavy gates nightly/phase-bounded, not per-PR).
- The repo stays clean; evidence retention 90 days via artifacts.
- Owner action eventually needed: arm64 device runner or manual gate sessions (tracked in ROADMAP decision queue). *Decided on 2026-11-11: see the amendment.*

## Amendment (2026-11-11, owner decisions)
- **arm64 hardware:** Firebase Test Lab's physical devices run the tests that need no computer attached: the runtime's instrumentation tests (`ExecModelTest`, `SealedShellTest`) and the in-app benchmark, from a CI job. Its free tier allows about five physical-device runs a day. The host-driven gate groups (the folder picker, the key injector) stay on the emulator, and the owner's phone sessions cover what neither can, each recorded with device, build hash and operator. Owner action by Phase 4: a free Firebase project and one CI credential (a GitHub secret). This replaces the self-hosted runner: GitHub advises against self-hosted runners on public repositories.
- **Update (2026-11-12, found while planning Phase 4):** Firebase has deprecated Test Lab and shuts it down on 30 September 2027. Its successor, Google Cloud's Developer Device Platform, requires billing. Until then the Spark plan's 10 virtual-device and 5 physical-device runs a day stay, so Test Lab still serves Phase 4. What runs the arm64 tests after that is in ROADMAP's decision queue.
- **No nightly run:** the emulator gate runs once per work package (`[phase-gate]` commits). All work stays on the working branch until v1 or later, and GitHub runs scheduled workflows only from the default branch, so none is scheduled.
