# Phase 5 Report — Terminal & Execution

**Status:** **Built, awaiting the owner's acceptance** (this report asks the owner to accept Phase 5 or ask for changes); the exit gate, 44900930980, passed whole on every target (§4); the phone session (§8) and the owner's release and Play actions (§10) are open, and non-blocking · **Date:** 2026-11-21 · **Branch:** `arena/f57c33ee-codeforge`
**Plan:** [PHASE_5_PLAN.md](PHASE_5_PLAN.md) · **Spec:** §8 Phase 5, §6.4–6.5, §7, §10 · **Rule:** every claim below cites a CI run, a phase gate or an evidence commit. Where something was not measured or not met, this report says so.

---

## 1. Summary

Phase 5 runs the user's code in CodeForge, on the sealed runtime Phase 4 put in the app:
- **A terminal on a pseudo-terminal CodeForge wrote itself.** CodeForge's launcher opens the PTY and relays between it and the app (ADR-0014), so nothing forks inside the app's process. A session runs bash with CodeForge's rc file, takes window sizes in order with the keystrokes, delivers Ctrl-C to the foreground job, and ends with its whole process tree. A flood waits in the kernel once the view is a 256 KiB window behind. Up to 8 sessions run at once. xterm.js 6 draws them in a WebView of its own, behind a validated protocol, with tabs, a row of extra keys, copy and paste, touch, and the input method's text sent whole.
- **Within its budgets on a phone.** On Test Lab's Pixel 8a with Android 14, in a profile build (CI 44893095694, then the exit gate 44900930980):
  - a keystroke's echo drawn in **37.2 ms** at the 95th percentile, then 38.4 ms (budget 50 ms);
  - a 10 MiB flood whole in 3.3 s with **none** of Flutter's frames over 32 ms, then in 3.5 s with 0.9 % (budget under 5 %);
  - the terminal open and idle costs **55.3 MB** more, then 44.6 MB (budget 90 MB, the owner's decision).
- **Run.** The open file runs with node, python, bash, ruby or perl, and a project runs an npm script or its entry file. Each run is a terminal session, with its exit code, Stop for its whole tree, and `file:line` in the output opening the editor at that line. A folder from shared storage runs in an incremental copy (ADR-0013), whose new files can be exported back. When a package needs a compiler, a banner says why it can't build.
- **Sessions that last.** A `specialUse` foreground service runs while any session does, with "*N* terminal sessions running" and *End all*. After process death, each session leaves a tombstone. Each session runs under a 4 GiB file size, 2,048 processes and a raised OOM score, each measured on API 26 to 36 and the Pixel 8a before it was set. SECURITY §2.2 reviews the boundary, T1 to T16.
- **Ready to release, once the owner's keys exist.** The release workflow's dry run built the signed arm64 App Bundle, at 146.2 MB per device (73.1 % of Play's limit), and the APK, with the source archive beside them: 261.7 MB, 55 package versions, 69 upstream files, each verified (CI 44399784786). About shows the written offer, CodeForge's licence and every bundled package's licence text.
- **Real targets:** every phase gate ran emulators with Android 8.0, 8.1, 9, 14 and 16. Test Lab's physical Pixel 8a ran in W2, W5, W6 and the exit gate.

**All seven gates are met** (§4), and the exit gate, 44900930980, passed whole on every target. Not met, and why:
- **ADR-0006's 80 MB after a flood.** The terminal open and idle is within it (55.3 MB; 44.6 MB in the exit gate), but once settled after a 10 MiB flood the app holds 100.3 to 130.2 MB more in the three phone runs since the memory work, mostly the WebView's GPU memory. The owner decided to work it down, then to judge the open terminal within 90 MB and record a flood's growth (PHASE_5_PLAN §10, item 7). After the flood the app's PSS was 539 MB, and 583 MB in the exit gate, before any language server. PERFORMANCE allows 600 MB for the editor, a terminal and one language server (of RSS, a different measure), so Phase 6 starts near that line.
- **No phone checks by a person yet** (§8). These need the owner's phone: Gboard by hand; taps and typing through Hybrid Composition++, which no automated test reaches; nano across a turn; a long session in the background; the tombstones after process death.
- **No binary release yet** (ADR-0010). It waits for the owner's keys and the licence review.
- **Play needs the owner:** the developer account, the testers, the forms and the special-use declaration. Play's rule on downloaded executable code also needs the owner's review (§9.2).
- **The last pass found two things** (§9.1). A measurement the plan's risk table gave W4 had not been made, and the native-addon text said more than Android does. W7 made the first and corrected the second. The measurement found that **node loads a native addon from the app's storage on every Android version measured**, which Play's rule on downloaded code makes the owner's question (§9.2, §10).

## 2. Evidence index

| Work package | Done | CI runs | Phase gates | Test Lab |
|---|---|---|---|---|
| W1 The release workflow, the source archive, the licences in the app | 2026-11-18 | 44377396101 ✗, 44381310978 (`+895`), 44414221251 (the docs); the release dry runs 44389009942 ✗, 44394419519 ✗, **44399784786** ✓ | **44405049032** ✓ | — |
| W2 The PTY and terminal sessions | 2026-11-19 | 44445690182, 44451456079, 44474274477 (`+904`), 44486800285 (the docs) | 44454605348 ✗, 44461809588 ✗, **44475934378** ✓ | **CI 44482754814** (Pixel 8a, 25 of 25) |
| W3 The terminal view | 2026-11-19 | 44516067221 ✗, 44518519957, 44572951140 (`+1033`), 44613792689 (the docs) | 44520440304 ✗, 44557551890 ✗, 44575917666 ✗, 44588484255 (canceled), 44589259655 ✗, 44596547784 ✗, **44606021478** ✓ | — |
| W4 Run | 2026-11-20 | 44619907768 ✗, 44681887078 ✗, 44683359188 ✗, 44685984006 ✗, 44687566636 ✗, 44689410417, 44705297317 (`+1072`), 44714378285 (the docs) | 44690833991 ✗, 44697552696 ✗, **44707562888** ✓ | — |
| W5 Sessions that last | 2026-11-20 | 44732997918 (`+1076`; the API floor ✗, fixed in the next commit), 44792580156 (the docs) | 44735804283 ✗, 44744464658 ✗, 44752660910 ✗, 44763350329 ✗, **44777091949** ✓ | **CI 44786509685** (Pixel 8a, 29 of 29) |
| W6 The terminal gate on real targets, and the memory work | 2026-11-21 | 44804897631 ✗, 44816821921, 44862901068, 44866950104 (`+1086`), 44875569267 (the docs); the memory work 44882599973 (`+1090`), 44892056800, 44895571872 (the docs) | 44807458944 ✗, **44870622961** ✓, **44883909195** ✓ (the memory work) | 44818854015 ✗, 44863955928 ✗, 44868218258 ✗, 44889362793 ✗, **CI 44893095694** ✓ (Pixel 8a, 31 of 31) |
| W7 The docs and the phase exit | 2026-11-21 | 44899559170 (`+1090`; the code and the docs, `7680614`) | **44900930980** ✓, the exit gate (`e85c408`, an empty commit after 44899559170 passed; evidence `4dcdc75`, `915dbf1`, `9db59b7`) | **CI 44900930980** (Pixel 8a, 32 of 32; 5 of the day's 5) |

Every ✗ is explained in §9.3. A `[phase-gate]` push gives one run whose verdict covers CI and the gate. The gates' evidence is committed back to `app/ci-results/gate/` and `app/ci-results/runtime-gates/`, Test Lab's to `app/ci-results/testlab/`, and the runtime job's to `runtime/ci-results/`. Test Lab's plan allows five physical-device tests a day. On 2026-11-21 (UTC), W6 spent four of them, 44863955928, 44868218258, 44889362793 and 44893095694, and the exit gate the fifth.

## 3. What was built

- **The release (W1):**
  - `.github/workflows/release.yml`, a reusable workflow that `ci.yml` calls for a `[release]` subject line. It builds the arm64 App Bundle and APK in release mode and signs them: with throwaway keys in a dry run, with the owner's upload and release keys once they exist. It then runs seven checks, judged together, and writes `SHA256SUMS`.
  - `runtime/sources.py`, with 27 tests: the copyleft packages' corresponding source, from Termux's recipes at the commits that built them and the upstream files, each verified, from mirrors when a host fails, failing closed.
  - In the app: About → Source code shows the written offer, About → CodeForge's license, and the licence page lists the userland's texts (`app/assets/licenses/userland.txt`, which CI checks against the pins).
- **The PTY and sessions (W2; C and Kotlin):**
  - The launcher's terminal mode (`native/runtime-core/src/main/jni/codeforge-spawn.c`), with framed input and sizes on its stdin.
  - In `runtime/`: `TerminalSession` (a 1 MiB ring, batches at most every 16 ms, the credit window, a writer thread), `Terminals` (the spec's checks, bash with CodeForge's rc file, the terminal's environment) and `SessionRegistry` (the cap of 8, End all, the bounded pool of 16 threads).
  - The Pigeon `TerminalApi`, with output through the `TerminalEvents` Flutter API, and its Dart client.
- **The terminal view (W3):**
  - The terminal page, built in `editor/` with the editor page's kit: xterm.js 6.0.0, addon-fit 0.11.0 and addon-unicode11 0.9.0, and addon-webgl 0.19.0 since W6. It owns the input method's text (`ime.ts`) and touch (`touch.ts`).
  - The terminal protocol v1, with a validator on each side and shared fixtures: 41 valid and 37 invalid at the end.
  - In the app: `TerminalView`, `TerminalController`, and the terminal panel, with tabs, the extra-keys row, Copy and Paste, Maximize and End all.
- **Run (W4):**
  - `core/run/run_commands.dart` (what runs), `application/run/run_controller.dart` (runs as sessions, saved first, Stop), the Run panel and the status strip's chip.
  - `FolderCopy.kt` and the broker's copy, export and import operations, with *Import as project* on Home and in the explorer.
  - `file:line` links (`links.ts`, `core/terminal/file_links.dart`) and the native-addon banner (`core/terminal/native_addons.dart`).
- **Sessions that last (W5):**
  - `terminal/SessionService.kt` (`specialUse`, with *End all*) and `SessionKeeper`.
  - `runtime/SessionLedger.kt`, whose tombstones the controller shows.
  - `runtime/SessionLimits.kt`, with the launcher's `--fsize`, `--nproc` and `--oom-score-adj`.
  - Trimming under memory pressure, and views let go in the background.
  - The manifest's service with its three permissions, held by `check_manifest.py`, and `check_api_floor.py`'s guarded API 31 call.
- **The terminal gate (W6):**
  - The page's probe (`probe.ts`), shared by the phone's test and the emulator's group (`integration_test/terminal_measure.dart`, `phone_terminal_test.dart`), with the gate's requests answered on the phone by `GateAnswers.java`. Test Lab's phone runs a profile build.
  - WebGL as the renderer, with the DOM renderer where WebGL can't draw.
  - The memory work: Hybrid Composition++ app-wide (the manifest's `EnableHcpp`), the host's MessagePort to the terminal page (`webview/PagePorts.kt`, `services/editor/page_port.dart`, `hostport.ts`), and WebGL for the shown session only.
- **W7:** `RuntimeCommandsTest` (g) records whether node loads an addon from the app's storage. The native-addon texts are corrected (§9.1).
- **CI** (BUILD_AND_RELEASE §2.5):
  - `test-pty.py` and `test-sources.py` in the runtime job, and the terminal page's build and verification in the editor job.
  - The phase gate's `terminal`, `run` and `sessions` groups, and `TerminalSessionTest` and `SessionServiceTest` on every runtime leg.
  - The terminal's figures on Test Lab's phone, and the release dry run.
- **Documents:**
  - ADR-0014 (new in W2, as built in W7), SECURITY §2.2, and TERMINAL_ARCHITECTURE as built.
  - The Play drafts, revised in W1, W5 and W7, with the special-use declaration drafted for the owner.
  - This report and the phone checklist.

## 4. Gate by gate

| Gate | Result | Evidence |
|---|---|---|
| **G1 Release** | **Met.** The dry run built the arm64 App Bundle and APK, signed with throwaway keys, and all seven checks passed: 146.2 MB per device (73.1 % of Play's 200 MB); 258 of 258 objects 16 KB aligned; the release manifest; the notices current; one signer per file. The source archive holds 55 package versions, 69 upstream files each verified against its recipe's SHA-256, and Termux's tree at 42 commits; it failed closed twice before mirrors were added (§9.3). About shows the offer, and the licence page lists the editor page's and the userland's packages with their texts | release dry run CI 44399784786; CI 44381310978; gate 44405049032 |
| **G2 Sessions** | **Met.** The launcher's terminal mode passes `test-pty.py` on CI's Linux machine (19 tests then, 20 since W5; nine broken copies of the launcher each fail some). `TerminalSessionTest` passes on API 26 to 36 and on the Pixel 8a: bash echoes, `stty size` follows a resize, node's REPL answers, the 10 MiB flood arrives whole with at most the window unacknowledged, the ninth session is refused, and End all leaves no process. The 8a: echo p95 8.38 ms through the host, the flood in 1.04 s, End all in 112 ms | CI 44445690182; gates 44461809588, 44475934378; Test Lab CI 44482754814 |
| **G3 View** | **Met.** The page passes its build checks: the CSP's pinned hash, nothing external, the licences, and 174.8 KiB gzipped of its 256 KiB budget then (211.0 KiB now). The fixtures pass in vitest (74 tests) and Dart (78), and the panel's widget tests (15) pass. In the emulator gate, a tap gives the terminal the keyboard and typed text echoes. nano and top draw at the panel's size in portrait (46×23), landscape (60×7) and portrait again (46×22). The scripted composition suite's ten cases arrive whole | CI 44596547784, 44606021478; gate 44606021478 |
| **G4 Run** | **Met.** main.js, app.py and a shell script give exactly their lines and exit codes 0, 0 and 3; `npm run start` gives exactly its script's lines. Stop ends a node program and the `sleep` it spawned in 206 ms, and nothing is left. The gate folder (1,006 files) runs through its copy: 4,781 ms the first time, 495 ms with nothing changed, 506 ms after one change. The file the run wrote is exported, and the host's `sha256sum` matches. The native-addon banner shows on a fixture that needs a compiler. The E2E scenario part 1 passes | gate 44707562888; CI 44705297317 |
| **G5 Lifecycle** | **Met.** On API 26 to 36 the service started with the first session (74 to 143 ms after it was asked for) and was gone at most 54 ms after the last; End all ended every tree in 129 to 207 ms. In the real app on API 36, a session ran 332 s in the background without a gap over 2 s. After `kill -9` of the app, no session's process was left, and the next start showed the tombstones. The release manifest holds exactly the allowed permissions. Each limit was measured first, its value and reason recorded (SECURITY T14, T15; the 8a in CI 44786509685), and SECURITY §2.2 is written | gate 44777091949; CI 44732997918; Test Lab CI 44786509685 |
| **G6 Terminal budgets** | **Met, as the owner decided the memory budget** (PHASE_5_PLAN §10, item 7). On the Pixel 8a: echo p95 37.2 ms with WebGL (42.2 ms with the DOM renderer); the 10 MiB flood whole, 0.0 % of Flutter's frames over 32 ms, none frozen; the terminal open and idle 55.3 MB, within 90 MB and within ADR-0006's 80 MB; 100.3 MB once settled after the flood, recorded. The exit gate measured them again: echo 38.4 ms, the flood whole with 0.9 % of Flutter's frames over 32 ms, open 44.6 MB, 130.2 MB after the flood. On the emulator, the same figures recorded, and the composition suite whole (10 of 10). The renderer, WebGL, was chosen with numbers (ADR-0006 *As built*) | Test Lab CI 44893095694 (44868218258 first); gates 44870622961, 44883909195; the exit gate 44900930980 |
| **G7 Docs** | **Met.** The docs are synced as PHASE_5_PLAN §7 lists, and ADR-0014 has its *As built*. This report and [PHASE_5_PHONE_CHECKLIST.md](PHASE_5_PHONE_CHECKLIST.md) are written | PHASE_5_PLAN *As built (W7)*; CI 44899559170 |

**The exit gate, 44900930980, passed every group on its first attempt** (`gate_result=pass`; each of its 25 test runs at `attempt=1`): the Phase 3 groups, the runtime group (`runtime_instrumented=pass OK (14 tests)`, `RUNTIME_UI tools ok=7 of=7`), search, the terminal, run and sessions groups, and the cold start, 1,130 ms. All five runtime legs passed, 28 of 28 tests each, and Test Lab's Pixel 8a 32 of 32, in the same run. What each group showed again:
- **The terminal:** the composition suite 10 of 10; nano, top, less and the node REPL fitting the panel across the turns; a session started in 1.3 s. The emulator ran at its usual speed again, unlike W6's second gate (§7.1).
- **Run:** the files and the npm script with their exact lines and exit codes; Stop in 209 ms with nothing left; the native-addon banner; the E2E scenario part 1; the gate folder through its copy in 6,077 / 736 / 635 ms, and the export checked on disk.
- **Sessions:** 332 s in the background, the longest gap 2 s; no process left after the app's death or a force-stop; the tombstones after it.
- **W7's test:** `RuntimeCommandsTest` (g) loaded the library from the app's storage on every target it ran on (§9.2).

The emulator logged one ANR since boot, in Google Play services (`com.google.android.gms.persistent`, which failed to complete its startup), not in CodeForge, and no crash.

## 5. Tests

| Suite | Count at Phase 5's end | Where |
|---|---|---|
| Flutter unit, widget, golden, accessibility | `+1090: All tests passed!` (`+885` at Phase 4's end) | CI 44882599973 (`app/ci-results/test.txt`, commit `e3c0960`) |
| Kotlin (JVM) | 188, none skipped (138 at Phase 4's end) | CI 44882599973 (`kotlin-tests.txt`) |
| The sealed kernel (JVM) | 23 | every CI run (`sealed-runtime-tests.txt`) |
| The pages (vitest) | 373 tests in 25 files; `verify_terminal.mjs` 32 checks and `verify_bundle.mjs` 14 on the built pages | CI's editor job (`app/ci-results/editor/`, commit `e3c0960`) |
| `runtime/tests/` | 8 files, 142 cases (`script_test_files=8 cases=142 failed_files=0`): pins 21, notices 27, provenance 15, the launcher 22, its terminal mode 20, sources 27, and t1's two (bundle size 9, the sealed payload) | the runtime job, every push (`runtime/ci-results/script-tests.txt`) |
| CI tool self-tests | `check_manifest.py` 17 cases, `check_signer.sh` 8, `testlab_diagnose` 11, and `gate_results.py` with the phone picker, among others | every push (`ci-results/manifest.txt`, `release-scripts.txt`, `testlab-scripts.txt`) |
| Instrumented (`androidTest/`) | 32 since W7: `RuntimeInstallTest` 7, `RuntimeCommandsTest` 7 (6 before W7), `TerminalSessionTest` 7, `SessionServiceTest` 4, `SyncModesTest` 4, `SealedShellTest` 2, `ExecModelTest` 1. The runtime legs run all but `SyncModesTest` | the exit gate 44900930980: 28 of 28 on each runtime leg, 32 of 32 on the Pixel 8a, and the emulator gate's runtime group 14 of 14 (W6: 27 of 27 on each leg, gate 44883909195; 31 of 31 on the 8a, CI 44893095694) |
| Integration (`integration_test/`) | the Phase 3 and Phase 4 groups, plus `terminal`, `run`, `sessions_a`/`sessions_b` and `phone_terminal` | every phase gate, and Test Lab |

TESTING.md §1.5 describes each Phase 5 suite.

## 6. Build artifacts

- **Every CI run:** `codeforge-debug-apk` (every ABI, no runtime, 84.7 MB in CI 44882599973), kept 90 days. The release x86_64 APK with its runtime is built and checked, but not uploaded.
- **Every phase gate:** `codeforge-phone-profile-arm64`, the phone build: profile mode, arm64, with the runtime. **For the owner's phone checks:** [the exit gate's artifact](https://github.com/Skill-center/CodeForge-/actions/runs/44900930980/artifacts/14707861503) (run 44900930980, commit `e85c408`, kept until 2026-12-21). It is a zip holding one APK (165,095,365 B).
- **The release dry run** (CI 44399784786): `codeforge-<label>-app`, `-sources` and `-release`, kept 14 days (until 2026-12-02). They are signed with keys nobody holds, so none can be installed over a real release, and none is a release.
- **No release:** nothing is published before the owner's keys exist and the licence review is done (ADR-0010; §10).

## 7. Performance

### 7.1 The terminal (W6)

| Measure | Pixel 8a, judged (CI 44893095694) | Pixel 8a, the exit gate (CI 44900930980) | Pixel 8a, first (CI 44868218258) | Emulator, DOM (gate 44883909195) | Budget |
|---|---|---|---|---|---|
| Echo, 95th percentile (median; max) | **37.2 ms** (26.8; 59.4), WebGL | **38.4 ms** (27.2; 47.9), WebGL | 48.4 ms (28.6), WebGL | 180.4 ms (118.5) | ≤ 50 ms |
| Echo with the DOM renderer, 95th percentile | 42.2 ms | 41.2 ms | 62.3 ms | (draws with the DOM) | — |
| The 10 MiB flood | whole, 3.3 s | whole, 3.5 s | whole, 3.0 s | whole, 39.8 s | whole |
| Flutter's frames over 32 ms during it | **0.0 %**, none frozen (208 frames) | **0.9 %**, none frozen (231 frames) | 0.5 % | all (a software GPU) | < 5 % |
| The page's own frames over 32 ms | 10.6 % | 17.0 % | 13.2 % | 90.7 % | recorded |
| The app before any terminal (PSS, editor open) | 439.0 MB | 452.7 MB | 473.0 MB | 511.5 MB | — |
| The terminal open and idle, full stop (half) | **+55.3 MB** (+44.8) | **+44.6 MB** (+30.6) | +85.2 MB (+73.5) | +16.2 MB (+18.6) | ≤ 90 MB (the owner's decision; ADR-0006 said 80) |
| Settled after the flood, 2 s after it (its peak) | +100.3 MB (+154.7) | +130.2 MB (+146.6) | +153.7 MB (+169.0) | +62.2 MB | recorded |
| Composition, and how output reaches the page | Hybrid Composition++, the port | Hybrid Composition++, the port | texture layer, a script per batch | texture layer, the port | — |

TERMINAL_ARCHITECTURE §2.2 has the method (an input method's commit timed to the frame that draws its echo; the flood hashed on the page; `dumpsys meminfo` by row) and where the memory goes. The memory work moved the open terminal's cost from 85.2 to 53.6 MB in the run after it (CI 44889362793). The app's graphics fell from +46.4 to +17.9 MB, as the second WebView is no longer copied into a texture, and the renderer's share from +21.1 to +12.2 MB. The app before any terminal fell by 32.5 MB too, since the editor's WebView is no longer copied either. A flood's growth is mostly the WebView's GPU memory (+52.4 MB of the app's graphics), and the same after the DOM renderer's flood. The emulator's second gate was slow throughout: a session started in 2.6 s against 1.2 s, the composition suite took 15.4 s against 10.7 s, and W5's gate 44763350329, without W6's code, had been as slow (a session in 2.1 s, the suite in 15.3 s; evidence `a09c078`). Its figures are recorded, not judged. The exit gate's emulator ran at its usual speed: a session in 1.3 s, the composition suite in 10.5 s, echo 77.1 ms at the 95th percentile with the DOM renderer, the flood whole in 22.5 s, and the terminal +18.1 MB open and +64.7 MB after the flood. The phone's settled growth after a flood varies by run: 114.8, 100.3 and 130.2 MB in the three runs since the memory work.

### 7.2 Sessions, the host and the limits

| Measure | Emulators (API 26 to 36) | Pixel 8a |
|---|---|---|
| A keystroke's echo through the host, 95th percentile | 0.68 to 5.12 ms over W2's three gates | 8.38 ms (CI 44482754814); 6.29 ms (CI 44893095694); 5.36 ms (the exit gate) |
| 10 MiB through the host | whole in 0.67 to 0.88 s, 41 to 43 batches | whole in 1.04 s, then 0.91 s twice (43 and 42 batches) |
| The service in the foreground after the first session / gone after the last | 74 to 143 ms / at most 54 ms (gate 44777091949) | 67 / 56 ms (CI 44786509685); 96 / 55 ms (CI 44893095694); 92 / 1 ms (the exit gate) |
| End all, every tree ended, nothing left | 129 to 207 ms | 143 ms; 142 ms; 146 ms |
| The limits a session runs under | 4 GiB file size, 2,048 processes, OOM score 800 (stays the app's on API 26 to 28) | the same, with 2,017 processes of headroom over the app's 31 |

### 7.3 Run and a folder's copy (W4, W6)

The gate folder, 1,006 files: first copy / nothing changed / one file changed.
- **Emulator:** 4,781 / 495 / 506 ms (gate 44707562888); 6,077 / 736 / 635 ms in the exit gate.
- **Pixel 8a:** 7,396 / 780 / 1,124 ms (CI 44868218258), then 7,862 / 739 / 1,017 ms (CI 44893095694), and 7,805 / 1,070 / 1,106 ms in the exit gate. That is about 7.5 ms a file, so the copy's cap of 10,000 files takes about 75 s on a phone, with its progress and Cancel shown.

### 7.4 Sizes

- **The release APK (x86_64):** 150.0 MB (150,024,083 B, CI 44882599973; 150,023,619 B in the exit gate), from 149.5 MB at Phase 4's end.
- **Per device on Play (arm64):** a 148.0 MB base module, 74.0 % of Play's 200 MB limit (147,954,674 B; gate 44883909195, and the same in the exit gate), from 147.4 MB at Phase 4's end. The release workflow's dry run measured 146.2 MB in W1.
- **The terminal page:** 682.8 KiB, 211.0 KiB gzipped, 82 % of its 256 KiB budget (CI's editor job, `app/ci-results/editor/build_terminal.txt`).

### 7.5 Cold start (release build, emulator, median of 10; budget 1,500 ms)

Phase 4's exit gate: 1,121 ms. Phase 5: W1 1,140 ms; W2 1,344 ms; W3 1,028 ms; W4 1,125 ms; W5 831 ms; W6 1,117 ms (gate 44870622961), then 1,400 ms in the slow gate 44883909195 (Skia 1,179). The terminal page loads only when a terminal opens, so it adds nothing to the cold start. **The exit gate: 1,130 ms** (Skia 1,021; the shipped APK once more, 1,123).

## 8. The phone checks

- **[PHASE_5_PHONE_CHECKLIST.md](PHASE_5_PHONE_CHECKLIST.md)** (W7), about 35 minutes:
  - Gboard and the extra-keys row in the terminal;
  - taps and typing in the terminal and the editor on Android 14 or later, through Hybrid Composition++, which no automated test reaches;
  - nano across a turn;
  - a run;
  - a long session in the background, with its notification;
  - the tombstones after process death.
- **[PHASE_3_PHONE_CHECKLIST.md](PHASE_3_PHONE_CHECKLIST.md)** and **[PHASE_4_PHONE_CHECKLIST.md](PHASE_4_PHONE_CHECKLIST.md)** are still open. They can use the same APK.
- All three are non-blocking for acceptance unless the owner decides otherwise. Results go here.

| Run | Date | Phone | Build | Result |
|---|---|---|---|---|
| — | — | — | — | not run yet |

## 9. Deviations and known limitations

### 9.1 Deviations from the plan (documented as built)

- **W1:**
  - A `[release]` subject line starts the dry run: GitHub offers a manual run only for a workflow on the default branch, and `main` has none.
  - The userland's licence texts are a committed asset that CI checks, not a build step's output.
  - About shows the offer's own words, not a link.
  - The archive holds more than the recipes: Termux's build system, and the upstreams' patches that a build step downloads.
- **W2:**
  - Window sizes travel as frames on the launcher's stdin, not on a FIFO.
  - Output goes through a Flutter API, not an event channel.
  - `TERMINFO` joins the terminal's environment.
- **W3:**
  - The protocol grew beyond the plan's list, for one page with many sessions.
  - Touch and the input method's text are the page's own, since xterm.js's own paths garbled Gboard's text.
  - No fallback input line was needed: nothing was lost.
- **W4:**
  - Ruby and Perl run too.
  - Files a run changed are copied again, so every run starts from the folder.
  - npm 12 runs no dependency's install script unasked, so the banner shows when node-gyp, prebuild or pip do run and fail.
- **W5:**
  - The OOM score is not raised on API 26 to 28, where the kernel refuses it.
  - Every view lets go in the background, not only the hidden ones.
  - Memory warnings rarely come since API 34.
  - Process death is measured on the emulator, since Test Lab can't kill the app it instruments.
- **W6:**
  - **The memory budget,** as the owner decided: worked down, then judged as the open terminal within 90 MB.
  - **Hybrid Composition++ app-wide,** the editor included, instead of plain Hybrid Composition for the terminal, which would hardly have saved memory (Flutter 3.50's source; the owner's decision of 2026-11-21).
  - The open terminal's figure is taken after 15 s idle.
  - The phone measures a profile build.
  - The emulator draws with the DOM renderer, since its software GPU can't keep up with WebGL.
- **W7:**
  - **§9's risk table had W4 measure whether node loads a `.node` library from the app's storage, and W4 did not.** `RuntimeCommandsTest` (g) now records it on every target, without judging it (§9.2).
  - **The native-addon text said Android won't run programs written to app storage.** That holds from Android 10, as ExecModelTest measures it (`exec_model_data_exec=denied` on API 34, 36 and the Pixel 8a). On API 26 to 28 the same copy runs (`allowed`). The banner and Settings → Linux runtime now say "Android 10 and later". They suggest pure packages only, since a banner shows when a package found nothing prebuilt and tried to build.

### 9.2 Known limitations, carried forward

- **No binary release** until the owner's keys exist and a qualified person has reviewed THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md.
- **Memory after a flood:** +100.3 MB once settled in W6's judged run (539 MB in all) and +130.2 MB in the exit gate (583 MB in all), against PERFORMANCE's 600 MB for the editor, a terminal and one language server (§1, §7.1).
- **Hybrid Composition++ needs Android 14 or later with Vulkan,** and only the Pixel 8a measured it. Elsewhere the WebViews are composed through the texture layer. With it, before W6's other changes, the open terminal cost 85.2 MB on the 8a (CI 44868218258). The emulator measures that mode.
- **Programs and native addons from the app's storage:**
  - **Programs:** Android 10 and later refuse to run a program written there (ExecModelTest: `denied` on API 34, 36 and the Pixel 8a). On Android 8.0 to 9 it runs (`allowed` on API 26 to 28), as the app's user, as everything in a session runs (SECURITY §1).
  - **Libraries load on every version measured.** Node's `process.dlopen` mapped a library from the runtime's home on API 26, 27, 28, 34 and 36 and on the Pixel 8a, there in 341 ms (exit gate 44900930980, its legs and Test Lab; `RuntimeCommandsTest` g). The test had expected `refused` from Android 10, but Android's rule covers running a program, not mapping a library.
  - **What that means:** Android lets a prebuilt Android addon that a user's `npm install` fetches (`@rollup/rollup-android-arm64`'s `.node`, for one) load, while a prebuilt program (`@esbuild/android-arm64`'s) runs only on Android 8.0 to 9. Those two packages were not run; the test loads a library of CodeForge's own. Play's Device and Network Abuse policy says an app may not download executable code, "such as dex, JAR, .so files", from a source other than Google Play, and exempts code run by an interpreter. The app downloads nothing itself, but this is the owner's to review before the first submission (§10).
- **No compiler** (the build-tools pack comes later), so native addons can't be built. **No 32-bit ARM build.**
- **Sessions end with a force-stop or a reboot.** Process death and its tombstones were measured on the emulator only, and removing the app's task is not measured: the phone checklist covers both.
- **The phone's terminal panel** opens at half and maximizes from its menu, but has no control for its peek stop, and is not yet the draggable sheet ARCHITECTURE §5 describes. vim and htop are not in the runtime.
- **Firebase Test Lab shuts down on 2027-09-30.** What runs the arm64 tests after it is in ROADMAP's decision queue.
- **Physical-phone figures come from one Pixel 8a.** The owner's phone adds a second (§8).

### 9.3 Gate history

- **W1:**
  - CI 44377396101: libdb's licence text was missing under its name, and a widget test loaded an asset inside `runAsync`.
  - Dry run 44389009942: mirrors.kernel.org timed out, so the archive failed closed; hence the mirrors.
  - Dry run 44394419519: a pipe race in the signer check, and fossies.org's HTTP 401.
  - Gate 44405049032: its quality job hit Maven Central's HTTP 429 and passed on a re-run.
- **W2:**
  - Gate 44454605348: End all returned before the places were free, and API 26's next start was refused.
  - Gate 44461809588: all five legs passed. The emulator failed fetching Gradle's Kotlin library (transient), then in the watch group: a batch of outside changes under way when the app went to the background took a change in while away.
- **W3:**
  - CI 44516067221: two panel tests.
  - Gate 44520440304: the test binding dropped the device's own touches.
  - Gate 44557551890: a tap the page canceled never focused the WebView.
  - Gate 44575917666: Gboard's text garbled through xterm.js's own paths; hence `ime.ts`.
  - Gates 44589259655 and 44596547784: Gboard finished compositions it did not start; the scripted suite now runs with the input methods off.
  - Gate 44588484255 was canceled for the next fix.
- **W4:**
  - CI 44619907768 to 44687566636: a test in the first slice, an icon's name, and a cancelled subscription awaited in the root zone, which hung every folder run in the widget tests.
  - Gate 44690833991: npm 12 prints no script banner.
  - Gate 44697552696: npm 12 runs no install script unasked.
- **W5:**
  - CI 44732997918: API 31's call failed the API floor, though behind a version check.
  - Gate 44735804283: the gate's driver answered a stale request.
  - Gate 44744464658: part A was judged before the kill was recorded.
  - Gate 44752660910: the hub published READY while the install still held the prefix (API 27 and 34).
  - Gate 44763350329: npm's update notice reached a run's output, and the explorer's driver answered the folders group's pick.
- **W6:**
  - CI 44804897631: Riverpod 3 exports `Override` from `misc.dart`.
  - Gate 44807458944: WebGL's first erase on the emulator's software GPU took over 2 s.
  - Test Lab 44818854015 and 44863955928: UiAutomation's shell turned accessibility on, and Flutter's test binding failed on the semantics it left ("A SemanticsHandle was active"). The phone's driver now asks for no accessibility on API 33 and later.
  - Test Lab 44868218258: the memory, 85.2 MB over 80, which went to the owner.
  - Test Lab 44889362793: the memory after the work, judged by the old rule: open 53.6 MB, but 114.8 MB after the flood. Then the judge changed as the owner had decided.

## 10. Next-phase readiness (Phase 6 — Language intelligence), and the owner's decisions

**Ready for Phase 6:**
- a language server can run as a runtime process, under the same launcher, limits and process-tree ending as a session, with the foreground service keeping it in the background;
- node 26.13.1 and python 3.14.10 at their pins, proven on API 26 to 36 and arm64;
- the editor protocol, ready for diagnostics and completions;
- memory measured, with the line it leaves (§9.2).

**For the owner:**
1. **Accept Phase 5,** or ask for changes.
2. **The phone session:** PHASE_5_PHONE_CHECKLIST (about 35 minutes) on the exit gate's APK (§6), with PHASE_3_PHONE_CHECKLIST (about 75) and PHASE_4_PHONE_CHECKLIST (about 20), which can use the same APK.
3. **The first release** (BUILD_AND_RELEASE §5):
   - the upload key and the release key, as eight repository secrets;
   - whether Play's app signing key is the release key;
   - the licence review.

   Then the agent adds the tag trigger, and a `v<version>` tag makes a draft GitHub Release.
4. **Play** ([docs/store/README.md](../store/README.md)):
   - the developer account, Play App Signing, 15 to 20 testers and a contact address;
   - the privacy policy's three placeholders;
   - the special-use declaration, drafted in listing.md;
   - **Play's rule on downloaded executable code:** a user's `npm install` can fetch prebuilt Android addons and programs. The app downloads nothing itself, but W7 measured that node loads such an addon from the app's storage on every Android version tested, while a fetched program runs only on Android 8.0 to 9 (§9.2). The owner reviews it before the first submission: whether a user's download through the terminal falls under the rule, and if so what the app must do (for example, say so in the listing, or refuse to load libraries from the app's storage).
5. **Later:** what runs the arm64 tests after Test Lab, before 2027-09-30.
