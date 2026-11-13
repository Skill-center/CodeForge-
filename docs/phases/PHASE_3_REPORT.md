# Phase 3 Report — Workspace & Files

**Status:** **Accepted by the owner on 2026-11-12**; the owner runs the exit phone session after the next slice of work (§1, §8) · **Date:** 2026-11-12 · **Branch:** `arena/f57c33ee-codeforge`
**Plan:** [PHASE_3_PLAN.md](PHASE_3_PLAN.md) · **Spec:** §8 Phase 3, §7, §12.19 · **Rule:** every claim below cites a CI run or an evidence commit. Where something was not measured or not met, this report says so.

---

## 1. Summary

Phase 3 turns the single demo workspace into a project-based IDE:
- **Projects** live in the app's own storage, one folder each. **Folders on the device** open through Android's own folder picker, with no storage permission. Only a Kotlin storage broker touches them, behind a typed Pigeon API.
- **Home is the launcher.** Its recents show each workspace's kind, place and status. Projects are created, renamed and deleted there. Folders are reconnected when they move and given back to Android when they leave the recents.
- **Each workspace keeps its tabs, unsaved text and explorer view** across switches and restarts.
- **The explorer** creates, renames, moves, copies, duplicates and deletes on both kinds of workspace, and open documents follow every change. **Go to File** finds a file by name.
- **Files changed by other apps** reach the editor as it happens, and unsaved text is never overwritten.
- **Android backup is the user's choice,** off by default. **Logs are kept on disk,** redacted, and can be copied or saved.
- **The app renders with Impeller,** Flutter's default, instead of the deprecated Skia opt-out.

ROADMAP's MVP 3, "SAF open-folder, explorer CRUD, file watch, state survives restart, recents", is met (G1–G5), and so is its gate, the storage scoping security review (SECURITY.md §4.1).

| Gate | Result | Evidence (details in §4) |
|---|---|---|
| G1 Folders | ✅ met | the gate's `folders` group in every gate since W2 (first in 43007795087); 44 JVM tests |
| G2 Projects & recents | ✅ met | workspace and Home tests, the v1 → v2 migration from a fixture (CI 43284276980); the restore pair with a folder and a switch (gates since 43069846571) |
| G3 Explorer | ✅ met | service tests on a real folder, widget tests at 10,000 entries; the gate's `explorer` group (since 43183687317) |
| G4 Outside changes | ✅ met | the gate's `watch` group (since 43222339848): reloads within 2 s on the emulator; unit and widget tests |
| G5 Restart | ✅ met | the restore pair, extended (since 43069846571) |
| G6 Owner items | ✅ met | the backup group (`bmgr`) in every gate since W1; the log sink's tests; the W4 and W6 items |
| G7 Performance | ◐ measurements recorded; **the release cold start met the budget in the exit gate (1302 ms), but not reliably:** with Impeller it went over 1500 ms in two of Phase 3's five gates; **decided 2026-11-12:** the exit session's phone figure decides | `measure.json`, `perf.json` (§7) |
| G8 Quality & security | ✅ met | CI 43284276980: Flutter, editor and Kotlin green, the manifest check; SECURITY §4.1 done; the accessibility sweeps |
| G9 Docs | ✅ this commit | this report; the plan's §7 documents synced |

**What the gates found.** The emulator gate runs the real app, with input and file changes from outside it. In Phase 3 it, CI and code review caught these before a work package counted:
- **Android's restore stamps files with January 1970** (W1, the backup group): AOSP passes seconds where milliseconds are expected. Nothing broke, since the app compares stamps only for equality, and W4 and W5 were built not to trust those times.
- **The keys flake** (W3): a dialog of another app's could take the injected tap. The injector now records which window has the focus around every tap, and the gate hides Android's error dialogs after boot. `keys` has passed on its first try in every gate since 43076652650.
- **The explorer carried one workspace's expanded folders into the next** (W3, CI 43067325867): Riverpod keeps a notifier's fields across rebuilds.
- **The Flutter pin was not enforced** (W3): the workflows installed whatever Flutter was the latest stable, which became 3.50.0 and broke the debug build. Both workflows now install `.flutter-version` exactly and fail on any other.
- **The watcher promised to retry failed watches on resume, and didn't** (W5, review during gate 43222339848). 62cc4ae fixed it.
- **The benchmark's DevTools driver missed whole engines** (W6): two gates lost one engine's figures, and the first fix stalled adb for half an hour by polling another app's frozen DevTools socket. The driver now gives up on unanswered requests and talks only to the app's own socket (§9.1).
- **What the app said was still to come was out of date** (W7): Settings listed Phase 3's own *Storage & folders* as coming, and four places named the wrong phase for search, Git and extensions. `later_phases_test` pins them now.

**Owner decisions during the phase:**
- **2026-11-10, at Phase 2's acceptance:** backup as an offer, off by default; the on-disk log sink in Phase 3; the parked large-file checks become phone-only (PHASE_3_PLAN §0).
- **2026-11-11, the 18 open items from Phases 0–2** (PHASE_3_PLAN §0): what Phase 3 builds (W3's keys diagnosis, W4's Save logs and icons, W6's six items), one phone session at the exit (W7), search across files in Phase 4, other encodings later, and Flutter 3.47.9 kept.
- **W1–W5:** each work package was reported and accepted with "next".
- **2026-11-12, after W6:** the owner told the agent to continue into W7 without waiting for approval ("you are free"). W6's report and this one were therefore written without an intermediate "next".

**Owner decisions at acceptance (2026-11-12).** The report asked four questions, and the owner answered:
1. **Phase 3 is accepted** ("yeah I accept, I'll do it after this slice"). The owner runs the exit phone session after the next slice of work (§8).
2. **G7's cold start: the exit session's phone figure decides,** for now ("your recommendation is ok for now"). Impeller stays.
3. **FULL against NORMAL moves to Phase 4's Firebase Test Lab runs.** The owner adds the Firebase project and its CI credential after the next slice ("yeah I will add it after this slice").
4. **Flutter 3.50.0 is taken, with the Android Gradle Plugin and Kotlin's Gradle plugin upgraded together** ("so we upgrade all of them together"). Following the 3.50.0 template, as since Phase 1, that means AGP 9.3.1, Kotlin 2.4.20 and Gradle 9.5.0 (BUILD_AND_RELEASE §3).

## 2. Evidence index

All runs are on `Skill-center/CodeForge-`, branch `arena/f57c33ee-codeforge`. `[bootstrap]` runs commit their diagnostics back (`app/ci-results/`), and gate runs commit `app/ci-results/gate/`; see [BUILD_AND_RELEASE.md §2.1](../BUILD_AND_RELEASE.md). Test counts are quoted from the compact reporter's final line. Each work package's own evidence is in the plan's *As built (W1)* to *(W6)*.

| Run | Workflow | Head commit | Result | What it proves |
|---|---|---|---|---|
| **43284276980** | CI `[bootstrap]` | `a78cbee` (final app tree) | ✅ | **The final tree:** `01:38 +846: All tests passed!`, analyze clean, format unchanged, goldens `+26`, `kotlin_tests=44 failures=0 errors=0`, `manifest_check=pass findings=0`, the editor job's 208 vitest tests, coverage 8212/9081 lines (90.4 %), and the debug APK with its SHA-256 (§6) |
| **43284276984** | Phase gate | `a78cbee` | ✅ | **The final app on the KVM emulator:** every group on its first try (`gate_result=pass`), 38 minutes; release cold start 1302 ms (Skia 992 ms); both benchmark engines driven (CodeMirror: input p95 49.6 ms, composition 9 of 9); release memory 231.0 MB; `watch` reloads 470 and 888 ms; the measurements; the phone profile APK (§6). Evidence `ca2a51b` |
| 43281243227 | CI `[bootstrap]` | `3b8aa50` | ✅ | `02:15 +845: All tests passed!`; the Settings and Privacy goldens without Phase 3's entry (`18d7363`) |
| 43270594252 | Phase gate | `1680e1d` | ✅ | W6's final gate: every group on its first try, both benchmark engines driven, cold start 1527 ms (Skia 1061 ms), measurements |
| 43256861510 | Phase gate | `f9a4b43` | ✅ | both engines driven, but adb stalled (71 minutes); cold start 1403 ms (Skia 961 ms); measurements |
| 43247963954 | Phase gate | `4ca62ed` | ✅ | the first measurements; cold start 1388 ms (Skia 1067 ms); the driver missed CodeMirror |
| 43247964184 | CI `[bootstrap]` | `4ca62ed` | ✅ | W6: `02:09 +839: All tests passed!`, coverage 90.4 % |
| 43238952262 | Phase gate | `61edcfd` | ✅ | Impeller's run: every group on its first try; cold start 1688 ms |
| 43228855243 | Phase gate | `62cc4ae` | ✅ | W5: `watch` reloads 574 and 792 ms after the write |
| 43228855253 | CI | `62cc4ae` | ✅ | W5: `02:06 +809: All tests passed!`, coverage 90.2 % |
| 43183687317 | Phase gate | `a0fd31e` | ✅ | W4: the `explorer` group, 19 disk checks |
| 43166674651 | CI | `a722f1a` | ✅ | W4: `02:03 +773: All tests passed!`, coverage 89.8 % |
| 43088413208 | Phase gate | `d69bd61` | ✅ | W3 on the enforced Flutter 3.47.9 pin |
| 43076652650 | Phase gate | `0c4337f` | ✅ | W3: `keys` fixed; the restore pair with a folder and a switch |
| 43069846481 | CI | `3bdb685` | ✅ | W3: `01:37 +687: All tests passed!`, coverage 89.1 %, schema v2 |
| 43007795087 | Phase gate | `b72da16` | ✅ attempt 2 | W2: the `folders` group passed in both attempts (attempt 1 failed only `keys`) |
| 43007795037 | CI | `b72da16` | ✅ | W2: `01:37 +631: All tests passed!`, Kotlin 44 |
| 42862715744 | Phase gate | `a558bd3` | ✅ attempt 2 | W1: the backup group's three results |
| 42862715832 | CI | `a558bd3` | ✅ | W1: `01:30 +607: All tests passed!`, Kotlin 7 |

## 3. What was built

| WP | What | Plan |
|---|---|---|
| W1 | Android backup as a switch, off by default, with a host backup agent and rules files (ADR-0012); the log file, rotated and redacted; tab semantics for TalkBack; saves that keep permission bits; *Create large test files* and the benchmark's plain-text pass; Kotlin tests in CI | *As built (W1)* |
| W2 | SECURITY §4.1 first (S1–S7); the Kotlin storage broker behind Pigeon's `StorageApi`; `SafFileService`; *Open Folder…*; the gate's `folders` group with a host-side picker driver | *As built (W2)* |
| W3 | the keys flake found and fixed; projects (create, rename, delete); Home as the launcher with recents and statuses; reconnect and remove; schema v2 and its migration; each workspace's tabs, unsaved text and explorer view; the restore pair with a folder and a switch; the Flutter pin enforced | *As built (W3)* |
| W4 | the explorer's operations on both backends, with open documents and their journal following; Go to File; *Save logs* through the create-document picker; Material Symbols Rounded and the file glyphs; the gate's `explorer` group | *As built (W4)* |
| W5 | outside changes: inotify in projects and the provider's notices in folders, 300 ms batches, reloads, the conflict banner, deleted files, re-checks on resume; the gate's `watch` group | *As built (W5)* |
| W6 | Impeller; the manifest check; the save digest off the UI isolate; the benchmark driver's reconnect, time limits and own-socket forwarder; golden diff images; the debug log viewer; the `ProviderObserver`; the accessibility sweeps and goldens of the new chrome; the gate's `measure` group and the Skia comparison | *As built (W6)* |
| W7 | the docs synced; the exit phone checklist; this report; Settings and the workbench naming ROADMAP's phases | *As built (W7)* |

## 4. Gate by gate

**G1 Folders** ✅
- *A folder opens through Android's picker, and its grant survives a process death:* the `folders` group drives DocumentsUI from the host (*Use this folder*, *Allow*), then `am force-stop`, then part B finds the folder reopened by itself (every gate since 43007795087).
- *Every operation through the real provider, checked on disk:* 23 disk checks and 3 listings per run, shorter text over longer checked with `sha256sum`, and a case-only rename (`Readme.md` → `README.md`) with no "(1)" left.
- *Nothing outside the tree:* `..` paths refused by the broker itself, the folder beside the granted one and the folder above refused as never granted (gate), and SECURITY §4.1's JVM tests (`StoragePathsTest`, `DocumentOpsTest`, `CappedReadTest`).
- *A missing folder or a lost grant shows its status:* part B deletes the folder (*missing*) and releases the grant (*access lost*), without a crash.

**G2 Projects & recents** ✅
- Projects created, renamed and deleted, and recents with kind, place and status: `home_launcher_test`, `workspace_switch_test` and `project_storage_test`.
- Switching keeps each workspace's tabs and unsaved text: `workspace_switch_test`, and the restore pair (part A leaves unsaved text in both workspaces; part B finds both).
- The v1 → v2 migration passes from a fixture: `test/drift/app/migration_test.dart`, with drift_dev's verifier (ADR-0008).

**G3 Explorer** ✅
- New file and folder, rename (case-only too), move, copy, duplicate and delete on both kinds of workspace: the services' tests on a real temporary folder and against a fake broker, `explorer_operations_test`, and the gate's `explorer` group on the demo project and on a picked folder (19 disk checks, one save through the create-document picker; since 43183687317).
- Open tabs and the journal follow every change: `DocumentController.pathMoved` and `SessionStore.movePaths` (one transaction), with tests; the restore pair's part B after renames.
- A name collision never overwrites: `exists` in every backend's tests.
- The tree builds only visible rows at 10,000 entries: `explorer_operations_test` ("at 10,000 entries the tree builds only the rows on screen").

**G4 Outside changes** ✅
- The gate's `watch` group changes files behind the app's back, as `run-as` in the project and as the shell user in the folder, and times each reload from the write on the device's clock. Reloads took 545 to 997 ms in W5's and W6's gates (470 and 888 ms in the exit gate), all within 2 s.
- Unsaved text is never overwritten, new and deleted files reach the explorer, the app's own saves cause no reload, and changes made in the background are caught on resume: the same group, `file_watch_test` and `outside_changes_test`.

**G5 Restart** ✅ The restore pair, extended in W3: after `am force-stop`, part B finds the last workspace (a folder), its tabs with their unsaved text, its expanded folders and the project's explorer scroll, and the recents. The log file holds part A's last record ahead of part B's session marker. It has passed in every gate since 43069846571.

**G6 Owner items** ✅
- Backup off by default; with it on, a backup and reinstall restore a project and its unsaved text, never the logs; with it off, a fresh app: the gate's backup group with `bmgr` and the local transport, the same three results in every gate since W1, and `BackupPolicyTest`.
- The log sink rotates, redacts and survives a crash: `file_log_sink_test`, `logger_test`, and the restore pair's log check after a force-stop.
- The Developer action writes byte-identical gate files, and the plain-text pass runs: `large_test_files_test`, `developer_tools_test`.
- TalkBack hears the active tab and unsaved changes: `editor_tabs_test` ("*name*, unsaved changes"; selected state).
- Project saves keep permission bits: `local_file_service_test` (W1).
- The items of 2026-11-11: Save logs and Material Symbols (W4); the digest off the UI isolate, the driver's reconnect, golden diff images, the log viewer and the `ProviderObserver` (W6). Each has its tests in the plan's *As built*.

**G7 Performance** ◐
- *The W6 measurements, recorded on the renderer the app ships:* ✅ in three gates on Impeller (§7.1).
- *Release cold start ≤ 1500 ms:* **met in the exit gate (1302 ms), but not reliably.** Impeller's medians were 1688, 1388, 1403 and 1527 ms in W6's gates and 1302 ms in the exit gate: two of five over the budget. The same build on Skia took 961 to 1067 ms in the same runs. Decision 2 in §1 asks how G7 is judged.

**G8 Quality & security** ✅
- CI green, Flutter, editor and Kotlin: CI 43284276980 (§2).
- No storage permission: `tool/ci/check_manifest.py` on every debug build since W6 (`manifest_check=pass findings=0`).
- SECURITY §4's storage review: done, S1–S7 each with its proof (SECURITY.md §4.1).
- The accessibility suite covers the new chrome, and nothing overflows with the keyboard up: `accessibility_test` and `keyboard_insets_test` since W6 (Home's recents and dialogs, a recent's actions, the explorer's menu, Privacy, the log viewer).

**G9 Docs** ✅ This report; the plan's §7 list synced in W7 (ARCHITECTURE §2.8 and §3, EDITOR_ARCHITECTURE §6, SECURITY §1 and §4, ADR-0008 and ADR-0012, RUNTIME_INTEGRATION §4, TESTING, BUILD_AND_RELEASE, TECH_STACK, PERFORMANCE §4, UI_DESIGN_SYSTEM, CHANGELOG, ROADMAP, README), and the exit checklist.

## 5. Tests

| | Phase 2 exit | W1 | W2 | W3 | W4 | W5 | W6 | W7 |
|---|---|---|---|---|---|---|---|---|
| Flutter tests (`+N: All tests passed!`) | 563 | 607 | 631 | 687 | 773 | 809 | 839 | 846 |
| Coverage, hand-written code | 88.0 % | 88.3 % | 87.9 % | 89.1 % | 89.8 % | 90.2 % | 90.4 % | 90.4 % |
| Kotlin (JVM) | — | 7 | 44 | 44 | 44 | 44 | 44 | 44 |
| Editor vitest | 187 | 188 | | | 189 | 194 | 201 to 208 | 208 |
| Goldens | 22 | 22 | 22 | 22 | 22 | 22 | 26 | 26 |

Coverage per layer in the final tree (CI 43284276980): application 93.3 %, core 93.8 %, design_system 95.3 %, features 92.9 %, services 79.4 %, the root 96.8 %. The services' gap is the platform glue (Pigeon, method channels, `dart:io` failures), which the gate runs on the emulator. `FolderWatches.kt` has no JVM test, since it needs a real provider; the `watch` group runs it.

The emulator gate gained five groups, numbered 9 to 13 in BUILD_AND_RELEASE §2: `backup` (W1), `folders` (W2), `explorer` (W4), `watch` (W5) and `measure` (W6). Since W3 the restore pair opens a folder and switches workspaces.

## 6. Build artifacts

- **Debug APK** (all ABIs): the `codeforge-debug-apk` artifact of CI 43284276980, 177,806,969 bytes, SHA-256 `2fdf948b7446d00bd68d711c2116aeaf3f2193c7d31c03e822b9cbe7bd56fbc2`, kept until 2027-02-10.
- **Phone profile APK** (arm64): the `codeforge-phone-profile-arm64` artifact of phase gate 43284276984 ([artifact 13975424637](https://github.com/Skill-center/CodeForge-/actions/runs/43284276984/artifacts/13975424637)), kept until 2026-12-12. The exit checklist uses it.
- Every CI build is signed with its own throwaway key, so an earlier build must be uninstalled first, and a backup restores only into the same APK file.

## 7. Performance

### 7.1 The W6 measurements (G7, recorded)

Medians of three runs each, in phase gates 43247963954, 43256861510 and 43270594252 (PHASE_3_PLAN *As built (W6)*); recorded, never judged on the emulator:

| What | dart:io (a project) | the broker (a folder from shared storage) |
|---|---|---|
| Write 1 MiB | 29, 23, 25 ms | 80, 89, 75 ms |
| Read 1 MiB | 25, 14, 13 ms | 45, 29, 49 ms |
| Write 10 MiB | 76, 51, 81 ms | 135, 162, 130 ms |
| Read 10 MiB | 29, 62, 41 ms | 79, 90, 98 ms |

- A project of 10,000 files opened in 331, 296 and 330 ms; Go to File's index of it was built in 239, 217 and 208 ms.
- A folder of 1,000 entries was listed in 572, 583 and 477 ms.
- 10 MiB digested on the UI isolate took 280, 270 and 260 ms with no frame drawn. In the background it took 821, 700 and 796 ms, while 14, 13 and 14 frames were drawn, at most 96, 133 and 140 ms apart.
- **The exit gate, 43284276984, measured within the earlier gates' range or below it:** dart:io 14, 8, 70 and 29 ms in the table's order, the broker 71, 22, 133 and 96 ms; the project opened in 273 ms and was indexed in 206 ms; the folder was listed in 529 ms; the digest took 269 ms on the UI isolate, and 662 ms in the background with 11 frames at most 134 ms apart.

### 7.2 Cold start

| Gates | Renderer | Release cold start (median of 10) |
|---|---|---|
| W1 to W5 (42862715744 … 43228855243) | Skia | 755 to 1372 ms |
| 43238952262 (W6, Impeller's run) | Impeller | 1688 ms |
| 43247963954 / 43256861510 / 43270594252 (W6) | Impeller, then the same build on Skia | 1388 / 1403 / 1527 ms; Skia 1067 / 961 / 1061 ms |
| 43284276984 (exit) | Impeller, then Skia | 1302 ms (1232 to 1406); Skia 992 ms; Impeller again 1338 ms |

The two renderers run the same app code, which awaits only the preferences before its first frame (G5). The 0.31 to 0.47 s between them in the same run is the renderer starting on the emulator's software GPU (SwiftShader), where Impeller runs its OpenGLES backend. On a phone, Impeller has a real GPU; the exit session times it (§8).

### 7.3 Memory, outside changes and the editor

- **Release memory with a 1 MiB file restored** (app and WebView renderers, PSS): 221.6 to 233.8 MB across Phase 3's gates (231.0 MB in the exit gate), against ADR-0004's 250 MB; 224.6 MB at Phase 2's exit.
- **Outside changes:** reloads 470 to 997 ms after the write (G4: within 2 s), caught up 140 to 822 ms after coming back.
- **The editor benchmark,** where the driver reached the engine: CodeMirror's input p95 50.6 to 79.8 ms and memory 518.4 to 527 MB in W6's gates, within the range of the gates before (frame-timed figures are judged on a phone, PHASE_2_REPORT §7.1). In the exit gate: 49.6 ms and 527.5 MB, composition 9 of 9; Monaco 68.4 ms and 597.5 MB.

## 8. The exit phone session

**Decided at acceptance (2026-11-12):** the owner runs the session after the next slice of work. If that slice changes the app, the checklist will name the newer phase-gate build; Phase 3's final build (artifact 13975424637) stays downloadable until 2026-12-12. **2026-11-13:** Phase 4 W1 moved the app to Flutter 3.50.0, so the checklist names its build: phase gate 43384226759, [artifact 14018654763](https://github.com/Skill-center/CodeForge-/actions/runs/43384226759/artifacts/14018654763), kept until 2026-12-13.

The owner chose one session at Phase 3's exit for every check parked since Phase 1 (2026-11-11). [PHASE_3_PHONE_CHECKLIST.md](PHASE_3_PHONE_CHECKLIST.md) has all of them, on the profile APK of the exit gate, in about 75 minutes: Impeller and frame timing, folders on the owner's phone (picker, outside changes, restart, reconnect), large files with the policy and the save pause, the keyboard (Gboard) matrix, the selection matrix, TalkBack over Phases 1–3's chrome, cold start and memory with adb (optional), and backup with a Google account.

| Check | From | Result |
|---|---|---|
| Impeller on hardware, and frame timing | Phase 3 W6 (Phase 1 G6 done on Skia: 3.4 %) | not run yet |
| Folder picker and a folder workspace, reconnect | Phase 3 W2, W3 | not run yet |
| Large files with the policy; the save pause | Phase 2 W7, ADR-0004, ADR-0008 | not run yet |
| Gboard matrix (swipe, voice, CJK, emoji) | Phase 2 G1 | not run yet |
| Selection matrix | Phase 2 W6 | not run yet |
| TalkBack spot-check (16 items) | Phases 1–3 | not run yet |
| Cold start (G7) and memory, with adb | Phase 3 W6, ADR-0004 | not run yet |
| Backup with a Google account | Phase 3 W1, ADR-0012 | not run yet |
| FULL against NORMAL (ADR-0008) | Phase 2 W7 | moved to Phase 4's Firebase Test Lab (owner decision 2026-11-12) |

## 9. Deviations and known limitations

### 9.1 Deviations from the plan (documented as built)

- **G7's cold start is not reliably met on the emulator** with Impeller: two of five gates over the budget, the exit gate within it (§7.2). The owner decided at acceptance that the exit session's phone figure decides (§1).
- **The benchmark driver.** The owner's item was a reconnect "so that every gate has complete figures". The reconnect is built and tested (7 vitest tests), but no Phase 3 gate has dropped an open session, so it has not met a real drop. What did cost figures was different: in gates 43222339848 and 43247963954 the driver never reached one engine's page, and the first fix (f9a4b43) polled another app's frozen DevTools socket so often that adb stalled for half an hour. Since 1680e1d the driver limits every call and forwards only to the app's own socket. Gate 43270594252 drove both engines without a stall, and so did the exit gate, 43284276984.
- **No intermediate "next" after W6:** the owner let the agent continue into W7 (§1).
- **One phase gate per work package** stayed the rule, but W6 needed four: Impeller's run, the measurements, and two driver fixes. W7 cancelled one (43281243239) that a later commit superseded.

### 9.2 Known limitations, carried forward

| Item | Impact | Where it goes |
|---|---|---|
| Saves to folders from shared storage are not atomic (the broker writes in place) | an interrupted save may leave the file incomplete; the document stays unsaved, its text in the journal | planned limitation (PHASE_3_PLAN §8) |
| Watching covers what the user can see (64 folders at most), plus stamp checks | a change deep in a collapsed folder shows when it is opened | planned limitation |
| Providers other than the device's shared storage are best effort | the rules hold, but only the device's own provider is gate-tested | planned limitation |
| Frame-timed numbers come from an emulator | judged on a phone | the exit session (§8) |
| `FolderWatches.kt` has no JVM test; services coverage 79.4 % | covered on the emulator only | Phase 4, if a fake provider can host a cursor's observer |
| Undo history doesn't survive a process death; the unsaved text does | accepted 2026-11-11 | revisit if it becomes a problem |
| The status strip shows a fixed branch chip, `main`, until Git arrives | its tooltip says so | Phase 7 |
| Flutter 3.50.0 needs AGP 9.1.1 and KGP 2.4.10 | the app stayed on 3.47.9 through Phase 3 | **decided 2026-11-12:** upgraded together after acceptance (§1, decision 4) |
| Other text encodings, search across files, copying between projects and folders | refused, Phase 4, decided with the runtime | ROADMAP; PHASE_3_PLAN §8 |

### 9.3 Gate history

- **Durations:** 33 to 46 minutes of the 75-minute limit, except 43256861510 (71 minutes, the adb stall). The exit gate took 38.
- **Retries:** a group runs again only after an infrastructure failure. In Phase 3 that happened to `keys` (the first attempts of W1's and W2's gates, and W3's first gate, 43069846571, before W3's fix) and to CodeMirror's benchmark in 43256861510 (the adb stall).
- **ANRs:** Google Play services processes sometimes fail to finish starting on the emulator (2 in 43238952262, 1 in 43270594252, 3 in the exit gate); none has been CodeForge's, and no gate has recorded a crash.

## 10. Next-phase readiness (Phase 4 — Runtime integration)

- **Owner actions before Phase 4** (ROADMAP's decision queue): the licence direction (ADR-0011), by Phase 4's start; a free Firebase project and one CI credential for Test Lab (ADR-0009), which the owner adds after the next slice; t1's PR #81 merged.
- **Carried in:** search across files with the runtime (ripgrep in projects, a scan in folders); how a folder reaches the runtime (a copy into a project, or import and export); minSdk 26 verified on API 26–28 emulators; FULL against NORMAL on Test Lab's phones. Phase 4 starts on Flutter 3.50.0.
- **Ready:** the storage model's two workspace kinds exist (RUNTIME_INTEGRATION §4); the Kotlin host has its first real surface, a typed Pigeon API and JVM tests in CI; the emulator gate has a host-side driver for Android's own UI.
