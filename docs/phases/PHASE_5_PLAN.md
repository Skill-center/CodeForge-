# Phase 5 Plan — Terminal & Execution

**Status:** **In progress.** Proposed on 2026-11-18, the day Phase 4 was accepted. **The owner's decisions on 2026-11-18** (§10): start with W1; the release build gets network access from Phase 5; the release workflow runs dry until the owner adds the keys; the owner arranges the licence review, and no public binary goes out before it · **Spec reference:** §8 Phase 5 (terminal and execution), §6.4 (the terminal connects to the existing environment), §6.5 (the capability model), §7 (security), §10 (the end-to-end scenario) · **Architecture:** [TERMINAL_ARCHITECTURE.md](../TERMINAL_ARCHITECTURE.md), [ADR-0006](../adr/0006-terminal-frontend.md) (xterm.js), [ADR-0013](../adr/0013-folders-and-the-runtime.md) (a folder runs in a copy), [SECURITY.md](../SECURITY.md) §2, [RUNTIME_INTEGRATION.md](../RUNTIME_INTEGRATION.md), [ADR-0010](../adr/0010-distribution.md), [ADR-0011](../adr/0011-license.md) · **Builds on:** Phase 4 ([report](PHASE_4_REPORT.md)): the sealed runtime, its exec model and launcher, search

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

### W7 — Docs and the phase exit (1 session) → G7

- **The docs:**
  - TERMINAL_ARCHITECTURE as built, and SECURITY §2 (the terminal boundary).
  - ARCHITECTURE, RUNTIME_INTEGRATION, TESTING, PERFORMANCE (the terminal's budgets) and BUILD_AND_RELEASE (the release workflow).
  - REPOSITORY_STRUCTURE.
  - The ADRs: 0006 and 0013 as built, and 0014 (the PTY and sessions).
  - ROADMAP, README and the changelog.
  - docs/store: the foreground service, its notification, and the network if the owner decided it.
- **The exit:** PHASE_5_REPORT, and PHASE_5_PHONE_CHECKLIST.

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
| **G6 Terminal budgets** | On the arm64 phone: input to echo at p95 within 50 ms, a 10 MB flood whole without a frozen UI, a memory delta within 80 MB. On the emulator: the same figures recorded, and the IME suite losing nothing. The renderer chosen with numbers | Test Lab, the phase gate |
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
5. **For W5:** Play Console's special-use declaration for the foreground service, at the first submission, with text the agent drafts.
6. **Left to the agent,** unless the owner wants them: the PTY's design (§3, W2), the session cap (8), the limits' values (measured), the renderer (measured), and the flow control's sizes.
