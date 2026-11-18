# ADR-0009: GitHub Actions as the build authority; evidence-gate CI philosophy from t1

**Status:** Accepted · 2026-11-05 · amended 2026-11-11 (owner decisions: arm64 runs on Firebase Test Lab; no nightly run) · as built in Phase 4 W5 (2026-11-18: the runtime gates and the Test Lab job)

## Context
The development sandbox cannot build Android (no Flutter/Java/Android SDK; dl.google.com unreachable). The user explicitly wants GitHub Actions for builds. The audited t1 project demonstrates a rigorous CI discipline: JVM gates, emulator E2E on TCG `aosp_atd` images, exec-model publishability gates, size/alignment checks, fail-closed signing — with evidence published per run.

## Decision
- **GitHub Actions is the build authority from Phase 1.** No local-only "it builds on my machine" claims; phase reports cite run ids (spec rules 15/16).
- Pipelines per BUILD_AND_RELEASE.md: `ci.yml` (PR, <15 min), `phase-gate.yml`, `runtime-gates.yml` (Phase 4+), `release.yml` (tags), `deps.yml` (monthly). *(As built in Phase 4 W5: the runtime gates are jobs of `phase-gate.yml`, not a workflow of their own; see the amendment.)*
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
- **As built (Phase 4 W5, 2026-11-18):**
  - **The runtime gates** are jobs of `phase-gate.yml`, in the same run as the emulator gate, so a work package still has one gate. One job builds the debug APK with the x86_64 payload and its test APK. One leg per API level (26, 27, 28, 34, 36) runs the runtime's instrumented tests on them (`app/tool/ci/runtime_gate_leg.sh`). A last job keeps the legs' evidence in `app/ci-results/runtime-gates/` and fails the run when a leg failed.
  - **t1's evidence rule:** `app/tool/ci/gate_results.py` judges each run the way t1's `assert-gate-results.py` does. Every expected class runs at least its number of tests, and none fails or is skipped. It also requires figures, such as every audit at 0.
  - **The arm64 leg** is `ci.yml`'s `testlab` job. A commit with `[testlab]` in its subject line starts it, after a plain CI run of the change has passed (the owner's rule, BUILD_AND_RELEASE §4). It builds the arm64 payload APK and runs the same tests, and the session store's two sync modes (ADR-0008), on one physical phone with Android 14 or later. That is one test of the day's five.
  - **The API floor:** `ci.yml`'s *API floor* step checks the debug APK's dex against the SDK's API database on every push (ADR-0007).
