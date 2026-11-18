# Build & Release

**Status:** Design accepted Phase 0 (ADR-0009/0010) · **`ci.yml` and `phase-gate.yml` were implemented in Phase 1**, with the editor job and the editor's gate groups added in Phase 2 (§2.2). **Since Phase 4 W6 they are one workflow, `ci.yml`** (§2.4, the owner's request). §2.1 says how they differ from this spec; `runtime-gates.yml`, `release.yml` and `deps.yml` remain spec until their phases.

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
| `ci.yml` | every PR + push to main/arena branches | Dart analyze/format/test (unit+widget+goldens, with coverage) · import-boundary lint · Kotlin/JVM tests (since Phase 3 W1) · editor JS build+vitest (from Ph. 2) · `flutter build apk --debug` + SHA-256/size · license check · lockfile drift check · the release x86_64 APK (Ph. 4 W1) · the sealed-runtime JVM tests and the runtime supply-chain job (Ph. 4 W2, §2.4) · the runtime in the APKs, and the instrumented tests' APK (Ph. 4 W3) | PR merge blocker |
| `ci.yml`'s phase gate (`phase-gate.yml` until Ph. 4 W6) | `[phase-gate]` in the head commit message (a manual run with the `phase_gate` input, once on `main`) | emulator integration tests on API 36 x86_64 `google_apis` (KVM) incl. the process-death restore pair · the runtime group (Ph. 4 W3: install, warm start, a flipped byte, the exec audit) · cold-start measurement on a release x86_64 APK · size report (`perf.json`) · the arm64 bundle's size per device (Ph. 4 W3) | phase exit blocker |
| `runtime-gates.yml` | changes under native/, runtime/ (Ph. 4+; no nightly run, ADR-0009 amendment) | payload build (pins verified) · `ExecModelTest` + `SealedShellTest` on 34/36 · `ExecAudit`=0 · page-alignment check · bundle-size check · arm64 device leg (Firebase Test Lab, see §4) | release blocker |
| `release.yml` | version tag `v*` | build GitHub "full" APK (arm64 + x86_64) · build Play AAB (arm64 base + PFD pack) · sign (secrets) · hashes + pins manifest · GitHub Release draft · Play upload to internal track (manual promote) | — |
| `deps.yml` | monthly cron | dependency update PR (pub/npm/gradle) with full ci.yml | — |

### 2.1 As built in Phase 1 — the evidence channel

The authoring sandbox cannot reach GitHub's log and artifact download hosts, so principle 4 is applied with one deliberate exception: **diagnostics are committed back to the working branch**, always with `[skip ci]`, and only when asked for:

- **`[bootstrap]`** in a commit message makes `ci.yml` run `dart fix` + `dart format`, regenerate golden baselines on the Linux runner (the `test/goldens` suites only), and commit both back. Every quality gate then writes its full output to `app/ci-results/*.txt` (goldens, analyze, format, imports, licenses, lockfile, test, build, apk, coverage), which is committed back too. The run's own verdict is the evidence. Plain pushes run the same gates without any commit-back, except the images of golden tests that failed (§2.3, since Phase 3 W6). When tests fail, the last 40 lines of their output also go out as a check-run annotation, which the API can read even after a plain push.
- **Generated code (Phase 2 W5).** `[bootstrap]` also runs the code generators and commits their output with the lockfile: `build_runner` (Drift's `*.g.dart`), `drift_dev make-migrations` (schema dumps in `app/drift_schemas/`, and from the second schema version on the migration steps) and `drift_dev schema generate` (the migration-test helpers in `app/test/drift/`). Every run's "Generated code check" regenerates and fails on any difference. The phase gate checks out the pushed commit, not the commit-back, so it generates before building.
- **Coverage** (`ci-results/coverage.txt`) counts hand-written code only. Generated `*.g.dart` and `*.steps.dart` files are left out, as they are for analysis. Their line count is printed as `generated_lines_excluded`. Totals from before W5 had no generated code, so they compare directly.
- **`[phase-gate]`** runs the phase gate (`phase-gate.yml` until Phase 4 W6, now jobs of `ci.yml`); its evidence lives in **`app/ci-results/gate/`**, a directory owned by the gate script (host/acceleration, readiness timings, every test attempt with exit codes, restore-pair proof, cold-start samples, `perf.json`, logcat and emulator tails). `tool/ci/commit_gate_evidence.sh` commits it by snapshotting the directory, resetting to the remote tip and restoring only that directory — never a rebase of a dirty runner checkout, so concurrent commit-backs cannot collide. The key files are also published as check-run annotations (`tool/ci/annotate_gate_evidence.sh`), readable through the API if a push ever fails.
- **`[testlab]`** (since Phase 4), in the commit's subject line, runs `ci.yml`'s Firebase Test Lab check on a physical arm64 phone. Its evidence lives in **`app/ci-results/testlab/`** (§4).
- Commit-backs from `ci.yml` push through `tool/ci/push_with_retry.sh` (fetch + rebase on rejection).
- **Phone test build (Phase 2 W3):** after the release x86_64 APK, the phase gate builds the editor benchmark pages (`npm run build:bench`) and then a **profile arm64 APK** that bundles them. It is uploaded as the artifact `codeforge-phone-profile-arm64` (kept 30 days), and its SHA-256 is printed in the step log. Profile mode is optimised like release but keeps Settings → Developer (`!kReleaseMode`). It is signed with the runner's throwaway debug key, which changes with every run, so an earlier CodeForge build must be uninstalled before a new one installs. The release APK is built before the pages exist, so it never contains them.
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
- **Build digest** (`ci.yml`, since 2026-11-11): every run notes the runner's image, free disk and memory. A failed debug build or Kotlin test run leaves Gradle's *What went wrong* and the output's last lines in an annotation, which the API can read where the log hosts are out of reach.
- **The Flutter pin** (both workflows, since 2026-11-11): see §3.
- **Generated code check:** since W2 it covers Pigeon's output (`pigeons/storage_api.dart`, generated into Dart and Kotlin) and fails when a generator fails. Since schema v2 (W3) that includes Drift's migration steps (`app_database.steps.dart`), which exist from the second schema version on.
- **Manifest check** (`ci.yml`, since W6, gate G8): after the debug build, `tool/ci/check_manifest.py` reads the merged manifest (`build/app/intermediates/merged_manifest/debug/…`) and fails on any storage permission (`READ_`/`WRITE_`/`MANAGE_EXTERNAL_STORAGE`, `READ_MEDIA_*`, `MANAGE_DOCUMENTS` and the like), on `requestLegacyExternalStorage`, or on backup attributes other than ADR-0012's. It first shows itself catching each kind of drift (`--self-test`). The output goes to `ci-results/manifest.txt`; `manifest` is one of the gates *Enforce quality gates* checks. The debug manifest holds everything the release one does, plus the debug-only `INTERNET`.
- **Golden failure images** (`ci.yml`, since W6, an owner item): a golden test that fails leaves its golden, its own drawing and their differences beside it; `tool/ci/collect_golden_failures.sh` moves them to `ci-results/golden-failures/` and lists them in `golden-failures.txt`, and a warning names them. A `[bootstrap]` run commits them with everything else; any other run commits `ci-results/` alone, with them (*Commit golden failures back*). `push_with_retry.sh` rebases with `--autostash`, since such a run leaves other files changed.
- **Renderer comparison** (the phase gate, since W6): after the release APK, the same build with Flutter's Skia opt-out (`tool/ci/skia_manifest.py`; the manifest is put back and checked unchanged), which the cold-start group times beside the shipped APK. It is never shipped.
- **The phase gate's groups** after the edit pair:
  9. `backup` (W1, G6): first a backup with the switch never touched, which the transport declines (*Transport rejected*: the agent writes nothing), and an uninstall; then `backup_a` → a backup → a reinstall → `backup_b` → a backup → a reinstall → `backup_c`, through Android's local transport.
  10. `folders` (W2, G1): `folders_a` → `am force-stop` → `folders_b`, with Android's folder picker driven from the host, and the host's disk checks.
  11. `explorer` (W4, G3): every file operation on the demo project and on a folder picked in Android's picker, with the host's disk checks, and a file saved through Android's create-document picker.
  12. `watch` (W5, G4): files changed behind the app's back on both kinds of workspace, with the app sent to the background and back.
  13. `measure` (W6, G7): a 10,000-file project opened and indexed, 1 and 10 MiB through `dart:io` and through the broker, a 1,000-entry folder listed, and frames while 10 MiB is digested on and off the UI isolate; recorded, never judged (`measure.txt`, `measure.json`).

  Since W3 the restore pair opens a folder through the same picker driver, and its part B switches workspaces. Since W3 the gate also hides Android's error dialogs after boot (`hide_error_dialogs`): in gate 43069846571, Android's *Application Not Responding* dialog for System UI took the keys group's tap. A full run took 33 minutes at W1 (42862715744), 37 at W2 (43007795087, attempt 1), 33 to 39 at W3 (43088413208, 43076652650, 43069846571), 36 at W4 (43183687317), 40 at W5 (43228855243) and 46 at W6 (43247963954; 40 in 43270594252, and 71 in 43256861510, after adb stalled), and 38 at Phase 3's exit (43284276984).

### 2.4 Added in Phase 4

- **Release build** (`ci.yml`, since W1): see §3.
- **Sealed runtime tests** (`ci.yml`, since W2, gate G2): `:native:sealed-runtime:test` runs t1's kernel tests (22) on the JVM after the Kotlin tests. The counts go to `ci-results/sealed-runtime-tests.txt`, and `sealed_runtime_tests` is one of the gates *Enforce quality gates* checks.
- **The runtime job** (`ci.yml`, since W2, gate G2) runs beside the editor and quality jobs, with Python 3 and no Flutter. In order:
  1. the `runtime/` script tests (t1's two and CodeForge's three);
  2. `provenance.py check`: native/PROVENANCE.md against the vendored files;
  3. `pins.py check`;
  4. the pinned bootstrap and packages fetched for both ABIs, verified and cached (§3);
  5. a live fail-closed check: one pinned package pointed at a version the repository lacks must fail the fetch;
  6. the payloads, built by t1's script from the pinned files (informative until W3);
  7. the notices, checked current.

  A `[repin]` commit first re-resolves the pins against the live repository. Its evidence goes to `runtime/ci-results/`, which `[bootstrap]` and `[repin]` runs commit back, along with the pins and the regenerated notices. It takes about 3½ minutes.
- **The runtime in the build** (`ci.yml`, since W3, gate G3):
  - *Generated code check* covers the runtime's Pigeon API (`pigeons/runtime_api.dart`).
  - **The Kotlin step** also runs `:app:assembleDebugAndroidTest`. The instrumented tests then compile on every run, and their APK's dependencies and manifest are checked in CI rather than first in the gate, which is where W3 found both problems.
  - *Restore the runtime's pinned files* restores the runtime job's cache before the release build, which carries the x86_64 payload since W3.
  - **Runtime in the APKs** (`tool/ci/check_runtime_apk.py`; `runtime_apk` in *Enforce quality gates*):
    - the release APK carries one ABI's payload and that ABI's libraries only;
    - its userland zip is stored, not compressed again;
    - every library its exec manifest names is in the APK, beside the preload and the exec probe;
    - the native libraries are compressed (legacy packaging), so Android extracts them as real files;
    - the debug APK, built for two ABIs, carries no payload.

    `check-page-alignment.py` then requires every shipped object to be 16 KB aligned. The checker first tests itself on 8 cases.
  - `check_manifest.py` also requires `android:extractNativeLibs="true"`.
- **The phase gate since W3:**
  - **Payloads:** its groups run on builds without one (`ORG_GRADLE_PROJECT_codeforgePayload=none`). The release x86_64 APK and the phone's arm64 APK carry theirs.
  - **The emulator** has an 8 GB data partition.
  - **Sizes:** it builds an arm64 app bundle and measures its size per device with `check-bundle-size.py` (`bundle-size.txt`; Play's limit is 200 MB per device). It runs the runtime APK checks on its own APKs (`runtime-apks.txt`).
  - **The runtime group** runs before the cold start, in three steps. Its figures go to `runtime.txt`.
    1. A debug build with the x86_64 payload, and its test APK.
    2. The instrumented tests, with `am instrument`. They pass when the output has a line `OK (n tests)`.
    3. The A/B pair through the app, across a process death.
  - **The limit:** the job may take 100 minutes. W3's gate took 35.6.
- **Search** (since W6, gate G8): *Generated code check* covers a third Pigeon API (`pigeons/search_api.dart`). The phase gate gets a `search` group after the runtime group, on the same build with the x86_64 payload (`search_run` in `tool/ci/emulator_gate.sh`, `integration_test/search_test.dart`). It pushes the gate folder with `many/` (1,000 files), a needle, a binary file and `node_modules/`, and the gate's folder driver answers the picker. Its verdict and times go to `search.txt` and `search.json`, and the host's own lines to `search_logcat.txt`.
- **Upstream patches for t1** (`ci.yml`, W6 only): each patch in `native/upstream/` was applied to the vendored kernel, tested with the kernel's tests and taken off again, until t1's owner took it. **Retired in W7:** the owner allowed CodeForge to change t1's code (2026-11-18), so the one patch is now applied to the vendored copy for good, in `native/patches/`. `runtime/provenance.py check` verifies it on every push (native/PROVENANCE.md, *Patches*), and the kernel's tests run with it (23).
- **One workflow** (since W6; the owner, 2026-11-18): `phase-gate.yml`'s four jobs moved into `ci.yml` with their steps unchanged, renamed (*Phase gate · emulator (API 36)*, *· runtime build*, *· runtime API n*, *· runtime evidence*). A `[phase-gate]` push now starts one run instead of two, and its verdict covers the build, the tests and the gate together.
  - **When:** the gate's jobs run when the head commit of a push carries `[phase-gate]`, or in a manual run with the `phase_gate` input (once the workflow is on `main`), and never for a pull request. They need no other job, so they start beside the build, as before.
  - **Queues:** runs on a branch queue one after another, plain runs and gate runs separately. A push never waits behind a gate, which takes about 50 minutes, and two gates never overlap: each commits its evidence back, and the newer must land last. As before, a newer queued run replaces an older queued one, and a superseded gate is cancelled by hand (`gh run cancel`).

## 3. Toolchain pins in CI

- Flutter: `.flutter-version` (**3.50.0** since Phase 4 W1; 3.47.9 before). Both workflows read the file and pass the version to `subosito/flutter-action`; the next step records the Flutter installed (`ci-results/flutter.txt`, and a notice on the run) and fails if it is another.
  - **Until 2026-11-11 the pin was not enforced.** The workflows handed the action the file itself, which it reads only as a pubspec (`environment: flutter:`) or an FVM file. It found no version in `.flutter-version` and installed the latest stable release. That was 3.47.9 until Flutter 3.50.0 reached the stable channel. 3.50.0 refuses an Android Gradle Plugin below 9.1.1, so the debug build failed on the runners that got it (CI 43082992891 attempt 1, 43084317447, 43086757260). A run whose debug build passed had 3.47.9, the only other release that was the latest stable since the pin was set. CI 43088413162 and phase gate 43088413208 ran on the enforced pin.
- Java: Temurin 17; Android SDK 36 (runner image); NDK **28.2.13676358** (resolved by the Flutter Gradle plugin; since Phase 4 W3 it also builds the runtime's preload, with ndk-build); Gradle wrapper **9.5.0** + AGP **9.3.3** and Kotlin's Gradle plugin **2.4.20** (committed since Phase 4 W1: the pins of Flutter 3.50.0's template, except AGP, which is the 9.3 line's latest patch; before, 3.47.9's 9.3.1 + 9.1.0 + 2.4.0); Node: `.nvmrc` (24 LTS) for the editor workspace from Phase 2.
  - **AGP 9.3.3, not the template's 9.3.1:** 9.3.0 and 9.3.1 bundle a lint that crashes on JDK 17 (`NoSuchMethodError: java.util.List.removeLast()`, Google issue 522845800), which failed every release build in W1's first gate (43375227077); 9.3.2 fixes it, and 9.3.3 adds D8/R8 fixes, among them dex files that fail verification. AGP 9.3 needs JDK 17 and Gradle 9.5.0, as before.
  - **Release builds in CI (since Phase 4 W1):** every CI run also builds the x86_64 release APK (`ci-results/build-release.txt`; its size goes to `apk.txt`), because AOT-compiled Dart, R8 and the release lint run in no debug build. That gate's first run on Flutter 3.50.0 passed every debug check while all three AOT builds failed.
  - **Dart 3.14.0's AOT compiler** (Flutter 3.50.0) crashes on one shape of code: a `final` local assigned in one case of a switch whose other cases return, then captured by a closure ([dart-lang/sdk#64917](https://github.com/dart-lang/sdk/issues/64917), P0, open on 2026-11-13). Home's folder reconnect had it and was restructured; a scan of `lib/` and of the main dependencies found no other. The release build in CI catches a new one.
  - **Known Gradle warnings, none from our build files.** AGP 9.3 warns that `android.builtInKotlin=false` and `android.newDsl=false` (set by Flutter's template, as in 3.47.9) are deprecated, that the legacy variant API (`applicationVariants`, `testVariants`, `unitTestVariants`, and `libraryVariants` in Flutter's `integration_test`) is obsolete, and Kotlin 2.4.20 that the `kotlin-android` plugin the Flutter Gradle plugin applies is no longer needed since AGP 9. AGP 10 removes all of these. They are Flutter's to move first, through its template and Gradle plugin; the app's build files use none of these APIs (CI 43373527631, `ci-results/kotlin-tests.txt`).
- **The runtime's inputs** (since Phase 4 W2): `runtime/pins.json` pins the Termux bootstrap per ABI (`2026.02.12-r1+apt.android-7`, by t1's SHA-256s) and every package of the payload by version, file and SHA-256: 50 per ABI on 2026-11-13.
  - **Fetching:** CI fetches exactly those files and caches them under the hash of `pins.json` (`actions/cache`, about 208 MB).
  - **Failing closed:** when a pinned file is gone, the build fails and names the package. Termux keeps only the latest versions, and GitHub evicts a cache that goes unused for 7 days.
  - **Re-pinning** is a `[repin]` commit (runtime/README.md).
- **ABIs** (since Phase 4 W3): arm64-v8a and x86_64 only; armeabi-v7a is dropped (PHASE_4_PLAN §2). Flutter's `target-platform` property decides which a build targets (`codeforgeAbis` in `android/build.gradle.kts`).
  - **The payload rule:** a build for one ABI carries that ABI's payload. A build for both, like the plain debug build, carries none, so no APK carries two payloads.
  - **`codeforgePayload` overrides the rule:** `none`, or a comma-separated list of ABIs the build targets. Set it with `-PcodeforgePayload=…` or `ORG_GRADLE_PROJECT_codeforgePayload`. An ABI the build doesn't target fails the build.
  - **What the payload costs:** the release x86_64 APK grew from 24.6 MB to 149.4 MB, and the arm64 phone APK is 164.2 MB. An arm64 device downloads 147.3 MB of the bundle (gate 43808489945).
- **The instrumented tests' dependencies** (`androidTestImplementation` in `android/app/build.gradle.kts`, since Phase 4 W3) stay on the androidx.test train that Flutter's `integration_test` plugin puts into debug builds: runner 1.3.0 with junit 4.12.
  - **Why:** the test APK runs in the app's process, so AGP resolves its dependencies to the debug app's versions, and a newer train fails to resolve (CI 43804216240). `integration_test` is a dev dependency, which only release builds leave out.
  - **No `androidx.test.ext:junit`:** that train's version brings activities without `android:exported`, which fails the manifest merge for apps that target Android 12 or later (CI 43805853809). So the tests are plain JUnit4 classes, which `AndroidJUnitRunner` runs as they are.
  - **When Flutter's plugin moves to a newer train,** these follow it. The JVM unit tests are not affected; they keep junit 4.13.2.
- Actions: the Node 24 majors since Phase 4 W1 (TECH_STACK §6): `actions/checkout` v7, `setup-java` v6, `cache` v6, `upload-artifact` v7, `download-artifact` v8, `setup-node` v7, and `subosito/flutter-action@v2`.
- Caches: pub, gradle, npm keyed by lockfiles. The Gradle distribution is cached by the wrapper properties and fetched with retries when the cache has none (`app/tool/ci/fetch_gradle.sh`), because services.gradle.org stalls now and then (phase gates 42477797842 and 42478331067). Emulators: GitHub's Linux runners **do** expose KVM to public repositories once a udev rule is applied — Phase 1's first six gate runs silently fell back to software emulation (the KVM probe raced the asynchronous `udevadm trigger`), with 4.5–15.6 min boots and system_server watchdog restarts. The gate now settles udev before probing, records the acceleration it actually used, and waits for a *stable* framework (three consecutive package/settings/activity-manager probes), not just `sys.boot_completed`.
- Secrets (release only): `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`, `PLAY_SERVICE_ACCOUNT_JSON`. Never available to fork PRs. `GITHUB_TOKEN` least privilege per job.

## 4. Device testing

- **Emulators (CI-owned):** x86_64 API 34 & 36 — correctness gates (t1-proven). **Since Phase 4 W5:** the runtime gates run the runtime's instrumented tests on x86_64 API 26, 27, 28, 34 and 36 in every phase gate (`tool/ci/runtime_gate_leg.sh`; ADR-0007, ADR-0009), and the emulator gate's groups run on API 36.
- **Connecting Test Lab** (since 2026-11-15; the owner's Firebase project, on the no-cost Spark plan):
  - **The credential:** a service account with the **Editor** role. Its JSON key goes in the repository secret `FIREBASE_TEST_LAB_KEY`, and the project id in `FIREBASE_PROJECT_ID`, a repository variable or a repository secret (the variable wins when both are set; as a secret, the job's log masks it). The owner stored both as secrets on 2026-11-17.
    - **The key is the Firebase Admin SDK account's** (`firebase-adminsdk-fbsvc@…`). On its own that account cannot use Test Lab: listing the phones was refused with a 403 (CI 44144982229 and 44153536306) until the owner gave it Editor on the project's IAM page and enabled the Cloud Testing and Cloud Tool Results APIs (2026-11-17).
    - Firebase requires Editor for tests that use Test Lab's default results bucket (its IAM reference). The narrower pair, *Firebase Test Lab Admin* and *Firebase Analytics Viewer*, works only with a bucket of one's own, and that needs billing.
    - The project holds nothing else and has no billing account, which bounds what the key can do.
  - **Storage on Spark:** since 2026-02-03 a Spark project can't use its own Cloud Storage buckets. Test Lab's default results bucket, however, lives in a project Test Lab owns (the Tool Results API's `initializeSettings`), so runs should keep working without billing. The jobs never pass `--results-bucket`. **Confirmed on 2026-11-17** (CI 44167128978): the results went to Test Lab's own bucket, without billing.
  - **The job** is `ci.yml`'s `testlab` job, run by a pushed commit with `[testlab]` in its subject line. The tag only in the message's body stops the job at its first step, so a message that mentions it spends no test:
    - **Since Phase 4 W5 it is the runtime's arm64 gate** (G6, with G3's and G4's arm64 figures and ADR-0008's phone measurement):
      - It builds the arm64 debug APK, which carries the arm64 payload, with `integration_test/sync_modes_test.dart` as its Dart entrypoint. One Gradle run builds it and its test APK, and `tool/ci/same_signer.sh` checks that one key signed both.
      - It runs the test APK's `dev.codeforge.app` package on one phone: the runtime's four instrumented classes, then `SyncModesTest`. Since Phase 4 W6 the same Dart entrypoint also runs search on the phone (`integration_test/phone_search_test.dart`), so `SyncModesTest` runs two Dart tests, and the job requires the `CODEFORGE_SEARCH_JSON` document beside `CODEFORGE_SYNC_JSON`.
      - It fetches the JUnit report and the device log from Test Lab's results bucket, judges them with `tool/ci/gate_results.py`, and commits `ci-results/testlab/` back.
      - `tool/ci/testlab_device.py --runtime` chooses the phone. It must run Android 14 or later. A mid-range one with high or medium capacity comes first (Pixel a, Galaxy A, moto g, Redmi Note, Nord), then the order below.
    - Until W5 it ran one Robo crawl of the run's debug APK, the connection check below. `tool/ci/testlab_device.py` without `--runtime` chooses as it did then: the most spare capacity first, then the newest Android version from API 26 to 36, then a Pixel.
    - It commits `ci-results/testlab/` back, with the project id replaced by `$FIREBASE_PROJECT_ID`.
    - Listing the devices costs nothing. The crawl uses 1 of the Spark plan's 5 physical-device tests a day.
    - **When listing fails** (a refused key), `tool/ci/testlab_diagnose.py` asks gcloud what the key can see: its account, the account's roles on the project, and the Cloud Testing and Cloud Tool Results APIs. It ends with one hint and prints no id. It costs no test.
    - W5's runtime gates build on it.
  - **Connected on 2026-11-17** (CI 44167128978, about 7.6 minutes):
    - Test Lab listed 212 models, 204 of them physical. 211 phone and version pairs qualified, and the picker chose a Google Pixel 10 (`frankel`) on API 36, with high capacity.
    - The 83.7 MB debug APK waited 2 minutes in the queue, then Robo crawled it for 192 s. The outcome was *Passed* (gcloud's exit 0).
    - The evidence is `app/ci-results/testlab/` (`check.txt`, `device.txt`).
  - **The first runtime run** (2026-11-18, CI 44240926191, 12.7 minutes, after CI 44239443972 passed on the change):
    - 162 phone and version pairs qualified, and the picker chose a Google Pixel 8a (`akita`) with Android 14 and high capacity.
    - It waited 1 minute in the queue. The 17 tests passed in 90 s of the phone's time (gcloud's exit 0, *17 test cases passed*).
    - The results bucket was readable with the key's Editor role. The evidence is `app/ci-results/testlab/` (`runtime.txt`, `runtime.json`, `logcat-runtime.txt`, `check.txt`, `device.txt`, `fetch.txt`).
    - It was 1 of the day's 5 physical-device tests.
  - **Spending Test Lab runs** (the owner's rule, 2026-11-17): a change is first green in a plain CI run, without the tag. Only then does a separate commit, usually empty, carry the tag in its subject line, so a Test Lab run never tests a change that CI hasn't passed. CI's *Test Lab scripts* step runs both scripts' self-tests on every push, so plain CI covers changes to them too. The agent decides when a Test Lab run is worth it, and keeps within the day's five physical-device tests.
- **arm64 hardware:** required for Phase 4 exit (sealed-on-arm64 gap R2), perf budgets, IME matrix, release sign-off. **Owner decision 2026-11-11 (ADR-0009 amendment):** Firebase Test Lab's physical devices run the tests that need no computer attached (the runtime's instrumentation tests, the in-app benchmark) from a CI job (`gcloud firebase test android run`), with one CI credential the owner adds by Phase 4. The host-driven checks (the folder picker, the key injector, `adb`-timed measurements) stay on the emulator, and the owner's phone sessions cover the rest: those produce a **manual-checklist artifact**, and the phase report records device + build hash + operator — never a silent skip. *(Superseded plan: a self-hosted GitHub Actions runner on a machine with the device attached, labeled `arm64-device`. GitHub advises against self-hosted runners on public repositories.)*

## 5. Versioning & artifacts

- SemVer `MAJOR.MINOR.PATCH`; `versionName` from tag, `versionCode` monotonic (CI run number + offset). Phase milestones tag `v0.N.0`; public release starts `v1.0.0` at Phase 10 exit.
- GitHub Release: `CodeForge-vX.Y.Z-arm64.apk` (full), `-x86_64.apk` (emulator/dev), `SHA256SUMS`, `PINS.json` (Flutter/AGP/NDK/bootstrap/package versions), source tarball link. Pre-release flag until Phase 10.
- Play: AAB arm64 base + `pack_buildtools` on-demand; internal → closed → production promotion is manual; data-safety answers from t1 `store/data-safety.md` template (nothing collected).
- **License gate:** no binary release until `THIRD_PARTY_NOTICES.md` and the source offer for GPL userland components are published with the release (ADR-0011 resolved on 2026-11-12: Apache-2.0).

## 6. Local developer builds (documented for CONTRIBUTING)

```bash
# Phase 1+ (UI only)
cd app && flutter pub get && flutter test && flutter build apk --debug

# Phase 2+ (editor bundle first)
cd editor && npm ci && npm run build   # outputs to app/assets/editor/
npm run build:bench                    # optional, debug/profile only: benchmark pages
                                       # to app/assets/editor_bench/ (~1.3 MB gz);
                                       # never present for a release build

# Phase 4+ (runtime payload; network needed once, SHA-verified; runtime/README.md)
python3 runtime/pins.py fetch --arch x86_64 --cache runtime/generated/cache \
    --out runtime/generated/debs/x86_64             # exactly the pinned packages
(cd app/android && ./gradlew :native:sealed-runtime:test)   # the kernel's JVM tests
# W3 wires the payload into the Gradle build
```

Sandbox note (honesty): the Phase 0 environment had no Flutter/Java/Android SDK and no access to `dl.google.com`, so **all builds happen in GitHub Actions or on developer machines** — this repo's CI is the build authority from day one.
