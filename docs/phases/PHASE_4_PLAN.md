# Phase 4 Implementation Plan — Runtime Integration

**Status:** **In progress.** Proposed on 2026-11-12; **W1 done on 2026-11-13** (CI 43373527631, 43375227087, 43379964388 and 43384226740; phase gates 43375227077, 43379964330 and 43384226759, see *As built (W1)*); **W2 done on 2026-11-13** (CI 43401882656 and 43403453442, see *As built (W2)*). **The licence is decided: Apache-2.0** (the owner, 2026-11-12; [ADR-0011](../adr/0011-license.md) Accepted), so by ADR-0006's rule the terminal is xterm.js and no Termux code is vendored. t1 carries the same licence since 2026-11-13 (main `d9789a2`), and CodeForge vendors from that commit.
**Spec reference:** §8 Phase 4 (runtime integration), §2 (reuse existing assets), §6.4–6.5 (the terminal connects to the existing environment; the capability model), §7 (security) · **Architecture:** [RUNTIME_INTEGRATION.md](../RUNTIME_INTEGRATION.md), [EXISTING_RUNTIME_AUDIT.md](../EXISTING_RUNTIME_AUDIT.md), [ADR-0005](../adr/0005-sealed-runtime.md), [ADR-0006](../adr/0006-terminal-frontend.md), [ADR-0007](../adr/0007-min-sdk.md), [ADR-0009](../adr/0009-ci-github-actions.md), [ADR-0010](../adr/0010-distribution.md), [ADR-0011](../adr/0011-license.md) · **Source:** `m-cyber12/t1` main @ `d9789a2` (2026-11-13): the audited tree `0e26d7a` (merged as `7b496c3`) plus its Apache-2.0 LICENSE

---

## 0. Carried in from Phase 3 and the owner

**Owner decisions at Phase 3's acceptance (2026-11-12)** ([PHASE_3_REPORT](PHASE_3_REPORT.md) §1):
1. Phase 3 is accepted. The owner runs the exit phone session after the next slice of work, which this plan makes W1 (its phone profile APK becomes the session's build).
2. G7's cold start is judged by that session's phone figure, for now. Impeller stays.
3. FULL against NORMAL ([ADR-0008](../adr/0008-persistence.md)) moves to this phase's Firebase Test Lab runs. The owner adds the Firebase project and its CI credential after the next slice.
4. Flutter 3.50.0, the Android Gradle Plugin and Kotlin's Gradle plugin are upgraded together ("so we upgrade all of them together"): W1.

**Owner decision while planning (2026-11-12): the licence is Apache-2.0.** Asked with this plan (ADR-0011's paths: A GPLv3, B permissive, C source-available), the owner chose path B with Apache-2.0, as recommended. So:
- ADR-0011 is Accepted, and CodeForge's `LICENSE` (the Apache License 2.0) was added with the decision.
- By ADR-0006's rule a permissive licence means **xterm.js** (ADR-0006 Accepted). Termux's `terminal-emulator` (with `termux.c` and `TerminalSession`), `terminal-view` and t1's `HarnessSession` are never vendored. Phase 5 builds the PTY and the session: the PTY clean-room (about 200 lines), or `termux.c` only if a legal review verifies its Apache-2.0 jackpal lineage.
- The terminal-gate package this plan had for path A fell away, so the plan has seven packages.
- t1 takes the same licence (an owner action) before W2 vendors from it.

**Owner decisions for Phase 4 from 2026-11-11** (PHASE_3_PLAN §0):
- **Licence** (ADR-0011): decided by Phase 4's start. Until then: no licence file, nothing GPL-derived vendored, no binary release. **Decided on 2026-11-12: Apache-2.0** (above).
- **Terminal frontend** (ADR-0006): Termux's terminal view if the licence is GPLv3 and the view passes this phase's arm64 gate; otherwise xterm.js. **With Apache-2.0: xterm.js** (above).
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
6. **Play Feature Delivery's library** (`com.google.android.play:feature-delivery`, used by t1's `PlayPackInstaller`) is published under the Play Core Software Development Kit Terms of Service, not an open-source licence. It would have mattered for a GPLv3 app's Play build; with Apache-2.0 there is no conflict. This phase does not need it (§2).

## 1. Objectives

1. Move to Flutter 3.50.0 with AGP, Kotlin's Gradle plugin and Gradle upgraded together, and migrate to `package:material_ui`, which 3.50 requires. Phase 3's evidence is re-established on the new toolchain.
2. Vendor t1's runtime under the licence the owner chose (Apache-2.0, ADR-0011), with its provenance and pinned inputs.
3. Install the sealed userland in CodeForge. It installs lazily on the first workspace open, verifies every file while writing it, shows its progress, and audits itself at every start (`ExecAudit` = 0). A warm start takes 100 ms or less. Failures are typed and visible.
4. Run one-shot commands and probe the tools across a typed boundary to Flutter: node, python, git, bash, perl, ruby and rg versions in the UI, and no orphan process.
5. Turn the gates green on API 34 and 36 x86_64 emulators, on API 26–28 (ADR-0007) and on a physical arm64 phone in Test Lab (audit gap R2). Measure FULL against NORMAL on that phone (ADR-0008).
6. Search across files: ripgrep in projects, a scan by the app in folders.
7. Draft the third-party notices and source offer, and prepare the Play Console. (The terminal frontend is resolved: xterm.js, by ADR-0006's rule.)

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

**As built (W1):**
- **Pins:** Flutter 3.50.0 (Dart 3.14.0), Kotlin's Gradle plugin 2.4.20 and Gradle 9.5.0, as planned. **Deviation:** the Android Gradle Plugin is **9.3.3**, the 9.3 line's latest patch, not the template's 9.3.1. AGP 9.3.0 and 9.3.1 bundle a lint that crashes on JDK 17 in every release build (Google issue 522845800, fixed in 9.3.2), and 9.3.3 also fixes D8/R8 bugs. Flutter 3.50.0 warns only below 9.3.1. JDK 17, compileSdk, targetSdk and the NDK are unchanged.
- **`material_ui` 1.10.0:** the bootstrap's `migrate_design_widgets` pass moved all 87 imports and changed nothing else. `pubspec.yaml` was untouched by it, and the lockfile only marks `material_ui` direct and moves `test_api` to 0.7.14. `analysis_options.yaml` enables the lint. None of the 26 golden images changed.
- **Navigation** builds go_router's `NoTransitionPage` itself, with go_router's own key, name, arguments and restoration id.
- **What the gates found** (three runs):
  1. **Gate 43375227077:** every group passed, but the three AOT builds (release x64, the Skia comparison, the phone profile APK) failed, so the cold start fell back to the debug APK (2443 ms). The job log named two causes:
     - Dart 3.14.0's AOT compiler crashes on a `final` local assigned in one case of a switch whose other case returns, then captured by a closure ([dart-lang/sdk#64917](https://github.com/dart-lang/sdk/issues/64917), P0, open on 2026-11-13). Home's folder reconnect had that shape and was restructured, with the same behaviour. A scan of `lib/` and of the main dependencies found no other instance.
     - AGP 9.3.1's lint crashes on JDK 17, hence 9.3.3.
  2. **Gate 43379964330:** the release builds worked (cold start 901 ms). Every group passed except watch: all of its checks passed, but the snack bar of its last reload was still animating when the test ended. The test now waits for that notice.
  3. **Gate 43384226759:** every group passed, each integration test on its first attempt, with no ANR and no crash.
- **CI builds the x86_64 release APK on every run** (24,631,359 bytes), so a failure only release builds show is caught there. The phase gate keeps its build logs in its evidence.
- **Actions:** the Node 24 majors. GitHub's warnings about Node 20 and the deprecated setup-java v4 are gone (CI 43375227087).
- **Gradle warnings** from AGP 9.3 and KGP 2.4.20 come from Flutter's template and Gradle plugin, not from our build files (BUILD_AND_RELEASE §3).
- **Evidence:** CI 43373527631 (the bootstrap: `+846: All tests passed!`, analysis clean, 230 files formatted with none changed, 44 Kotlin tests, coverage 90.4 %), 43375227087, 43379964388 and 43384226740, and the gates above.
- **Against Phase 3's exit gate** (43284276984; debug-APK figures vary from run to run on the emulator):

  | | Phase 3 exit | W1, gate 43384226759 |
  |---|---|---|
  | Cold start, release x64 with Impeller (G6 budget 1500 ms) | 1302 ms | **879 ms** |
  | The same build with Skia | 992 ms | 793 ms |
  | The shipped APK again, after Skia | 1338 ms | 875 ms |
  | Release memory, app and renderers | 231.0 MB | 230.4 MB |
  | CodeMirror (debug): input p95, memory | 49.6 ms, 527.5 MB | 55.8 ms, 520.4 MB |
  | Monaco (debug): input p95, memory | 68.4 ms, 597.5 MB | 50.7 ms, 624.5 MB |
  | Project of 10,000 files: opened, indexed | 273 ms, 206 ms | 247 ms, 142 ms |
  | 1,000 entries listed through the broker | 529 ms | 326 ms |
  | Watch reloads: project, folder | 470 ms, 888 ms | 784 ms, 782 ms |
  | ANRs (Phase 3's were Play services') | 3 | 0 |
  | Debug APK | 177,806,969 B | 175,890,512 B |

- **The exit phone session's build:** the `codeforge-phone-profile-arm64` artifact of gate 43384226759 ([artifact 14018654763](https://github.com/Skill-center/CodeForge-/actions/runs/43384226759/artifacts/14018654763), kept until 2026-12-13), which PHASE_3_PHONE_CHECKLIST names.

### W2 — Provenance, pins and the sealed-runtime kernel (1 session; needs t1's Apache-2.0 LICENSE) → G2

- **The licence is in place:** ADR-0011 was Accepted on 2026-11-12 (Apache-2.0), and CodeForge's `LICENSE` came with the decision. t1 gets the same LICENSE (an owner action), and CodeForge vendors from that commit, keeping t1's attribution in PROVENANCE.
- **`native/sealed-runtime/`:** a plain Java library (`java-library`, no Android SDK). It holds the 8 kernel classes (`SealedInstaller`, `PayloadExtractor`, `RuntimeManifest`, `SealedLayout`, `ExecAudit`, `ExecutableProbe`, `ExecutableKind`, `SealedUninstaller`) and the 3 JVM test classes (`SealedInstallerTest`, `ExecSealingTest`, `PackPayloadTest`). They are renamed to `dev.codeforge.runtime.sealed` with t1's `export-sealed-runtime.sh` pattern, and the tests are otherwise unchanged. `app/android/settings.gradle.kts` includes the module, and CI runs `:native:sealed-runtime:test`.
- **`native/PROVENANCE.md`:** the source repository and commit, every file with its SHA-256, its licence, the package renames, and the re-vendor procedure.
- **`runtime/`:** `build-sealed-payload.py`, `fetch-core-debs.py`, `check-bundle-size.py`, `check-page-alignment.py` and `check-sealed-manifest.sh`, with their unit tests running in CI.
- **`runtime/pins.json` pins every input.** The bootstrap is pinned per ABI with t1's SHA-256 (aarch64 `ea2aeba8…f4f3`, x86_64 `b7fd0f2e…4f7a`). The core package set is resolved once and pinned: name, version, file and SHA-256 for each package and its dependencies.
  - Because Termux keeps only the latest versions, CI caches the pinned `.deb`s under the pins' hash.
  - A pinned version that has gone from the repository fails the build closed and names the package.
  - Re-pinning is a deliberate commit.
  - A mirror of the pinned packages (a GitHub release) would redistribute GPL binaries, so it is considered only after the licence decision, with the source offer.
- **The notices start here.** THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md are drafted from the pinned packages' copyright files (ADR-0011's interim rule 3).

**As built (W2):**
- **The source:** t1's main at `d9789a2` (2026-11-13). It differs from the audited `0e26d7a` only by its Apache-2.0 LICENSE, which is the text of CodeForge's own ([native/PROVENANCE.md](../../native/PROVENANCE.md)).
- **The kernel** (`native/sealed-runtime/`):
  - t1's 8 classes and 3 test classes, copied by t1's own `export-sealed-runtime.sh` with the package `dev.codeforge.runtime.sealed`. Each file differs from t1 in its `package` line alone.
  - The build script is t1's, in the Kotlin DSL. `settings.gradle.kts` includes the module and points both project directories, `:native` and `:native:sealed-runtime`, at the repository's root.
  - Nothing depends on the module before W3. **Its 22 tests pass** (CI 43401882656), and the debug and release APKs are unchanged by it.
- **`runtime/`:** t1's five scripts and their two tests, byte for byte. CodeForge's own files sit beside them (REPOSITORY_STRUCTURE's boundary rule 3): `pins.py`, `notices.py`, `provenance.py`, the tests' fixtures, three test files and a live check, and a README.
- **PROVENANCE** lists every vendored file with its t1 path and the SHA-256 of both copies.
  - `runtime/provenance.py check`, run in CI, proves that undoing the package rename gives t1's bytes for each file. It also fails on any file under `native/` or `runtime/` that isn't recorded.
  - Its `record` command is the last step of a re-vendor.
- **The pins** (`runtime/pins.json`):
  - **What is pinned:** the bootstrap per ABI by t1's SHA-256, and t1's 13 core packages. CI's first `[repin]` resolved them with t1's resolver into **50 packages per ABI**, at the same versions on both: 72.7 MB of `.deb`s for arm64 and 74.4 MB for x86_64. 17 of them replace the bootstrap's copies, and 33 are new.
  - **Found by the first resolution:** replacing a bootstrap library strands the bootstrap packages built against it. A Termux subpackage depends on its parent's exact version, so the bootstrap's `curl` 8.18.0-1 needs `libcurl (= 8.18.0-1)`, and it would have shipped beside 8.23.0. t1 composes its payload the same way.
    - **The fix:** `pins.py resolve` adds every stranded package to the request and resolves again, until every dependency in the payload is met. This time that was `curl` and `xz-utils`, which pins.json lists under `consistency`.
    - `check` now verifies the whole payload, the bootstrap's packages included (CI 43403453442).
  - **Fetching never resolves.** It takes exactly the pinned files and verifies each one. When a file is gone it fails closed, naming every missing package and what the index lists now.
  - **Caching:** CI keeps the files in a cache keyed on the pins' hash.
  - **Re-pinning** is a commit tagged `[repin]`: CI resolves it and commits the result back.
- **G2's fail-closed criterion, shown twice:**
  - **On a synthetic repository** (`test-pins.py`): a version that is gone, changed bytes, a different bootstrap, and every missing package named in one report.
  - **On the live Termux repository:** CI points one pinned package at a version that doesn't exist. The fetch exits 1, names `git`, and hands nothing to the payload builder (`runtime/ci-results/fail-closed.txt`).
- **The payloads build** from exactly the pinned files with t1's script. This is informative until W3.

  | ABI | Executables | Shipped as | Data files |
  |---|---|---|---|
  | arm64 | 534 | 252 unique binaries, 99.5 MB as JNI libraries | 13,892, in a 97.9 MB zip |
  | x86_64 | 535 | 251 unique binaries, 99.2 MB | 13,894, in a 98.0 MB zip |

  **For W3:** that is about 197 MB per ABI before the APK compresses it. The APK and per-device sizes are G3's to measure.
- **The notices** are drafted from the licence files inside the pinned packages: 112 package versions, 52 of them under a copyleft licence (SOURCE_OFFER.md).
  - **How licences are named:** most come from Termux's links to `share/LICENSES/<id>.txt`. The others are identified from their text and marked with an asterisk.
  - **16 packages are listed for W7's review:**
    - 8 have no licence file of their own. 7 of them are subpackages whose licence sits in their parent's directory (`curl`'s in `libcurl`'s); `gpgv`'s parent isn't shipped at all.
    - The other 8 have a text the draft doesn't identify: lsof's and Info-ZIP's own licences, and summary files.
- **CI:**
  - **The quality job** runs the kernel's tests as its gate `sealed_runtime_tests`.
  - **A new `runtime` job** runs the script tests (5 files, 45 cases), the provenance and pins checks, the fetch for both ABIs, the live fail-closed check, the payloads and the notices. It takes about 3½ minutes, a re-pin included.
- **Evidence:**
  - **CI 43401882656** (`[bootstrap][repin]`): every job green, `sealed_runtime_tests=22`, `+846: All tests passed!`, 44 Kotlin tests, and the release x64 APK unchanged at 24,631,359 bytes.
  - **CI 43403453442:** the consistency re-pin. Every job is green, the sealed-runtime tests and the release build among them.
  - **No emulator gate for W2:** nothing in the app changed, and G2's evidence is CI. W3's gate runs on the module in the build.

### W3 — RuntimeHost: install, verify, audit (2 sessions) 🔑 critical path → G3

**`native/runtime-core/`:** an Android library in the package `dev.codeforge.runtime.core`.
- **Vendored:** t1's `HarnessConfig`, `HarnessPaths`, `HarnessEnvironment`, `HarnessCommandRunner`, `HarnessSizeReport`, `Toolchain`, `exec/SealedPayloadInstaller` and `packs/{Pack, PackState, PackResult, PackInstaller, Packs}`. `Packs.isSealedBuild` is true at compile time, and the apt branch is deleted, not switched off.
- **Left behind:** `HarnessBootstrap`, `provision/*`, `HarnessPackageInstaller`, `AptPackInstaller` and `PackCommands`.
- **Not vendored:** `HarnessSession`, which is built on Termux's `TerminalSession`, and with it t1's `api project(":terminal-emulator")`. Phase 5 writes CodeForge's own session on its own PTY. `PlayPackInstaller` comes with the build-tools pack.

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

### W7 — Notices, Play preparation, docs and the phase exit (1 session) → G9

**Notices:** THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md are completed.
- They cover the userland's packages with versions and licences, the Dart and npm dependencies, and the Flutter engine.
- No binary release happens until both documents are published (ADR-0010; ADR-0011 is Accepted).

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
- ADR-0007 Accepted, ADR-0008's phone measurement, and ADR-0013 (how a folder reaches the runtime). ADR-0011 (Apache-2.0, with CodeForge's `LICENSE`) and ADR-0006 (xterm.js) were decided with this plan.
- THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md; the Play listing drafts; PHASE_4_REPORT.

## 5. Acceptance criteria (measurable gates)

| Gate | Criterion | Evidence |
|---|---|---|
| **G1 Toolchain** | CI builds with Flutter 3.50.0, AGP 9.3.3 (planned as 9.3.1; see *As built (W1)*), KGP 2.4.20 and Gradle 9.5.0. Analysis is clean and formatting unchanged, every test passes, and every changed golden has been looked at. The Kotlin tests pass. Every phase-gate group passes, and the cold start is recorded with Impeller and with Skia | CI and gate run ids |
| **G2 Kernel** | `:native:sealed-runtime:test` passes with t1's tests changed only in their package. The `runtime/` script tests pass. PROVENANCE is complete. A missing pinned package fails the build closed | CI |
| **G3 Install** | The first install runs off the UI thread with progress, within 60 s on a mid-range phone (emulator and Test Lab figures recorded). A warm start takes 100 ms or less. A flipped byte gives a typed failure and the runtime is never marked ready. `ExecAudit` = 0 at every start. APK and per-device sizes recorded | the gate's runtime group, instrumented tests |
| **G4 Versions** | node, python, git, bash, perl, ruby and rg versions reach the Flutter UI through RuntimeHost and match the pinned packages. Ending a process leaves no child | instrumented, widget and gate tests |
| **G5 Emulators** | `ExecModelTest` and `SealedShellTest` pass on API 34 and 36 x86_64 | runtime-gates run |
| **G6 arm64** | The same tests pass on a physical arm64 phone in Test Lab. FULL against NORMAL is measured there and ADR-0008 updated | Test Lab runs |
| **G7 minSdk** | The API 26–28 legs pass and ADR-0007 is Accepted at 26, or the owner signs off a raise to 29 | runtime-gates run |
| **G8 Search** | ripgrep in projects and the scan in folders find the gate's fixtures. Results open at the line and cancelling works. Figures recorded and a budget proposed | widget, integration and gate tests |
| **G9 Licence and docs** | ADR-0011 Accepted (Apache-2.0) with CodeForge's `LICENSE`, and t1 licensed alike. ADR-0006 resolved (xterm.js). Notices and source offer drafted. Docs synced and PHASE_4_REPORT written | the documents |

## 6. Tests

- **JVM:** the vendored kernel's tests, unchanged; the adapter's and `RuntimeHost`'s tests; `FolderWatches.kt` if possible.
- **Python:** the `runtime/` scripts' unit tests, including the pins' failure when a version has gone.
- **Instrumented (`androidTest`):** `ExecModelTest`, `SealedShellTest`, the flipped-byte install, no orphan child, the warm start. These run on five emulator levels and on Test Lab's arm64 phone.
- **Flutter:** widget tests for the Runtime page, the status strip, the Search panel and the capability flags. The existing suite runs unchanged on 3.50.0 and material_ui.
- **Phase gate:** every Phase 3 group, plus the runtime group and search on the gate's fixtures.

## 7. Documentation

RUNTIME_INTEGRATION (as built), EXISTING_RUNTIME_AUDIT (t1's merge, PR #229), ARCHITECTURE, SECURITY §2, TECH_STACK, BUILD_AND_RELEASE, TESTING, PERFORMANCE, REPOSITORY_STRUCTURE, ADR-0006, ADR-0007, ADR-0008, ADR-0009 (Test Lab's deprecation), ADR-0011, ADR-0013, ROADMAP, README, the changelog, PHASE_3_PHONE_CHECKLIST (the new build) and PHASE_4_REPORT.

## 8. Known limitations (planned) and out of scope

- No terminal sessions and no *Run* (Phase 5: xterm.js, with CodeForge's own PTY and session), no language servers (Phase 6), no Git UI (Phase 7), though git ships in the payload.
- No build-tools pack: no C or C++ compiling in this phase.
- No 32-bit ARM build (§2).
- No binary release: CI artifacts only, until the notices and source offer are published (ADR-0010).
- Folders don't reach the runtime in this phase. W6 decides how, and Phase 5 builds it.
- npm and pip packages with native addons can't build without the build-tools pack. Phase 5 documents this in the app (SECURITY §2).

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| t1's LICENSE waits, and with it the vendoring | W1 needs none. It is asked for with this plan (§10) |
| Termux removes a pinned package version | Pins plus a CI cache under the pins' hash; the build fails closed, naming the package; re-pinning is a deliberate commit; a mirror after the licence decision |
| The payload more than doubles the APK, slowing CI and the gate's installs (W6 once saw a 544.6 s install while adb stalled) | One payload ABI per APK; the install time recorded in the gate; the gate's limits raised only on evidence |
| AGP 9.3 with a `java-library` and an ndk-build module inside a Flutter project (t1 built on AGP 8.13.2) | W2 and W3 build the modules first in a bootstrap commit, before any app code depends on them |
| The sealed model on arm64 hardware is unproven (audit gap R2) | Test Lab in W5. No arm64 claim until it has run |
| API 26–28 behave differently (audit risk R3) | ADR-0007's rule |
| Test Lab: 5 physical runs a day, 45 minutes a run, shut down on 2027-09-30 | One run per gate. A successor is decided before September 2027 (ROADMAP's decision queue) |
| Side effects of the Material migration | Pages kept as `NoTransitionPage`; every changed golden looked at; `byTooltip` matches through semantics |
| A long first install on low-end phones | Measured in Test Lab; progress in the UI; the editor works during the install |
| Storage: 360–380 MB installed plus the APK | The Runtime page shows the size; *Reinstall* and uninstall through `SealedUninstaller` |

## 10. Owner actions and decisions, in order

1. **Decided on 2026-11-12: Apache-2.0** (ADR-0011's path B), recorded in ADR-0011 and ADR-0006, with CodeForge's `LICENSE`. The userland (bash, git, coreutils…) still ships as an aggregate, with its licence texts and a source offer (W2, W7).
2. **Now, t1's LICENSE:** the Apache License 2.0 on t1's main. On GitHub: *Add file* → *Create new file*, name it `LICENSE`, *Choose a license template* → *Apache License 2.0*, and commit it to `main`. W2 vendors from that commit.
3. **After W1, the next slice:**
   - **The exit phone session:** PHASE_3_PHONE_CHECKLIST, on W1's phone profile APK.
   - **Firebase:**
     1. Create a new Firebase project on the no-cost Spark plan, without a billing account.
     2. In its Google Cloud console, enable the Cloud Testing API and the Cloud Tool Results API.
     3. Create a service account with the roles *Firebase Test Lab Admin* (`roles/cloudtestservice.testAdmin`) and *Firebase Analytics Viewer* (`roles/firebase.analyticsViewer`).
     4. Store its JSON key as the repository secret `FIREBASE_TEST_LAB_KEY`, and the project id as the repository variable `FIREBASE_PROJECT_ID`.

     GitHub's OIDC token through Workload Identity Federation avoids a stored key, at the cost of a few more steps.
4. **During this phase, the Play Console:** the developer account and the upload key. The closed test's start is proposed in W7.
5. **Later (ROADMAP's decision queue):** what runs the arm64 tests after Test Lab shuts down on 2027-09-30. The options are the Developer Device Platform (needs billing), the owner's phone sessions, or both.
