# Phase 2 Report — Workbench & Editor Engine

**Status:** **Built and CI-verified, awaiting owner acceptance** · **Date:** 2026-11-10 · **Branch:** `arena/f57c33ee-codeforge`
**Plan:** [PHASE_2_PLAN.md](PHASE_2_PLAN.md) · **Spec:** §8 Phase 2, §4.4, §6.1, §6.3 · **Rule:** every claim below cites a CI run or an evidence commit. Where something was not measured or not built, this report says so.

---

## 1. Summary

Phase 2 turns the Phase 1 shell into a working code editor. CodeMirror 6 runs in a locked-down Android System WebView and edits real UTF-8 files in an app-private workspace. Many files can be open at once, and each tab keeps its own cursor, scroll, selection and undo. Unsaved text survives the app being killed and a crash of the editor's renderer. Phase 2 adds find and replace, go to line, a symbol toolbar on the soft keyboard and hardware-keyboard shortcuts. A large-file policy was set from measurements. MVP 2, "a functional code editor that opens and edits real local source files", is met within the plan's scope decision: Phase 2's files are the app's own workspace folder, and opening folders elsewhere on the device is Phase 3.

| Gate | Result | Evidence (details in §4) |
|---|---|---|
| G1 Engine | ✅ engine decided: CodeMirror 6 · ◐ two budgets await the parked phone run | gate 42206498197 and the owner's phone run; ADR-0004 Accepted |
| G2 Files | ✅ met | file service tests on a real folder (CI 42238016497); byte-exact saves on the emulator (gate 42238016973) |
| G3 Tabs | ✅ met | 12 tabs with their own cursor, scroll, selection and undo; tabs reopen after a process death (gate 42238016973) |
| G4 Zero loss | ✅ met | the edit pair after a renderer crash and a force-stop, and rotation (gate 42386742421); journal property tests (CI 42386742434) |
| G5 Editing | ✅ met | vitest, widget tests and the editing group on the real page (gates 42437560830 and 42676631509) |
| G6 Keyboards | ✅ met | real touches and key chords on the emulator (gates 42517731718 and 42676631509) |
| G7 Large files | ✅ met | `large_files.json` at 1, 5 and 10 MiB without the policy (42616081317) and with it (42659207710, 42665305004, 42676631509) |
| G8 Quality | ✅ met | CI 42678576228: both jobs green, `+563: All tests passed!`, editor job 187/187 |
| G9 Docs | ✅ this commit | this report with run ids; the plan's §7 documents synced |

**The gates found real defects.** The emulator gate drives the real page in the real WebView, with input from outside the app. It found two defects that no host test could:
- **Commands sent while the page restarted** (W5, gate 42379885027). A command sent just after the page started, before the host had reopened the documents, reached a page with no active document. Document commands now wait for that replay.
- **Hardware Tab** (W6, gate 42491602659). Android hands every key to Flutter before the focused WebView. On a real keyboard, Tab would have moved Flutter's focus instead of indenting.

The new accessibility sweep in CI found a third (CI 42665305010): text fields 47 dp tall, under the 48 dp rule, because the theme made them dense. All three are fixed and covered by tests.

**Found while syncing the docs: Android Auto Backup.** SECURITY.md §4 said app data has "no cloud sync by default". That is not what Android does:
- The app's manifest sets neither `android:allowBackup` nor `android:dataExtractionRules`, so Android's default applies: Auto Backup is on.
- When the user has device backup turned on, Android uploads up to 25 MB of the app's files to the user's own Google Drive about once a day. It is end-to-end encrypted on Android 9 and later when the phone has a screen lock, and it is restored when the app is installed again ([Android: Auto Backup](https://developer.android.com/identity/data/autobackup)).
- It covers the folder behind `getFilesDir()`, so the workspace and `codeforge.sqlite` (which holds unsaved text), and the settings too.

No one else can read that copy, but the app never tells the user about it. SECURITY.md §4 now describes what happens. The fix is a small manifest change that needs its own CI and gate run, so it is a decision for you (below), not a W8 change.

**Also found in the review:** TalkBack doesn't hear which tab is active or which has unsaved changes. The tab strip shows both only visually, though the close prompt still asks before unsaved text is closed. A semantics fix with a widget test is proposed for Phase 3's first package (§9.2).

**Owner decisions during the phase:**
- **2026-11-06, at Phase 1's acceptance:** the phone checks were parked, so G1 was to run on the emulator. The owner then ran the benchmark on a realme C51 anyway, and took the low-end phone as G1's reference ("I use a low phone for tests it means app will work on every phone").
- **W1–W7:** each work package was reported and accepted with "next".
- **The W7 report (2026-11-09), accepted with "next":**
  - plain text above 512 KiB, and files over 10 MiB refused;
  - ADR-0008 keeps `synchronous = NORMAL`;
  - ADR-0004's large-file and memory carry-overs are answered on the emulator, and their phone runs stay parked.

**Decisions requested now:**
1. **Accept Phase 2.** Under the plan's definition of done, the parked phone checks (§8) don't block acceptance.
2. **Auto Backup:**
   - **Recommended:** opt out (`android:allowBackup="false"`, or extraction rules that exclude the workspace and the database) until Phase 10 designs explicit backup and export. It would ship in Phase 3's first package.
   - **Or:** keep backups on and tell the user in the app.
3. **Carry the on-disk log sink to Phase 3.** Phase 2 did not build it (§3).
4. **A way to run the parked large-file checks on the phone** (§8): a Developer action that writes the gate's large files into the workspace, and a plain-text pass in the benchmark. Proposed for Phase 3's first package.

## 2. Evidence index

All runs are on `Skill-center/CodeForge-`, branch `arena/f57c33ee-codeforge`. `[bootstrap]` runs commit their diagnostics back (`app/ci-results/*.txt`), and gate runs commit `app/ci-results/gate/`; see [BUILD_AND_RELEASE.md §2.1](../BUILD_AND_RELEASE.md). Test counts are quoted from the compact reporter's final line.

| Run | Workflow | Head commit | Result | What it proves |
|---|---|---|---|---|
| **42678576228** | CI `[bootstrap]` | `ea8ef61` (final app tree) | ✅ | **The final tree:**<br>• `00:56 +563: All tests passed!`<br>• analyze clean, and format left all 154 files unchanged<br>• the editor job's typecheck, 187 vitest tests in 15 files, licence gate, page build and page verification<br>• coverage 4736/5382 (88.0 %)<br>• debug APK and its SHA-256<br>Commit-backs: `06542e4`, goldens `dbd98af`, diagnostics `d90de11` |
| **42676631509** | Phase gate | `decd7ec` (`lib/`, `integration_test/`, `android/` and `editor/src/` identical to the final tree) | ✅ | **The final app on the KVM emulator:**<br>• all 11 groups passed on attempt 1: smoke, editor bridge, editing, keys, both engine benchmarks, large files, the restore pair and the edit pair<br>• release cold start median 906 ms<br>• a release build restoring a 1 MiB file took 224.6 MB<br>Evidence `440dcb5` |
| 42681804307 | CI | `303b854` | ✅ | the W7 documents commit; every gate green |
| 42665305004 | Phase gate | `ed3e50e` | ✅ | G8 code before the text-field fix: 11/11 on attempt 1; release memory with 1 MiB restored 227.6 MB; cold start 1307 ms — evidence `807675c` |
| 42659207677 | CI | `65fe2ca` | ✅ | the large-file policy: `+552: All tests passed!`, analyze clean, format 0 changed |
| 42659207710 | Phase gate | `65fe2ca` | ✅ (run attempt 2) | the policy on the emulator: 11/11 on attempt 1 of the tests. The 1 MiB `.js` file typed like the `.txt` file and had no long tasks after the open. Release memory 224.5 MB; cold start 995 ms — evidence `b303746` |
| 42616081306 | CI | `1da630f` | ✅ | `+539: All tests passed!`, coverage 87.7 % |
| 42616081317 | Phase gate | `1da630f` | ✅ | the large-file numbers without the policy, 11/11 — evidence `14838fd` |
| 42517731644 | CI `[bootstrap]` | `e45ea41` | ✅ | toolbar and keyboards: `+539: All tests passed!`, coverage 4656/5310 (87.7 %) |
| 42517731718 | Phase gate | `e45ea41` | ✅ | G6: the keys group (real taps, key chords through the emulator's keyboard device), 10/10 on attempt 1; cold start 976 ms — evidence `8c61195` |
| 42437560827 | CI `[bootstrap]` | `d4d2256` | ✅ | find, replace and go to line: `+512: All tests passed!`, coverage 87.8 % |
| 42437560830 | Phase gate | `d4d2256` | ✅ | G5: the editing group on the real page, 9/9 — evidence `970d248` |
| 42386742434 | CI `[bootstrap]` | `b6b799b` | ✅ | journal, database and process-death tests: `+477: All tests passed!`, coverage 4014/4627 (86.8 %) |
| 42388617576 | CI | `515f85a` | ✅ | `+478: All tests passed!`, adding the restore of unsaved changes to a file that became unreadable |
| 42386742421 | Phase gate | `b6b799b` | ✅ | G4: the edit pair (262 characters, cursor 44, dirty dot after a renderer crash and a force-stop; rotation without a page reload), 8/8 on attempt 1; cold start 1078 ms — evidence `6b2b9ba` |
| 42238016497 | CI | `744a149` | ✅ | files and tabs: `+431: All tests passed!`, `LocalFileService` on a real folder, coverage 3432/3999 (85.8 %) |
| 42238016973 | Phase gate | `744a149` | ✅ | G2, G3: byte-exact saves, 12 tabs, and the restore pair reopening tabs, 6/6 on attempt 1; cold start 1284 ms — evidence `b0d9132` |
| 42216855073 | CI `[bootstrap]` | `58d91fa` | ✅ | the selection fix from the phone run: `+370: All tests passed!` |
| 42216855184 | Phase gate | `58d91fa` | ✅ | the benchmark re-run kept CM6 ahead — evidence `607feea` |
| **42206498197** | Phase gate | `a86371b` | ✅ | **G1:** CM6 against Monaco on the emulator (`editor_bench.json`). Its profile arm64 APK was the owner's phone build — evidence `41247d0` |
| 42191259151 | CI `[bootstrap]` | `7d4f3cb` | ✅ | host and bridge: `+344: All tests passed!`, coverage 2312/2723 (84.9 %) — diagnostics `6c99461` |
| 42191259123 | Phase gate | `7d4f3cb` | ✅ | the real, verified page in the WebView (editor bridge test); cold start 1412 ms — evidence `4a9e484` |
| 42171281309 | CI `[bootstrap]` | `148c286` | ✅ | the editor page and the CI `editor` job: 98 vitest tests, page build and verification; the Flutter suite was unchanged at 236 tests — diagnostics `f4e2365` |

The documentation commits passed CI too: 42169268837 (the plan, `659ef3c`), 42389275130 (W5, `48011bd`), 42520373038 (W6, `d04ae2c`) and 42681804307 (W7).

Not every run passed:
- **Phase gate:** 33 runs, of which 13 passed, 19 failed and 1 was cancelled. This counts every run that started in Phase 2; runs skipped because the commit had no `[phase-gate]` are left out.
- **CI:** 48 runs, of which 38 passed, 9 failed and 1 was cancelled.

The causes are in §9.3. No number from a failed run is used in this report.

## 3. What was built

| Work package | Delivered | Not delivered / changed (see §9) |
|---|---|---|
| **W1 Editor workspace & protocol** | `editor/`: TypeScript 5.9.3, esbuild 0.28.2, vitest 5.1.0 and happy-dom 21.0.4, exact pins with `npm ci`, on Node 24. CodeMirror 6.43.15 with one `EditorState` per document; highlighting for JavaScript/JSX, TypeScript/TSX, Python, JSON, HTML, CSS and Markdown; batched incremental change sets. Protocol v1 with a validator for every message type, and JSON fixtures shared with Dart. One self-contained, reproducible HTML page with a hash-pinned CSP; a runtime licence gate; a bundle verifier; the CI `editor` job | The inline page replaces `WebViewAssetLoader`, which the plugin doesn't expose (SECURITY §3) |
| **W2 WebView host & bridge** | `webview_flutter` 4.14.1 behind `EditorSurface`, with a scripted Dart page for widget tests. The page is checked against its manifest SHA-256 before it loads. Navigation is refused, file and content access are off, and debugging is on in debug builds only. One JavaScript channel, with validated, size-capped and rate-limited messages. A Dart mirror of protocol v1. The host keeps a shadow copy of every document and reopens all of them whenever the page restarts | A renderer crash ends the app, because the plugin has no `onRenderProcessGone`. W5's journal covers it |
| **W3 Engine gate (ADR-0004)** | CM6 and Monaco 0.57.0 benchmark pages at identical scope. The gate runs 3 fresh runs per engine plus a DevTools driver for input latency, 9 composition cases and memory. Settings → Developer → Editor benchmark and Frame timing serve phone runs, from a profile arm64 APK the gate publishes. ADR-0004 Accepted: CodeMirror 6. The phone run's selection bug is fixed | The developer screens are in debug **and profile** builds, so a phone can run them. The memory session is shorter than the ADR's 10 minutes |
| **W4 Real files, documents & tabs** | `LocalFileService` on `dart:io` in `<filesDir>/workspaces/demo`:<br>• canonical root, so neither `..` nor a symbolic link escapes it<br>• atomic writes (temp file, flush, rename)<br>• strict UTF-8 that keeps the BOM and CRLF<br>• binary and invalid files refused<br>• stamp checks before a save overwrites<br>`DocumentController`:<br>• dirty means different from the saved text<br>• Save As, New File, the close prompt, Close others<br>• tabs that reopen after a restart<br>Also language detection by extension, file name and shebang, and the workbench shortcuts | The workspace root comes from a one-method channel, not path_provider. Tabs were kept in the shell envelope until W5. A save does not keep the file's permission bits |
| **W5 Zero-loss persistence** | Drift 2.35.3 over SQLite (`codeforge.sqlite`, schema v1, WAL, `synchronous = NORMAL`), opened lazily in a background isolate, with a migration test harness. The hot-exit journal: snapshots plus the editor's change sets, written as you type. On a cold start the journal replays and documents reopen still unsaved, with cursor and scroll. A file that changed meanwhile keeps both texts and asks. The editor pane moves between layouts without reloading the page. CI generates the Drift code and checks it | The journal lives in SQLite, not files (ADR-0008 amended). Undo history does not survive a process death |
| **W6 Editing & keyboards** | A find bar: match case, whole word, regular expressions, a count up to 1,000, replace one, and replace all as one undo step. Go to line (`42` or `42:7`). A symbol toolbar of 48 dp keys that never take focus from the WebView, with presets per language and the user's own keys. `insertIndent` for Tab. Soft-keyboard and hardware-keyboard providers. App shortcuts work while the editor has the focus. The emulator's key injector | App shortcuts are handled by Flutter first, not caught in the WebView. Beside a hardware keyboard the toolbar steps aside only while the soft keyboard is down. The manual selection matrix is parked |
| **W7 Large files, tests & quality** | Large-file measurements at 1, 5 and 10 MiB in the gate. The policy: plain text above 512 Ki characters, with a banner offering *Highlight anyway*, and files over 10 MiB refused before they are read. `CfAlertDialog`s that fit beside the keyboard. The accessibility sweep over the new chrome. The protocol contract on both sides. Goldens for the new chrome. Per-layer coverage | Sizes are MiB, not MB. Nothing was measured on a phone (parked) |
| **W8 Docs & exit** | This report. ADR-0004's status. EDITOR_ARCHITECTURE (status, §2's protocol list). SECURITY §3 (the page as shipped, renderer crashes) and §4 (Auto Backup). TESTING (§1.2 totals, §5, §6). BUILD_AND_RELEASE §2.2 (the editor job and the gate's groups). ARCHITECTURE §2.7. TECH_STACK (Phase 2 as built). PERFORMANCE §4. CHANGELOG, ROADMAP and README | — |
| **Carried in from Phase 1 (plan §0)** | 48 dp toolbar keys (W6); features reach files only through controllers, enforced by the import lint (W4); keyboard-visibility and hardware-keyboard providers (W6) | **The on-disk log sink was not built.** Logs stay in the 500-record memory ring buffer, which Settings → About can copy. Proposed for Phase 3 |

**Size:** 86 hand-written Dart files in `lib/` (15,428 lines, up from 39 files and 5,409 lines at Phase 1), plus Drift's generated code. 44 host test files (55 Dart files and 10,389 lines with test support). 10 integration tests (2,161 lines). In `editor/`, 32 source, benchmark and tool files (4,912 lines) and 15 test files (17 files and 1,727 lines with fixtures and helpers). That is 49 authored commits, plus CI's commit-backs.

## 4. Gate by gate

| Gate | Criterion (plan §5) | Result | Evidence |
|---|---|---|---|
| **G1** | CM6 within the ADR-0004 budgets on the KVM emulator:<br>• cold load ≤ 800 ms<br>• input → frame p95 ≤ 32 ms<br>• a 1 MB file opens without OOM, with < 5 % of scroll frames over 32 ms<br>• memory ≤ 250 MB<br>• bundle ≤ 1.5 MB gz<br>• 0 composition corruptions<br>Monaco is measured with the same suite | ✅ engine decided · ◐ two budgets on hardware parked | Gate 42206498197 (`editor_bench.json`, evidence `41247d0`) and the owner's phone run (2026-11-06, `docs/phases/evidence/phase2-phone-2026-11-06/`); tables in §7.1, decision in ADR-0004.<br>**Met:**<br>• cold load: 364.8 ms on the emulator, 217–228 ms on the phone<br>• composition: 0 of 9 failures for both engines in every gate that ran the cases, the final 42676631509 included<br>• size: 300,795 B gzipped<br>• the 1 MiB file opens without OOM<br>• typing p95 on the phone: 21.7–22.4 ms<br>• memory in a release build: 224.5–236 MB (W7)<br>**Not judged on the emulator:** the frame-timed budgets. It renders in software at about 7 fps, so the owner took the low-end phone as the reference (W3).<br>**Open on hardware:**<br>• 1 MiB typing in mid-file: 133–136 ms p95 highlighted. W7's policy makes such a file plain text, and on the emulator it then types like a `.txt` file<br>• scrolling: 1.7 % and 9.8 % slow frames in two sessions<br>Both are parked (§8) |
| **G2** | open, edit, save and save-as real files; atomic writes (an interrupted save leaves the old file intact); BOM and CRLF preserved; binary and invalid UTF-8 refused | ✅ | `local_file_service_test` on a real temporary folder: an interrupted save leaves the old file, symbolic links can't escape, BOM and CRLF bytes are kept, creation is exclusive. Plus `text_codec_test` and `workspace_path_test` (CI 42238016497, and every CI since through 42678576228). On the emulator, a save writes exactly the editor's text, and a CRLF + BOM file survives edit, save and Save As byte for byte (gate 42238016973). The editor group has passed in every gate since |
| **G3** | ≥ 10 open documents; switching keeps each one's cursor, scroll, selection and undo; dirty dot + close prompt; tabs reopen after restart | ✅ | Gate 42238016973:<br>• 12 tabs kept their text, cursor and scroll across switches (scroll tops 1088–2978 px)<br>• a select-all selection survived a switch<br>• undo stayed per tab, and undoing back to the saved text cleared the dot<br>• the restore pair reopened the tabs in order, with the same tab active, after `am force-stop`<br>`documents_test` covers the dirty dot and Save / Don't Save / Cancel. Since W5 each tab also gets back its cursor and scroll |
| **G4** | type without saving → process death → relaunch: identical text, still dirty, cursor restored; the same after a renderer crash and after rotation; journal replay equals the live text for randomized edit sequences | ✅ | Edit pair (gate 42386742421, evidence `6b2b9ba`): 262 unsaved characters, among them `é`, `中` and an emoji outside the Basic Multilingual Plane, came back identical and unsaved, with the cursor at 44. That was after a renderer crash took the app down and `am force-stop` confirmed it. Rotation to landscape and back kept the page without a reload. Journal replay equals the live text for 400 seeded sequences, and through SQLite for 8 seeds of 50–199 edits (CI 42386742434). The pair has passed in every gate since, including 42676631509 |
| **G5** | highlighting for the six initial language families; detection by extension and shebang; find/replace including regex; undo/redo; go to line; bracket matching, auto-close, auto-indent, folding | ✅ | vitest (`languages`, `editing`, `search_session`) and widget tests (`find_test`). The editing group on the real page: counts 6/5/4 by option, a whole-word replace all undone in one step, `$2 = $1` groups, and line 42 reached as line 3, column 7 (gate 42437560830, and the same line in 42676631509). Detection is tested in `editor_core_test` and `document_controller_test` |
| **G6** | the toolbar inserts at the cursor without closing the IME; 48 dp keys; Tab/Shift+Tab; hardware shortcuts (save, find, undo/redo, palette, close and next tab) work while the editor has focus | ✅ | The keys group (gate 42517731718, and again in 42676631509): the toolbar's `()` and Tab, pressed with a real tap, typed at the cursor with the soft keyboard up throughout. From the emulator's keyboard device: Tab, Shift+Tab, Ctrl+Z, Ctrl+Shift+Z, Ctrl+S, Ctrl+Tab, Ctrl+W, Ctrl+F and Ctrl+Shift+P, with 0 resyncs. 48 dp keys in `symbol_toolbar_test` and the accessibility sweep |
| **G7** | open, scroll, typing and memory measured at 1, 5 and 10 MB; the large-file policy implemented and tested | ✅ | `large_files.json`/`.txt` without the policy (gate 42616081317) and with it (42659207710, 42665305004 and 42676631509). Each records the open, the page's work, long tasks, a 3 s scroll, 60 real keys at the middle line, memory and the save, at 1, 5 and 10 MiB as `.js` and as `.txt`, plus a release build's memory with 1 MiB restored. The policy is tested in `large_files_test`, `document_controller_test`, `local_file_service_test` and widget tests, and the gate checks it on every file it opens |
| **G8** | CI green (Flutter and editor jobs); protocol contract tests on both sides; the accessibility suite covers the new chrome; no overflow, including with the keyboard up | ✅ | CI 42678576228: `+563: All tests passed!`, and the editor job passed 187/187. The contract is checked on both sides: `editor_protocol_test.dart` and `protocol.test.ts` each read the other side's message tables. The accessibility sweep covers the find bar, toolbar, banner, dialogs and file menu. `keyboard_insets_test` opens every alert dialog beside the keyboard at the five gate sizes, at 1.0× and 1.3× text, with no overflow |
| **G9** | docs synced; PHASE_2_REPORT with run ids | ✅ | this commit (owner review) |

## 5. Tests

The CI totals are authoritative: `app/ci-results/test.txt` reads `00:56 +563: All tests passed!`, and `app/ci-results/editor/test.txt` reads `Tests  187 passed (187)`. Both come from CI 42678576228. The Flutter count grew 236 (Phase 1, unchanged by W1) → 344 (W2) → 370 (W3) → 431 (W4) → 478 (W5) → 539 (W6) → 563 (W7). TESTING.md §1.2 lists every suite file by file.

| Suite | Files | Proves |
|---|---|---|
| Editor page (vitest + happy-dom) | 15 files in `editor/test` | protocol validation; change sets against CodeMirror; the controller and bridge; batching; languages; the search session; Tab and paired inserts; the cursor-only active line; benchmark statistics; the large-file probe, driver and report |
| Bridge contract, both sides | `editor/test/protocol.test.ts`, `app/test/core/editor_protocol_test.dart` | the same JSON fixtures parse or fail with the same error code; the Dart message tables equal the page validator's, and each side reads the other's |
| Unit: core | 12 files in `test/core/` | the codec (BOM and CRLF byte for byte; binary, malformed UTF-8 and UTF-16 refused); workspace paths; change sets and shadows; journal replay = live text for 400 seeds; line targets; toolbar keys; the large-file policy |
| Unit: services, on real resources | `local_file_service_test` (real temporary folder), `drift_session_store_test` and `test/drift/app/schema_test.dart` (real SQLite), and 6 more files | atomic saves, symbolic-link escapes, exclusive creation; tabs, journal writes and failure recovery; schema v1 checked with drift_dev's verifier; page and benchmark manifests |
| Application | 6 files in `test/application/` | dirty against the saved text; conflicts; process death mid-edit, with the file unchanged, changed, deleted or unreadable; damaged journals; page-restart races; large-file decisions at open, restore and Save As; the find session |
| Widget | 10 more files in `test/widget/`, over the scripted editor page | tabs and close prompts; documents; the find bar; the toolbar and focus; shortcuts; developer screens; layouts |
| Keyboard and accessibility | `keyboard_insets_test`, `accessibility_test`, with the dialog launchers in `workbench_dialogs.dart` | every alert dialog beside the keyboard at 5 sizes × 1.0/1.3 text; 48 dp targets and labels on the new chrome |
| Goldens | `test/goldens/{gallery,screens,chrome}_golden_test.dart` | the workspace with the real editor; find and replace and the large-file banner at 412×915; go to line beside the keyboard at 800×360 |
| Integration (emulator), 11 groups | 10 files in `integration_test/`, run by `tool/ci/emulator_gate.sh` | smoke; the editor bridge; editing; keys; the benchmark for each engine; large files; the restore pair; the edit pair. The benchmark file runs once per engine, so 10 files make 11 groups |

**Coverage** of hand-written code (CI 42678576228; generated Drift code excluded, 1239 lines):

| Layer | Phase 1 exit | Phase 2 exit |
|---|---|---|
| core | 85/93 (91.4 %) | 591/640 (92.3 %) |
| application | 156/189 (82.5 %) | 1468/1586 (92.6 %) |
| design_system | 478/512 (93.4 %) | 540/567 (95.2 %) |
| features | 658/829 (79.4 %) | 1480/1694 (87.4 %) |
| services | 217/236 (91.9 %) | 636/866 (73.4 %) |
| app root | 22/27 (81.5 %) | 21/29 (72.4 %) |
| **total** | 1616/1886 (85.7 %) | **4736/5382 (88.0 %)** |

Phase 2 set no coverage target. Core still clears Phase 1's 90 % bar. Most of what services miss is platform glue that runs only on a device: the WebView surfaces (`webview_editor_surface.dart`, `bench/bench_surface.dart`) and the app's directories channel. The emulator gate runs that code.

## 6. Build artifacts

| Artifact | Size | SHA-256 | Where |
|---|---|---|---|
| Debug APK (final tree) | 177,348,309 B | `872061279f9274a50f3fb32f61c02c75fc0aecb1d1a492d0de543efe9b6ccc92` | artifact `codeforge-debug-apk` (13702480428) on CI 42678576228, kept until 2027-02-07 |
| Release APK, x86_64, debug-signed (gate only: cold start and release memory) | 24,489,779 B | not recorded (not a distributable) | built inside gate 42676631509 (`perf.json`) |
| Profile arm64 APK with the benchmark pages (phone runs) | 21,509,213 B zipped | printed in the gate's step log, not committed | artifact `codeforge-phone-profile-arm64` (13701794019) on gate 42676631509, kept until 2026-12-09 |
| Editor page `editor.html` (inside every APK) | 768.4 KiB; 291,951 B gzipped (budget 1,572,864 B) | `84431233cb8721838888d4a7230c9c5f074c30b7f69e9604bb7c0aa6f67caa8a` (CSP script hash `sha256-csqXDdzzvB25mLR2mBYrAmqOOjLWRYZ7xGw6yMzoWRc=`) | artifact `editor-page` on CI 42678576228; `app/ci-results/editor/{build,verify}.txt` |
| Coverage `lcov.info` · gate results | — | — | artifacts `coverage` (CI) and `phase-gate-results` (gate) |

Since Phase 1 the debug APK grew by 7,535,727 B (from 169,812,582 B) and the release x86_64 APK by 3,271,573 B (from 21,218,206 B, +15.4 %). The growth comes from the WebView plugin, Drift with SQLite's native libraries, and the editor page. The editor page is 285.1 KiB gzipped, under a fifth of its budget. The CodeMirror benchmark page is slightly larger (300,833 B), because it carries the harness.

As in Phase 1, debug APKs are not bit-reproducible across CI builds, so each hash is quoted with its run. No binary is published: the licence is still undecided (ADR-0011).

## 7. Performance

All CI numbers come from an API 36 `google_apis` x86_64 emulator on a GitHub-hosted runner (4 vCPU, 16 GB). It is KVM-accelerated (`host.txt`), with a software GPU (SwiftShader) and WebView Chrome 133. That is indicative, not a device measurement:
- Frame-timed numbers are bounded by software rendering.
- Debug builds carry the Dart JIT.
- The speed of the host varies between runs.

The phone numbers come from the owner's realme C51 (Unisoc T612, 4 GB RAM, Android 13), a deliberately low-end phone.

### 7.1 Editor engine (ADR-0004, G1)

**Emulator gate 42206498197** (debug APK, medians of 3 fresh runs per engine):

| Metric (budget) | CM6 | Monaco |
|---|---|---|
| Cold load → first editor frame (≤ 800 ms) | **364.8 ms** ✓ | 1145.7 ms ✗ |
| Typing p95, engine path (≤ 32 ms) | 164.3 ms ✗ (p50 96.3) | 178 ms ✗ (p50 84.7) |
| Input → frame p95, DevTools keys (≤ 32 ms) | 126.9 ms ✗ (p50 43.7) | 136.3 ms ✗ (p50 68.7) |
| 1 MiB scroll, frames over 32 ms (< 5 %) | 95.2 % ✗ | 94.7 % ✗ |
| Composition failures, 9 cases (0) | **0** ✓ | **0** ✓ |
| Memory, app + renderer PSS, debug build (≤ 250 MB) | 509.2 MB ✗ (renderer 121.5) | 633.2 MB ✗ (renderer 186.7) |
| Size, gzip (≤ 1.5 MB) | **300,795 B** ✓ | 1,054,113 B ✓ |
| 1 MiB open / typing p95 | 240 / 188 ms | 529 / 233.4 ms |

**Phone run, 2026-11-06** (profile arm64 APK from gate 42206498197; session medians, two sessions):

| Metric (budget) | CM6, session 1 / 2 | Monaco, session 1 / 2 |
|---|---|---|
| Cold load → first editor frame (≤ 800 ms) | **217.1 / 228.2 ms** ✓ | 743.2 / 743.7 ms ✓ |
| Typing p95, engine path (≤ 32 ms) | **21.7 / 22.4 ms** ✓ (p50 19.5) | 25.4 / 24.4 ms ✓ |
| 1 MiB scroll, frames over 32 ms (< 5 %) | **1.7 %** ✓ / 9.8 % ✗ | 37.4 / 35.7 % ✗ |
| 1 MiB open | 89.8 / 88.7 ms | 266.2 / 346.2 ms |
| 1 MiB typing p95, mid-file | 133.2 / 136.0 ms | **45.4 / 37.2 ms** |

**Reading these numbers:**
- **CM6 leads on almost every metric.** It loads 3.3–3.4× faster on the phone, has 3.6–22× fewer slow scroll frames there, is 3.5× smaller and uses 124 MB less memory on the emulator. It matches Monaco's composition correctness.
- **Monaco's one measured win** is typing in the middle of a highlighted 1 MiB file. W7's large-file policy answers that (§7.2).
- **A re-run on the emulator** (gate 42216855184) kept the ranking.
- **The benchmark still runs in every gate.** On the final tree (42676631509), CM6 had cold load 142.6 ms, input p95 36 ms, 0 of 9 composition failures and 300,833 B. Monaco had 373.9 ms, 52.3 ms, 0 failures and 1,054,113 B. CM6's memory figure is missing from that run (§9.2).

### 7.2 Large files (W7, G7)

**With the policy, gate 42676631509** (debug APK; files above 512 Ki characters open as plain text, marked *):

| File | Open | Long tasks | Typing p50 / p95 | Memory (debug) | Save |
|---|---|---|---|---|---|
| 512 KiB `.js`, highlighted | 115 ms | 4, 335 ms | 38.3 / 100.4 ms | 513.9 MB | 73 ms |
| 1 MiB `.js`, plain* | 119 ms | 0 | 19.6 / 74.6 ms | 559 MB | 112 ms |
| 1 MiB `.txt` | 128 ms | 1, 53 ms | 22.8 / 93.7 ms | 543.5 MB | 124 ms |
| 5 MiB `.js`, plain* | 498 ms | 1, 134 ms | 21.2 / 66.3 ms | 610.9 MB | 230 ms |
| 5 MiB `.txt` | 393 ms | 1, 146 ms | 23.8 / 70.1 ms | 641.7 MB | 237 ms |
| 10 MiB `.js`, plain* | 917 ms | 1, 391 ms | 25.3 / 65.9 ms | 709.8 MB | 519 ms |
| 10 MiB `.txt` | 806 ms | 1, 262 ms | 23 / 70 ms | 795 MB | 472 ms |

- **What the policy changed.** Gate 42616081317, without the policy, typed the highlighted 1 MiB `.js` file at 44.2 / 109.4 ms, against 27 / 66.8 ms for the `.txt` file. That open had 6 long tasks (594 ms). With the policy, the `.js` file types like the `.txt` file in all three runs.
- **Highlighted opens are the slow ones.** In every run they had 4–6 long tasks, totalling 0.3–0.7 s; plain opens had at most 2.
- **Memory in a release build** restoring a session with the 1 MiB file open: 224.5, 227.6 and 224.6 MB with the policy (gates 42659207710, 42665305004 and 42676631509), and 236 MB highlighted (42616081317). The budget is 250 MB. The debug figures in the table include the Dart JIT and are not comparable with the budget.
- **Scroll carries no signal.** 85–100 % of frames are over 32 ms for every file, highlighted or not, because the emulator renders in software. Only a phone can judge scrolling.
- **The session store** (ADR-0008), across four runs:
  - a snapshot write takes a median of 10–43 ms at 1 MiB and 137–250 ms at 10 MiB, with NORMAL and FULL alike;
  - FULL adds at most 0.4 ms per change;
  - the digest of the saved text, on the UI isolate, takes up to 28 ms at 1 MiB and 80–184 ms at 10 MiB.

### 7.3 Cold start, memory and frames

| Metric | Value | Budget | Notes |
|---|---|---|---|
| Release cold start, median of 10 | **906 ms** (42676631509) | ≤ 1500 ms | samples 858, 1233, 946, 830, 854, 1159, 867, 1087, 849 and 1023 ms (`perf.json`) |
| Earlier Phase 2 medians, same method | 1412 (W2) · 1146–1322 (W3) · 1284 (W4) · 1349 and 1078 (W5) · 976 (W6) · 995 and 1307 ms (W7) | — | Phase 1 exit: 1148 ms. Single runs vary with the host; every median is within budget |
| App + renderer memory, release build, 1 MiB file restored | **224.6 MB** (42676631509) | ≤ 250 MB | §7.2 |
| Navigation frames over 32 ms, phone | **3.4 %** (11 of 319) | ≤ 5 % | Phase 1's G6, measured 2026-11-06 with the W3 Frame timing screen |
| Editor ready after opening the workbench | 3821 ms (W4, debug APK) | — | the emulator's debug build; not a budget |

## 8. Parked owner checks

None of these blocks acceptance (plan §5, definition of done). They are tracked in [ROADMAP.md](../ROADMAP.md) under "Parked owner checks". For the selection and Gboard matrices, use the profile arm64 APK from gate 42676631509 (§6). For TalkBack, use the debug APK from CI 42678576228. Uninstall the earlier CodeForge build first: every CI build is signed with a different throwaway key.

| Check | What it needs | Can it run today? | Emulator counterpart |
|---|---|---|---|
| **Gboard IME matrix** (swipe, voice, CJK, emoji) | a phone with Gboard; [PHASE_2_PHONE_CHECKLIST.md](PHASE_2_PHONE_CHECKLIST.md) §3 | yes | 9 scripted composition cases: 0 failures in every gate that ran them |
| **Selection matrix** (handles at line boundaries, copy and paste, undo and redo) | a phone, about 10 minutes; [PHASE_2_SELECTION_MATRIX.md](PHASE_2_SELECTION_MATRIX.md) | yes | none: Android System WebView draws the handles |
| **Large files on arm64 with the policy** (ADR-0004): 1 MiB typing p95 and scrolling | a large file on the phone, or a plain-text pass in the benchmark | **no**: the benchmark always highlights its 1 MiB file, and Phase 2 has no way to bring a large file into the workspace without a computer | the gate's large-file group (§7.2) |
| **Memory on hardware** (ADR-0004) | `adb shell dumpsys meminfo` from a computer: an app cannot read the memory of its WebView renderer, which runs as a separate isolated process | with a computer only | the release measurement (224.6 MB) |
| **FULL against NORMAL on flash, and the save pause** (ADR-0008) | the large-file group run against a phone over adb, or a phone user saving a 5–10 MiB file | **no** without a computer, for the same reason as the large-file check | the gate's store timings (§7.2) |
| **TalkBack spot-check** | Phase 1's 10 items ([PHASE_1_REPORT.md §8](PHASE_1_REPORT.md)), plus the 5 below | yes | `accessibility_test`: tap targets, labels, 1.3× text, the new chrome |

**TalkBack, Phase 2 additions:**

11. **Tabs:** each tab reads its file name, and its close button reads "Close" and the file name. A known gap (§9.2): TalkBack does not hear which tab is active or which has unsaved changes.
12. **Find bar:** the find and replace fields are labelled. Match case, whole word and regular expression announce their state, and the previous, next, replace and close buttons are named.
13. **Symbol toolbar:** each key announces what it types or does (Tab, Undo, the arrows, Hide keyboard).
14. **Large-file banner** (open a document over 512 KiB): the banner is read in full, and *Highlight anyway* is announced as a button.
15. **Dialogs:** in the close prompt (Save / Don't Save / Cancel), Save As and go to line, the title, the field and the buttons are read in order.

**Proposal:** add a Developer action in debug and profile builds that writes the gate's 1, 5 and 10 MiB files into the workspace. Add a plain-text pass to the benchmark too; its harness already has a plain-text mode. Every large-file check except memory would then need only the phone: typing in the real editor with the policy, scrolling through Frame timing, and the save pause. This is item 4 of §1's decisions.

## 9. Deviations and known limitations

### 9.1 Deviations from the plan (documented as built)

- **One inline page instead of `WebViewAssetLoader`.** webview_flutter_android 4.14.1 exposes no request interception. The page is self-contained, and a CSP pins its one script by hash (W1; SECURITY §3).
- **A renderer crash is a process death.** The plugin has no `onRenderProcessGone`, so Android ends the app, and the journal restores the text on the next start (W2, W5).
- **G1's frame-timed budgets were judged on the owner's phone, not on the emulator,** by the owner's decision (W3).
- **The developer screens are in debug and profile builds,** not debug only, because the phone build is a profile build. Release builds never contain them (W3).
- **The workspace root comes from a one-method MainActivity channel,** not path_provider, whose Android side would pull an NDK build into every APK (W4; TECH_STACK §5).
- **The journal lives in SQLite, not files** (ADR-0008 amended): a snapshot must replace the changes it covers in one transaction (W5). Tabs moved there from the shell envelope with a one-time import.
- **App shortcuts are handled by Flutter first.** Android delivers keys to Flutter before the WebView. The page still forwards the same shortcuts for any key that reaches it first (W6).
- **Beside a hardware keyboard, the toolbar steps aside only while the soft keyboard is down.** It comes back when a soft keyboard comes up (W6; ARCHITECTURE §5).
- **Large-file sizes are MiB, not MB.** The 10 MiB test files stop 128 characters short of the cap, so that they open (W7).
- **The emulator suite runs in the phase gate, not nightly.** TESTING §5, PERFORMANCE §4 and ROADMAP planned a nightly run from Phase 2. The gate runs on `[phase-gate]` commits instead. From W2 on, each work package's final code passed it before the package was reported, and the final app tree passed it in 42676631509.
- **Not built:** the on-disk log sink, a Phase 1 carry-over (plan §0).

### 9.2 Known limitations, carried forward

| Item | Impact | Where it goes |
|---|---|---|
| Files live only in the app's workspace folder: no folders elsewhere on the device, no file watching | Outside changes are caught at save time, and the user is asked | Phase 3 (SAF, file watching with `doc.replace`) |
| Android Auto Backup is on by default (§1) | app files, unsaved text and settings can reach the user's Google Drive | **owner decision**; the fix ships in Phase 3's first package |
| The tab strip shows the active tab and unsaved changes only visually (found in the W8 review) | TalkBack reads each tab's file name and "Close <file name>", but not which tab is active or has unsaved changes. The close prompt still asks before unsaved text is closed | Phase 3's first package: tab semantics, with a widget test |
| On-disk log sink not built | logs are memory only (500 records, copyable from About) | Phase 3 |
| Large-file checks on arm64 (typing, scroll, memory), FULL on flash, and the save pause | ADR-0004 and ADR-0008 answered on the emulator only | parked (§8); the proposed Developer action makes them phone jobs |
| The digest of the saved text runs on the UI isolate | up to 28 ms at 1 MiB, 80–184 ms at 10 MiB, in a debug build | move it to a background isolate if a phone shows the pause (ADR-0008) |
| Not measured: minified files (very long lines), and 512 KiB to 1 MiB documents on a phone | The policy counts characters, not lines | with the phone runs; Phase 3 if minified files prove slow |
| The benchmark's DevTools driver sometimes loses its CodeMirror session, and the report then records n/a, not a failure | Of the last 11 gate runs, 7 have no CM6 debug memory figure. In 5 of them the session closed after the composition cases ("DevTools connection closed"), the final 42676631509 among them; in 2 it timed out before them ("Runtime.evaluate timed out"). The timeout also hit one passing gate, 42437560830, which therefore has no CM6 composition figure. When CM6's debug memory was measured in W7, it was 514.9–578.2 MB (Monaco 601.3–659.4 MB). The release measurement is the memory evidence | harness fix in a later phase |
| `durability = NORMAL` | an OS crash or a power cut can lose the last transactions; app crashes and process deaths cannot | ADR-0008; revisit with the phone measurement |
| Undo history does not survive a process death | a restored document starts with an empty history; rotation keeps it | later (the journal would have to store history) |
| A conflict offers "keep my changes" or "use the file", with no side-by-side comparison | — | Phase 7 (diff view) |
| A save replaces the file, so its permission bits are not kept | harmless in the app-private folder | Phase 3/4, before user folders (SECURITY §4) |
| Text is UTF-8 only; other encodings are refused | refused, never converted | by design for now |
| Keys injected from Android's virtual keyboard without meta state (`adb input keycombination`) | the page caught Ctrl+S, Ctrl+W and Ctrl+Z, but not Ctrl+Tab, Ctrl+F or Ctrl+Shift+P; cause unknown. Hardware keyboards are not affected | open question |
| Skia instead of Impeller | carried from Phase 1 | Phase 4 device lab |
| Phase 1 items still not built: `ProviderObserver`, LogViewer, a Material Symbols subset and file glyphs, uploading golden diff images on failure | none is gate-relevant | Phase 3 (file glyphs), later |
| Licence undecided (ADR-0011) | no binary release | owner decision, by Phase 4 |

### 9.3 Gate history (why early numbers are not used)

- **W2:**
  - CI 42183490857 hung in golden generation for over 20 minutes and was cancelled.
  - CI 42187071054 named the cause: `EditorHost.dispose()` awaited `StreamSubscription.cancel()`, whose root-zone future never completes inside a widget test.
  - Every test run is now time-bounded (`ff90b2a`), and dispose cancels synchronously (`7d4f3cb`).
- **W3:** CI 42206498250: the benchmark screen without pages gave its reason twice → `f056669`.
- **W4:**
  - CI 42232179190: four analyzer findings → `e1a6cf5`.
  - Gate 42233424845: the smoke test looked for the workbench before the first run had finished writing the workspace. It now waits.
- **W5:**
  - CI 42377268979: the migration-test helpers were missing, because `make-migrations` writes them only from schema v2 on. The bootstrap now runs `drift_dev schema generate`.
  - Gate 42379885027: typing reached the page before the page had reopened `main.js`. Document commands now wait for the page sync.
- **W6, find and replace:**
  - CI 42398536299: the find bar touched its lazy replace controller while unmounting → `aa2d768`.
  - Gate 42399401256: the test looked for the go-to-line dialog before the page's flush had come back → `d4d2256`.
- **W6, the keys gate** (13 failed and 1 cancelled gate runs, 1 failed CI run):
  - Gate 42442722184: the emulator reports a hardware keyboard, as AVDs do, so the toolbar was away. The toolbar now steps aside only while the soft keyboard is down (`3812f21`).
  - Gradle downloads stalled (CI 42477797826; gates 42477797842 and 42478331067).
  - The injector never saw the test's requests (42479571017, 42482002996).
  - The test binding dropped device touches (42484555140).
  - Tab never reached the page (42491602659).
  - Modifiers arrived released (42494656149, 42497788524).
  - The emulator console reached nothing (42507384710), and `sendevent` needed root (42509926650).
  - The test expected the wrong next tab (42512666974, 42515305565).
  - A smoke test hung until the job's cap (42500759166, cancelled), hence the 10-minute limit per attempt.
  - The details are in the plan's As built W6.
- **W7:**
  - CI 42611941480 and gate 42611941538: a missing import.
  - Gate 42654133163: the 10 MiB test files were over the new cap. CI 42654133167 timed out, because the scripted page laid out the whole document. Both fixed in `65fe2ca`.
  - The first attempt of gate 42659207710 stopped while building the debug APK, before any test; its second attempt passed.
  - CI 42665305010: the new sweep found the 47 dp text fields, and at 1.3× text a tap landed below the screen → `decd7ec`.
  - Gate 42667620018 never started a job (GitHub reported a workflow file problem for an unchanged file). The next `[phase-gate]` push ran normally.

## 10. Next-phase readiness (Phase 3 — Workspace & files)

**Ready:**
- **The `FileService` contract** with its `dart:io` implementation, scoped to a canonical root and tested on a real folder. The Kotlin SAF broker plugs in behind the same contract (ARCHITECTURE §2.5).
- **`DocumentController`**, with stamp checks at save and the conflict question.
- **Drift schema v1** with a migration harness: the first schema change gets its migration test automatically.
- **Protocol v1's `doc.replace`**, ready for file watching.
- **The explorer**, listing the real folder.
- **The import lint**, keeping features off the file service.
- **CI with two jobs**, about 7 minutes. The emulator gate has 11 groups and takes about 29 minutes.

**Phase 3 entry items:**
- owner acceptance of Phase 2;
- the Auto Backup decision;
- the on-disk log sink;
- tab semantics for TalkBack (§9.2);
- the Developer action for large test files and the benchmark's plain-text pass, if you want them;
- the Phase 3 plan, with ROADMAP's storage-scoping security review;
- keeping permission bits on save before user folders arrive.
