# Build & Release

**Status:** Design accepted Phase 0 (ADR-0009/0010) · Workflows are implemented in Phase 1 W1 — this document is their spec. Nothing here claims a pipeline exists yet.

---

## 1. Principles (adopted from the audited t1 CI)

1. **Evidence gates, not status badges.** Every release-blocking claim (exec model, bundle size, tests) is a CI job that uploads machine-readable results; phase reports cite run ids. t1's `assert-gate-results.py` pattern is reused: a gate that can't produce its evidence file fails.
2. **Fail closed.** Unsigned release artifacts are labeled and never published; bundle tasks refuse targetSdk < 36 (t1 guard carried over); size gate fails on per-device > 200 MB.
3. **PRs are cheap, gates are thorough.** PR pipeline < 15 min; heavy emulator/runtime gates nightly + at phase boundaries.
4. **Artifacts, not diagnostics branches.** t1 published evidence to hundreds of `diagnostics/*` branches; CodeForge uses workflow artifacts + job summaries (retention 90 days) and a single `ci-evidence` orphan branch only for gate JSON history if needed.
5. **Reproducibility:** pinned toolchains (Flutter version file, Gradle wrapper, NDK pin, Node version file, lockfiles), pinned bootstrap/package SHA-256s; release notes record all pins + bundle hashes.

## 2. Pipeline inventory (Phase 1 creates the first two)

| Workflow | Trigger | Jobs | Gate? |
|---|---|---|---|
| `ci.yml` | every PR + push to main/arena branches | Dart analyze/format/test (unit+widget+goldens) · import-boundary lint · Kotlin/JVM tests (from Ph. 4) · editor JS build+vitest (from Ph. 2) · `flutter build apk --debug` · license check · lockfile drift check | PR merge blocker |
| `phase-gate.yml` | manual + phase tags | full test matrix · emulator instrumented (API 34/36 x86_64 `aosp_atd`) · perf benchmarks · size report | phase exit blocker |
| `runtime-gates.yml` | changes under native/, runtime/ + nightly (Ph. 4+) | payload build (pins verified) · `ExecModelTest` + `SealedShellTest` on 34/36 · `ExecAudit`=0 · page-alignment check · bundle-size check · arm64 device leg (self-hosted runner, see §4) | release blocker |
| `release.yml` | version tag `v*` | build GitHub "full" APK (arm64 + x86_64) · build Play AAB (arm64 base + PFD pack) · sign (secrets) · hashes + pins manifest · GitHub Release draft · Play upload to internal track (manual promote) | — |
| `deps.yml` | monthly cron | dependency update PR (pub/npm/gradle) with full ci.yml | — |

## 3. Toolchain pins in CI

- Flutter: `.flutter-version` (3.47.x) honored by `subosito/flutter-action`; Java: Temurin 17; Android SDK 36 via `android-actions/setup-android`; NDK 27.2.12479018; Node: `.nvmrc` (24 LTS) for editor workspace; Gradle wrapper 9.2.1 (committed).
- Caches: pub, gradle, npm keyed by lockfiles; emulator snapshots cached (t1 pattern: TCG `aosp_atd` images, no KVM on GitHub runners; generous adb timeouts — t1 hit ddmlib API-level-1 misdetection, fix carried over).
- Secrets (release only): `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`, `PLAY_SERVICE_ACCOUNT_JSON`. Never available to fork PRs. `GITHUB_TOKEN` least privilege per job.

## 4. Device testing

- **Emulators (CI-owned):** x86_64 API 34 & 36 — correctness gates (t1-proven).
- **arm64 hardware (owner device or self-hosted runner):** required for Phase 4 exit (sealed-on-arm64 gap R2), perf budgets, IME matrix, release sign-off. Setup: a self-hosted GitHub Actions runner on a machine with the device attached (`adb`), labeled `arm64-device`; jobs tagged `runs-on: [self-hosted, arm64-device]`. Until a runner exists, gate jobs produce a **manual-checklist artifact** and the phase report records device + build hash + operator — never a silent skip.

## 5. Versioning & artifacts

- SemVer `MAJOR.MINOR.PATCH`; `versionName` from tag, `versionCode` monotonic (CI run number + offset). Phase milestones tag `v0.N.0`; public release starts `v1.0.0` at Phase 10 exit.
- GitHub Release: `CodeForge-vX.Y.Z-arm64.apk` (full), `-x86_64.apk` (emulator/dev), `SHA256SUMS`, `PINS.json` (Flutter/AGP/NDK/bootstrap/package versions), source tarball link. Pre-release flag until Phase 10.
- Play: AAB arm64 base + `pack_buildtools` on-demand; internal → closed → production promotion is manual; data-safety answers from t1 `store/data-safety.md` template (nothing collected).
- **License gate:** no binary release until ADR-0011 resolved + `THIRD_PARTY_NOTICES.md` + source-offer for GPL userland components published with the release.

## 6. Local developer builds (documented for CONTRIBUTING)

```bash
# Phase 1+ (UI only)
cd app && flutter pub get && flutter test && flutter build apk --debug

# Phase 2+ (editor bundle first)
cd editor && npm ci && npm run build   # outputs to app/assets/editor/

# Phase 4+ (runtime payload; network needed once, SHA-verified)
python3 runtime/fetch-core-debs.py && ./gradlew :app:assembleDebug
```

Sandbox note (honesty): the Phase 0 environment had no Flutter/Java/Android SDK and no access to `dl.google.com`, so **all builds happen in GitHub Actions or on developer machines** — this repo's CI is the build authority from day one.
