# Build & Release

**Status:** Design accepted Phase 0 (ADR-0009/0010) · **`ci.yml` and `phase-gate.yml` are implemented (Phase 1)**, with the editor job and the editor's gate groups added in Phase 2 (§2.2). §2.1 says how they differ from this spec; `runtime-gates.yml`, `release.yml` and `deps.yml` remain spec until their phases.

---

## 1. Principles (adopted from the audited t1 CI)

1. **Evidence gates, not status badges.** Every release-blocking claim (exec model, bundle size, tests) is a CI job that uploads machine-readable results; phase reports cite run ids. t1's `assert-gate-results.py` pattern is reused: a gate that can't produce its evidence file fails.
2. **Fail closed.** Unsigned release artifacts are labeled and never published; bundle tasks refuse targetSdk < 36 (t1 guard carried over); size gate fails on per-device > 200 MB.
3. **PRs are cheap, gates are thorough.** PR pipeline < 15 min; heavy emulator/runtime gates once per work package and at phase boundaries (no nightly run: owner decision 2026-11-11, ADR-0009 amendment).
4. **Artifacts, not diagnostics branches.** t1 published evidence to hundreds of `diagnostics/*` branches; CodeForge uses workflow artifacts + job summaries (retention 90 days) and a single `ci-evidence` orphan branch only for gate JSON history if needed.
5. **Reproducibility:** pinned toolchains (Flutter version file, Gradle wrapper, NDK pin, Node version file, lockfiles), pinned bootstrap/package SHA-256s; release notes record all pins + bundle hashes.

## 2. Pipeline inventory (Phase 1 creates the first two)

| Workflow | Trigger | Jobs | Gate? |
|---|---|---|---|
| `ci.yml` | every PR + push to main/arena branches | Dart analyze/format/test (unit+widget+goldens, with coverage) · import-boundary lint · Kotlin/JVM tests (since Phase 3 W1) · editor JS build+vitest (from Ph. 2) · `flutter build apk --debug` + SHA-256/size · license check · lockfile drift check | PR merge blocker |
| `phase-gate.yml` | `[phase-gate]` in the head commit message (manual dispatch once on `main`) | emulator integration tests on API 36 x86_64 `google_apis` (KVM) incl. the process-death restore pair · cold-start measurement on a release x86_64 APK · size report (`perf.json`) | phase exit blocker |
| `runtime-gates.yml` | changes under native/, runtime/ (Ph. 4+; no nightly run, ADR-0009 amendment) | payload build (pins verified) · `ExecModelTest` + `SealedShellTest` on 34/36 · `ExecAudit`=0 · page-alignment check · bundle-size check · arm64 device leg (Firebase Test Lab, see §4) | release blocker |
| `release.yml` | version tag `v*` | build GitHub "full" APK (arm64 + x86_64) · build Play AAB (arm64 base + PFD pack) · sign (secrets) · hashes + pins manifest · GitHub Release draft · Play upload to internal track (manual promote) | — |
| `deps.yml` | monthly cron | dependency update PR (pub/npm/gradle) with full ci.yml | — |

### 2.1 As built in Phase 1 — the evidence channel

The authoring sandbox cannot reach GitHub's log and artifact download hosts, so principle 4 is applied with one deliberate exception: **diagnostics are committed back to the working branch**, always with `[skip ci]`, and only when asked for:

- **`[bootstrap]`** in a commit message makes `ci.yml` run `dart fix` + `dart format`, regenerate golden baselines on the Linux runner (the `test/goldens` suites only), and commit both back. Every quality gate then writes its full output to `app/ci-results/*.txt` (goldens, analyze, format, imports, licenses, lockfile, test, build, apk, coverage), which is committed back too. The run's own verdict is the evidence. Plain pushes run the same gates without any commit-back. When tests fail, the last 40 lines of their output also go out as a check-run annotation, which the API can read even after a plain push.
- **Generated code (Phase 2 W5).** `[bootstrap]` also runs the code generators and commits their output with the lockfile: `build_runner` (Drift's `*.g.dart`), `drift_dev make-migrations` (schema dumps in `app/drift_schemas/`, and from the second schema version on the migration steps) and `drift_dev schema generate` (the migration-test helpers in `app/test/drift/`). Every run's "Generated code check" regenerates and fails on any difference. The phase gate checks out the pushed commit, not the commit-back, so it generates before building.
- **Coverage** (`ci-results/coverage.txt`) counts hand-written code only. Generated `*.g.dart` and `*.steps.dart` files are left out, as they are for analysis. Their line count is printed as `generated_lines_excluded`. Totals from before W5 had no generated code, so they compare directly.
- **`[phase-gate]`** runs `phase-gate.yml`; its evidence lives in **`app/ci-results/gate/`**, a directory owned by the gate script (host/acceleration, readiness timings, every test attempt with exit codes, restore-pair proof, cold-start samples, `perf.json`, logcat and emulator tails). `tool/ci/commit_gate_evidence.sh` commits it by snapshotting the directory, resetting to the remote tip and restoring only that directory — never a rebase of a dirty runner checkout, so concurrent commit-backs cannot collide. The key files are also published as check-run annotations (`tool/ci/annotate_gate_evidence.sh`), readable through the API if a push ever fails.
- Commit-backs from `ci.yml` push through `tool/ci/push_with_retry.sh` (fetch + rebase on rejection).
- **Phone test build (Phase 2 W3):** after the release x86_64 APK, `phase-gate.yml` builds the editor benchmark pages (`npm run build:bench`) and then a **profile arm64 APK** that bundles them. It is uploaded as the artifact `codeforge-phone-profile-arm64` (kept 30 days), and its SHA-256 is printed in the step log. Profile mode is optimised like release but keeps Settings → Developer (`!kReleaseMode`). It is signed with the runner's throwaway debug key, which changes with every run, so an earlier CodeForge build must be uninstalled before a new one installs. The release APK is built before the pages exist, so it never contains them.
- Infrastructure retries are explicit and logged: an integration test is retried only on known *infrastructure* signatures (package service missing, broken adb pipe, device offline, …) or when an attempt outlives its 10-minute limit (`flutter test` can wait forever for an app that never connects; gate 42500759166 sat 65 minutes after installing the smoke test, until the job's limit stopped it); an assertion failure is never retried. Every attempt is listed in `attempts.txt`.

### 2.2 As built in Phase 2: the editor job and the gate's groups

- **The `editor` job** (`ci.yml`) runs in `editor/`, with Node from `editor/.nvmrc`, an npm cache keyed by `editor/package-lock.json` and a 15-minute limit. Its steps, in order:
  1. `npm ci` from the lockfile.
  2. `tsc --noEmit`.
  3. vitest: unit and contract tests.
  4. The licence gate for the page's runtime packages (`tool/check_licenses.mjs`).
  5. The page build (`tool/build.mjs`), which writes `app/assets/editor/editor.html` and its `manifest.json`.
  6. Page verification (`tool/verify_bundle.mjs`):
     - exactly one inline script, whose hash the CSP pins and the manifest records;
     - no external references in the markup, and a default-deny CSP;
     - the manifest's SHA-256 matches the file, and the gzipped size is within budget;
     - booted in happy-dom, the page announces `editor.ready`, answers protocol requests, batches an edit into one `doc.changed`, rejects a bad payload, and logs no errors.

  Each step records its output in `editor-results/` and may fail on its own, so one run reports every problem. "Enforce editor gates" then fails the job if any step failed.
- **Artifacts and the Flutter job:** the editor job uploads `editor-page` (the built page) and `editor-results`.
  - The Flutter job `needs: editor` and downloads the page into `app/assets/editor/` before it resolves dependencies, so every test run and APK uses the page built from the same commit. The page itself is gitignored.
  - In bootstrap mode the editor results are committed to `app/ci-results/editor/`.
- **The phase gate's groups** (`tool/ci/emulator_gate.sh`), in this order:
  1. `smoke`.
  2. `editor`: the bridge, on the real page.
  3. `editing` (G5).
  4. `keys` (G6), with the key injector.
  5. `editor_bench_codemirror` and `editor_bench_monaco` (G1), with the DevTools driver.
  6. `large_files_itest` (G7): an 18-minute limit and 2 attempts.
  7. The restore pair: `restore_a` → `am force-stop` → `restore_b`.
  8. The edit pair: `edit_a` → renderer crash → `am force-stop` → `edit_b`.

  The release x86_64 APK serves the cold start and the large-file group's release-memory step. The benchmark pages and the profile arm64 APK for phone runs are built after it (§2.1). The final Phase 2 gate, 42676631509, took 29 minutes, and the final CI run, 42678576228, 7 minutes.

### 2.3 Added in Phase 3

- **Kotlin unit tests** (`ci.yml`, since W1): `:app:testDebugUnitTest` (JUnit 4) runs the backup agent's tests (W1) and the storage broker's (W2), 44 in all at W3. The counts go to `ci-results/kotlin-tests.txt`, and the quality gate fails on a failure or on no tests.
- **Generated code check:** since W2 it covers Pigeon's output (`pigeons/storage_api.dart`, generated into Dart and Kotlin) and fails when a generator fails. Since schema v2 (W3) that includes Drift's migration steps (`app_database.steps.dart`), which exist from the second schema version on.
- **The phase gate's groups** after the edit pair:
  9. `backup` (W1, G6): `backup_a` → a backup → a reinstall → `backup_b` → a backup → a reinstall → `backup_c`, through Android's local transport.
  10. `folders` (W2, G1): `folders_a` → `am force-stop` → `folders_b`, with Android's folder picker driven from the host, and the host's disk checks.

  Since W3 the restore pair opens a folder through the same picker driver, and its part B switches workspaces. Since W3 the gate also hides Android's error dialogs after boot (`hide_error_dialogs`): in gate 43069846571, System UI's *Application Not Responding* dialog took the keys group's tap. A full run took 33 minutes at W1 (42862715744), 37 at W2 (43007795087, attempt 1) and 38 to 39 at W3 (43069846571, 43076652650).

## 3. Toolchain pins in CI

- Flutter: `.flutter-version` (**3.47.9**) honored by `subosito/flutter-action`; Java: Temurin 17; Android SDK 36 (runner image); NDK **28.2.13676358** (resolved by the Flutter Gradle plugin); Gradle wrapper **9.3.1** + AGP 9.1.0 (committed); Node: `.nvmrc` (24 LTS) for the editor workspace from Phase 2.
- Caches: pub, gradle, npm keyed by lockfiles. The Gradle distribution is cached by the wrapper properties and fetched with retries when the cache has none (`app/tool/ci/fetch_gradle.sh`), because services.gradle.org stalls now and then (phase gates 42477797842 and 42478331067). Emulators: GitHub's Linux runners **do** expose KVM to public repositories once a udev rule is applied — Phase 1's first six gate runs silently fell back to software emulation (the KVM probe raced the asynchronous `udevadm trigger`), with 4.5–15.6 min boots and system_server watchdog restarts. The gate now settles udev before probing, records the acceleration it actually used, and waits for a *stable* framework (three consecutive package/settings/activity-manager probes), not just `sys.boot_completed`.
- Secrets (release only): `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`, `PLAY_SERVICE_ACCOUNT_JSON`. Never available to fork PRs. `GITHUB_TOKEN` least privilege per job.

## 4. Device testing

- **Emulators (CI-owned):** x86_64 API 34 & 36 — correctness gates (t1-proven).
- **arm64 hardware:** required for Phase 4 exit (sealed-on-arm64 gap R2), perf budgets, IME matrix, release sign-off. **Owner decision 2026-11-11 (ADR-0009 amendment):** Firebase Test Lab's physical devices run the tests that need no computer attached (the runtime's instrumentation tests, the in-app benchmark) from a CI job (`gcloud firebase test android run`), with one CI credential the owner adds by Phase 4. The host-driven checks (the folder picker, the key injector, `adb`-timed measurements) stay on the emulator, and the owner's phone sessions cover the rest: those produce a **manual-checklist artifact**, and the phase report records device + build hash + operator — never a silent skip. *(Superseded plan: a self-hosted GitHub Actions runner on a machine with the device attached, labeled `arm64-device`. GitHub advises against self-hosted runners on public repositories.)*

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
npm run build:bench                    # optional, debug/profile only: benchmark pages
                                       # to app/assets/editor_bench/ (~1.3 MB gz);
                                       # never present for a release build

# Phase 4+ (runtime payload; network needed once, SHA-verified)
python3 runtime/fetch-core-debs.py && ./gradlew :app:assembleDebug
```

Sandbox note (honesty): the Phase 0 environment had no Flutter/Java/Android SDK and no access to `dl.google.com`, so **all builds happen in GitHub Actions or on developer machines** — this repo's CI is the build authority from day one.
