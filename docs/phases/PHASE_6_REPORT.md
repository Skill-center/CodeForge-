# Phase 6 Report — Language Intelligence

**Status:** **Built, for the owner's acceptance** (2026-11-23): all seven gates are met (§4), and the exit gate runs on this report's commit (§4, *The exit gate*). The phone session (§8) and the owner's release and Play actions (§10) are still open, and non-blocking · **Date:** 2026-11-23 · **Branch:** `arena/f57c33ee-codeforge`
**Plan:** [PHASE_6_PLAN.md](PHASE_6_PLAN.md) · **Spec:** §8 Phase 6, §6.5 (the capability model), §6.6 (never a broken editor), §9 · **Rule:** every claim below cites a CI run, a phase gate or an evidence commit. Where something was not measured or not met, this report says so.

---

## 1. Summary

Phase 6 gives CodeForge language intelligence, offline, on the sealed runtime Phase 4 put in the app:
- **Two language servers inside the app.** Pyright 1.1.414 for Python, and typescript-language-server 6.1.0 with TypeScript 6.0.3 for JavaScript and TypeScript. Both passed a smoke suite on API 26 to 36 and on a Pixel 8a before anything was built on them (phase gate 44977463887; [ADR-0015](../adr/0015-language-servers.md)). They ship in the APK as archives built from npm packages pinned with their SHA-512, and install, verified file by file, the first time their language is needed (CI 44994907490; phase gate 44995822826). Nothing is downloaded at run time.
- **A host and a client.**
  - Kotlin's `LspHost` runs each server through CodeForge's launcher, in its own process group under the sessions' limits. It frames the server's messages, reads its memory, stops it first on low memory, and ends it with its whole tree (phase gate 45029118568).
  - Dart's `LanguageClient` speaks JSON-RPC to it (CI 45065692542): timeouts and cancellation, incremental sync from the editor's change sets, restarts with a backoff and a cap, the idle stop, and since W7 a watch for a silent server (CI 45204541929).
- **In the editor** (CI 45131313756; phase gate 45135282059):
  - completion as you type, with the document's own words while no server can answer;
  - problems underlined and listed in a *Problems* sheet;
  - go to definition, with a server's own files read-only;
  - rename across files, all or nothing, with one undo per open file;
  - hover on a long press;
  - all of it for folders from shared storage too, through their copy.
- **Within its budgets on a phone.** On Test Lab's Pixel 8a with Android 14, in a profile build, in the real app on 200-file projects (phase gate 45182761593):
  - completion lists drawn **139.0 ms** (Pyright) and **64.5 ms** (TypeScript) after they were asked for, at the 95th percentile (budget 300 ms);
  - problems shown **476.9** and **657.7 ms** after a save, at the 95th percentile (budget 1 s);
  - each server's process tree at **169.9** and **246.5 MB** of PSS (budget 300 MB each, the owner's decision).
- **Never a broken editor.** A server that crashes, breaks the protocol or goes silent restarts with its documents. At its fourth end within five minutes the status strip offers *Restart*, while editing and word completion go on (phase gate 45135282059's `lsp` group; the silence since W7, CI 45204541929).
- **Reviewed:** SECURITY §2.3, threats L1 to L12, each with its mitigation built and its proof running.
- **Real targets:** every phase gate ran emulators with Android 8.0, 8.1, 9, 14 and 16, and Test Lab's physical Pixel 8a in the same run.

**All seven gates are met** (§4). Not met, and why:
- **PERFORMANCE's 600 MB for the editor, a terminal and one language server.** A server alone takes 169.9 or 246.5 MB of PSS, and the app with the editor and its renderer 511.4 MB (phase gate 45182761593). The owner decided on 2026-11-22 to give each server a budget of its own, judged in W6, and to record the total: 927.7 MB with both servers. The exit gate records it with a terminal open too (§7.1).
- **No phone checks by a person yet** (§8): Gboard against the completion list, the long press, a rename and the Problems sheet by hand. The phone's budget test never focused the editor, so no input method took part.
- **No binary release yet** (ADR-0010). It waits for the owner's keys and the licence review, which the servers' notices join.
- **The last pass found two promises the plan made and no work package had kept** (§9.1). §9's risk table promised that a server answering nothing for 30 s would be restarted, which W4's per-request timeouts did not do. Objective 3 promised memory measured with the editor and a terminal open, which W6 measured without the terminal. W7 built both.

## 2. Evidence index

| Work package | Done | CI runs | Phase gates | Test Lab |
|---|---|---|---|---|
| The plan | 2026-11-21 | 44943017667 (`ea82568`) | — | — |
| W1 The compatibility spike | 2026-11-22 | 44976282000; 44981999845 (the docs) | **44977463887** ✓ | in the gate: Pixel 8a, 36 of 36 |
| W2 The servers in the payload | 2026-11-22 | 44994907490 (`+1093`); 44999844945 (the docs) | **44995822826** ✓ | in the gate: 39 of 39 |
| W3 The host | 2026-11-22 | 45016628119 ✗, 45017913412 ✗, 45018943282, 45020136733 (`+1093`, 225 Kotlin tests), 45027761446; 45034648615 (the docs) | 45021556836 ✗, **45029118568** ✓ | in the gate: 40 of 40 (and passed in the first) |
| W4 The client | 2026-11-22 | 45063872382 ✗, 45065692542 (`+1179`); 45101263354 (the docs) | **45067383709** ✓ (its emulator job run again) | in the gate: 41 of 41 |
| W5 The language features | 2026-11-23 | 45115097753 ✗, 45131313756 (`+1281`), 45133675713; 45142647447 (the docs) | **45135282059** ✓ | in the gate: 41 of 41 |
| W6 The language gate | 2026-11-23 | 45180564110 (`+1286`); 45193031036 (the docs) | **45182761593** ✓ | in the gate: 42 of 42 |
| W7 The docs and the phase exit | 2026-11-23 | 45204541929 (`+1291`; the code: the silent server, the total with a terminal) | the exit gate (§4) | in the exit gate |

Every ✗ is explained in §9.3. A `[phase-gate]` push gives one run whose verdict covers CI, the emulator, the five runtime legs and, with `[testlab]`, the Pixel 8a. The gates' evidence is committed back to `app/ci-results/gate/` and `app/ci-results/runtime-gates/`, Test Lab's to `app/ci-results/testlab/`, and the runtime job's to `runtime/ci-results/`. Test Lab's plan allows five physical-device tests a day, and Firebase counts the day from midnight Pacific time (08:00 UTC).

## 3. What was built

- **The spike (W1):** `LanguageServerTest`, the smoke suite under the sealed runtime's node; the candidates' pins with the registry's SHA-512 (`app/tool/ci/language_servers.json`, retired in W2); ADR-0015 with the numbers.
- **The servers in the payload (W2):**
  - `runtime/language-servers/`: `package.json`, npm's lockfile and `bundled.json`, which pins the 58 packages bundled inside the servers' JavaScript from their source maps.
  - `runtime/language_servers.py` (`check`, `fetch`, `build`, `notices`, `lock`): exact versions with SHA-512, a licence allowlist, no install script that ships, native code and links refused, reproducible archives with manifests.
  - `LanguageServers.kt`, the installer, verifying every file and allowing no other; THIRD_PARTY_NOTICES §6 and the app's licence page, written and checked by CI.
- **The host (W3; Kotlin):** `runtime/LspHost.kt` (`LanguageServerProcess`, a third session kind, the limits, memory every 10 s, low-memory stops), `runtime/LspFraming.kt` (`LspFrameReader`), `lsp/LanguageServerHost.kt`, and the Pigeon API `pigeons/lsp_api.dart` (`LspApi`, `LspEvents`).
- **The client (W4; Dart):**
  - `LspService` in `services/contracts.dart`, with its Pigeon client and an honest fake;
  - `application/lsp/`: `lsp_connection.dart` (JSON-RPC 2.0), `language_client.dart` (the session, the documents, the restarts, the idle stop), `lsp_controller.dart` (the workspace's servers) and `lsp_clock.dart`;
  - `core/lsp/`: text sync, URIs, globs and models;
  - the status strip's server chip, and *analyzable* in the capability model.
- **The language features (W5):**
  - **The protocol:** `diag.set`, `doc.applyEdits`, `lsp.complete`, `lsp.resolve`, `lsp.hover`, `lsp.definition`, `lsp.prepareRename` and `lsp.cancel`, with 31 shared fixtures and checked results on both sides.
  - **The page:** `editor/src/editor/lsp.ts`, `requests.ts` and `markdown.ts`: completion, the lint layer (`@codemirror/lint` 6.9.8), the symbol menu, F12, F2 and F8.
  - **The host:** `lsp_features.dart` and `rename.dart`; `core/lsp/lsp_answers.dart` and `workspace_edit.dart`.
  - **The screens:** the problems chip, the *Problems* sheet, the rename dialog, the read-only sheet for a server's own files, Settings → Editor's servers, and the servers in Settings → Linux runtime.
  - **The gate:** the emulator's `lsp` group (`integration_test/lsp_test.dart`).
- **The language gate (W6):** the page's completion timings (`timings.ts`) and `probe.read`; `integration_test/phone_lsp_test.dart` on Test Lab's phone, judged by `gate_results.py --require`, and recorded in the `lsp` group.
- **W7:**
  - **A silent server:** `LspConnection` watches a server's silence once it is asked something, and `LanguageClient` ends and restarts a server silent for 30 s unless it reports progress (`LspClientSettings.hangTimeout`).
  - **The total with a terminal open:** `phone_lsp_test.dart`'s last step records it.
  - **The documents:** LSP_ARCHITECTURE as built, ADR-0015's *As built (W6)* and *(W7)*, SECURITY §2.3 (L1 to L12), ARCHITECTURE §2.12, this report and [PHASE_6_PHONE_CHECKLIST.md](PHASE_6_PHONE_CHECKLIST.md).
- **CI** (BUILD_AND_RELEASE §2.6): the runtime job's *Language servers* step; the archives in every payload build; `LanguageServerTest` and `LanguageServerInstallTest` on every runtime leg and the phone; the `lsp` group; the language budgets on Test Lab.

## 4. Gate by gate

| Gate | Result | Evidence |
|---|---|---|
| **G1 Compatibility** | **Met.** Both servers passed the smoke suite on API 26, 27, 28, 34 and 36 and on the Pixel 8a: `initialize`, the error in the diagnostics, completion (cold, repeated and after an edit), definition and rename across two files, the error fixed and gone, `shutdown` and `exit` with nothing of the group left; then the same, apart from definition, rename and the fix, on 200 files. On the phone, completion after an edit took 43 to 93 ms at p95, first diagnostics 1.21 to 2.77 s, and a server 167.1 to 255.2 MB of PSS. ADR-0015 records the choice with the numbers | phase gate 44977463887 (Test Lab 36 of 36 in the same run); ADR-0015 |
| **G2 Payload** | **Met.** 61 tarballs pinned with SHA-512, checked on every push: exact versions, the licence allowlist, no install script that ships, no native file, no link. One archive and manifest per server, reproducible: Pyright 6.06 MB (5,423 files), the TypeScript server 5.15 MB (145). Installed when first asked for, every file verified: Pyright in 0.83 to 2.48 s on the emulators and 3.65 s on the 8a, reused in 0 to 5 ms. An archive with one byte changed was refused as `damaged` on every target, leaving nothing. THIRD_PARTY_NOTICES §6 lists all 61 package versions. The base module was 158.3 MB, 79.2 % of Play's 200 MB | CI 44994907490; phase gate 44995822826 (Test Lab 39 of 39) |
| **G3 Host** | **Met.** `LspFramingTest` (11) and `LspHostTest` (12, then 15) pass on the JVM with the real launcher and a misbehaving stub server. On every target a second Pyright was refused as `already_running`, and SIGKILL to the server's node was reported as `signaled` with signal 9 within 3 to 7 ms on the emulators and 226 ms on the phone, with nothing of its group left. `LanguageServerTest`'s smoke cases passed through the host on every target | CI 45020136733; phase gate 45029118568 (Test Lab 40 of 40) |
| **G4 Client** | **Met.** 86 new Dart tests against the scripted host on a clock moved by hand: the handshake (UTF-16, one workspace folder), versions in order, change sets to ranges, cancellation and timeouts, the server's own requests, the restart backoff (1, 2, 4 s) and its cap, the idle stop, and each request's stages. On the phone the heap cap made no difference to Pyright's completion (p95 82.2 to 85.0 ms with and without it), so it stays | CI 45065692542 (`+1179`); phase gate 45067383709 (Test Lab 41 of 41) |
| **G5 Editor** | **Met.** In the real app on the emulator (the `lsp` group, 43 s): Pyright's error listed and underlined, then cleared in 476 ms by a fix not yet saved; completion through the page (`greet` taken); hover; a definition into another file; a rename across three files through the dialog, with one undo per open document; TypeScript's errors and completion; Pyright killed with SIGKILL back with its documents in 2,318 ms; *Restart* offered after three restarts, the editor still editing with word completion; a folder analysed through its copy. 102 new Dart tests and 67 new vitest tests | CI 45131313756 (`+1281`); phase gate 45135282059 (Test Lab 41 of 41) |
| **G6 Language budgets** | **Met, with the memory budget the owner decided.** On the Pixel 8a, in the app on the 200-file projects: completion p95 139.0 ms (Pyright) and 64.5 ms (TypeScript), within 300 ms; diagnostics after a save p95 476.9 and 657.7 ms, within 1 s; PSS 169.9 and 246.5 MB, within 300 MB each. Every list drawn (`undrawn=0`). The total recorded: 927.7 MB with both servers. On the emulator the same figures recorded, never judged (§7.1) | CI 45180564110 (`+1286`); phase gate 45182761593 (Test Lab 42 of 42: six `lsp_phone_*_under_budget=1`) |
| **G7 Docs** | **Met.** LSP_ARCHITECTURE as built, ADR-0015's *As built* through W7, SECURITY §2.3 with L1 to L12, and the docs PHASE_6_PLAN §7 lists synced. This report and [PHASE_6_PHONE_CHECKLIST.md](PHASE_6_PHONE_CHECKLIST.md) are written | PHASE_6_PLAN *As built (W7)*; CI 45204541929 for W7's code |

**The exit gate** runs on this report's commit: an empty `[phase-gate] [testlab]` commit once its plain CI has passed, as Phase 5's did. Its result, its evidence commits and the phone's figures with a terminal open go here and in §7, with the artifact for the phone checklist in §6.

## 5. Tests

| Suite | Count at Phase 6's end | Where |
|---|---|---|
| Flutter unit, widget, golden, accessibility | `+1291: All tests passed!` (`+1090` at Phase 5's end): W2 3 more, W4 86, W5 102, W6 5, W7 5 | CI 45204541929 (`app/ci-results/test.txt`); analyze clean, and `dart format` changed none of 350 files |
| Kotlin (JVM) | 228, none skipped (188 at Phase 5's end): `LanguageServersTest` 14, `LspFramingTest` 11, `LspHostTest` 15 | CI 45204541929 (`kotlin-tests.txt`), as in every run since CI 45065692542 |
| The sealed kernel (JVM) | 23 | every CI run (`sealed-runtime-tests.txt`) |
| The pages (vitest) | 448 (373 at Phase 5's end): `lsp.test.ts` 36, and the protocol's fixtures | CI 45204541929's editor job (`app/ci-results/editor/`) |
| `runtime/tests/` | 9 files, 164 cases (`script_test_files=9 cases=164 failed_files=0`; 8 files and 142 at Phase 5's end): `test-language-servers.py` 22 | the runtime job, every push (`runtime/ci-results/script-tests.txt`) |
| CI tool self-tests | `check_runtime_apk.py` 3 more cases (the servers' archives); W1's `fetch_language_servers.py` (15) until W2 | every push |
| Instrumented (`androidTest/`) | 42 (32 at Phase 5's end): `LanguageServerTest` 6, `LanguageServerInstallTest` 3, `SyncModesTest` 5 (4 before W6), and Phase 5's. The runtime legs run all but `SyncModesTest`: 37 each | phase gate 45182761593: 37 of 37 on each runtime leg, 42 of 42 on the Pixel 8a |
| Integration (`integration_test/`) | the earlier groups, plus `lsp` (W5) and `phone_lsp` (W6; the gate's `lsp` group and Test Lab) | every phase gate, and Test Lab |

TESTING.md §1.6 describes each Phase 6 suite.

## 6. Build artifacts

- **Every CI run:** `codeforge-debug-apk` (every ABI, no runtime; 85,069,700 B in CI 45204541929), kept 90 days. The release x86_64 APK with its runtime and the servers is built and checked, but not uploaded.
- **Every phase gate:** `codeforge-phone-profile-arm64`, the phone build: profile mode, arm64, with the runtime and the servers (176,142,351 B in phase gate 45182761593). **For the owner's phone checks:** the exit gate's artifact, whose link goes here once the gate has run.
- **No release:** nothing is published before the owner's keys exist and the licence review is done (ADR-0010; §10).

## 7. Performance

### 7.1 The language budgets (W6)

| Measure | Pixel 8a, judged (gate 45182761593) | Emulator, recorded (the same gate; debug, API 36) | Budget |
|---|---|---|---|
| Completion after an edit, from the page's request to the list drawn: p95 (p50; slowest) | Pyright **139.0 ms** (69.7; 161.0); TypeScript **64.5 ms** (45.8; 72.5) | 162.3 ms; 144.1 ms | p95 ≤ 300 ms |
| Of which, the request to the host's answer: p95 | 116.0 ms; 48.1 ms | — | — |
| Diagnostics after a save: p95 (p50; slowest) | Pyright **476.9 ms** (405.2; 490.4); TypeScript **657.7 ms** (542.2; 658.9) | 325.4 ms; 418.7 ms | p95 ≤ 1 s |
| Each server's process tree: PSS (RSS), processes | Pyright **169.9 MB** (197.9), 2; TypeScript **246.5 MB** (299.6), 3 | 168.5 MB; 232.6 MB | ≤ 300 MB of PSS each (the owner's decision) |
| Running, then the first error listed, after the file opened | 1,554 ms, then 2,608 ms; 915 ms, then 2,318 ms | — | recorded |
| The app with the editor, and its renderer | 428.3 + 83.1 = 511.4 MB | 424.9 + 114.1 = 539.0 MB | recorded (§2's own budgets) |
| With both servers | **927.7 MB** | 940.2 MB | recorded |

Pyright's lists held 26 items (the median) and TypeScript's 3. Every list was drawn, and no frame was waited for in vain (`undrawn=0`, `throttled=0`). The saves themselves took 29.1 ms (Pyright's file) and 28.3 ms (TypeScript's) at p50. PERFORMANCE §4 and PHASE_6_PLAN *As built (W6)* have the method: the page times each list to the end of the frame that draws it, and each save to the page's taking the new set with the expected count. **With a terminal open,** W7's step of the same test records the total in the exit gate (§4).

### 7.2 The servers through the runtime suite (`LanguageServerTest`, recorded)

Completion after an edit, p95, on two files and on 200, and PSS after the suite, on Test Lab's Pixel 8a:

| Gate | Pyright | TypeScript | PSS |
|---|---|---|---|
| W1, the test's own client (44977463887) | 43 / 56 ms | 93 / 60 ms | 167.1 to 255.2 MB |
| W2, the servers from the payload (44995822826) | 62.4 / 58.0 ms | 57.3 / 59.3 ms | 167.5 to 257.0 MB |
| W3, through `LspHost` (45029118568) | 83.3 / 111.9 ms | 33.9 / 59.3 ms | 165.2 to 254.8 MB |
| W4 (45067383709) | 85.4 / 95.4 ms | 79.6 / 45.1 ms | 165.8 to 257.6 MB |
| W5 (45135282059) | 89.1 / 97.7 ms | 74.3 / 78.5 ms | 163.2 to 255.0 MB |
| W6 (45182761593) | 88.5 / 118.3 ms | 78.9 / 69.8 ms | 162.5 to 257.7 MB |

- **Pyright got slower between W2 and W3,** for a reason never found. W4 ruled out the heap cap on the phone: its totals were the same with and without it. The server's own work took 31 to 34 ms at p50, the host's queue about 3 ms and the delivery 0.6 ms. All of it is within the budget.
- **First diagnostics on the legs (API 26 to 36) in W6:** Pyright 622 to 970 ms, TypeScript 1,086 to 1,970 ms. On the phone: Pyright 1,301 and 1,579 ms, TypeScript 2,326 and 2,686 ms.

### 7.3 The emulator's `lsp` group

| | W5 (gate 45135282059) | W6 (gate 45182761593) |
|---|---|---|
| Pyright's first error listed, after the files were written (its first install included) | 3,080 ms | 4,705 ms |
| Cleared after the fix, not saved | 476 ms | 446 ms |
| A SIGKILLed Pyright back with its documents | 2,318 ms | 2,729 ms |

### 7.4 Sizes

- **The servers' archives:** Pyright 6.06 MB (5,423 files), the TypeScript server 5.15 MB (145 files).
- **The release APK (x86_64):** 161,699,500 B (CI 45204541929), from 150,023,619 B at Phase 5's exit; 161,533,268 B after W2.
- **Per device on Play (arm64):** a 158.5 MB base module, 79.2 % of Play's 200 MB (the bundle-size evidence `134fd8f8`, the same since), from 148.0 MB at Phase 5's exit; 158.3 MB after W2.
- **The editor page:** 309.6 KiB gzipped, within its 1.5 MiB budget (285.2 KiB at its last record before W5, `af5ea8ef`); the terminal page 211.6 KiB.

### 7.5 Cold start (release build, emulator, median of 10; budget 1,500 ms)

Phase 5's exit gate: 1,130 ms. Phase 6: W1 1,169 ms; W2 873 ms; W3 1,094 ms; W4 1,302 ms (recorded only, in the job run again after the black screen at boot); W5 886 ms; W6 1,030 ms (Skia 1,015). The servers start with the first file of their language, never with the app, so they add nothing to it.

## 8. The phone checks

- **[PHASE_6_PHONE_CHECKLIST.md](PHASE_6_PHONE_CHECKLIST.md)** (W7), about 20 minutes:
  - a server's first start on the phone;
  - completion with Gboard: its suggestions, its Enter and a swipe while the list is open;
  - the long press for hover and definition, a server's own files read-only;
  - a rename across files, with undo;
  - the Problems sheet.
- **[PHASE_5_PHONE_CHECKLIST.md](PHASE_5_PHONE_CHECKLIST.md)**, **[PHASE_4_PHONE_CHECKLIST.md](PHASE_4_PHONE_CHECKLIST.md)** and **[PHASE_3_PHONE_CHECKLIST.md](PHASE_3_PHONE_CHECKLIST.md)** are still open. They can use Phase 6's exit gate APK, which has everything theirs has.
- All four are non-blocking for acceptance unless the owner decides otherwise. Results go here.

| Run | Date | Phone | Build | Result |
|---|---|---|---|---|
| — | — | — | — | not run yet |

## 9. Deviations and known limitations

### 9.1 Deviations from the plan (documented as built)

- **W1:** completion was timed both repeated (the servers cache the answer) and after an edit, as typing does; W6 judged the second.
- **W2:**
  - **No npm in the build:** `language_servers.py` reads the lockfile, downloads each tarball and checks its SHA-512, so an APK build needs only Python. npm only re-pins (`[repin]`).
  - **The bundled packages weren't planned:** Pyright and typescript-language-server bundle 58 npm packages into their JavaScript without their licence texts. `bundled.json` pins them from the source maps, and their tarballs give the texts. Two, `@yarnpkg/fslib` 2.10.4 and `@yarnpkg/libzip` 2.3.0 (BSD-2-Clause), ship no licence file; THIRD_PARTY_NOTICES names them for the licence review.
  - What asks for a server and shows its progress moved to W3 and W4.
- **W3:**
  - The 10-minute idle stop moved to W4's Dart, which knows the open documents.
  - One server per server id, not per language: the same today, with one server per language.
- **W4:**
  - The host's Pigeon API grew: a start names the workspace's folder as the server sees it, and the stages of a request's time need the host's timestamps.
  - Folders waited for W5. `didChangeWatchedFiles` comes from comparing listings, since Phase 3's watcher reports folders.
  - Servers are off in the integration tests, so the other groups' figures stay comparable; the `lsp` group and `phone_lsp_test` turn them on.
- **W5:**
  - The `lsp` group came with W5, as G5's evidence.
  - **"Three crashes":** the backoff restarts a server three times within five minutes and gives up at its fourth end, with *Restart* offered.
  - Read-only definitions open in a sheet, not a tab. A rename's closed files are not undone by the editor's undo: the summary names them. `doc.applyEdits` carries every open document in one message.
- **W6:**
  - Diagnostics are judged at the 95th percentile, as completion is.
  - One project holds both languages, so both servers ran side by side.
  - The emulator's figures come from a second run in the `lsp` group, never judged.
  - **No input method took part:** the test does not focus the editor. Gboard with the list is the phone checklist's first check.
- **W7:**
  - **A silent server.** §9's risk table promised that a server answering nothing for 30 s while requests wait would be restarted, counted against the backoff. W4 built a timeout per request and cancellation, but nothing that restarted a server that stayed silent. W7 built it, with three refinements: any message the server writes counts as speaking, so a server that logs but never answers is not restarted (its requests time out one by one); a server reporting progress is busy, not hung, so a long first analysis is not cut short; and a request given up still counts, since a server must answer even those.
  - **The memory with a terminal open.** Objective 3 asked for memory measured with the editor and a terminal open. W6 measured the editor and both servers. W7's step of the phone test opens a terminal after the budgets and records the total, never judged; the exit gate measures it.

### 9.2 Known limitations, carried forward

- **No binary release** until the owner's keys exist and a qualified person has reviewed THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md, now with the servers' 61 package versions.
- **Memory:** with both servers the app and its renderer held 927.7 MB of PSS on the Pixel 8a (§7.1), against PERFORMANCE's 600 MB for the editor, a terminal and one server. The owner's budget per server holds, and servers are the first thing stopped on Android's low-memory warning; a phone with 4 GB will stop them more often. Only one phone has measured it.
- **What the servers do:** completion, diagnostics, definition, rename and hover. No signature help, code actions, formatting, references, semantic tokens, inlay hints or workspace-wide diagnostics. Pyright analyses open files only.
- **What the servers see:**
  - A JavaScript project gets node's types only with `@types/node` in it, and Python sees the packages pip installed into the runtime.
  - JavaScript files get TypeScript's syntax errors, not its type errors, unless a file starts with `// @ts-check` or a `jsconfig.json` turns on `checkJs`: CodeForge gives the TypeScript server no settings, and typescript-language-server 6.1.0's default for a file outside a project is `checkJs: false`. TypeScript files are checked in full.
- **TypeScript 7 is not used:** its native server has no Android build (ROADMAP's queue).
- **Servers end with the app,** and start again with the next file of their language. At most two run.
- **A file rewritten at the same size outside the app** is missed by `didChangeWatchedFiles` unless it is open.
- **Firebase Test Lab shuts down on 2027-09-30.** What runs the arm64 tests after it is in ROADMAP's decision queue. Physical-phone figures come from one Pixel 8a; the owner's phone adds a second (§8).

### 9.3 Gate history

- **W3:**
  - CI 45016628119: W3's new tests did not compile, and the *Kotlin digest* showed no compiler errors; it lists them since (BUILD_AND_RELEASE §2.6).
  - CI 45017913412: `LspHostTest` caught `send` and `stop` answering `no_such_server` on success, a Kotlin elvis taking the success's null for a missing server; CI 45018943282 has the fix.
  - Gate 45021556836: W3 had added the stopped servers to the memory-pressure line in which the emulator gate counts the terminals' trimmed buffers, so the sessions group found no count and failed. The line is as it was again, and the servers have a line of their own (45027761446). That gate's runtime legs and Test Lab had passed.
- **W4:**
  - CI 45063872382: a test's missing import, and a widget test that had not counted the TypeScript server the demo's `main.js` starts.
  - Gate 45067383709: the emulator job's first attempt met a black screen at boot (System UI's keyguard hung 20 s), so the keys group's first tap failed. That job alone was run again, and passed.
- **W5:** CI 45115097753 failed five tests and one warning:
  - the host's tests counted the new `PageSynced`;
  - the rename test expected file changes for a server that had not asked for them;
  - a two-taps test met a settings row that was no longer built;
  - Settings → Editor did not stop a server at once, because Riverpod 3 pauses a provider nobody listens to;
  - the workspace switch had an unreachable default.

## 10. Next-phase readiness (Phase 7 — Git & source control), and the owner's decisions

**Ready for Phase 7:**
- Git 2.56.1 is in the runtime, and `RuntimeCommandsTest` checks it against its pin on API 26 to 36 and the Pixel 8a at every phase gate;
- the launcher runs one-shot commands, streamed commands (search), terminal sessions and, since Phase 6, long-lived processes on pipes, each ended with its whole tree under measured limits;
- the editor protocol takes new types with shared fixtures, as Phase 6's nine did, for a diff view;
- a project's files, a folder through its copy, and the watcher's changes are what a repository's status needs;
- the credential store is Phase 7's (ARCHITECTURE §4): no credential exists in the app yet, and the runtime's environment carries none.

**For the owner:**
1. **Accept Phase 6,** or ask for changes.
2. **The phone session:** PHASE_6_PHONE_CHECKLIST (about 20 minutes) with the Phase 3, 4 and 5 checklists, on the exit gate's APK (§6).
3. **The first release** (BUILD_AND_RELEASE §5):
   - the upload key and the release key, as eight repository secrets;
   - whether Play's app signing key is the release key;
   - the licence review, which now covers the servers' notices and the two bundled packages without licence files.

   Then the agent adds the tag trigger, and a `v<version>` tag makes a draft GitHub Release.
4. **Play** ([docs/store/README.md](../store/README.md)), as at Phase 5's end:
   - the developer account, Play App Signing, 15 to 20 testers and a contact address;
   - the privacy policy's three placeholders;
   - the special-use declaration, drafted in listing.md;
   - Play's rule on downloaded executable code (PHASE_5_REPORT §9.2). The servers add nothing to it: they are JavaScript inside the APK.
5. **Later:** what runs the arm64 tests after Test Lab, before 2027-09-30; TypeScript 7's native server, when TypeScript 6 falls behind; more servers (JSON, HTML, CSS, YAML, shell, and clangd with the build-tools pack), each a phase's choice.

Phase 7's plan follows the acceptance.
