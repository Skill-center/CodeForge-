# Phase 4 Implementation Plan — Runtime Integration

**Status:** **Proposed (2026-11-12).** W1 starts on the owner's "next". The vendoring packages (W2 on) start once the licence is decided ([ADR-0011](../adr/0011-license.md), due by this phase's start) and t1 carries that licence.
**Spec reference:** §8 Phase 4 (runtime integration), §2 (reuse existing assets), §6.4–6.5 (the terminal connects to the existing environment; the capability model), §7 (security) · **Architecture:** [RUNTIME_INTEGRATION.md](../RUNTIME_INTEGRATION.md), [EXISTING_RUNTIME_AUDIT.md](../EXISTING_RUNTIME_AUDIT.md), [ADR-0005](../adr/0005-sealed-runtime.md), [ADR-0006](../adr/0006-terminal-frontend.md), [ADR-0007](../adr/0007-min-sdk.md), [ADR-0009](../adr/0009-ci-github-actions.md), [ADR-0010](../adr/0010-distribution.md), [ADR-0011](../adr/0011-license.md) · **Source:** `m-cyber12/t1` main @ `7b496c3`, whose tree equals the audited `0e26d7a`

---

## 0. Carried in from Phase 3 and the owner

**Owner decisions at Phase 3's acceptance (2026-11-12)** ([PHASE_3_REPORT](PHASE_3_REPORT.md) §1):
1. Phase 3 is accepted. The owner runs the exit phone session after the next slice of work, which this plan makes W1 (its phone profile APK becomes the session's build).
2. G7's cold start is judged by that session's phone figure, for now. Impeller stays.
3. FULL against NORMAL ([ADR-0008](../adr/0008-persistence.md)) moves to this phase's Firebase Test Lab runs. The owner adds the Firebase project and its CI credential after the next slice.
4. Flutter 3.50.0, the Android Gradle Plugin and Kotlin's Gradle plugin are upgraded together ("so we upgrade all of them together"): W1.

**Owner decisions for Phase 4 from 2026-11-11** (PHASE_3_PLAN §0):
- **Licence** (ADR-0011): decided by Phase 4's start. Until then: no licence file, nothing GPL-derived vendored, no binary release.
- **Terminal frontend** (ADR-0006): Termux's terminal view if the licence is GPLv3 and the view passes this phase's arm64 gate; otherwise xterm.js.
- **minSdk** (ADR-0007): stays 26, verified on API 26–28 emulators in this phase. A raise to 29 needs the owner's sign-off.
- **arm64 hardware** (ADR-0009, amended): Firebase Test Lab's physical phones, for the tests that need no computer attached.
- **Play Console and upload key** (ADR-0010): prepared in this phase. A personal account created after 13 November 2023 needs a closed test (12 testers, 14 days in a row) before production.
- **Search across files:** ripgrep for projects, and a scan by the app for SAF folders, which ripgrep can't read.
- **Unchanged:** one emulator gate per work package and no nightly or scheduled run; all work on this branch, `main` keeps its initial commit; undo history doesn't survive a process death (accepted); other text encodings come later.

**Carried over from Phase 3** (PHASE_3_REPORT §10): search across files; how a folder reaches the runtime (a copy into a project, or import and export); minSdk 26 on API 26–28; the terminal frontend by ADR-0006's rule; a unit test for `FolderWatches.kt` if its seams allow.

**Found while planning (2026-11-12):**
1. **t1's code is merged.** PR #81 was closed without merging on 2026-11-11 at 14:32 UTC, and the same branch (`arena/f91bdedf-t1`, head `0e26d7a`) was merged two minutes later as PR #229. t1's main is `7b496c3`, and GitHub's comparison finds no file that differs from `0e26d7a`, the audited commit. t1 still has no LICENSE.
2. **The runtime core needs no Termux code.** The two gates this phase ports (`ExecModelTest`, `SealedShellTest`), the command runner (`HarnessCommandRunner` starts processes with `ProcessBuilder`), `HarnessEnvironment`, `Toolchain`, `SealedPayloadInstaller`, the `sealed-runtime` kernel and the two preload helpers (`harness-exec.c`, `harness-probe.c`) are t1's own code. Only the interactive terminal is Termux-derived: `HarnessSession` (built on Termux's `TerminalSession`), the PTY in `termux.c` and the `terminal-view` renderer. In t1, `harness-core` declares `api project(":terminal-emulator")` for that one class. **So the licence decides the terminal, not this phase's runtime core.**
3. **Termux's package repository keeps only the latest version of each package** (Termux's own documentation: "we do not keep history of package versions"). t1 pins the bootstrap by SHA-256, but `fetch-core-debs.py` takes whatever versions the repository's index lists at build time ("the bootstrap is pinned, the package set is not"). W2 pins the package set (§3, W2).
4. **Flutter 3.50 deprecates the framework's Material library.** `package:flutter/material.dart` is a `@Deprecated` library in 3.50.0 ("Use package:material_ui/material_ui.dart instead"), and CI's analysis fails on infos, so W1 migrates (§3, W1). go_router 18.1.3, already in the app, imports `package:material_ui` and recognises only material_ui's `MaterialApp`. The app's `MaterialApp` is the framework's, so go_router builds every page today as a `NoTransitionPage`.
5. **Firebase Test Lab is deprecated:** Firebase's documentation says it shuts down on **30 September 2027**. Its successor, Google Cloud's Developer Device Platform, requires billing. Until then the free Spark plan allows 10 virtual-device and 5 physical-device test runs a day. Test Lab still serves this phase and probably the next few. What replaces it after September 2027 joins ROADMAP's decision queue.
6. **Play Feature Delivery's library** (`com.google.android.play:feature-delivery`, used by t1's `PlayPackInstaller`) is published under the Play Core Software Development Kit Terms of Service, not an open-source licence. That matters for a GPLv3 app's Play build (§10, decision 1). This phase does not need it (§2).

## 1. Objectives

1. Move to Flutter 3.50.0 with AGP, Kotlin's Gradle plugin and Gradle upgraded together, and migrate to `package:material_ui`, which 3.50 requires. Phase 3's evidence is re-established on the new toolchain.
2. Record the licence decision (ADR-0011), and vendor t1's runtime with its provenance and pinned inputs.
3. Install the sealed userland in CodeForge. It installs lazily on the first workspace open, verifies every file while writing it, shows its progress, and audits itself at every start (`ExecAudit` = 0). A warm start takes 100 ms or less. Failures are typed and visible.
4. Run one-shot commands and probe the tools across a typed boundary to Flutter: node, python, git, bash, perl, ruby and rg versions in the UI, and no orphan process.
5. Turn the gates green on API 34 and 36 x86_64 emulators, on API 26–28 (ADR-0007) and on a physical arm64 phone in Test Lab (audit gap R2). Measure FULL against NORMAL on that phone (ADR-0008).
6. Search across files: ripgrep in projects, a scan by the app in folders.
7. Resolve the terminal frontend by ADR-0006's rule, draft the third-party notices and source offer, and prepare the Play Console.

## 2. MVP 4 definition (ROADMAP)

"Sealed userland alive", with the exit "ExecModel+SealedShell gates green incl. arm64 device (Firebase Test Lab); versions via UI; ExecAudit=0; warm start ≤100 ms; search across files (ripgrep for projects, the app scans SAF folders)".

**Scope decisions (proposed with this plan):**
- **The core payload only:** t1's core set on its pinned bootstrap (`2026.02.12-r1+apt.android-7`): git, ripgrep, python and pip, nodejs and npm, perl, ruby, jq, tree, which, file and openssh. The build-tools pack (clang, cmake, make), which ships through Play Feature Delivery, comes when C and C++ compiling does (the capability model's *compilable*), or with Phase 10's Play shape. Leaving it out also keeps Play Feature Delivery's library out of this phase.
- **Two ABIs, as ADR-0010 decided:** arm64-v8a for phones and x86_64 for emulators. Flutter builds armeabi-v7a too by default (its default platforms are arm, arm64 and x86_64). t1 never built a 32-bit payload, so W3 restricts the build to the two payload ABIs, and **phones that run only 32-bit ARM code can no longer install the app.**
- **No user code runs yet.** Running a file or project, and terminal sessions, are Phase 5. This phase runs only the app's own probes (versions, the audit, the gates) and the search.
- **Nothing executable is downloaded, ever** (SECURITY §2, Play policy). Every executable comes out of the APK. The apt shape is not vendored (RUNTIME_INTEGRATION §5).
- **Test Lab runs only the tests that need no computer attached** (ADR-0009's amendment). The host-driven gate groups stay on the emulator.

## 3. Technical implementation (work packages)

### W1 — Toolchain: Flutter 3.50.0, AGP 9.3.1, Kotlin 2.4.20, Gradle 9.5.0 (1–2 sessions) → G1

**Pins.** The app has followed the Flutter template's Android pins since Phase 1. These are 3.50.0's, from `gradle_utils.dart` and `DependencyVersionChecker.kt` at the 3.50.0 tag:

| | Now | W1 | 3.50.0 refuses below / warns below |
|---|---|---|---|
| Flutter | 3.47.9 | **3.50.0** (the only 3.50 stable release) | — |
| Android Gradle Plugin | 9.1.0 | **9.3.1** | 9.1.1 / 9.3.1 |
| Kotlin Gradle plugin | 2.4.0 | **2.4.20** | 2.4.10 / 2.4.20 |
| Gradle | 9.3.1 | **9.5.0** (AGP 9.3 needs 9.5.0 or later) | 9.3.1 / 9.5.0 |
| compileSdk, targetSdk, NDK | 36, 36, 28.2.13676358 | unchanged | — |

The template's Android files are otherwise the same in 3.47.9 and 3.50.0 (`gradle.properties` with `android.newDsl=false` and `android.builtInKotlin=false`, the settings, the app's build file), so only the versions change. The committed wrapper jar fetches the new distribution, and the CI cache key follows the wrapper's properties.

**The Material migration (required by 3.50):**
- 87 files import `package:flutter/material.dart` (39 in `lib/`, 48 in the tests) and none imports Cupertino. They move to `package:material_ui/material_ui.dart`. The bootstrap runs `dart fix --apply --code=migrate_design_widgets` before its usual `dart fix --apply` and format, and commits the result.
- `material_ui` becomes a direct dependency, pinned exactly at **1.10.0**, the version the lockfile already resolves for go_router (TECH_STACK §4's justification: the framework's Material moved there). The app doesn't use `flutter_localizations`, so no localization delegate changes.
- **Navigation stays as it is.** Once the app's `MaterialApp` is material_ui's, go_router would recognise it and switch from `NoTransitionPage` to Material pages with Material's transitions. W1 builds `NoTransitionPage`s explicitly so that the upgrade changes no interaction. Whether routes animate is a design choice for later; UI_DESIGN_SYSTEM has no route motion.
- `flutter_test`'s `find.byTooltip` matches tooltips through the `RawTooltip` semantics they build, so material_ui's tooltips are still found (2 uses).
- **Goldens:** material_ui 1.10.0 may draw slightly differently from the framework's frozen copy. The bootstrap regenerates the goldens, and each changed golden is looked at before it is accepted.

**Other 3.50 breaking changes:**
- Release builds now ignore engine flags passed in intents, and check who sent an intent that sets a route or an entry point. The gate starts the app without extras (`am start -W -n`), so neither change affects it.
- The gate's Skia comparison switches the renderer with a manifest flag, not an intent. 3.50.0 still accepts `EnableImpeller` in release builds (`FlutterEngineFlags`: "Allowed in release to control which rendering backend is used in production"), and its `flutter_main.cc` keeps the Skia path in the same lines as 3.47.9. The gate proves the comparison still builds and runs.
- Soft hyphens and the order of WidgetSpans in right-to-left text change, which the app is not expected to notice. The goldens would show it.

**The Dart language version stays.** `sdk: ^3.11.0-0` is unchanged (3.50.0's framework requires Dart 3.13), so neither the language version nor the formatter's style changes in W1.

**CI actions:** the workflows move off the deprecated Node 20 actions, to the current majors as of today: checkout v7, setup-java v6 (v4 is deprecated), cache v6, upload-artifact v7, download-artifact v8 and setup-node v7. Each is read against its release notes and changed in its own commit.

**Evidence:**
- CI on the bootstrap's commit-backs.
- One phase gate on W1's last commit: every group, and the cold start with Impeller and with Skia, set against Phase 3's exit gate (1302 ms, Skia 992 ms).
- That gate's phone profile APK becomes the build of the exit phone session, which the owner runs after this slice. PHASE_3_PHONE_CHECKLIST will name it. Phase 3's final build (artifact 13975424637) stays downloadable until 2026-12-12.

**Docs:** TECH_STACK, BUILD_AND_RELEASE §3, `app/README.md`, the changelog.

### W2 — Licence, provenance and the sealed-runtime kernel (1 session; needs ADR-0011 decided and t1 licensed) → G2

- **ADR-0011 → Accepted** with the owner's path. ADR-0006's outcome follows: path A sends Termux's view to W7's gate; paths B and C choose xterm.js by the rule. t1 gets its LICENSE (an owner action), and CodeForge vendors from the licensed commit.
- **`native/sealed-runtime/`:** a plain Java library (`java-library`, no Android SDK). It holds the 8 kernel classes (`SealedInstaller`, `PayloadExtractor`, `RuntimeManifest`, `SealedLayout`, `ExecAudit`, `ExecutableProbe`, `ExecutableKind`, `SealedUninstaller`) and the 3 JVM test classes (`SealedInstallerTest`, `ExecSealingTest`, `PackPayloadTest`). They are renamed to `dev.codeforge.runtime.sealed` with t1's `export-sealed-runtime.sh` pattern, and the tests are otherwise unchanged. `app/android/settings.gradle.kts` includes the module, and CI runs `:native:sealed-runtime:test`.
- **`native/PROVENANCE.md`:** the source repository and commit, every file with its SHA-256, its licence, the package renames, and the re-vendor procedure.
- **`runtime/`:** `build-sealed-payload.py`, `fetch-core-debs.py`, `check-bundle-size.py`, `check-page-alignment.py` and `check-sealed-manifest.sh`, with their unit tests running in CI.
- **`runtime/pins.json` pins every input.** The bootstrap is pinned per ABI with t1's SHA-256 (aarch64 `ea2aeba8…f4f3`, x86_64 `b7fd0f2e…4f7a`). The core package set is resolved once and pinned: name, version, file and SHA-256 for each package and its dependencies.
  - Because Termux keeps only the latest versions, CI caches the pinned `.deb`s under the pins' hash.
  - A pinned version that has gone from the repository fails the build closed and names the package.
  - Re-pinning is a deliberate commit.
  - A mirror of the pinned packages (a GitHub release) would redistribute GPL binaries, so it is considered only after the licence decision, with the source offer.
- **The notices start here.** THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md are drafted from the pinned packages' copyright files (ADR-0011's interim rule 3).

### W3 — RuntimeHost: install, verify, audit (2 sessions) 🔑 critical path → G3

**`native/runtime-core/`:** an Android library in the package `dev.codeforge.runtime.core`.
- **Vendored:** t1's `HarnessConfig`, `HarnessPaths`, `HarnessEnvironment`, `HarnessCommandRunner`, `HarnessSizeReport`, `Toolchain`, `exec/SealedPayloadInstaller` and `packs/{Pack, PackState, PackResult, PackInstaller, Packs}`. `Packs.isSealedBuild` is true at compile time, and the apt branch is deleted, not switched off.
- **Left behind:** `HarnessBootstrap`, `provision/*`, `HarnessPackageInstaller`, `AptPackInstaller` and `PackCommands`.
- **Arrives later:** `HarnessSession` comes only with the terminal (W7 under path A, or Phase 5). `PlayPackInstaller` comes with the build-tools pack.

**JNI:** `harness-exec.c` (the `LD_PRELOAD` path translator) and `harness-probe.c` (the exec probe), both t1's own. They are built with ndk-build and keep t1's 16 KB page-alignment flags (NDK 28.2 aligns by default anyway); `check-page-alignment.py` checks the APK.

**The payload in the build:**
- Gradle tasks download the bootstrap (SHA-256 checked), take the pinned `.deb`s, and run `build-sealed-payload.py`. The result is generated `assets/` (`userland-<abi>.zip` plus the manifest, exec and symlink lists) and `jniLibs/<abi>/lib*.so` for each ABI.
- The packaging switches are `jniLibs.useLegacyPackaging = true` and `android:extractNativeLibs="true"`, the two facts that make the executables real files in `nativeLibraryDir`.
- `abiFilters` is set to arm64-v8a and x86_64 (§2).
- The gate's builds carry x86_64 only, and the phone and Test Lab builds arm64-v8a only, so that no APK carries two payloads.

**`RuntimeHost.kt`:**
- `install()` runs the installer and streams its progress to Dart over an event channel.
- `audit()` runs `ExecAudit` at every start. Zero executables outside the APK is the only healthy result; anything else puts the runtime in a degraded mode, with a report the user can read and copy.
- The install is lazy: it starts on the first workspace open, off the UI thread, and the editor keeps working meanwhile (RUNTIME_INTEGRATION §3). A warm start skips the re-extract (budget 100 ms or less).
- The four invariants (RUNTIME_INTEGRATION §2) hold unchanged: symlinks into `nativeLibraryDir`, never copies; verified while written; dependencies by version; explicit interpreter environment.

**The boundary to Flutter:** a typed Pigeon API, `pigeons/runtime_api.dart`, beside Phase 3's storage API: status, install, audit and size, plus the progress events.

**In the app:**
- Settings gets a *Runtime* page: state, payload version, installed size (unique inodes, `HarnessSizeReport`), the audit, and *Reinstall* (`SealedUninstaller`).
- The workbench's status strip shows the runtime's state in place of "Runtime installs in Phase 4".

**Tests:**
- JVM tests for the adapter.
- A flipped byte in the payload must make the install fail with a typed error, with the runtime never marked ready (instrumented).
- Widget tests for the page and the strip.

**Measured:**
- The APK's size per ABI, against PERFORMANCE's 300 MB for the full APK.
- The per-device size of an AAB, with `check-bundle-size.py` (Play's limit is 200 MB per device; t1 measured 136.0 MB).
- The first install's time (budget 60 s on a mid-range phone; emulator figures now, Test Lab's in W5).

### W4 — Commands, tools and versions in the UI (1–2 sessions) → G4

**`exec()`** runs one-shot commands through `HarnessCommandRunner`.
- It returns a typed result: exit code, capped stdout and stderr, duration, and a failure kind.
- It runs in the runtime's home or a project.
- Its environment follows SECURITY §2: HOME, TMPDIR and the XDG directories live in the runtime root; no secrets go in; `PYTHONHOME`, `GEM_HOME` and `NODE_PATH` are set explicitly; the preload is set.

**`SessionRegistry`** owns every child process (one-shot processes now, PTY sessions in Phase 5). It ends whole process groups and enforces timeouts. After an end, no child remains (an instrumented assertion).

**`tools()`** runs the `Toolchain` probes: the node, python, git, bash, perl, ruby and rg versions, each with its health, on Settings' Runtime page.

**The capability model** (spec §6.5): JavaScript, Python and shell advertise *executable* once the runtime is ready. Only the flag changes; *Run* arrives in Phase 5.

**Security review at the new boundary:** SECURITY §2 is written up as built (the exec model, the environment, process hygiene, resource limits where bionic has them), like Phase 3's storage review.

### W5 — The runtime gates: emulators, minSdk, arm64 in Test Lab (2 sessions) → G5, G6, G7

**The tests:**
- `ExecModelTest` and `SealedShellTest` are ported into `app/android/app/src/androidTest/`, with the package renames.
- `HarnessBootstrap.ensureSealedPayload` becomes RuntimeHost's install.
- The pack cases wait for a pack, as PROVENANCE records.

**The emulator legs:**
- A runtime-gates job (ADR-0009's `runtime-gates`) runs on `[phase-gate]` commits, inside the same gate run, so there is still one emulator gate per work package.
- Its legs: API 34 and 36 x86_64, plus API 26, 27 and 28 x86_64 for ADR-0007.
- Each leg writes its evidence as JSON (t1's `assert-gate-results.py` pattern), including `ExecAudit`.

**The arm64 leg:** a Test Lab job, once the owner's Firebase project and credential exist.
- It runs the arm64-v8a debug and test APKs on one physical arm64 phone, Android 14 or later, chosen from Test Lab's catalogue.
- On the same phone it measures FULL against NORMAL, with the repository's large-file integration test, and records the result in ADR-0008.
- It counts against the quota: 5 physical runs a day on Spark, one per gate, 45 minutes at most per run.
- Until the credential exists it skips, with a notice and no failure, and no arm64 claim is made.

**The minSdk rule:** if API 26–28 pass, ADR-0007 becomes Accepted at 26. Failures with fixes of a week or less are fixed. A structural failure goes to the owner, whose sign-off a raise to 29 needs.

**The existing gate gains a runtime group:** the install's time, the warm start and the audit, end to end through the app. Its other groups keep running.

**Carried:** a JVM test for `FolderWatches.kt`, if its seams allow one without Robolectric.

### W6 — Search across files (1–2 sessions) → G8

- **Projects:** `rg --json` through `exec()`. Results stream in, the search can be cancelled, the matches are capped, `.gitignore` is respected and binary files are skipped.
- **Folders:** ripgrep can't read SAF trees, so the storage broker scans them in Kotlin. Results stream in, the scan can be cancelled, file sizes and counts are capped, and text is detected by the editor's UTF-8 rule.
- **The Search panel** replaces its placeholder. It has a query, case, regex and whole-word switches, include and exclude globs, results grouped by file, and a tap opens the file at the line.
- **Budget:** PERFORMANCE has no search budget yet. W6 records the first-result and full-search times on the gate's 10,000-file project and folder, and proposes the budget.
- **How a folder reaches the runtime** is decided in ADR-0013, with copy costs measured on the gate's folders. The options are (a) running in a copy, a one-way copy into a project, or (b) import and export. Phase 5 builds it with *Run*.

### W7 — The terminal frontend's gate (path A only; 1–2 sessions) → G9

- **Under path A (GPLv3):**
  - Termux's `terminal-emulator` (with the PTY in `termux.c`), `terminal-view` and `HarnessSession` are vendored.
  - The view is embedded as a PlatformView.
  - ADR-0006's gate is measured on the Test Lab phone: input-to-echo p95 50 ms or less, a 10 MB flood without a frozen UI, a memory delta of 80 MB or less, composition jank under 5 %. The IME part goes to the owner's phone session.
  - If it passes, the native view is chosen; if not, xterm.js.
- **Under paths B and C:** no gate. ADR-0006 chooses xterm.js by its rule, and Phase 5 writes the PTY clean-room (about 200 lines), or reuses the Apache-2.0 jackpal lineage after a review.

### W8 — Notices, Play preparation, docs and the phase exit (1 session) → G10

**Notices:** THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md are completed.
- They cover the userland's packages with versions and licences, the Dart and npm dependencies, and the Flutter engine.
- No binary release happens until ADR-0011 is Accepted and both documents are published (ADR-0010).

**Play Console** (ADR-0010):
- The owner: the developer account, and Play App Signing with an upload key.
- The agent: listing drafts from t1's `store/` templates, the data-safety answers ("nothing collected"), a privacy policy draft, and a proposed start for the 14-day closed test.

**Docs:** RUNTIME_INTEGRATION as built, ARCHITECTURE, SECURITY §2, TECH_STACK (the NDK row, the pins), BUILD_AND_RELEASE (the payload's build, caches, Test Lab), TESTING (the runtime gates), PERFORMANCE (install, warm start, sizes), REPOSITORY_STRUCTURE, the ADRs' statuses, ROADMAP, README and the changelog.

**The exit:** PHASE_4_REPORT, and phone checks for the runtime on the owner's phone (install time, audit, versions).

## 4. Deliverables

- Flutter 3.50.0, AGP 9.3.1, Kotlin 2.4.20 and Gradle 9.5.0, the app on `package:material_ui`, and the workflows on Node 24 actions.
- `native/sealed-runtime/` and `native/runtime-core/` with `native/PROVENANCE.md`.
- `runtime/` with its scripts, tests and `pins.json`.
- `RuntimeHost.kt`, `SessionRegistry.kt` and the runtime's Pigeon API.
- Settings' Runtime page, the status strip's runtime state, and the Search panel.
- The ported gates in `androidTest/`, a runtime-gates job with five emulator legs, and a Test Lab job.
- ADR-0011 and ADR-0007 Accepted, ADR-0006 resolved, ADR-0008's phone measurement, and ADR-0013 (how a folder reaches the runtime).
- THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md; the Play listing drafts; PHASE_4_REPORT.

## 5. Acceptance criteria (measurable gates)

| Gate | Criterion | Evidence |
|---|---|---|
| **G1 Toolchain** | CI builds with Flutter 3.50.0, AGP 9.3.1, KGP 2.4.20 and Gradle 9.5.0. Analysis is clean and formatting unchanged, every test passes, and every changed golden has been looked at. The Kotlin tests pass. Every phase-gate group passes, and the cold start is recorded with Impeller and with Skia | CI and gate run ids |
| **G2 Kernel** | `:native:sealed-runtime:test` passes with t1's tests changed only in their package. The `runtime/` script tests pass. PROVENANCE is complete. A missing pinned package fails the build closed | CI |
| **G3 Install** | The first install runs off the UI thread with progress, within 60 s on a mid-range phone (emulator and Test Lab figures recorded). A warm start takes 100 ms or less. A flipped byte gives a typed failure and the runtime is never marked ready. `ExecAudit` = 0 at every start. APK and per-device sizes recorded | the gate's runtime group, instrumented tests |
| **G4 Versions** | node, python, git, bash, perl, ruby and rg versions reach the Flutter UI through RuntimeHost and match the pinned packages. Ending a process leaves no child | instrumented, widget and gate tests |
| **G5 Emulators** | `ExecModelTest` and `SealedShellTest` pass on API 34 and 36 x86_64 | runtime-gates run |
| **G6 arm64** | The same tests pass on a physical arm64 phone in Test Lab. FULL against NORMAL is measured there and ADR-0008 updated | Test Lab runs |
| **G7 minSdk** | The API 26–28 legs pass and ADR-0007 is Accepted at 26, or the owner signs off a raise to 29 | runtime-gates run |
| **G8 Search** | ripgrep in projects and the scan in folders find the gate's fixtures. Results open at the line and cancelling works. Figures recorded and a budget proposed | widget, integration and gate tests |
| **G9 Terminal** | ADR-0006 resolved by its rule; under path A, by the arm64 gate | the ADR, Test Lab runs |
| **G10 Licence and docs** | ADR-0011 Accepted and t1 licensed. Notices and source offer drafted. Docs synced and PHASE_4_REPORT written | the documents |

## 6. Tests

- **JVM:** the vendored kernel's tests, unchanged; the adapter's and `RuntimeHost`'s tests; `FolderWatches.kt` if possible.
- **Python:** the `runtime/` scripts' unit tests, including the pins' failure when a version has gone.
- **Instrumented (`androidTest`):** `ExecModelTest`, `SealedShellTest`, the flipped-byte install, no orphan child, the warm start. These run on five emulator levels and on Test Lab's arm64 phone.
- **Flutter:** widget tests for the Runtime page, the status strip, the Search panel and the capability flags. The existing suite runs unchanged on 3.50.0 and material_ui.
- **Phase gate:** every Phase 3 group, plus the runtime group and search on the gate's fixtures.

## 7. Documentation

RUNTIME_INTEGRATION (as built), EXISTING_RUNTIME_AUDIT (t1's merge, PR #229), ARCHITECTURE, SECURITY §2, TECH_STACK, BUILD_AND_RELEASE, TESTING, PERFORMANCE, REPOSITORY_STRUCTURE, ADR-0006, ADR-0007, ADR-0008, ADR-0009 (Test Lab's deprecation), ADR-0011, ADR-0013, ROADMAP, README, the changelog, PHASE_3_PHONE_CHECKLIST (the new build) and PHASE_4_REPORT.

## 8. Known limitations (planned) and out of scope

- No terminal sessions and no *Run* (Phase 5), no language servers (Phase 6), no Git UI (Phase 7), though git ships in the payload.
- No build-tools pack: no C or C++ compiling in this phase.
- No 32-bit ARM build (§2).
- No binary release: CI artifacts only, until ADR-0011 is Accepted and the notices and source offer are published (ADR-0010).
- Folders don't reach the runtime in this phase. W6 decides how, and Phase 5 builds it.
- npm and pip packages with native addons can't build without the build-tools pack. Phase 5 documents this in the app (SECURITY §2).

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| The licence decision waits, and with it the vendoring | W1 needs no licence. The runtime core is the owner's own code under any path (§0, finding 2) |
| Termux removes a pinned package version | Pins plus a CI cache under the pins' hash; the build fails closed, naming the package; re-pinning is a deliberate commit; a mirror after the licence decision |
| The payload more than doubles the APK, slowing CI and the gate's installs (W6 once saw a 544.6 s install while adb stalled) | One payload ABI per APK; the install time recorded in the gate; the gate's limits raised only on evidence |
| AGP 9.3 with a `java-library` and an ndk-build module inside a Flutter project (t1 built on AGP 8.13.2) | W2 and W3 build the modules first in a bootstrap commit, before any app code depends on them |
| The sealed model on arm64 hardware is unproven (audit gap R2) | Test Lab in W5. No arm64 claim until it has run |
| API 26–28 behave differently (audit risk R3) | ADR-0007's rule |
| Test Lab: 5 physical runs a day, 45 minutes a run, shut down on 2027-09-30 | One run per gate. A successor is decided before September 2027 (ROADMAP's decision queue) |
| Side effects of the Material migration | Pages kept as `NoTransitionPage`; every changed golden looked at; `byTooltip` matches through semantics |
| Play Feature Delivery's terms with a GPLv3 app | `PlayPackInstaller` waits for the build-tools pack, and is decided with ADR-0011 |
| A long first install on low-end phones | Measured in Test Lab; progress in the UI; the editor works during the install |
| Storage: 360–380 MB installed plus the APK | The Runtime page shows the size; *Reinstall* and uninstall through `SealedUninstaller` |

## 10. Owner actions and decisions, in order

1. **Now, the licence (ADR-0011).** It was due by this phase's start, and W2 waits for it.
   - **A. GPLv3:** Termux's terminal view can be used, if it passes W7's gate. The whole app is GPLv3. Its source is already public; GPL licence texts and the userland's source offer are needed. In the Play build, Termux's GPLv3 code would be combined with Google's Play Feature Delivery library, whose terms are not open source. The owner can add a permission for his own code, but not for Termux's authors' code, so a Play build that uses packs needs a careful look.
   - **B. Permissive (Apache-2.0 or MIT):** xterm.js (MIT) in a WebView, like the editor. The PTY is written clean-room (about 200 lines) or comes from the Apache-2.0 jackpal lineage after a review. No Termux code is vendored. Apache-2.0 adds an explicit patent grant.
   - **C. Source-available or proprietary:** the same constraints as B, plus a legal review of every vendored file.
   - **Under every path:** the userland (bash, git, coreutils…) ships as an aggregate and needs its licence texts and a source offer. t1's runtime core can go under the chosen licence, since the owner wrote it.
2. **After W1, the next slice:**
   - **The exit phone session:** PHASE_3_PHONE_CHECKLIST, on W1's phone profile APK.
   - **Firebase:**
     1. Create a new Firebase project on the no-cost Spark plan, without a billing account.
     2. In its Google Cloud console, enable the Cloud Testing API and the Cloud Tool Results API.
     3. Create a service account with the roles *Firebase Test Lab Admin* (`roles/cloudtestservice.testAdmin`) and *Firebase Analytics Viewer* (`roles/firebase.analyticsViewer`).
     4. Store its JSON key as the repository secret `FIREBASE_TEST_LAB_KEY`, and the project id as the repository variable `FIREBASE_PROJECT_ID`.

     GitHub's OIDC token through Workload Identity Federation avoids a stored key, at the cost of a few more steps.
3. **After the licence decision, t1's LICENSE:** the same licence, on t1's main. CodeForge vendors from that commit.
4. **During this phase, the Play Console:** the developer account and the upload key. The closed test's start is proposed in W8.
5. **Later (ROADMAP's decision queue):** what runs the arm64 tests after Test Lab shuts down on 2027-09-30. The options are the Developer Device Platform (needs billing), the owner's phone sessions, or both.
