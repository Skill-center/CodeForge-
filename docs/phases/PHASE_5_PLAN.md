# Phase 5 Plan — Terminal & Execution

**Status:** **Built, awaiting the owner's acceptance** (W1 to W7 done; [PHASE_5_REPORT.md](PHASE_5_REPORT.md)). Proposed on 2026-11-18, the day Phase 4 was accepted. **W1 done on 2026-11-18** (CI 44381310978 and 44399784786, whose release dry run passed whole; phase gate 44405049032; see *As built (W1)*). **W2 done on 2026-11-19** (phase gate 44475934378 on API 26 to 36, and Test Lab's arm64 phone in CI 44482754814; see *As built (W2)*). **W3 done on 2026-11-19** (phase gate 44606021478's terminal group on API 36: typed text echoes through Gboard, nano and top fit the panel after turns, the composition suite loses nothing; see *As built (W3)*). **W4 done on 2026-11-20** (phase gate 44707562888's run group on API 36: files and an npm script with their exact output and exit codes, Stop with no process left, the native-addon banner, the E2E scenario part 1, and the gate folder through its copy, 1,006 files first in 4.8 s and then in half a second, with export; see *As built (W4)*). **W5 done on 2026-11-20** (phase gate 44777091949: the foreground service with the first session and gone after the last, *End all* from its notification with no process left, the limits measured on API 26 to 36, and in the real app five and a half minutes in the background, process death with no process left and the tombstones after it; `SessionServiceTest` 4/4 on Test Lab's Pixel 8a with Android 14 in CI 44786509685; see *As built (W5)*). **W6 done on 2026-11-21: measured, G6 met but for the memory budget, then the memory worked down the same day and judged as the owner decided** (Test Lab's Pixel 8a, in a profile build, CI 44868218258: with WebGL, now the page's renderer, input to echo 48.4 ms at the 95th percentile and the 10 MiB flood whole in 3.0 s with 0.5 % of Flutter's frames over 32 ms; the terminal 85.2 MB more with it open at its full stop and 153.7 MB once settled after the flood, against 80 MB; phase gate 44870622961 passed whole with the emulator's figures, the composition suite 10/10, and nano, top, less and the node REPL fitting the panel across the turns. **The owner's decision** (§10, item 7): work the memory down, then judge what remains as found. With Hybrid Composition++, the host's messages through a MessagePort and WebGL for the shown session only, CI 44889362793 on the same phone: the terminal open 53.6 MB, within 80 MB, 114.8 MB once settled after the flood; echo 37.5 ms, none of Flutter's frames slow in the flood; phase gate 44883909195 whole. Test Lab's judge as decided, the terminal open within 90 MB and a flood's growth recorded, passed whole in CI 44893095694: open 55.3 MB, settled after the flood 100.3 MB, echo 37.2 ms; see *As built (W6)*). **W7 done on 2026-11-21** (the docs synced, ADR-0014 as built, PHASE_5_REPORT and PHASE_5_PHONE_CHECKLIST, and two corrections the last pass found; the exit gate on every target; see *As built (W7)*). **The owner's decisions on 2026-11-18** (§10): start with W1; the release build gets network access from Phase 5; the release workflow runs dry until the owner adds the keys; the owner arranges the licence review, and no public binary goes out before it · **Spec reference:** §8 Phase 5 (terminal and execution), §6.4 (the terminal connects to the existing environment), §6.5 (the capability model), §7 (security), §10 (the end-to-end scenario) · **Architecture:** [TERMINAL_ARCHITECTURE.md](../TERMINAL_ARCHITECTURE.md), [ADR-0006](../adr/0006-terminal-frontend.md) (xterm.js), [ADR-0013](../adr/0013-folders-and-the-runtime.md) (a folder runs in a copy), [SECURITY.md](../SECURITY.md) §2, [RUNTIME_INTEGRATION.md](../RUNTIME_INTEGRATION.md), [ADR-0010](../adr/0010-distribution.md), [ADR-0011](../adr/0011-license.md) · **Builds on:** Phase 4 ([report](PHASE_4_REPORT.md)): the sealed runtime, its exec model and launcher, search

---

## 0. Carried in from Phase 4 and the owner

**From Phase 4** (PHASE_4_REPORT §9.2, §10):
- **The exec model is built for one-shot commands only.** The launcher `libcodeforge-spawn.so` starts each command in its own session and process group, as a child subreaper. It ends the whole tree after an exit, a time limit or an end, and sets no core files. Commands get a time limit of 100 ms to 10 min and an output cap of 1 KiB to 1 MiB. The environment is built from nothing (SECURITY §2.1, E1–E8).
- **SECURITY §2.1's "not yet" list, which this phase must close before it runs code the user wrote:**
  - the session cap (8) and a bounded pool for the commands' threads;
  - CPU-time, file-size and process-count limits and the OOM-score adjustment, each measured with bionic and Android's cgroups before it is set;
  - the foreground service with "kill all", and what becomes of the processes when Android ends the app;
  - output coalescing for the terminal.
- **ADR-0013:** a folder from shared storage runs in an incremental, one-way copy made in Kotlin, with *Import as project* beside it and an explicit export of what a run wrote.
- **Before the first binary goes out** (SOURCE_OFFER.md, ADR-0010):
  - the source archive, built by a release workflow;
  - the written offer in the app's About;
  - the userland's licence texts in the app's licence page;
  - a licence review by a qualified person.

  PHASE_4_REPORT §10 proposed the first three for this phase's first work package, so that Play's closed test can start early.
- **Measured, not met yet:** a folder's first search took about 10 s for 1,007 files on the emulator, against about 5 s after it (PHASE_4_REPORT §7.2). The owner's phone session will time it on a phone.
- **Pending with the owner:** the Phase 3 and Phase 4 phone checklists, on one APK (gate 44332891340, kept until 2026-12-18). Also the Play account, Play App Signing, the testers, and the privacy policy's three placeholders.

**The owner's standing rules:**
- **Test Lab:** a change goes through CI first. Only after that run is green does a separate commit with `[testlab]` in its subject run it on a phone (BUILD_AND_RELEASE §4). 5 physical tests a day.
- **CI and the phase gate are one workflow;** a `[phase-gate]` push gives one run.
- **t1's code may be changed,** as recorded patches in `native/patches/`.

**Verified while planning (2026-11-18):**
- **xterm.js on npm:** `@xterm/xterm` 6.0.0 (2025-12-22, MIT, no dependencies). Its addons, MIT and dependency-free: `addon-fit` 0.11.0, `addon-unicode11` 0.9.0, `addon-search` 0.16.0, `addon-web-links` 0.12.0 and `addon-webgl` 0.19.0. `addon-canvas` 0.7.0 supports xterm 5 only, so the renderer is xterm's DOM renderer or WebGL.
- **Foreground services on Android 14 and later:**
  - A foreground service must declare its type, with that type's permission.
  - For apps targeting API 35 and later, the `dataSync` type is capped at 6 hours in any 24, after which the system stops it ([Android Developers: foreground service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout)).
  - `specialUse` has no time limit. It needs a `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` in the manifest and a justification in Play Console at submission.
- **Play's Data safety:** a transfer to a third party "based on a specific user-initiated action, where the user reasonably expects the data to be shared" is exempt from disclosure. That is what a user's own `npm install` or `git clone` is (§10, item 4).
- **The payload's full-screen programs:** `nano`, `top` (procps), `less` and `dialog` ship, as do the node and python REPLs. vim and htop don't (THIRD_PARTY_NOTICES §5). TERMINAL_ARCHITECTURE's rotation test, written for vim and htop, uses these instead.
- **Pigeon 29.2.0,** the app's pin, generates event channels as well as host and Flutter APIs.

## 1. Objectives

1. **A real terminal.** Several sessions at once on the sealed runtime, through a PTY that CodeForge writes itself (clean-room, AGENTS §4), shown by xterm.js in the workbench. On phones it sits in a bottom sheet, and on tablets in a docked panel.
2. **Run.** Run the current file or the project: JavaScript, Python, shell, Ruby, Perl, and the project's npm scripts. It works in projects, and in folders through ADR-0013's copy. The output, the exit status and a stop that leaves nothing running come with it.
3. **Safe under load.** A 10 MB flood without a frozen UI, every session ending clean, a session cap, measured resource limits, and a foreground service with *End all*.
4. **The end-to-end scenario, part 1** (TESTING.md, from spec §10), in every phase gate: open a project, create a file, edit, save, run, read the output, edit, run again. The commit, part 2, is Phase 7's.
5. **The native-addon limitation, explained where users meet it.** `npm install` or `pip install` of a package that needs a compiler is detected, and the app says why it can't work and what to use instead (SECURITY §2).
6. **Ready to distribute.** A release workflow builds and signs the App Bundle and an APK, and builds the source archive. The app shows the source offer and the userland's licences. GitHub Releases and Play's closed test can then start when the owner is ready.

## 2. MVP 5 definition (ROADMAP)

ROADMAP's row: a write, run, output loop, with multiple sessions, Run File and Run Project (JS, Python, shell), flood-safe, kill-clean, the E2E scenario's part 1, and the native-addon limitation shown in the app.

**In scope:** the items above, ADR-0006's terminal budgets on an arm64 phone, the release workflow (ROADMAP's Phase 10 still holds the public v1.0.0).

**Out of scope:** language servers (Phase 6), the git UI (Phase 7; git works in the terminal), debugging (Phase 9), the build-tools pack and any compiler, 32-bit ARM, extensions (Phase 8).

## 3. Technical implementation (work packages)

### W1 — The release workflow, the source archive, and the licences in the app (1–2 sessions) → G1

**The release workflow** (`.github/workflows/release.yml`; `ci.yml` stays the build authority for every push):
- **Triggers:** a push whose subject line carries `[release]` runs a dry run, like `[testlab]`. `release.yml` is a reusable workflow (`workflow_call`), and ci.yml calls it, so a push still makes one run. **Found when W1 started:** GitHub starts a manual run (`workflow_dispatch`) only for a workflow that exists on the default branch, and `main` has none. Later, a tag `v*` publishes. **The tag trigger stays off** until the owner's keys exist and the owner decides on the first release (§10, item 3).
- **The build:** one arm64 release App Bundle for Play and one arm64 release APK for GitHub Releases, from the same commit.
- **The checks:** `check-bundle-size.py` against Play's 200 MB per-device limit, 16 KB page alignment, the release manifest gate, and the notices being current.
- **Signing:**
  - The App Bundle is signed with Play's upload key, the APK with the owner's release key, both from repository secrets. With Play App Signing, Google re-signs the bundle, so the Play and GitHub builds carry different signatures: a user switches channels by reinstalling. BUILD_AND_RELEASE says so.
  - **A dry run** signs with a throwaway key made in the job, and names it in its output. Nothing from a dry run is published.
- **Publishing,** only from a tag with the keys present: a draft GitHub Release, which the owner publishes. It holds the APK, the source archive, `SHA256SUMS`, THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md. The App Bundle stays a workflow artifact, for the owner to upload to Play (the API upload is left for later).

**The source archive** (`runtime/sources.py`, CodeForge's own, with fixture tests and no network in the tests). For every copyleft package version in the payload (SOURCE_OFFER's table, 55 today):
- **The recipe:** Termux's recipe at that version. In a blobless clone of `termux/termux-packages`, it is the commit whose `build.sh` (the parent's, for a subpackage) has the pinned version and revision. The archive takes the recipe's folder at that commit: `build.sh` and its patches.
- **The upstream source:** fetched from the recipe's source URL and verified against the recipe's SHA-256.
- **The result:** one tar, `codeforge-<version>-sources.tar`, with a manifest (package, version, recipe commit, upstream URL, both hashes) and a README.
- **It fails closed:** a package whose source can't be found or verified fails the release, naming it.
- **Cached** under the pins' hash, as the payload's inputs are. The pins are already the payload's record, so nothing new is pinned.

**In the app:**
- **Settings → About** gets the written offer (who, what, for how long, and where: the release's source archive, or a request through the repository's issues until the owner names an address) and CodeForge's own licence.
- **The licence page** (Flutter's `showLicensePage`) also lists:
  - **the editor page's packages,** whose texts the editor build already writes;
  - **the userland's packages** with their licence texts. A build step writes those texts from the payload's licence files into an asset beside the userland archive, so they show before the runtime is installed. The host serves them, and Dart registers them with `LicenseRegistry`.

**Not in W1:** the first real release. That waits for the owner's keys and the licence review (§10, item 3).

**As built (W1):**
- **G1 met by the release dry run CI 44399784786,** all four jobs:
  - **The App Bundle and the APK,** arm64, signed with throwaway keys. All seven checks passed (`release_checks=pass`). The figures, the same in each dry run (CI 44389009942 for the detail):
    - Play's per-device size: 146.2 MB, 73.1 % of the 200 MB limit (97.5 MB shared and 48.7 MB of libraries).
    - The APK: 149,579,340 bytes, carrying arm64's payload (260 native libraries, 252 executables).
    - 16 KB alignment: 258 of 258 objects, under `--require-compliant`. The risk that arm64's Termux libraries were not aligned did not happen.
    - The release manifest: INTERNET and androidx.core's own permission, nothing else.
    - The notices are current, and each file has one signer, the expected key.
  - **The source archive,** 261,662,720 bytes: 55 package versions, 69 upstream files, each verified against its recipe's SHA-256, and Termux's tree at 42 commits. It took 10.6 minutes with its cache warm (SOURCE_OFFER.md, *As built*).
  - **The checksums:** `SHA256SUMS` over the APK, the archive and the two notices, and a report with the App Bundle's checksum. Nothing was published.
- **The phase gate 44405049032 passed.** The emulator's 22 group runs passed on their first attempt (cold start 1,140 ms), and so did the five runtime legs, API 26 to 36. Its quality job hit Maven Central's HTTP 429 in every Gradle build and passed on a re-run (attempt 2); the commit under it changed docs alone.
- **The app:** About shows the offer, CodeForge's licence, and the userland's texts on the licence page. CI 44381310978: `+895: All tests passed!`, ten more than before (the offer against SOURCE_OFFER.md, the bundled licence, the userland file's parser, both screens).
- **Deviations, and why:**
  - **The userland's texts are a committed asset,** not a build step's output that the host serves. runtime/notices.py writes `app/assets/licenses/userland.txt` from the pinned packages' own licence files, and CI checks it against the pins as it checks the notices: 112 package versions, 67 distinct texts, 645 KB. Dart reads it from the app's assets, so it shows before the runtime is installed, needs no Kotlin or Pigeon change, and a change to it is reviewed like any file.
  - **About shows the offer's own words,** not a link to SOURCE_OFFER.md, so the offer is there offline. A test holds the app's paragraphs and SOURCE_OFFER's quotation to the same words.
  - **The archive holds more than the recipe folders:** also Termux's build system at every commit and at the bootstrap's tag, an upstream's patches that a build step downloads (reviewed, `STEP_DOWNLOADS`), and dpkg's Git source as a reproducible tar. SOURCE_OFFER had promised Termux's build scripts.
  - **The cache is keyed by the pins' and the offer's hash,** each file under its SHA-256, and a run starts from the newest entry.
  - **A release's tag must be the app's version,** because About names the archive `codeforge-<version>-sources.tar`.
- **What the work found:**
  - **libdb's licence text was missing under its name.** Its `copyright` links to `AGPL-3.0-only.txt`, a name termux-licenses 2.2 introduced in August 2026, while the payload carries the bootstrap's 2.1, which has the same text as `AGPL-V3.txt`. Phase 4's check had taken every link target as present; writing the app's file follows each link, and failed (CI 44377396101). notices.py records the rename (`RENAMED_TEXTS`), checked both ways, and THIRD_PARTY_NOTICES marks the row.
  - **Hosts fail, so the archive has mirrors.** mirrors.kernel.org, which 36 of the 69 files name, timed out on the runner (CI 44389009942). fossies.org answered HTTP 401 (CI 44394419519). nano's `latest/` no longer holds the pinned 8.7.1. `sources.py` tries hosts that serve the same files (`MIRRORS`), and accepts a file only with the recipe's SHA-256, so the archive is the same bytes whichever host answered. 53 of the 68 archives have one.
  - **A pipe race failed a verified bundle once:** `printf | grep -q` under pipefail in the signer check (CI 44394419519). The script now reads through here-strings, and its `--self-test` (8 cases, the race first) runs in a new quality gate, *Release scripts*.
  - **A widget test that loaded an asset inside `runAsync`** left the screen waiting on a future of the real zone, which the fake clock never runs (CI 44377396101). The test binding serves assets synchronously, so the load needs no help.

### W2 — The PTY and terminal sessions (2 sessions) 🔑 critical path → G2

**The PTY, clean-room** (AGENTS §4; written from POSIX and Linux's man pages, with no Termux code):
- **The design, decided at W2's start with a measurement,** recorded in TERMINAL_ARCHITECTURE and a new ADR-0014:
  - **(a) The launcher makes the PTY.** `libcodeforge-spawn.so` gains a terminal mode. The launcher opens the PTY pair (`posix_openpt`, `grantpt`, `unlockpt`, `ptsname`) and starts the shell on the slave as the session's leader with it as the controlling terminal (`setsid`, `TIOCSCTTY`). It then relays between the master and its own stdin and stdout. Window sizes arrive on a small FIFO in the session's folder (`TIOCSWINSZ`, and the kernel sends `SIGWINCH`).
    - The launcher already leads each command's tree as a subreaper and ends it whole (SECURITY §2.1, E4), so terminal sessions get the same guarantees with no second mechanism.
    - Nothing forks inside the app's process: the host starts the launcher as it starts commands today.
    - The relay is plain C, tested on CI's Linux machine with real PTYs, as `test-spawn.py` tests the launcher today.
  - **(b) JNI forks the shell** from the app's process and hands the master to Kotlin (Termux's shape, which `termux.c` implements and CodeForge may not copy). It saves the relay's copy, but forks inside ART's multithreaded process, and needs the tree's end built twice.
  - **(a) is the plan's choice.** W2's first step measures what the relay adds to a keystroke's echo on the emulator. If (a) can't stay well inside ADR-0006's 50 ms, (b) is built instead, and the ADR says why.
- **The session** (Kotlin, CodeForge's own):
  - `TerminalSession` holds the launcher process and an output ring buffer that keeps the screen while the view is detached (1 MiB by default).
  - The session's specification is TERMINAL_ARCHITECTURE's: a folder, environment overrides, the shell, rows, columns and the scrollback.
  - The shell is the runtime's `bash -i` with CodeForge's own rc file: a prompt, and the user's `~/.bashrc` sourced if there is one. If bash can't start, the session says so; it never falls back silently.
  - The environment is E2's, with `TERM=xterm-256color` and `COLORTERM=truecolor` instead of `dumb`.
- **SessionRegistry grows to interactive sessions:**
  - ids, the cap (8: the ninth is refused with a typed failure), and a bounded pool for the commands' threads;
  - each session's state: starting, running, then exited with a code or a signal;
  - input, resize, end (the launcher's `SIGTERM` then `SIGKILL`), and *End all*.
  - **E3 widens with care:** a terminal may start in an open project's folder, which the host names itself, never a path from Dart. A folder from shared storage runs in its copy (W4).
- **Output to Dart:**
  - **Batching:** output goes in batches of up to 16 ms (at most 60 a second). The first bytes after a quiet moment go at once, so an echo never waits for a batch.
  - **Flow control by credit:** the page acknowledges what xterm.js has written (its write callback), and the host stops reading from a session that runs out of credit. A flooding program then blocks in the kernel's PTY buffer: nothing is lost and memory stays bounded.
  - **The API:** Pigeon's host API for the commands, with an event channel or a Flutter API for the output (W2 picks one).
- **Tests:**
  - **The launcher's terminal mode** on CI's Linux machine (`runtime/tests/`, real PTYs through Python's `pty` and `termios`): echo, `stty size` after a resize, Ctrl-C reaching the foreground job, the exit code, the tree ended after an end, and a flood through the relay with flow control.
  - **JVM:** `TerminalSession` and the registry with real processes, as `CommandRunnerTest` runs them.
  - **Instrumented, on every runtime leg (API 26 to 36) and the Test Lab phone:** `TerminalSessionTest`, which checks that
    - bash echoes;
    - `stty size` follows a resize;
    - node's REPL answers `1+1`;
    - a 10 MB flood arrives whole, with the host's memory bounded;
    - the ninth session is refused;
    - *End all* leaves no process.

**As built (W2):**
- **G2 met:**
  - **The launcher's terminal mode on CI's Linux machine:** `runtime/tests/test-pty.py`, 19 tests, in CI 44445690182 and every run since. Nine broken copies of the launcher each fail some of them.
  - **`TerminalSessionTest` on the runtime legs:** API 26 to 36 in phase gates 44461809588 and 44475934378 (seven tests a leg, and the seven figures the gate requires).
  - **`TerminalSessionTest` on the arm64 phone:** Test Lab in CI 44482754814 (`e2e0f59`), on a Google Pixel 8a (`akita`) with Android 14. All seven passed, among 25 test cases, with the seven figures:
    - echo p50 3.85 ms, p95 8.38 ms;
    - the 10 MiB flood whole in 1.04 s (43 batches), never more than the window unacknowledged;
    - End all in 112 ms, leaving no process;
    - node's prompt in 493 ms.
- **The design is (a), the launcher's terminal mode** (ADR-0014). On the emulators a keystroke's echo through the whole host path took p95 0.68 to 5.12 ms over the three phase gates (44454605348, 44461809588 and 44475934378). The relay alone adds about 0.12 ms on Linux. ADR-0006's budget is 50 ms.
- **What was built** (TERMINAL_ARCHITECTURE §1, SECURITY §2.2):
  - **The launcher** opens the PTY and relays, under a framed protocol on its stdin: input, and window sizes.
  - **`TerminalSession`:** a 1 MiB ring buffer, batches at most every 16 ms with the first bytes at once, credit flow control with a 256 KiB window, and a writer thread.
  - **`Terminals`:** the spec's checks, and bash with CodeForge's rc file.
  - **`SessionRegistry`:** the cap of 8, End all, and a sweep of the shell's session as the last resort.
  - **The environment:** the terminal's four variables.
  - **The rest:** a bounded command pool (16), the Pigeon API with a Flutter API for output, the host, and Dart's client. The workbench keeps the honest fake until W3's view.
- **Evidence:**
  - **test-pty.py:** CI 44445690182.
  - **JVM and Dart:** the bootstrap run 44451456079, `kotlin_tests=161` (23 more: `TerminalSessionTest`'s 22 and one in `RuntimeHubTest`), and `+902: All tests passed!` (7 more: the Pigeon client, the fake, the codes). After the watch fix, the bootstrap run 44474274477: `+904: All tests passed!` (its two tests), `kotlin_tests=161`.
  - **The phase gates:**
    - 44454605348, which found End all's race on API 26;
    - 44461809588: all five legs passed. Its emulator gate failed twice: first fetching Gradle's Kotlin library (a transient failure), then in the watch group (the finding below);
    - 44475934378, after the watch fix: everything passed, the watch group at its first attempt and a cold start of 1,344 ms (median of 10).
- **Deviations, and why:**
  - **Window sizes travel as frames on the launcher's stdin,** not on a FIFO: a resize keeps its order among the keystrokes, and a session needs no file.
  - **Output goes through a Flutter API** (`TerminalEvents`), as the runtime's and search's events do. The credit window already bounds what is in flight, so an event channel's buffering would add nothing.
  - **`TERMINFO`** joins the terminal's environment: Termux's ncurses looks for its descriptions under Termux's own prefix.
  - **The instrumented class installs a payload of its own** (`files/runtime-gate/terminal`), as `RuntimeCommandsTest` does, so neither depends on the other's order.
- **What the work found:**
  - **On the phone a keystroke's echo takes about ten times as long as on the emulators:** p95 8.38 ms. The emulators' median p95 was 0.88 ms, over the fifteen legs of the three phase gates (0.68 to 5.12 ms). The phone's figure is still 17 % of ADR-0006's budget.
    - Each sample follows 40 ms of quiet, as between keystrokes. The echo then wakes several threads in turn: the host's writer, the launcher, the kernel's terminal work, the launcher again, and the host's reader. Idle cores are the likely cause; this was not measured further.
    - W6 measures the whole path, with xterm.js, on the phone, against the rest of the budget.
  - **A batch of outside changes under way when the app went to the background took a change in while away** (phase gate 44461809588, the emulator's watch group; Phase 3 W5's code). Going away cancelled the batch's timer, not a batch already listing a folder, which then checked the open documents and reloaded a clean one. The batch now stops when the app is away, and a check under way takes nothing in once the app is away (`checkDisk`'s `active`). Coming back lists every folder and checks every document anyway. Two tests hold the fake service's listing or stat until the app is away.
  - **End all returned before the places were free.** A session gives its place back when its reader has finished, a moment after its launcher exits. On API 26 the next start came first, and was refused (phase gate 44454605348, test g). `endAll` now waits for the sessions to be finished too, and the JVM test checks that the places are free when it returns. Without the fix that check failed in 7 of 8 runs.
  - **An end must reach a session whose view stopped acknowledging.** A reader waiting for credit would never see its launcher's end-of-file. It now reads freely once the session is ending, and, after the launcher has exited, once the view has been silent for 2 s. Found while writing the flood test; the JVM test *anEndFromTheRegistryReachesASessionWhoseViewStoppedAcknowledging* holds it.
  - **The Kotlin is checked locally before CI:** the Kotlin compiler (npm's `kotlin-compiler`, 2.4.21, against the project's 2.4.20) and a Java runtime (PyPI's `jdk4py`) type-check the runtime package against stubs, and run `TerminalSessionTest` with real processes. Thirteen of fourteen broken copies of the Kotlin each failed some of its tests; the fourteenth is equivalent (bash without `-i` is interactive on a terminal anyway).

### W3 — The terminal view: xterm.js in the workbench (2 sessions) → G3

**The page:**
- Built in the `editor/` workspace, as a second page beside the editor's. It uses the same page kit (`page_kit.mjs`: a single HTML file, inline script and style, a CSP with the script's hash, the licence gate) and the same toolchain and lockfile. It builds into `app/assets/terminal/` (REPOSITORY_STRUCTURE planned that folder).
- **Dependencies,** each with AGENTS §5's justification paragraph (Android and ARM64, licence, maintenance, offline, size), an exact pin and the lockfile:
  - `@xterm/xterm` 6.0.0;
  - `addon-fit` 0.11.0, which sizes the terminal to its panel;
  - `addon-unicode11` 0.9.0, for wide characters and emoji;
  - `addon-webgl` 0.19.0, if W6's measurement shows the DOM renderer can't keep a flood smooth in the WebView.
  - `addon-search` and `addon-web-links` wait unless needed: W4's `file:line` links use xterm's own link API.
- **The terminal protocol v1,** in the editor protocol's style: a versioned envelope, a strict validator, typed failures, and contract fixtures shared by vitest and the Dart tests.
  - From the host: `write` (with a sequence number), `theme`, `focus`, `paste` and `clear`.
  - From the page: `ready`, `input`, `resized` (columns and rows, from `addon-fit`), `ack` (flow control), `title`, `bell` and `link`.

**In the app:**
- `TerminalService`'s real implementation (Pigeon types only in `services/terminal/native`), a terminal controller for the sessions and tabs, and the terminal surface.
- **One WebView** holds an xterm instance per session. Android's WebViews share one renderer process, so the terminal adds its page's memory rather than a process. ADR-0006's budget, a delta of 80 MB or less, is measured in W6.
- **The UX** (TERMINAL_ARCHITECTURE §3), on the three-stop sheet that the terminal pane has had since Phase 1:
  - tabs, to make, rename and close a session (closing a running one asks first) and to swipe between them;
  - the extra-keys row (Esc, Ctrl, Alt, Tab, arrows, `|`, `~`, `/`), reusing the editor's symbol toolbar;
  - copy and paste through xterm's selection and Flutter's toolbar, with pasted text sanitized and bracketed paste honoured;
  - the design tokens' themes, and the bundled monospace font.
- **IME:** xterm.js reads input through a hidden textarea, whose composition events in Android's WebView need care (Gboard's suggestions and swipe typing). The editor's composition suite is the model: scripted composition events on the emulator, Gboard on the owner's phone.
  - **If composition loses input:** a plain input line (a Flutter text field that sends what is typed) becomes the fallback input mode, and the gap is recorded.

**As built (W3):**
- **G3 met:**
  - **The page's build checks:** CI's editor job (44596547784 and 44606021478, with `Tests 339 passed` in vitest) builds `terminal.html` (547.4 KiB, 174.8 KiB gzipped, against a budget of 256 KiB; three packages) and `verify_terminal.mjs` passes its 22 checks: one inline script, whose SHA-256 the CSP pins; nothing external; the manifest and the budget; the three packages' notices; then a protocol round trip with the real xterm.js. The build is reproducible: the sandbox and CI produce the same SHA-256.
  - **The protocol's fixtures:** 36 valid and 31 invalid, in vitest (`terminal_protocol.test.ts`, 74 tests) and in Dart (`terminal_protocol_test.dart`, 78).
  - **Widget tests:** `terminal_pane_test.dart` (15): tabs (New terminal, a tap and a swipe, rename, close asking first while running), the extra keys (Esc and Tab, Ctrl latched for one key, Alt released by a typed key), Copy and Paste, End all, Maximize, and every stop at three sizes with two terminals open.
  - **The emulator gate's terminal group** (phase gate 44606021478, API 36, Gboard): a tap gives the terminal the keyboard; text typed through Android's input pipeline echoes and runs; nano and top draw at the panel's size in portrait (46×23), landscape (60×7) and portrait again (46×22); the composition suite's ten cases arrive whole; the session closes with no message dropped.
- **What was built** (TERMINAL_ARCHITECTURE §2.1 and §3, SECURITY §3):
  - **The page:** xterm.js 6.0.0 with addon-fit 0.11.0 and addon-unicode11 0.9.0, a terminal per session in one WebView, the DOM renderer. It is built with the editor page's kit, and refused on a WebView older than Chrome 87, as the editor's is.
  - **The terminal protocol v1:** the editor protocol's envelope and rules, a validator on each side and shared fixtures. A write is acknowledged once xterm.js has parsed it, and that acknowledgement is the session's credit (§1.3), so a flood waits in the kernel.
  - **In the app:** `TerminalView` (the page's host); `TerminalController` (sessions and tabs, UTF-8 output, input, sizes, and a page restart refilled from the sessions' buffers); the panel (tabs, the extra-keys row, Copy and Paste, Maximize); and the Pigeon service as `terminalServiceProvider`. The honest fake stays for tests and for hosts without a terminal.
  - **Input:** the extra keys in the terminal's modes; Ctrl and Alt latched for one key; pastes sanitized and bracketed; touch (a drag scrolls, or sends arrows in the alternate screen; a long press selects; a tap focuses); and the input method's text through the page's own path (`ime.ts`).
- **Evidence:**
  - **The bootstrap runs:** 44516067221, where two pane tests failed (a finder sees only the extra keys on screen; the keys row at the peek stop); 44518519957, `+1031: All tests passed!`; 44572951140, `+1033: All tests passed!` (the two Maximize tests), analyze clean, format 288 files with 0 changed.
  - **The phase gates:** 44520440304, 44557551890, 44575917666, 44589259655 and 44596547784 each failed in the terminal group, at the findings below, while every other group and all five runtime legs passed; 44588484255 was canceled for the next fix; then 44606021478 passed whole, every group at its first attempt (cold start 1,028 ms, median of 10; no ANR and no crash).
- **Deviations, and why:**
  - **The protocol grew** beyond the plan's list, for one page holding many sessions and for the app's toolbar: `terminal.configure` (the theme, the font size and the scrollback, in place of `theme`); `session.open`, `activate` and `close`; `session.key` (an extra key, which only the page can map to the terminal's modes); `terminal.modifiers` in both directions (the latched Ctrl and Alt); `session.select`, `session.copy` and `session.selection` (Copy on the app's toolbar); `session.snapshot` (the screen as text, for the tests and the gate); and `terminal.log`.
  - **Touch is the page's own:** xterm.js 6 reads no touch.
  - **The input method's text is the page's,** not xterm.js's: the third finding.
  - **The full stop maximizes docked layouts too,** from the panel's menu: the fourth finding.
  - **No fallback input line:** scripted composition loses nothing, and typed text arrives whole through Gboard. Gboard by hand is on W7's phone checklist.
- **What the work found:**
  1. **The test binding drops the device's own touches** unless the test lets them through (44520440304): the gate's first tap never reached the app. The keys group sets the flag around its touches; the terminal test now does too.
  2. **A tap the page canceled never focused the WebView** (44557551890). The page canceled every touch, to keep the WebView from panning and from synthesizing a mouse; but a WebView takes the app's focus only from a tap it sees, and Chromium dispatches no focus event to a page whose view lacks the focus, so xterm.js's input took the focus without the keyboard or a word to the host. The page now cancels a drag's and a long press's touches only (`touch-action: none` already stops the panning), and the long press's menu.
  3. **The input method's text garbled through xterm.js's own paths** (44575917666): `echo cf-typed-ok`, typed through Android's input pipeline, arrived as `echohoocf--ttypped-ok`. xterm.js reads its textarea three ways, and for keyCode 229, which every key of an Android input method carries, it diffs the textarea's text on a timer with String.replace; those timers raced its composition sends. `ime.ts` now owns the input method's text: what is committed is sent once and in order, then the textarea is emptied. In headless Chromium the sequences that garble the old page arrive exactly. On the emulator, Gboard's keys (a 229 and an `insertText` per character) echoed whole (44606021478, and 44589259655 and 44596547784 before it).
  4. **Beside the editor, a phone on its side left an open terminal a row or two,** or hid it. The dock's cap keeps 320 dp for the chrome and the editor, and the body is about 360 to 410 dp. Maximized, the terminal now takes all but the chrome and a 48 dp peek of the editor (7 rows in the gate's landscape).
  5. **Gboard comes up beside the emulator's hardware keyboard** (44575917666's photograph of the first tap), and it left the panel 46×8. It also finishes any composition it did not start while it is connected to the focused input, shown or not, so the scripted suite lost nine of its ten cases, each step sent as committed: with the keyboard up (44589259655), and again with it down (44596547784). The test measures the panel with the keyboard down, as the keyboard key leaves it, and the driver plays the scripted suite with the input methods off (`ime disable`, then back on). The editor's suite, whose page is never tapped, has none connected.
  6. **DevTools lists a page loaded with loadHtmlString without its base URL,** as the editor's drivers had found; the composition driver, looking for the URL, would never have found the page. It looks for the page's title, and the gate's probe records each tap and typed text (the events the page saw, and its focus).
  7. **The page is checked in a real browser before CI:** headless Chromium 153 (npm's `@sparticuz/chromium`, with its own NSS) runs the built page with touch emulation and DevTools' input methods. The composition suite, the touch gestures, Android-like input sequences and a hardware keyboard with Shift all pass there.

### W4 — Run: files and projects, folders through a copy (2 sessions) → G4

- **Run Current File** and **Run Project,** through the capability model (`core/editor/capabilities.dart`, where Run has waited since Phase 2):
  - **Profiles by extension:** `.js`, `.mjs` and `.cjs` with node; `.py` with python; `.sh` with bash; `.rb` with ruby; `.pl` with perl.
  - **Run Project:** a `package.json` script (`npm run <script>`, picked from a list), or the project's entry file.
  - **Each run is a terminal session,** with a status chip (running, exit *N*, or ended by a signal) in the status strip and the Run panel.
  - **Output links:** `file:line` in the output opens the editor at that line, through xterm's link API.
  - **Stop** sends `SIGTERM`, then `SIGKILL` after the grace period, to the whole tree (E4).
  - **Unsaved changes are saved before a run,** a setting that is on by default.
- **Folders (ADR-0013):**
  - **The copy:** the incremental one-way copy runs in Kotlin, reading four files at a time like W6's scan, with `.git` left out. Its size and count caps are set from W4's measurements, and the copy says what it left out.
  - **The run happens in the copy.** The Run panel lists the files a run created or changed, with *Export to folder*.
  - ***Import as project*** sits on Home and in the explorer.
- **The native-addon limitation:**
  - **Detected** in a session's output: npm's node-gyp and prebuild failures, and pip building a C extension with no compiler.
  - **Explained** in a banner on the session: no compiler ships (the build-tools pack comes later), and Android won't run a program written to the app's storage. It suggests what to use instead: pure-JS packages and prebuilt wheels.
  - **Also in Settings → Linux runtime,** where the runtime's other limits are described.
- **The E2E scenario, part 1,** as an integration test in the phase gate: open the demo project, create a file, type a program, save, run it, assert its output, edit it, run it again and assert the new output.

**As built (W4):**
- **G4 met:**
  - **The emulator gate's run group** (44707562888, API 36, in the real app on the sealed runtime): main.js (node), app.py (python) and a shell script give exactly their lines and exit codes 0, 0 and 3; `npm run start` gives exactly its script's three lines and exit 0; Stop ends a node program and the `sleep` it spawned (Signal 1, in 206 ms), and pgrep through the runtime finds none of them left; the native-addon banner shows when npm's node-gyp builds a fixture with no compiler (`gyp ERR! build error`, exit 1); the E2E scenario part 1 passes (a new file, a program typed through the editor page, saved, run: `e2e one`; edited, run again, saved by Run: `e2e one`, `e2e two`); the gate folder, 1,006 files with its 1,000-file `many/`, runs through its copy three times: the first copy took all 1,006 files (4,354 bytes) in 4,781 ms, the second copied nothing in 495 ms, and the third, after the host changed `hello.txt`, copied that one file in 506 ms; the file the run wrote is exported to the folder, and the host's `sha256sum` matches.
  - **Widget tests:** `run_test.dart` (10: each language's program, unsaved changes saved first or not, Stop and the chips, Run Project's choices, the runtime waited for, the palette's keys, the setting), `run_folder_test.dart` (6: the run in the copy and its summary, the files runs made exported, the copy's progress and Cancel, what the copy left out, Import from the explorer, the import's free name), `terminal_links_test.dart` (2: a link opens the file at its line, relative and absolute, and one outside says so; the native-addon banner, once, until dismissed), the import on Home, and Run's profiles (`run_commands_test.dart`, 8), the links (`terminal_links_test.dart` in core, 4) and the banners (`native_addons_test.dart`, 6).
  - **JVM:** `FolderCopyTest` (20) on the storage tests' provider and real files, and `TerminalSessionTest`'s copy (`kotlin_tests=182`); vitest's links and taps (344 tests).
- **What was built** (TERMINAL_ARCHITECTURE §3, ADR-0013's *As built*, SECURITY T3 and T9):
  - **Run:** `core/run/run_commands.dart` (what runs), `application/run/run_controller.dart` (runs as terminal sessions, saved first, followed by their tabs, Stop, a folder's copy, its changes and export), the Run panel (`run_panel.dart`) and the status strip's chip; Ruby and Perl joined the capability model; Settings → Save before running.
  - **The copy:** `FolderCopy.kt` (incremental, one way, `.git` left out, four readers, links never followed, caps counted), the broker's `syncCopy`, `cancelCopy`, `copyChanges`, `exportCopy`, `deleteCopy` and `importTree`, and `TerminalSpec.copy`, resolved by the host like a project.
  - **Links and banners:** the page's `links.ts` (patterns, the link provider, taps), `core/terminal/file_links.dart` (the path in the workspace) and `core/terminal/native_addons.dart` (the patterns, once per session).
- **Evidence:** CI 44619907768 (the first slice, one test failing), 44681887078 (an icon's name), 44683359188, 44685984006 and 44687566636 (the copy's spinner, the runtime page's scrolling, an import), then 44689410417 green; the bootstrap run 44705297317 (`+1072: All tests passed!`, analyze clean, `kotlin_tests=182`); phase gates 44690833991 and 44697552696, which failed in the new run group only (below), then 44707562888 passed whole, every group at its first attempt (cold start 1,125 ms, the median of 10; the three ANRs the device logged at boot are System UI's and Play services', none the app's, and no crash).
- **Deviations, and why:**
  - **Ruby and Perl run too,** beyond JS, Python and shell: the runtime carries them, and the plan's profiles named them.
  - **The copy's caps** are 10,000 files, 512 MB in all and 64 MB a file, at depth 64; the gate's 1,006-file folder (4.8 s for its first copy, half a second for the next) and the projects' sizes so far are far inside them. W6 measures the phone.
  - **Files a run changed are copied again** before the next run, so a run always starts from the folder; only files the folder doesn't have (a run's output, `node_modules`) stay in the copy.
  - **npm's install scripts:** npm 12 no longer runs a dependency's install script unasked, so `npm install` of a package with a native addon may not fail at all; the banner shows when node-gyp, prebuild or pip do run and fail.
- **What the work found:**
  1. **Awaiting a cancelled subscription hung every folder run in the widget tests** (44683359188): its future completes in the root zone, which a widget test's fake time never runs, so the copy's spinner stayed. The copy lets the subscription go without waiting.
  2. **npm 12 prints no `> name@version script` banner here** (44690833991): `npm run start` gave exactly its script's three lines. The check is on the script's own output.
  3. **pgrep counts its own launcher** when the pattern is in its arguments: the patterns are bracketed (`[s]leep 311.7`).
  4. **npm 12 no longer runs a dependency's install script unasked** (44697552696): `npm install` of the fixture never reached node-gyp. The fixture runs npm's own node-gyp.

### W5 — Sessions that last: the foreground service, limits, and process death (1–2 sessions) → G5

- **The foreground service** (`SessionService`), running while any session runs:
  - **Its type is `specialUse`:** a terminal runs for as long as the user lets it, and `dataSync`'s 6-hour cap would end it (§0).
  - **The manifest** names its subtype, and asks for `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_SPECIAL_USE` (install-time) and `POST_NOTIFICATIONS`. That last one is asked at the first session on Android 13 and later; declined, sessions still run, and Android lists the service in its task manager.
  - **The notification** reads "*N* terminal sessions running", with *End all*.
  - **The release manifest gate** allows exactly these three permissions beside androidx.core's own. docs/store (the listing and the privacy policy) say why.
  - **Play Console's special-use declaration** is the owner's, with text the agent drafts (§10, item 5).
- **When Android ends the app anyway:** what becomes of the sessions' processes is measured on the emulators and the Pixel 8a, not assumed. On the next start, each session left a tombstone: "Session ended (exit *N*)", or "ended by the system".
- **In the background:** sessions keep running under the service. The WebView may be destroyed, and on return the host's ring buffer redraws each session. Under memory pressure (`onTrimMemory`), hidden sessions' scrollback is trimmed and their views released. Processes are never killed to free memory.
- **The limits** (SECURITY §2), each measured on API 26 to 36 and the Pixel 8a before it is set, with its value and its reason recorded:
  - **The file-size limit,** so a runaway write can't fill the storage.
  - **The process-count limit,** only if it is safe: on Linux it counts every process and thread of the UID, the app's own threads included.
  - **The OOM-score adjustment** of the sessions' processes, which may only be raised.
  - **No CPU-time limit on sessions,** since a long build is legitimate. Run's one-shot commands keep their time limits.
- **The security review of the terminal boundary,** SECURITY §2.2, like §2.1's for commands: each threat with its mitigation and its proof.

**As built (W5):**
- **G5 met:**
  - **The service, on API 26 to 36** (`SessionServiceTest` a and b in phase gate 44777091949's runtime legs, through the app's own hub): no session, no service. The first session started `SessionService` in the foreground, as Android lists it, 74 to 143 ms after it was asked for; its notification counted 1, 2, then 1 again, and at most 54 ms after the last session's exit the service was gone. On API 34 and 36, which start without the notification permission, the service ran in the foreground without a notification, then showed it once allowed. *End all*, sent through the notification's own action, ended an interactive shell with three jobs (one a subshell's orphan) and a script with two children in 129 to 207 ms, left no process of either tree, and the service stopped.
  - **The real app, on API 36** (phase gate 44777091949's sessions group, `sessions_a_test.dart` and `sessions_b_test.dart`):
    - the service in the foreground with type `specialUse` (`types=0x40000000`) and "2 terminal sessions running", as `dumpsys` shows them;
    - **332 s in the background:** the heartbeat session wrote 326 beats, with no gap over 2 s, the service in the foreground throughout, the app's process at OOM score 200 and the sessions' at 800; back in front, the shown session was drawn again from its buffer, and the shell answered;
    - **memory warnings:** `RUNNING_LOW` let the hidden views go (3.4 s), `RUNNING_CRITICAL` trimmed the two sessions without a view, and nothing ended;
    - **process death:** five seconds after `kill -9` of the app's process, none of the sessions' processes was left (a script, an interactive shell's job). On the next start the tabs showed "exited with code 7" and twice "ended by the system", a new session took id 4, and the service ran with "1 terminal session running" until it ended. After `flutter test`'s force-stop, no process was left either.
  - **The release manifest** (CI 44732997918): `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`, `INTERNET`, `POST_NOTIFICATIONS` and androidx.core's `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`; `SessionService` the only service; `manifest_check=pass`.
  - **The limits, measured before they were set** (`SessionServiceTest` c, API 26 to 36): the app's process has no file-size limit, the kernel's process limit (14,587 to 15,660) and OOM score 0, and its user ran 25 to 27 processes and threads. A session runs with 4 GiB and 2,048, soft and hard, the CPU time unlimited and no core files. A 64 KiB limit stopped a write at 65,536 bytes (`SIGXFSZ`, exit 153), and a process limit 16 above the user's count refused 110 of 120 forks. The score is 800 on API 34 and 36, and stays the app's on API 26 to 28. On the Pixel 8a with Android 14 (Test Lab, CI 44786509685): the app's user ran 31 processes and threads under a kernel limit of 26,185; a session ran with the same limits and its score raised to 800, 2,017 processes of headroom, and both limits enforced as on the emulators. Each value and its reason: SECURITY T14 and T15, TERMINAL_ARCHITECTURE §4.
  - **SECURITY §2.2** is written: T10 to T16, each with its mitigation and its proof, and T7 grew with the hub's READY.
- **What was built** (TERMINAL_ARCHITECTURE §4, SECURITY §2.2):
  - **The service:** `terminal/SessionService.kt`. `SessionService` is `specialUse` on API 34 and later, never restarts itself (`START_NOT_STICKY`), and carries the notification with *End all*. `SessionKeeper` starts it with the first running session and stops it after the last, once it is in the foreground (stopped sooner, API 26 to 28 crash the app). The manifest has the service, its subtype and the three permissions; `TerminalHost` asks for notifications once, at the first session on Android 13 and later.
  - **The ledger and the tombstones:** `runtime/SessionLedger.kt`, written by `Terminals` at each start, exit and removal and read when the command side is made (`RuntimeHub.withTerminals`); the failure code `system`, which Dart says as "ended by the system"; the controller takes the host's sessions and tombstones as tabs when it is made.
  - **Memory:** `RuntimeHost.onTrimMemory`, from `RUNNING_LOW` up, trims the rings of sessions without a view to their last 64 KiB (`Terminals.trimHidden`). The controller lets the hidden views go on Flutter's memory warning (`releaseHiddenViews`), every view when the app is paused (`releaseAllViews`), and draws the shown one again on return (`showAgain`).
  - **The limits:** `runtime/SessionLimits.kt`, and the launcher's `--fsize`, `--nproc` and `--oom-score-adj`, each limit only lowered and the score only raised, reported in the status file.
  - **The gates:** `check_manifest.py` (the permissions and the service), `check_api_floor.py` (the guarded API 31 call), `SessionServiceTest` in the runtime legs and Test Lab's judge (the `service_*` figures), and the emulator gate's sessions group, whose driver answers `service`, `trim`, `procs`, `home`, `front` and `die`.
- **Evidence:** the bootstrap run 44732997918 (`+1076: All tests passed!`, `kotlin_tests=187`), which failed only the API floor, fixed in the next commit; phase gates 44735804283 and 44744464658, whose new sessions group failed on the gate's own driver, 44752660910, whose emulator part passed whole while the runtime legs found the hub's race on API 27 and 34, and 44763350329, whose runtime legs and sessions group passed while two older groups failed, on npm's update notice and on the folder driver (below); then 44777091949 passed whole, every group at its first attempt (cold start 831 ms, the median of 10; no ANR and no crash since boot). Test Lab's Pixel 8a with Android 14 in CI 44786509685: all seven instrumented classes, 29 tests, with `SessionServiceTest` 4/4 (the service in the foreground in 67 ms and gone 56 ms after the last session; *End all* in 143 ms, no process left).
- **Deviations, and why:**
  - **The OOM score is not raised on API 26 to 28:** the kernel keeps the sessions at the app's score there (0 in front). Recorded, not an error; Android's lmkd reads the app's score, not the sessions', on every level.
  - **Every view lets go in the background,** the shown one's too, not only the hidden ones: a page Android has stopped acknowledges nothing, and a session waiting for acknowledgements would block its program once the credit window is full.
  - **Memory warnings rarely come:** since API 34 apps get only `UI_HIDDEN` and `BACKGROUND`, and an app with a running foreground service gets neither. The trimming serves older Android, and the gate sends the warnings with `am send-trim-memory`.
  - **The gate allows notifications** for the app before its integration tests, as a user would; an integration test can't answer Android's dialog. `SessionServiceTest` measures the service without the permission first on API 34 and 36; Test Lab grants an app's permissions when it installs it, so the phone showed the notification from the first session.
  - **Process death is measured on the emulator,** not on the phone: Test Lab runs instrumented classes, and killing the app's process ends the instrumentation with it. The phone checklist (W7) has the owner check the tombstones on a phone.
- **What the work found:**
  1. **API 31's `setForegroundServiceBehavior` failed the API floor** (44732997918), though behind a version check: the floor's allowlist names it as guarded.
  2. **The gate's driver answered a stale request** (44735804283): the run group's last request was still in the log, and the driver acts on the newest it finds. The log is cleared before the sessions group.
  3. **Part A was judged before the kill was recorded** (44744464658): `flutter test` saw the app die and ended before the driver wrote what was left. The gate waits for the driver's record first.
  4. **The hub published READY while the install still held the prefix** (44752660910): a session started the moment the runtime was ready was refused as "not_ready: the runtime is ready" on API 27 and 34. READY now follows the unlock, and `RuntimeHubTest` starts a command from a listener on hearing it.
  5. **npm's update notice reached a run's output** (44763350329, the run group): npm 12.2.3 came out on 2026-11-18, and npm asks the registry once a week and prints its notice when the answer comes before the script ends. The runtime's npm comes with the APK at its pin, so its commands run with `NPM_CONFIG_UPDATE_NOTIFIER=false`.
  6. **The explorer group's driver answered the folders group's first pick** (44763350329), read from a log that was being cleared, and tapped through a picker left on screen; the explorer's own picker then never showed. The driver stops DocumentsUI when it starts, ignores the requests already in the log, and answers none twice.

### W6 — The terminal gate on real targets (1–2 sessions) → G6

ADR-0006's budgets become xterm.js's:
- **Input to echo,** at the 95th percentile, 50 ms or less, from a key in the page to its echo drawn;
- **zero lost input** through the IME;
- **a 10 MB flood without a frozen UI:** the flood arrives whole, the Flutter UI keeps drawing, and frames over 32 ms stay under 5 %;
- **a memory delta of 80 MB or less** for the terminal.

**Where they are measured:**
- **The emulator gate,** in every phase gate's new `terminal` group: echo latency, the flood, rotation with `nano`, `top`, `less` and the node REPL, scripted IME composition, and the E2E scenario.
- **The runtime legs** run `TerminalSessionTest` on API 26 to 36.
- **The Test Lab phone** runs `phone_terminal_test.dart` (echo latency and the flood on arm64), in a `[testlab]` run after CI is green.
- **The renderer** is decided here: xterm's DOM renderer against WebGL, measured in the flood.
- **Phone checks for the owner** (W7's checklist): Gboard in the terminal, the extra-keys row, rotation in `nano`, a run, and a long session in the background with its notification.

**As built (W6):**
- **G6, on Test Lab's Pixel 8a with Android 14** (CI 44868218258, a profile build: the app's Dart compiled ahead of time, as it ships), in the real app with the editor open on `main.js` and a session at the panel's full stop:
  - **Input to echo: met.** With WebGL, 100 characters typed as an input method's commit reaches the page, each timed to the end of the frame that drew its echo: 28.6 ms at the median, **48.4 ms at the 95th percentile**, 59.6 ms at most, none lost; 44.1 ms in the run after the DOM's. With the DOM renderer: 62.3 ms.
  - **The flood: met.** 10 MiB from python3 (81,920 coloured lines of 128 bytes) arrived whole: the page counted 10,567,680 characters between the marks, CR LF included, and their FNV-1a, `59da1fa1`, is the test's own. With WebGL it took 3.0 s (3.3 MiB/s), and of the 189 frames Flutter drew meanwhile, with a progress bar laid over the app so that it drew every one, **0.5 % took over 32 ms**, none was frozen (over 700 ms), and none came more than 34.7 ms after the last; the page's own frames were slow 13.2 % of the time. With the DOM renderer: 4.1 s, 4.9 % of Flutter's frames and 44.4 % of the page's.
  - **Memory, as first measured: not met.** `dumpsys meminfo`'s PSS of the app's process and its WebView renderer, 473.0 MB before any terminal: **85.2 MB more with the terminal open** at its full stop and no output yet (73.5 MB at its half stop), **153.7 MB more once settled** 15 s after the WebGL flood (169.0 MB 2 s after it). By row: opening the terminal added 46.4 MB of the app's graphics (a second WebView's surfaces; the same at either stop), 11.5 MB of its native heap and 21.1 MB in the renderer (the page, xterm.js and WebGL's context); the flood added 58 MB in the renderer and 23 MB of the app's graphics, and turning to the DOM renderer gave back 35 MB and 17 MB of them. On the emulator a collection forced through DevTools after the flood took the renderer back to 5.3 MB above its size with the terminal open (below): what a flood leaves is garbage, mostly the script each batch of output travels in, which V8 had not collected 15 s later. Against ADR-0006's 80 MB the owner decided on 2026-11-21: work it down first, then judge what remains as found (§10, item 7).
- **The memory work** (the owner's decision of 2026-11-21, §10 item 7: (b), then (a)), measured on the same phone in CI 44889362793:
  - **What was built:** **Hybrid Composition++ app-wide** (the manifest's `io.flutter.embedding.android.EnableHcpp`, the owner's choice): on Android 14 and later with Impeller on Vulkan the engine composes every platform view, the editor's WebView and the terminal's, with SurfaceControl instead of copying each into a texture; elsewhere it keeps the texture layer (TLHC). **The host's messages through a MessagePort** instead of one `runJavaScript` per batch: as the terminal page loads, the app posts it one end of a message channel (`webview/PagePorts.kt`, a plugin of the app's own; `lib/services/editor/page_port.dart`), the page takes it (`editor/src/terminal/hostport.ts`) and says so in `terminal.ready` (`hostPort`), and from then on `WebViewEditorSurface.deliver` posts through it; a page or a host without one keeps the scripts. **WebGL for the shown session only,** while the page shows: hidden sessions draw with the DOM renderer, their WebGL context disposed, and a page hidden gives back the shown one's too. TERMINAL_ARCHITECTURE §2.2, SECURITY §3.
  - **Memory: the terminal open within 80 MB.** 440.5 MB before any terminal, 32.5 MB less than before (23.5 MB less of the app's graphics: the editor's WebView is no longer copied); **53.6 MB more with the terminal open** and idle 15 s at its full stop (38.1 MB at half), against 85.2 MB taken as the prompt showed (the budget judges the idle terminal, as (a) has it); **114.8 MB more once settled** after the WebGL flood (130.7 MB 2 s after it), against 153.7 MB. By row: opening the terminal now adds 17.9 MB of the app's graphics (46.4 MB before) and 12.2 MB in the renderer (21.1 MB); the flood adds 52.4 MB of the app's graphics (the WebView's GPU memory, which Android keeps in the app's process; the same after the DOM's flood) and 23.0 MB in the renderer (58 MB before). Which change saved what can't be told from one run beyond the baseline's graphics (Hybrid Composition++): on the emulator, with the port alone, the renderer grew in the flood as before.
  - **Echo and frames held, and improved.** With WebGL, echo 26.0 ms at the median and **37.5 ms at the 95th percentile** (48.4 ms before), 34.8 ms in the last run, none lost; the flood whole in 3.3 s with **none of Flutter's 215 frames over 32 ms** (none frozen, the longest gap 33.6 ms) and 10.8 % of the page's. The DOM renderer is within budget now too: echo 40.6 ms (62.3 ms before), the flood in 2.4 s (4.1 s) with 2.7 % of Flutter's frames slow and 4.5 % of the page's.
  - **Judged as the owner decided** ((a), for what is still over): Test Lab requires the terminal open and idle at its full stop within 90 MB (`page_memory_open_under_budget`; 53.6 MB, within ADR-0006's 80 MB too) and records a flood's growth without judging it (`page_memory_delta_mb`, `page_memory_peak_delta_mb`, and `page_memory_under_budget` against 80 MB). It also requires the composition (`page_composition=hcpp`) and the port (`page_host_port=1`).
  - **On the emulator** (phase gate 44883909195): no Hybrid Composition++ there (the texture layer), and the page holds the port. The terminal open costs 16.2 MB (24.4 MB before) and the flood's settled growth 62.2 MB (68.1 MB), the renderer's part of it as before (34.8 MB against 35.6); the page's JavaScript heap after the flood held less in use (10.1 MB against 12.6) but more allocated (25.2 MB against 15.5). The composition suite lost nothing (10 of 10), and nano, top, less and the node REPL fit the panel across the turns. **The echo there was slower:** 118.5 ms at the median and 180.4 ms at the 95th percentile, against 50.1 and 81.0 ms, in a run slow throughout (the session started in 2.6 s against 1.2 s, the composition suite took 15.4 s against 10.7 s; an earlier gate took 2.1 s and 15.3 s without any of this work). Recorded, not judged; the phone's echo improved on the same build, and the next gate shows whether it was the emulator.
  - **Not proven by automation:** Hybrid Composition++ runs only on phones, where no test types through a real input method or taps a WebView; the emulator's input tests ran with the texture layer. W7's phone checklist covers Gboard in the terminal and in the editor on an Android 14 phone.
- **G6, on the emulator** (phase gate 44870622961, API 36, a debug build on a software GPU): the same figures recorded, in `app/ci-results/gate/terminal_measure.json`. The page draws with the DOM there by itself ("a software GPU (Android Emulator OpenGL ES Translator (Google SwiftShader))"): echo 50.1 ms at the median and 81.0 ms at the 95th percentile, none lost; the flood whole in 31.5 s, every Flutter frame over 32 ms (raster 109 ms at the 95th percentile: the GPU is software); memory 24.4 MB more with the terminal open, 68.1 MB after the flood, and the renderer 30.3 MB smaller again after DevTools' collection (the page's JavaScript heap 15.5 MB, then 6.4 MB). **The composition suite lost nothing** (10 of 10). **nano, top, less and the node REPL** fit the panel at 46×22 in portrait, 60×7 in landscape and 46×22 again: `stty size` the page's size, nano's title centred and its shortcuts at the bottom, top unwrapped, less with a number on every row above its prompt, node reporting `'46x22'`; nano, open while the phone turned to landscape, redrew at 60×7, and less, open while it turned back, at 46×22. The E2E scenario part 1 stays in the run group, where it has run since W4.
- **The renderer, decided with these numbers: WebGL** (addon-webgl 0.19.0), where the device's GPU draws it. On the phone it drew the flood in 3.0 s against the DOM's 4.1 s, with 13.2 % of the page's frames slow against 44.4 %, and only it kept the echo within 50 ms (48.4 against 62.3 ms); the debug runs agreed (CI 44818854015: 3.3 against 5.7 s, 45.0 against 56.9 ms). It costs memory: 35 MB in the renderer and 17 MB of graphics after a flood. The page asks for WebGL and keeps the DOM renderer where WebGL can't draw: no WebGL2, a software GPU (on the emulator WebGL could not keep up with an erase), or a context Android takes back, which the page tries again when it shows again. **After the memory work WebGL stays:** with Hybrid Composition++ both renderers are within budget (above), but phones without it (Android 13 and older, or no Vulkan) keep the texture layer, where only WebGL kept the echo within 50 ms.
- **The folder copy's phone figures** (the same run): the gate folder's 1,006 files, put in Documents by the instrumentation's shell and picked through Android's picker, copied in 7,396 ms the first time, in 780 ms when nothing had changed, and in 1,124 ms after one file changed (the emulator: 4.8 s and half a second at W4). At that rate the copy's cap of 10,000 files is about 75 s on a phone, with its progress and Cancel shown; the caps stay.
- **What was built:**
  - **The page's probe** (`editor/src/terminal/probe.ts`, protocol messages `probe.echo`, `probe.flood` and `probe.read`, and `terminal.configure`'s `renderer`): echo typed through `ime.ts` as an input method's commit and timed with the editor benchmark's instruments (`bench/timing.ts`, `bench/stats.ts`), erased again; a flood counted and hashed between two marks without copying it, with the page's frames and long tasks. TERMINAL_ARCHITECTURE §2.1 and §2.2.
  - **The renderer** in `main.ts` (the software-GPU check, the WebGL addon, its context loss) and the controller (WebGL by default, a view that lost its context tried again when the page shows again, the reason logged once).
  - **The measurements** (`app/integration_test/terminal_measure.dart`): echo, the flood with Flutter's frame timings while an overlay keeps it drawing, the UI isolate's time on the output (`TerminalController.outputStats`), memory by `dumpsys` row, with each renderer, the shipped one first and again last; run by `terminal_test.dart` on the emulator and `phone_terminal_test.dart` on the phone.
  - **The gates:** the emulator's folder driver answers `mem` and `heap` (`editor/tool/terminal_cdp.mjs --heap`); on Test Lab, `androidTest/…/syncmodes/GateAnswers.java` answers `mem`, `fixture`, `pick` (through the accessibility tree), `put` and `heap`, from `folder_gate.dart`'s request files; Test Lab's judge requires WebGL and the four budgets (`page_*` figures). Test Lab's app is a profile build since W6 (`codeforge.testBuildType`).
- **Evidence:** the bootstrap runs 44804897631 (analyze: Riverpod 3's `Override` is in `misc.dart`), then 44816821921, 44862901068 and 44866950104 (`+1086: All tests passed!`, `kotlin_tests=188`); phase gate 44807458944, which measured the DOM and stopped when WebGL's first erase on the emulator took over 2 s (below), then 44870622961, whole (cold start 1,117 ms, the median of 10). Test Lab's Pixel 8a: CI 44818854015 and 44863955928 (debug builds: both renderers, then WebGL first; the copy each time), then CI 44868218258 (the profile build): every class passed, 31 tests, and the judge failed only `page_memory_under_budget`. **The memory work:** the bootstrap run 44882599973 (`+1090: All tests passed!`, `kotlin_tests=188`), phase gate 44883909195, whole; Test Lab CI 44889362793: every class passed, 31 tests, and the judge failed only `page_memory_under_budget`, which (a) no longer requires; plain CI 44892056800 with the judge changed, then Test Lab CI 44893095694, **whole**: Hybrid Composition++ and the port, echo 26.8 ms at the median and 37.2 ms at the 95th percentile, none lost; the flood whole in 3.3 s, none of Flutter's 208 frames over 32 ms; the terminal open 55.3 MB at its full stop (44.8 MB at half), 100.3 MB settled after the flood and 154.7 MB 2 s after it; the DOM renderer's echo 42.2 ms; the copy 7,862 ms, 739 ms and 1,017 ms.
- **Deviations, and why:**
  - **ADR-0006's memory budget holds for the open terminal only:** after the memory work it costs 53.6 MB at its full stop, but a flood's settled growth, 114.8 MB, is over 80 MB. As the owner decided ((b), then (a), §10 item 7), Test Lab judges the open terminal within 90 MB and records the flood's growth.
  - **Test Lab's build is a profile build,** not debug: a debug build's Dart is compiled as it runs. The figures moved little for echo (46.5 ms in debug, 48.4 in profile: the Dart side is a small part of it) and much for memory (the app and its renderer 222 MB smaller before any terminal). The store's and search's figures come from it too (search: the first result in 38 ms, all in 133 ms).
  - **The flood's figures for the UI are Flutter's frames**, with a progress bar laid over the app so that it draws every frame; the page's own frames are recorded beside them, and decided the renderer.
  - **The memory is measured after the flood has settled for 15 s**, and also 2 s after it, beside the terminal open with no output at both stops. A collection can be forced only through DevTools, so only on the emulator.
  - **The emulator measures the DOM renderer only:** its GPU is software, and the page draws with the DOM there. WebGL's figures come from the phone.
- **What the work found:**
  1. **WebGL on the emulator's software GPU could not keep up** (phase gate 44807458944): an erase took over 2 s, and the group stopped. The page now keeps the DOM renderer on a software GPU, and the other renderer's runs never fail the test.
  2. **The instrumentation turned accessibility on in the middle of the measurements** (CI 44818854015 and 44863955928): its first shell command connected Android's accessibility, Flutter built its semantics from then on, and the Dart test ended with a SemanticsHandle it had not made. `GateAnswers` now runs the shell without accessibility from before the app starts, and turns it on only to drive the picker.
  3. **Riverpod 3 exports `Override` from `misc.dart`** (44804897631), as `smoke_test.dart` already knew.
  4. **A flood's garbage outlives it:** V8 had not collected the per-batch scripts 15 s after the flood, on the emulator or the phone; DevTools' collection gave 30 MB back at once.

### W7 — Docs and the phase exit (1 session) → G7

- **The docs:**
  - TERMINAL_ARCHITECTURE as built, and SECURITY §2 (the terminal boundary).
  - ARCHITECTURE, RUNTIME_INTEGRATION, TESTING, PERFORMANCE (the terminal's budgets) and BUILD_AND_RELEASE (the release workflow).
  - REPOSITORY_STRUCTURE.
  - The ADRs: 0006 and 0013 as built, and 0014 (the PTY and sessions).
  - ROADMAP, README and the changelog.
  - docs/store: the foreground service, its notification, and the network if the owner decided it.
- **The exit:** PHASE_5_REPORT, and PHASE_5_PHONE_CHECKLIST. Since W6's memory work the checklist also covers Gboard and taps in the terminal and in the editor on a phone with Android 14 or later, where both WebViews are composed with Hybrid Composition++, which no automated test reaches (the emulator composes with the texture layer).

**As built (W7):**
- **G7 met:** the documents below are synced, ADR-0014 has its *As built (Phase 5)*, and [PHASE_5_REPORT.md](PHASE_5_REPORT.md) and [PHASE_5_PHONE_CHECKLIST.md](PHASE_5_PHONE_CHECKLIST.md) are written. §7's list, as synced:
  - TERMINAL_ARCHITECTURE (the status, §2.1's page size, §3's endings) and SECURITY (§2.1's list of what was not yet built, now built; §2.2 final; §6's signing as built with two keys);
  - ADR-0013 (the copy measured on the phone) and ADR-0014 (*As built (Phase 5)*); ADR-0006's W6 part was written in W6;
  - ARCHITECTURE (§1.2's channels as built, §2.4's panel, a new §2.11 for the terminal and Run, §6, §7), RUNTIME_INTEGRATION (sessions, Run, folders and what runs, as built), TESTING (§1.5's W7 row), PERFORMANCE (the status) and BUILD_AND_RELEASE (the status, and §2.5's CI from W2 to W6);
  - REPOSITORY_STRUCTURE (W6's files, `app/ci-results/`), TECH_STACK (the Phase 5 update), and, beyond §7's list, EDITOR_ARCHITECTURE (the composition, and its status) and UI_DESIGN_SYSTEM (Phase 5's chrome);
  - docs/store (the listing with the terminal and *Run*, the closed test's table with the licence review, the release checklist, the privacy policy's header), ROADMAP, README and the CHANGELOG.
  - THIRD_PARTY_NOTICES §3 and SOURCE_OFFER needed no change: CI writes §3 from the resolved packages, and lists the terminal page's four, and the archive is as W1 built it.
- **The last pass found two things, and W7 fixed them:**
  1. **The native-addon text said more than Android does.** The banner and Settings → Linux runtime said that Android won't run programs written to app storage. ExecModelTest measures that rule on API 34 and 36 and on the Pixel 8a (`exec_model_data_exec=denied`), but on API 26 to 28 the same copy runs (`allowed`): the rule needs both the app's target and the device at API 29 or later. Both texts now say "Android 10 and later". They no longer suggest prebuilt wheels either, since a wheel's C extension is a library in app storage too. `native_addons_test.dart` holds the words.
  2. **§9's risk table had W4 measure whether node loads a `.node` library from app storage, and W4 did not.** `RuntimeCommandsTest` (g) now records it on every runtime leg, in the emulator gate's runtime group and on Test Lab's phone. Node's `process.dlopen` loads a library copied into the runtime's home, and the test records `loaded` or `refused`, with ExecModelTest's rule beside it as the expectation. It is recorded, not judged; the exit gate's results are in PHASE_5_REPORT §9.2.
- **The exit:** the code and the docs passed CI first, then the exit gate ran every group on every target (PHASE_5_REPORT §4).

## 4. Deliverables

- `.github/workflows/release.yml`, `runtime/sources.py` with its tests, and the offer and the licences in the app.
- The launcher's terminal mode, `TerminalSession`, the interactive `SessionRegistry`, `SessionService`, and the terminal's Pigeon API.
- The terminal page (xterm.js), the terminal protocol v1, `TerminalService`'s real implementation, and the terminal panel with tabs and extra keys.
- Run (files and projects), ADR-0013's copy with export and *Import as project*, and the native-addon banner.
- The `terminal` gate group, the E2E scenario part 1, `TerminalSessionTest` on the legs, and `phone_terminal_test.dart` in Test Lab.
- ADR-0014, SECURITY §2.2, PHASE_5_REPORT and PHASE_5_PHONE_CHECKLIST.

## 5. Acceptance criteria (measurable gates)

| Gate | Criterion | Evidence |
|---|---|---|
| **G1 Release** | A dry run of the release workflow builds a signed App Bundle and APK. The bundle is within Play's per-device limit, page-aligned, and passes the release manifest gate. The source archive holds every copyleft package's recipe and upstream source, each verified against its SHA-256, and fails closed on a missing one. About shows the offer, and the licence page lists the editor page's and the userland's packages with their texts | the release workflow's run id, CI, widget tests |
| **G2 Sessions** | The launcher's terminal mode passes on CI's Linux machine: echo, resize, Ctrl-C, exit code, the tree ended, and a flood under flow control. `TerminalSessionTest` passes on API 26 to 36 and the arm64 phone: echo, resize, the REPL, a 10 MB flood whole with bounded memory, the cap, *End all* with no process left | CI, the runtime legs, Test Lab |
| **G3 View** | The terminal page passes its build checks (CSP, hash, licences, size). The protocol's fixtures pass in vitest and Dart. Tabs, extra keys, copy and paste pass in widget tests. In the emulator gate, typed text echoes, `nano` and `top` draw at the panel's size after a rotation, and scripted composition loses nothing | CI, the phase gate's `terminal` group |
| **G4 Run** | Runs of JS, Python and shell files and an npm script give their exact output and exit code. Stop leaves no process. A folder runs through its copy, the second copy is incremental (both timed), and export works. The native-addon banner shows on a fixture that needs a compiler. The E2E scenario part 1 passes | widget and integration tests, the phase gate |
| **G5 Lifecycle** | The foreground service starts with the first session and stops after the last. *End all* ends every tree. A session survives 5 minutes in the background. After the app's process dies, the sessions show tombstones. The release manifest holds exactly the allowed permissions. Each limit is measured and recorded with its value, and SECURITY §2.2 is written | instrumented tests, the phase gate, CI |
| **G6 Terminal budgets** | On the arm64 phone: input to echo at p95 within 50 ms, a 10 MB flood whole without a frozen UI, a memory delta within 80 MB (since the owner's decision of 2026-11-21, §10 item 7: the terminal open and idle within 90 MB at the full stop, a flood's growth recorded). On the emulator: the same figures recorded, and the IME suite losing nothing. The renderer chosen with numbers | Test Lab, the phase gate |
| **G7 Docs** | The docs synced, ADR-0014 written, PHASE_5_REPORT and the phone checklist written | the documents |

Each work package ends as Phase 4's did: CI green, one phase gate, the docs updated, a report in chat, then the owner's "next".

## 6. Tests

| New suite | Where |
|---|---|
| `runtime/tests/test-sources.py` (the source archive, with fixture recipes and upstreams) | CI's runtime job |
| The launcher's terminal mode (`runtime/tests/test-spawn.py` grows, or a new `test-pty.py`) | CI's runtime job |
| JVM: `TerminalSessionTest`, the registry's sessions, the folder copy | CI's quality job |
| Instrumented: `TerminalSessionTest`; the service and tombstones | the runtime legs, Test Lab |
| vitest: the terminal protocol and the page's controller | CI's editor job |
| Dart: the terminal service and controller, the protocol's fixtures, Run's profiles, the banners; widgets for tabs and extra keys | CI |
| Integration: `terminal_test.dart` (echo, flood, rotation, IME), `run_test.dart` (runs, Stop, folders, export), the E2E scenario part 1 | the phase gate |
| `phone_terminal_test.dart` | Test Lab |

## 7. Documentation

TERMINAL_ARCHITECTURE (as built), SECURITY §2.2, ADR-0014 (new), ADR-0006 and ADR-0013 (as built), ARCHITECTURE, RUNTIME_INTEGRATION, TESTING, PERFORMANCE, BUILD_AND_RELEASE (the release workflow and signing), REPOSITORY_STRUCTURE, TECH_STACK (xterm.js's pins), THIRD_PARTY_NOTICES (§3 grows with xterm.js by itself), SOURCE_OFFER (the archive as built), docs/store, ROADMAP, README, CHANGELOG, PHASE_5_REPORT, PHASE_5_PHONE_CHECKLIST.

## 8. Known limitations (planned) and out of scope

- **No language servers** (Phase 6), **no git UI** (Phase 7, though git works in the terminal), **no debugger** (Phase 9).
- **No compiler:** native npm addons and pip packages that need one can't be installed. W4 says so where it happens.
- **Sessions don't survive a reboot or a force-stop:** their processes end with the app. The tombstones say so.
- **The release build has network access from Phase 5** (the owner's decision, §10 item 4), as debug and profile builds already do. What a user's command sends is the user's own doing, and the app itself sends nothing.
- **No 32-bit ARM build;** the release APK in CI stays x86_64 for the emulators, while the release workflow builds arm64.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Composition in xterm.js's textarea loses or repeats input in Android's WebView (Gboard) | The editor's scripted composition suite, adapted; the owner's phone; a plain input line as the fallback mode |
| A flood freezes the WebView or the UI | Flow control by credit, so the page never holds more than it has drawn; batching at 60 Hz; the DOM renderer against WebGL, measured |
| The launcher's relay adds too much to an echo | Measured at W2's start; the JNI design (b) if so (§3, W2) |
| Play rejects the special-use declaration | Sessions then end when the app leaves the foreground, said plainly in the app. The `dataSync` type with its 6-hour cap and `onTimeout` is the second fallback |
| Android ends the app with its sessions despite the service, on a phone short of memory | Tombstones, and the scrollback kept in the host's buffer until the process dies; measured on the Pixel 8a |
| The process-count limit counts the app's own threads | Measured before it is set; left unset, with the reason recorded, if it would break the app |
| **Play's Device and Network Abuse policy:** an app "may not download executable code (such as dex, JAR, .so files) from a source other than Google Play", except code run by a virtual machine or an interpreter ([Play Console Help 16559646](https://support.google.com/googleplay/android-developer/answer/16559646)). With network access, a user's `npm install` can fetch native addons published for Android: `@rollup/rollup-android-arm64` and `lightningcss-android-arm64` (`.node` libraries) and `@esbuild/android-arm64` (a program), all on npm with `os: android` (checked 2026-11-18) | The app itself downloads nothing (ADR-0005). A program written to the app's storage can't be executed at target 36, and W4 measures whether node can load such a `.node` library from there. W4's banner explains either outcome. The question goes to the owner's Play review before the first submission, with the measurement |
| An upstream source URL disappears | The archive's cache under the pins' hash; the release fails closed, naming the package; the owner can't publish without the source |
| Test Lab's 5 daily tests, and its end on 2027-09-30 | One phone run per gate, as in Phase 4; ROADMAP's decision queue holds the successor |
| The terminal's WebView pushes memory past ADR-0004's budget, measured with the editor's | One WebView for every session; measured in W6 against ADR-0006's 80 MB delta |

## 10. Owner actions and decisions, in order

1. **Phase 4 accepted on 2026-11-18** (the owner's "next" after PHASE_4_REPORT asked to accept it or ask for changes).
2. **The phone session,** non-blocking: PHASE_3_PHONE_CHECKLIST and PHASE_4_PHONE_CHECKLIST, on the APK of gate 44332891340 (kept until 2026-12-18).
3. **For W1, the release:**
   - **The keys:** Play's upload key (with Play App Signing) and a release key for GitHub's APK, as repository secrets. BUILD_AND_RELEASE §4 will list the steps and the secrets' names. **Decided 2026-11-18: dry runs for now.** The workflow signs with a throwaway key until the owner adds the keys.
   - **The first GitHub Release:** after the licence review by a qualified person (SOURCE_OFFER.md). **Decided 2026-11-18: the owner arranges the review,** and no public binary goes out before it is done.
   - **The source offer's contact address:** until one is named, requests go to the repository's issues.
4. **Network access for the release build,** by W4 (Run, and `npm install` or `pip install` in the terminal):
   - **(a) Yes, from Phase 5.** npm, pip and later git work in the release build as they do in the debug build. The Data safety answers can stay "nothing collected": the app itself sends nothing, and what a user's command sends is a user-initiated transfer, which Play exempts (§0). They and the privacy policy are reworded to say so.
   - **(b) No, until Phase 7.** The release build stays offline, and `npm install` and `pip install` fail there with a message saying why.
   - **The agent recommends (a).** A terminal that can't install packages misses the phase's purpose, and the debug builds already work that way.
   - **Decided 2026-11-18: (a).** The release manifest gains `INTERNET` in W1, with the Data safety answers, the privacy policy and the listing reworded in the same change. Play's rule on downloaded executable code is a separate question, in §9.
5. **For W5:** Play Console's special-use declaration for the foreground service, at the first submission, with text the agent drafts. **Drafted** in [docs/store/listing.md](../store/listing.md) (*The foreground service declaration*), for the owner to paste.
6. **Left to the agent,** unless the owner wants them: the PTY's design (§3, W2), the session cap (8), the limits' values (measured), the renderer (measured), and the flow control's sizes.
7. **For W6, the terminal's memory budget** (ADR-0006: a delta of 80 MB or less). Measured on Test Lab's Pixel 8a in a profile build (*As built (W6)*): 85.2 MB more with the terminal open at its full stop and no output (73.5 MB at half), 153.7 MB once settled after a 10 MB flood. Most of the open cost is a second WebView's surfaces (46 MB of the app's graphics), and most of the flood's is garbage V8 had not collected yet, plus WebGL's buffers. Echo, the flood and the frames are within their budgets.
   - **(a) Accept the cost measured, and judge it from now on as it was found:** the terminal open and idle within 90 MB at the full stop, a flood's growth recorded but not judged (it is collectible: 30 MB came back at once on the emulator). Test Lab's judge would require that instead.
   - **(b) Work to bring it within 80 MB first** (an estimated one or two sessions, before Phase 6): the terminal's WebView composed in Android's view tree (Hybrid Composition) instead of through copied surfaces, output carried to the page by a message port instead of a script per batch, and WebGL for the shown session only. Each must keep W3's input-method proof and this package's echo and frames, so the terminal gate runs again.
   - **(c) The DOM renderer instead of WebGL:** about 35 MB less after a flood, but its echo is 62.3 ms, over its own budget, and the page drops frames during a flood.
   - **The agent recommends (b), then (a) for what remains.** The open cost is paid by everyone who opens a terminal; the flood's is transient.
   - **Decided 2026-11-21: (b), then (a) for what remains.** Building (b), the agent found in Flutter 3.50's source that plain Hybrid Composition would hardly save memory: while an HC view is on screen, Flutter draws the whole app into a full-screen image view (about 31 MB on the 8a), and anything Flutter draws over the terminal adds another such layer for as long as the terminal shows. Hybrid Composition++ (HCPP) needs neither, but it is a manifest switch the engine applies to every platform view, the editor's WebView too, and only on Android 14 and later with Vulkan. **Decided the same day: HCPP, app-wide** (`io.flutter.embedding.android.EnableHcpp`; other phones keep Flutter's texture layer), with the message port and WebGL for the shown session only.
   - **Outcome** (*As built (W6)*, CI 44889362793 on the Pixel 8a): the terminal open and idle at its full stop **53.6 MB**, within 80 MB, and 114.8 MB once settled after the flood; echo 37.5 ms and none of Flutter's frames slow in the flood. As (a) has it for what is still over, Test Lab judges the open terminal within 90 MB and records a flood's growth; ADR-0006 *As built* says so.
8. **Phase 5's exit (W7):** accept Phase 5, or ask for changes (PHASE_5_REPORT §10). Non-blocking, unless the owner decides otherwise:
   - **the phone session:** PHASE_5_PHONE_CHECKLIST, on the exit gate's APK, with the Phase 3 and Phase 4 checklists still open;
   - **Play's rule on downloaded executable code** (§9): the owner's review before the first submission, with W7's measurement;
   - **the first release** (item 3): the keys and the licence review.
