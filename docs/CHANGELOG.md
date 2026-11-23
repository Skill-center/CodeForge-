# Changelog

All notable changes to CodeForge. Format: [Keep a Changelog](https://keepachangelog.com/); versions: SemVer. Phase milestones tag `v0.N.0`; public release starts at `v1.0.0` (Phase 10).

## [Unreleased]

### Added — Phase 6 W7, the docs and the phase exit (plan: [phases/PHASE_6_PLAN.md](phases/PHASE_6_PLAN.md); report: [phases/PHASE_6_REPORT.md](phases/PHASE_6_REPORT.md))
- **A language server that goes silent comes back:** one that says nothing for 30 s after it is asked something is stopped and started again with its files, as a crashed one is, unless it is busy with a long analysis it reports. Repeated failures still end with the status strip offering *Restart*.
- **The language gate records the total with a terminal open** beside the editor and both servers, without judging it.
- **The documents, as built:** LSP_ARCHITECTURE grown from its seed into how the servers work today, ADR-0015's last *As built* sections, SECURITY §2.3's twelve threats with their proofs, the Phase 6 report, and a phone checklist: completion with Gboard, the long press for hover and definition, a rename, the Problems sheet.
- Verified by: CI 45204541929 (`+1291: All tests passed!`, the silent server's tests among them; 228 Kotlin tests); the exit gate 45225412011, whole, every group on its first attempt (the five runtime legs 37 of 37 each; the cold start 1,185 ms); Test Lab's Pixel 8a in the same run, 42 of 42, every language budget met, and 917.0 MB with a terminal open beside the editor and both servers.

### Added — Phase 6 W6, the language gate on a phone (plan: [phases/PHASE_6_PLAN.md](phases/PHASE_6_PLAN.md))
- **The language budgets are met on a real phone** (Test Lab's Pixel 8a, in the app, on a 200-file project in each language): completion lists appear 139.0 ms (Python) and 64.5 ms (TypeScript) after they are asked for, at the 95th percentile, against 300 ms; problems show 476.9 and 657.7 ms after a save, against 1 s; each language server takes 169.9 and 246.5 MB, against its own 300 MB.
- **The editor times its own completion lists,** from the request to the frame that draws them, for these measurements.
- Verified by: CI 45180564110 (`+1286: All tests passed!`, 228 Kotlin tests); phase gate 45182761593: Test Lab's Pixel 8a 42 of 42 in the same run with every budget met, every emulator group with the budgets' figures recorded, and `LanguageServerTest` 6 of 6 on each runtime leg.

### Added — Phase 6 W5, the language features in the editor (plan: [phases/PHASE_6_PLAN.md](phases/PHASE_6_PLAN.md))
- **Completion from the language server** as you type a name or after a `.`: each item with its kind's icon and its documentation when selected, imports added with it. While the server starts or restarts, the editor completes the file's own words.
- **Problems underlined as you type,** with marks in the gutter; a tap on an underline shows the message. The status strip counts the file's problems, and the *Problems* sheet lists every open file's (Ctrl+Shift+M); a tap goes to the line.
- **Go to definition** from a long press, the symbol toolbar or F12. It opens the file at the place, and Python's stubs and TypeScript's `lib.d.ts` open read-only.
- **Rename across files** (a long press or F2): the server's change applied to every file or none, each open file's as one undo step. A file that changed meanwhile stops it, and nothing is written.
- **Hover:** a long press shows what the server knows about a name, with code in the editor's font.
- **Folders from shared storage get all of this,** through their copy. **Settings → Editor** turns each language's server on or off, and **Settings → Linux runtime** shows each server with its memory and *Restart*.

### Added — Phase 6 W4, the language client (plan: [phases/PHASE_6_PLAN.md](phases/PHASE_6_PLAN.md))
- **The app speaks LSP:** a client in Dart for each language server. It gives every request a timeout (2 s for completion) and can call one off, opens the project as the server's one folder, and sends the editor's edits as ranges in version order, never whole documents but after a resync. Saves, closed tabs and files changed outside the app reach the servers too.
- **A server that fails comes back** after 1 s, 2 s and 4 s, with every open file. A fourth failure within five minutes stops it, and the status strip offers *Restart*. A server with no open file for ten minutes is shut down.
- **The status strip names the server:** starting, ready, analysing, restarting or off, with why. A language counts as analyzable while its server runs.
- **Where Pyright's time goes:** on the phone, its completion after an edit took the same with the 256 MB heap cap as without it (p95 82.2 to 85.0 ms), so the cap stays. The server takes most of each request (31 to 34 ms at p50), and handing a message to the host's writer thread costs about 3 ms on the phone.
- Completion, diagnostics, definition, rename and hover in the editor come in W5, and folders from shared storage get servers then too. The integration tests run without servers, so what they measure stays comparable.
- Verified by: CI 45065692542 (`+1179: All tests passed!`, 228 Kotlin tests); phase gate 45067383709: `LanguageServerTest` 6 of 6 on each runtime leg, every emulator group (the emulator job on its second attempt: the first met a black screen at boot), and Test Lab's Pixel 8a 41 of 41 in the same run.

### Added — Phase 6 W3, the language servers' host (plan: [phases/PHASE_6_PLAN.md](phases/PHASE_6_PLAN.md))
- **The app can run a language server:** `LspHost` starts one through the launcher with its stdin open, in its own process group under the sessions' limits. It carries whole messages both ways, stops the server with its whole tree, and says how each one ended (its exit code or signal, and the last 64 KiB of its stderr).
- **Messages are checked:** a message over 16 MiB, a malformed header or invalid UTF-8 ends the server as broken, never as half a message.
- **Bounded:** at most two servers, one per server; a project or a folder's copy by name, never a path; a 256 MB V8 heap cap; memory read every 10 s; servers stopped first when Android warns of low memory. No foreground service.
- **Dart's side:** the Pigeon API `LspApi` (start, send, stop, servers) with `LspEvents` for messages and exits. The client that uses it comes in W4.
- **Pyright got slower on the phone** through the host (completion after an edit at up to 111.9 ms p95, against 62.4 ms in W2), in both of W3's gates, for a reason not yet known. That is within the 300 ms budget, and W4 times each stage of a request.
- Verified by: CI 45020136733 (`+1093: All tests passed!`, 225 Kotlin tests) and plain CI 45027761446 on the final code; phase gate 45029118568, whole (the first, 45021556836, failed its sessions group on a log line W3 had changed, since fixed): `LanguageServerTest` 5 of 5 on each runtime leg (a second Pyright refused, a SIGKILL reported as signal 9 with nothing of its tree left), every emulator group at its first attempt, the cold start at 1,094 ms, and Test Lab's Pixel 8a 40 of 40 in the same run.

### Phase 6's memory budget decided (2026-11-22)
- The owner chose (b) (PHASE_6_PLAN §10, item 3): each language server gets a budget of its own, 300 MB of PSS for its process tree on the gate's 200-file project on the phone, beside the app's budgets, which stay as they are. The total is recorded. Servers stop first when Android warns of low memory, at most two run, and an idle one stops after 10 minutes.

### Added — Phase 6 W2, the language servers in the payload (plan: [phases/PHASE_6_PLAN.md](phases/PHASE_6_PLAN.md))
- **The servers ship in the app:** Pyright (6.06 MB) and the TypeScript server (5.15 MB) as archives beside the userland, built from npm packages pinned with their SHA-512 in `runtime/language-servers/`. The base module is now 158.3 MB, 79.2 % of Play's limit.
- **Installed when first needed:** a server is extracted into the runtime and verified file by file the first time it is asked for, then reused. On a Pixel 8a, Pyright's first install took 3.65 s and a later start 5 ms. A damaged archive is refused and leaves nothing behind.
- **Checked before they ship:** exact versions on the npm registry, a permissive licence allowlist, no install scripts, and no native code. The build fails on any of them.
- **Their licences are in the app:** THIRD_PARTY_NOTICES §6 lists 61 package versions, including 58 bundled inside the servers' JavaScript, and the licence page shows their texts. Two bundled packages ship without a licence file and are listed for the licence review.
- Verified by: CI 44994907490 (`+1093: All tests passed!`, 202 Kotlin tests); phase gate 44995822826, whole: the install tests 3 of 3 and the smoke suite 4 of 4 on each runtime leg, every emulator group at its first attempt, the cold start at 873 ms, and Test Lab's Pixel 8a 39 of 39 in the same run.

### Added — Phase 6 W1, the language servers' compatibility spike (plan: [phases/PHASE_6_PLAN.md](phases/PHASE_6_PLAN.md))
- **Both candidate servers work under the sealed runtime,** on every target: Pyright 1.1.414 for Python, and typescript-language-server 6.1.0 with TypeScript 6.0.3 for JavaScript and TypeScript ([ADR-0015](adr/0015-language-servers.md)). Each initializes, reports a fixture's error, completes a known member, finds a definition and renames across two files, clears the error once it is fixed, and exits with nothing left, on API 26 to 36 and on a Pixel 8a with Android 14.
- **Fast enough:** on the phone, completion after an edit took 43 to 93 ms at the 95th percentile against a 300 ms budget, and the first diagnostics 1.2 to 2.8 s after a file opened.
- **Heavier than planned:** a server takes 167 to 255 MB of PSS on the phone, so the editor, a terminal and a server come to about 665 to 753 MB against PERFORMANCE's 600 MB. The owner decides the budget (PHASE_6_PLAN §10, item 3).
- **Checked before they reach a device:** the servers come from the npm registry at pinned versions, each tarball checked against the registry's SHA-512, and refused if it holds native code, a link or a path outside the package (`app/tool/ci/fetch_language_servers.py`).
- Verified by: plain CI 44976282000; phase gate 44977463887, whole: `LanguageServerTest` 4 of 4 on each runtime leg, every emulator group at its first attempt, the cold start at 1,169 ms, and Test Lab's Pixel 8a 36 of 36 in the same run.

### Phase 6 planned (2026-11-21)
- [PHASE_6_PLAN.md](phases/PHASE_6_PLAN.md): language intelligence in seven work packages. First a compatibility spike: Pyright, and TypeScript 6.0.3 with typescript-language-server, under the sealed node on API 26 to 36 and the Pixel 8a, with their start, latency and memory measured. Then the servers in the payload (pinned with their integrity, JavaScript only, installed the first time their language is needed), the host's server processes with LSP's framing in Kotlin, the client in Dart, completion, diagnostics, definition, rename and hover in the editor, and the language gate on an arm64 phone. The owner decides which languages get a server, and the memory budget once W1 has measured it (§10).
- **The owner's decision (2026-11-22):** both languages get a server, Python and JavaScript/TypeScript (§10, item 2, option (a)).
- **Found while planning:** `typescript` 7 is a native port with no Android build, so the JavaScript line, 6.0.3, is the candidate. Test Lab counts its daily tests from midnight Pacific time, not UTC: PHASE_5_REPORT's count is corrected.

### Phase 5 accepted (2026-11-21)
- The owner accepted Phase 5 by saying "next" after its report ([PHASE_5_REPORT.md](phases/PHASE_5_REPORT.md)). The phone session, on the exit gate's APK, the first release and Play's owner actions stay open and non-blocking.

### Changed — Phase 5 W7, the docs and the phase exit (plan: [phases/PHASE_5_PLAN.md](phases/PHASE_5_PLAN.md), report: [phases/PHASE_5_REPORT.md](phases/PHASE_5_REPORT.md))
- **Phase 5 is written up:** [PHASE_5_REPORT.md](phases/PHASE_5_REPORT.md), with every gate's evidence, and [PHASE_5_PHONE_CHECKLIST.md](phases/PHASE_5_PHONE_CHECKLIST.md) for the owner's phone. The checklist covers Gboard and the extra keys, taps and typing through Hybrid Composition++ in the terminal and the editor, nano across a turn, a run, a long session in the background, and the tombstones.
- **ADR-0014 as built:** W3's acknowledgement through xterm.js's write callback, Run's sessions, W5's service and limits, and the whole path measured on the Pixel 8a: echo 37.2 ms at p95, with the host's part 6.3 ms.
- **The native-addon text is true on every Android version.** The banner and Settings → Linux runtime said that Android won't run programs written to app storage. The runtime gates measure that on Android 14 and 16 and on the Pixel 8a, but on Android 8.0 to 9 the same copy runs. Both now say "Android 10 and later", and suggest pure packages only.
- **Whether node loads an addon from the app's storage is recorded** on every runtime leg, in the emulator gate and on Test Lab's phone (`RuntimeCommandsTest` g, not judged). The plan's risk table had W4 measure it for Play's rule on downloaded code, and W4 had not. **It loads** on every version measured, API 26, 27, 28, 34 and 36, and on the Pixel 8a (exit gate 44900930980): Android 10's rule stops a program in app storage from running, not a library from loading. The owner's Play review gets the measurement.
- **The docs are synced with what Phase 5 built:** the terminal's architecture, security (§2.1's list now built, §6's two signing keys), the ADRs, the architecture (a new §2.11 for the terminal and Run), the runtime's integration, the editor (the composition), the build (CI's Phase 5 jobs), testing, performance, the repository's layout, the stack, the design system, the Play drafts (the listing with the terminal and Run, the licence review in the closed test's table), the roadmap and the README.
- Verified by: the bootstrap run 44899559170 (`+1090: All tests passed!`, `kotlin_tests=188`); the exit gate 44900930980, whole, every group on its first attempt (the five runtime legs 28 of 28 each; the cold start 1,130 ms); Test Lab's Pixel 8a in the same run, 32 of 32, with echo 38.4 ms at p95, the terminal open 44.6 MB, and 130.2 MB after a flood, recorded.

### Added — Phase 5 W6, the terminal gate on real targets (plan: [phases/PHASE_5_PLAN.md](phases/PHASE_5_PLAN.md))
- **The terminal draws with WebGL** where the phone's GPU is real (xterm.js's addon-webgl 0.19.0), and with the DOM elsewhere: no WebGL2, a software GPU such as the emulator's, or a context Android takes back, which it tries again when the app comes back. Chosen with numbers ([TERMINAL_ARCHITECTURE.md](TERMINAL_ARCHITECTURE.md) §2.2): on a Pixel 8a it drew a 10 MiB flood in 3.0 s against 4.1 s, with far fewer dropped frames, and only it kept typing's echo within 50 ms.
- **ADR-0006's budgets, measured on a phone** (Test Lab's Pixel 8a, Android 14, a profile build): input to echo 48.4 ms at the 95th percentile; the flood whole, with 0.5 % of the app's frames over 32 ms and none frozen. **The memory budget was not met:** 85.2 MB more with the terminal open at its full stop, 153.7 MB once settled after the flood, against 80 MB; most of it a second WebView's surfaces, and garbage the page had not collected yet. The owner decided to work it down first, then to judge what remains as found (PHASE_5_PLAN §10, item 7).
- **The terminal takes far less memory** (that work): on the Pixel 8a **53.6 MB with it open**, against 85.2 MB, and 114.8 MB once settled after the flood, against 153.7 MB; the app before any terminal 32.5 MB smaller too. Three changes: on Android 14 and later with Vulkan both WebViews, the editor's and the terminal's, are composed with **Hybrid Composition++** instead of being copied into textures (the manifest's `EnableHcpp`; other phones keep Flutter's texture layer); the terminal's output reaches its page through a **MessagePort** instead of a script per batch; and **only the session on screen draws with WebGL**, while the app shows.
- **Typing in the terminal echoes faster** on that phone: 37.5 ms at the 95th percentile with WebGL, against 48.4 ms, and 40.6 ms with the DOM renderer, against 62.3 ms; during the flood none of the app's frames took over 32 ms.
- **Test Lab judges the terminal's memory as the owner decided:** open and idle at its full stop within 90 MB; a flood's growth recorded, not judged. It also requires Hybrid Composition++ and the page's port on the phone.
- **The terminal measures itself:** the page types characters as an input method does and times each echo to the frame that draws it, and counts, hashes and times a flood between two marks (protocol messages `probe.echo`, `probe.flood`, `probe.read`). The emulator's terminal group records the figures every phase gate; Test Lab's phone holds them to the budgets.
- **less and the node REPL** fit the terminal in portrait and landscape too, and nano and less redraw at the new size when the phone turns under them.
- **A folder's copy, measured on a phone:** the gate folder's 1,006 files copied in 7.4 s, then in 0.8 s when nothing had changed, and 1.1 s after one file did. The phone's test drives Android's folder picker itself, through the accessibility tree.
- **Test Lab's app is a profile build,** its Dart compiled ahead of time as the app ships, so the phone's figures are the shipped app's.
- Verified by: the bootstrap runs 44816821921, 44862901068 and 44866950104 (`+1086: All tests passed!`, `kotlin_tests=188`); phase gate 44870622961, whole (cold start 1,117 ms; the composition suite 10 of 10); Test Lab's Pixel 8a in CI 44868218258, every class passing and only the memory budget failing. The memory work: the bootstrap run 44882599973 (`+1090: All tests passed!`, `kotlin_tests=188`); phase gate 44883909195, whole (the composition suite 10 of 10); Test Lab's Pixel 8a in CI 44889362793, every class passing and only the old flood budget failing, which the judge no longer requires; plain CI 44892056800, then Test Lab's Pixel 8a in CI 44893095694, whole (the terminal open 55.3 MB, echo 37.2 ms, no slow frame in the flood).

### Added — Phase 5 W5, sessions that last (plan: [phases/PHASE_5_PLAN.md](phases/PHASE_5_PLAN.md))
- **Sessions go on while you're in another app** ([TERMINAL_ARCHITECTURE.md](TERMINAL_ARCHITECTURE.md) §4): a foreground service runs while any terminal session or run does, with the notification "*N* terminal sessions running" and *End all*. It starts with the first session, stops after the last, and never starts by itself. Its type is `specialUse`, since `dataSync` would stop a session after six hours a day. On Android 13 and later the app asks once, at the first session, to show the notification; declined, sessions still run.
- **When Android ends the app anyway,** the sessions' processes end with it (measured: none was left after the app's process was killed), and the next start shows each session's tab with what became of it: "exited with code *N*", or "ended by the system".
- **In the background** every view lets go, and coming back draws the session from the host's buffer; under memory pressure the hidden sessions' buffers shrink to their last 64 KiB and their views go. Nothing is ended to free memory.
- **Limits** for every session, each measured on API 26 to 36 before it was set: a 4 GiB file size, 2,048 processes and threads, and an OOM score of 800, so the kernel takes a runaway session before the app. No CPU-time limit: a long build is legitimate.
- **SECURITY §2.2** is complete: T10 to T16, the service, the app's death, memory, the limits and the manifest, each with its mitigation and its proof.
- **The release manifest gate** allows exactly INTERNET, the service's three permissions and androidx.core's own, and `SessionService` as the only service, of type `specialUse` alone. docs/store says why, and drafts Play's special-use declaration for the owner.
- **Found and fixed:** the runtime said it was ready a moment before the install let go of its files, so a session started at that moment was refused (API 27 and 34). And npm's update notice, which told the user to replace the npm the app ships, is off: npm comes with the app at its pin.
- Verified by: the bootstrap run 44732997918 (`+1076: All tests passed!`, `kotlin_tests=187`); phase gates 44735804283, 44744464658, 44752660910 and 44763350329 (PHASE_5_PLAN *As built (W5)*), then 44777091949, whole: 332 s in the background with the heartbeat never stopping, and no process left after the app's death. On a Google Pixel 8a with Android 14 (Test Lab, CI 44786509685): `SessionServiceTest` 4/4, *End all* in 143 ms, the limits as on the emulators, and the OOM score raised.

### Added — Phase 5 W4, Run (plan: [phases/PHASE_5_PLAN.md](phases/PHASE_5_PLAN.md))
- **Run Current File and Run Project** ([TERMINAL_ARCHITECTURE.md](TERMINAL_ARCHITECTURE.md) §3): JavaScript (`.js`, `.mjs`, `.cjs`) with node, Python with python, shell scripts with bash, and now Ruby and Perl, which the runtime carries; a script without an extension counts by its `#!` line. Run Project offers the project's `package.json` scripts (`npm run <script>`, in the file's order), then its entry file. In the Run panel, the palette (Run Current File, Run Project…, Stop the Last Run) and with Ctrl+F5 and Shift+F5.
- **Each run is a terminal session,** named for what runs, with a status chip (Running, Exit N, Signal N, Ended) in the Run panel and the status strip. **Stop** ends the run's whole tree; its output stays. Unsaved changes are saved first, unless Settings → Save before running is off.
- **Folders run through a copy** ([ADR-0013](adr/0013-folders-and-the-runtime.md), as built): the first run copies the folder into the app's storage (in Kotlin, four files at a time, `.git` left out, the panel showing how far it is, with Cancel); later runs copy only what changed, in the folder or in the copy. Caps: 10,000 files, 512 MB, 64 MB a file, and the copy says what it left out. The Run panel lists the files runs made there, to **Export to folder**. **Import as project** (Home's recents, the folder's explorer) copies a whole folder, git included, into a new project.
- **Output links:** `file:line` in a run's output (node's stack frames, Python's tracebacks, Ruby, Perl, bash, compilers) opens the file at that line, from a tap or a click (xterm.js's link API).
- **The native-addon limitation, said where it happens:** when npm's node-gyp or prebuild, or pip building a C extension, fails for want of a compiler, the terminal says why (no compiler ships yet; Android won't run programs written to app storage) and what works instead. Settings → Linux runtime describes it too.
- **The E2E scenario, part 1,** is part of the emulator gate: a new file in the demo project, a program typed through the editor, saved, run, its output checked; then edited, run again (Run saves it), the new output checked.
- Verified by: CI 44689410417 and the bootstrap run 44705297317 (`+1072: All tests passed!`, `kotlin_tests=182`); phase gates 44690833991 and 44697552696, whose new run group found npm 12's ways (PHASE_5_PLAN *As built (W4)*), then 44707562888, whole: the first copy of the gate folder's 1,006 files in 4,781 ms, the next ones in about 500 ms.

### Added — Phase 5 W3, the terminal view (plan: [phases/PHASE_5_PLAN.md](phases/PHASE_5_PLAN.md))
- **A real terminal in the workbench:** xterm.js 6.0.0, with addon-fit 0.11.0 and addon-unicode11 0.9.0, on a page of its own. It is built in `editor/` with the editor page's kit: one file, an inline script whose hash the CSP pins, nothing fetched, the licences beside it ([TERMINAL_ARCHITECTURE.md](TERMINAL_ARCHITECTURE.md) §2.1). One WebView holds a terminal per session. The terminal pane now runs W2's sessions on the sealed runtime, and the preview is gone.
- **The terminal protocol v1:** the editor protocol's envelope and rules, a strict validator on each side, and 67 contract fixtures shared by vitest and Dart. Output is acknowledged once xterm.js has parsed it, and that is the session's credit: a flood waits in the kernel, not in the app or the WebView.
- **The panel** ([TERMINAL_ARCHITECTURE.md](TERMINAL_ARCHITECTURE.md) §3):
  - tabs: new, rename, close (a running one asks first), and a swipe between them;
  - the extra-keys row: Esc, Ctrl and Alt (latched for one key), Tab, the arrows, `|`, `~`, `/` and more, sent as the terminal's modes expect;
  - Copy and Paste, pastes sanitized and bracketed when the program asks;
  - touch: a drag scrolls (arrow keys in nano or less), a long press selects, a tap brings up the keyboard;
  - the theme's colours and the bundled font;
  - Maximize and Restore size, which beside the editor (landscape, tablets) leave the editor a peek.
- **The input method's text takes one path** (`ime.ts`): sent once, in order, as it is committed; a composition shows at the cursor until it ends. xterm.js's own handling garbled Android's input methods.
- **Proven on the emulator** (phase gate 44606021478, API 36, Gboard): typed text echoes and runs; nano and top draw at the panel's size in portrait, in landscape and in portrait again; the composition suite's ten cases (predictive Latin, autocorrect, pinyin, Japanese, Hangul, emoji, a canceled composition, the input method's backspace and more) arrive whole.
- **Found and fixed,** each by the emulator's terminal group:
  - the test binding dropped the gate's own touches;
  - the page canceled every touch, and a WebView takes the focus only from a tap it sees, so a tap never brought the keyboard;
  - `echo cf-typed-ok`, typed through Android's input pipeline, arrived as `echohoocf--ttypped-ok`;
  - beside the editor, a phone on its side left an open terminal a row or two, or hid it;
  - a connected input method finishes the compositions it did not start, shown or not, so the scripted suite plays with the input methods off, as the editor's suite has none connected.
- **A WebView older than Chrome 87** is refused, saying what to update, as the editor is (the API 27 image has WebView 61).
- Verified by:
  - the bootstrap runs 44518519957 (`+1031: All tests passed!`) and 44572951140 (`+1033: All tests passed!`);
  - phase gates 44520440304, 44557551890, 44575917666, 44589259655 and 44596547784, then 44606021478 (PHASE_5_PLAN *As built (W3)*).

### Added — Phase 5 W2, the PTY and terminal sessions (plan: [phases/PHASE_5_PLAN.md](phases/PHASE_5_PLAN.md))
- **A pseudo-terminal CodeForge writes itself** ([ADR-0014](adr/0014-pty-and-sessions.md), [TERMINAL_ARCHITECTURE.md](TERMINAL_ARCHITECTURE.md) §1). It is the launcher's new terminal mode: the launcher opens the PTY, runs the program on it as its session's leader, and relays between it and the app under a small framed protocol (input, window sizes). Nothing forks inside the app's process, and a session's whole tree ends as a command's does. No Termux code (AGENTS §4).
- **Terminal sessions in the host:**
  - **The shell:** the runtime's bash with CodeForge's rc file (a prompt, then `~/.bashrc`), or a named program such as node's REPL. With no bash, the session fails; it never falls back to another shell.
  - **Output:** a 1 MiB buffer for a view that attaches later. Batches go at most every 16 ms, the first bytes at once. Credit flow control: a flood blocks in the kernel instead of filling the app.
  - **Limits:** at most eight sessions, the ninth refused. *End all* ends them all.
  - **Folders and environment:** a project's folder, named by the host, never a path from Dart. The terminal's `TERM`, `COLORTERM` and `TERMINFO`.
  - **The API:** a Pigeon API with a Flutter API for output, and Dart's client. The workbench's pane keeps its preview until W3's xterm.js view.
- **Measured** on the emulators, API 26 to 36 (phase gates 44461809588 and 44475934378):
  - a keystroke's echo through the whole host path: p95 0.68 to 3.19 ms, against ADR-0006's 50 ms;
  - a 10 MiB flood: whole in 0.67 to 0.88 s, the Java heap growing at most 2,155 KiB;
  - *End all*: 102 to 114 ms, leaving no process.

  On a Google Pixel 8a with Android 14 (Test Lab): echo p95 8.38 ms, the flood whole in 1.04 s, *End all* in 112 ms.
- **Found and fixed:**
  - Phase 3's outside changes: a batch under way when the app went to the background could still reload a clean document while away. Now nothing is taken in until the app comes back, as designed (the emulator's watch group).
  - *End all* returned a moment before the sessions' places were free, so a start right after it could be refused (API 26).
  - An end could not reach a session whose view had stopped acknowledging.
- **SECURITY §2.2** begins with the sessions' threats, T1 to T8; W5 completes it with the limits and the foreground service.
- Verified by:
  - CI 44445690182 (`test-pty.py`, 19 tests);
  - the bootstrap run 44451456079 (`+902: All tests passed!`; `kotlin_tests=161`, 23 more), and 44474274477 after the watch fix (`+904: All tests passed!`);
  - phase gates 44454605348 and 44461809588, then 44475934378, the first to pass whole;
  - Test Lab in CI 44482754814: 25 of 25 tests on the phone, `TerminalSessionTest`'s seven among them (PHASE_5_PLAN *As built (W2)*).

### Added — Phase 5 W1, the release workflow, the source archive, and the licences in the app (plan: [phases/PHASE_5_PLAN.md](phases/PHASE_5_PLAN.md))
- **The release workflow** (`.github/workflows/release.yml`). A `[release]` tag in a commit's subject line runs a dry run after CI's own build:
  - an arm64 App Bundle signed with an upload key, and an APK signed with a release key, both throwaway keys made in the job;
  - seven checks: Play's per-device size, the runtime in the APK, 16 KB alignment, the release manifest, the notices, and each file's signer;
  - the source archive, and `SHA256SUMS`.

  Publishing a draft GitHub Release is written, and switched off until the owner's keys exist (BUILD_AND_RELEASE §2.5 and §5). Dry run CI 44399784786 passed whole: 146.2 MB per device (73.1 % of Play's limit), 258 of 258 objects aligned, one signer each.
- **The source archive** (`runtime/sources.py`). For each of the 55 copyleft package versions: Termux's recipe at the commit that built it, Termux's build system, every upstream file verified against the recipe's SHA-256, and a manifest. It is reproducible, fails closed, and falls back to mirrors when a host fails. The first: 261,662,720 bytes, 69 upstream files (SOURCE_OFFER.md).
- **The licences in the app.** About → Source code shows the written offer, About → CodeForge's license shows the repository's LICENSE, and Open-source licenses now lists the userland's packages with their texts (`app/assets/licenses/userland.txt`, written by runtime/notices.py and checked by CI). Two of SOURCE_OFFER's three items before the first distribution are done; the licence review remains the owner's.
- **The release build asks for INTERNET** (the owner's decision, 2026-11-18), so npm, pip and git work there. The store texts and the Data safety draft say so, and the release manifest gate allows INTERNET and nothing else new.
- **Found and fixed:** libdb's licence text, under a name termux-licenses has since changed (`RENAMED_TEXTS`); a pipe race in the signer check, which now has a self-test gate; a widget test waiting on the real zone.
- Verified by CI 44372237339, 44381310978 (`+895: All tests passed!`; the userland's texts written by its commit-back), the release dry runs 44389009942, 44394419519 and 44399784786, and phase gate 44405049032 (PHASE_5_PLAN *As built (W1)*).

### Phase 5's first decisions (2026-11-18)
- The owner decided: start with W1; the release build gets network access from Phase 5, so `npm install`, `pip install` and later `git clone` work there as they do in debug builds; the release workflow runs dry, signing with a throwaway key, until the owner adds the keys; the owner arranges the licence review, and no public binary goes out before it ([PHASE_5_PLAN.md](phases/PHASE_5_PLAN.md) §10).
- Found when W1 started: GitHub runs a manual workflow trigger only for workflows on the default branch, and `main` has none. So a `[release]` tag in a commit's subject line starts the release workflow's dry run, which ci.yml calls as a reusable workflow.

### Phase 5 planned (2026-11-18)
- [PHASE_5_PLAN.md](phases/PHASE_5_PLAN.md): the terminal and running code in seven work packages. First the release workflow, the source archive, and the offer and licences in the app, so that GitHub Releases and Play's closed test can start when the owner is ready. Then a PTY CodeForge writes itself, terminal sessions on the sealed runtime, the xterm.js view in the workbench, Run for files and projects (folders through ADR-0013's copy), a foreground service with *End all* and measured limits, and xterm.js's budgets on an arm64 phone. The owner decides the release keys, the first release, and network access for the release build (§10).

### Phase 4 accepted (2026-11-18)
- The owner accepted Phase 4 by saying "next" after its report ([PHASE_4_REPORT.md](phases/PHASE_4_REPORT.md)). The phone session, on the exit gate's APK, and Play's owner actions stay open and non-blocking.

### Changed — Phase 4 W7, t1 fixed in CodeForge's copy, the notices, Play's drafts and the phase exit (plan: [phases/PHASE_4_PLAN.md](phases/PHASE_4_PLAN.md), report: [phases/PHASE_4_REPORT.md](phases/PHASE_4_REPORT.md))
- **t1's installer is fixed where CodeForge uses it.** The owner said CodeForge may change t1 freely (2026-11-18). This account cannot push to t1, so the fix is applied to the vendored kernel as a recorded patch (`native/patches/`, two files), and CI checks the record against t1's files on every push ([native/PROVENANCE.md](../native/PROVENANCE.md)). The app installs through t1's own installer again: CodeForge's copy of its steps (`PayloadInstall`) and that copy's 4 tests are gone. The API-floor check now finds no unused vendored code: 0 violations, 1 guarded call, 0 dead entries (CI 44292608356).
- **The notices are complete** ([THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)): the 70 Dart packages in the app's dependency closure (a superset of what the compiler keeps), the editor page's 27 packages (all MIT), Flutter, its engine and the fonts, and every userland package with a licence. CI writes each list from the resolved dependencies or the pins, and fails when one goes stale.
- **No userland package is left without a licence.** For the 16 the text matching could not name, W7 read each package's Termux recipe and, at the pinned version, its upstream licence file; a subpackage with no text of its own points to its parent's. CI fails if a package ever ships without an identified licence, or if a named text is missing from the payload.
- **How the source is offered is decided** ([SOURCE_OFFER.md](../SOURCE_OFFER.md)): each binary that contains the userland is published with an archive of the copyleft packages' source and Termux's recipes, plus a written offer valid for at least three years. Building that archive, the offer in the app, and a licence review by a qualified person come before the first distribution.
- **Play is prepared, not submitted** ([docs/store/](store/README.md)): the listing, the Data safety answers (nothing collected, nothing shared, each with its reason), the privacy policy to publish, a release checklist, and who does what. The closed test is proposed to start with Phase 5's first work package, which builds the release workflow and the source archive.
- **The release build asks for no permissions, and CI keeps it so.** A new quality gate, *Release manifest*, reads the release build's merged manifest and fails on any permission but androidx.core's own signature permission. So the release build has no internet access, which is what the Data safety answers rely on (CI 44300179086).
- **The docs are synced with what Phase 4 built:** the architecture, the runtime's integration, security, the stack's runtime rows, the build, testing, performance, the repository's layout, the ADRs, the roadmap and the README. Phase 4's report and a runtime phone checklist close the phase.
- Verified by CI 44292608356, 44297145654 (`+885: All tests passed!`; 138 Kotlin tests, the 4 of `PayloadInstallTest` gone; 23 kernel tests), 44300179086 and 44329473907, and Phase 4's exit gate 44332891340: every group on its first attempt, the five runtime legs 16 of 16 each, and Test Lab's Pixel 8a 18 of 18 (3 of the day's 5). The patched kernel installs on API 26 to 28, where W5 found it failing.

### Added — Phase 4 W6, search across files (plan: [phases/PHASE_4_PLAN.md](phases/PHASE_4_PLAN.md))
- **The Search panel works.** Type a query, choose match case, whole word or regular expression, and narrow it to files to include or exclude (`src, *.js`). Results arrive grouped by file as they are found, and a tap opens the file with the cursor on the match. Stop keeps what was found.
- **Projects are searched by the runtime's ripgrep.** A 10,000-file project took about 120 ms on a Pixel 8a (110 to 150 ms on the emulator), with the first result after about 60 ms. `.gitignore` counts even without git, `.git`, `node_modules` and binary files stay out, and so does a file the editor would refuse. Stopping a search ends ripgrep at once, with nothing left running.
- **Folders from shared storage are searched too,** by CodeForge's own scan through the folder's grant, by the editor's rules for text and lines, and the same glob rules. It reads several files at a time; 1,000 small files took about 4.6 s on the emulator, where each file is a round trip to Android's storage provider. While the runtime installs, a project is searched the same way.
- **A budget for search** ([PERFORMANCE.md](PERFORMANCE.md)): on a mid-range phone, a project's first result within 0.5 s and all of 10,000 files within 2 s; a folder of 1,000 files within 6 s; a stop within 250 ms.
- **How a folder will run code** is decided ([ADR-0013](adr/0013-folders-and-the-runtime.md)): Phase 5 runs it in an incremental, one-way copy in the app's storage, with *Import as project* beside it. Copying the gate's 1,008-file folder through today's broker took 6 to 10 s on the emulator.
- **Found before the gate:** ripgrep reads its globs from the folder it runs in, so an include with a slash matched nothing. It now runs in the project. A local check against real ripgrep 13 and 14 caught it, and the gate test covers it.
- Verified by CI 44262330746, 44264577788, 44273190097 and 44275357542 (`+885: All tests passed!`; 142 Kotlin tests, 37 of them new, none skipped), phase gates 44264577788 and 44275357542 (the new `search` group and every other group passed), and Test Lab in CI 44275357542 (18 of 18 tests on the Pixel 8a, 2 of the day's 5).

### Changed — W5's three decisions, and CI in one workflow (2026-11-18)
The owner left W5's open decisions to the agent and asked for CI and the phase gate in one workflow.
- **The session store now syncs every change to storage** (`synchronous = FULL`, [ADR-0008](adr/0008-persistence.md)). Typing saved before an operating-system crash or a power cut is no longer lost. The phone measured the cost at about 0.1 ms per change.
- **A phone whose Android System WebView is too old for the editor now says so.** The editor page needs version 87 or later, and a phone with Android 8 or 9 that never updated its WebView has 61 to 69. Instead of failing to start after 20 seconds, the editor names the phone's version and what to update, and *Try again* works once it is updated ([ADR-0007](adr/0007-min-sdk.md)).
- **A fix for t1 is ready for its owner.** *(Superseded in W7: the fix is applied in CodeForge's copy; above.)* CodeForge keeps installing through its own steps (`PayloadInstall`). The fix for t1's API 33 call waits in `native/upstream/` as a patch with a test, and CI tests it against the vendored kernel on every push without shipping it ([native/PROVENANCE.md](../native/PROVENANCE.md)).
- **CI and the phase gate are one workflow** (`ci.yml`; `phase-gate.yml` is gone). A `[phase-gate]` push starts one run, whose verdict covers the build, the tests and the gate. Plain runs never wait behind a gate ([BUILD_AND_RELEASE.md §2.4](BUILD_AND_RELEASE.md), [ADR-0009](adr/0009-ci-github-actions.md)).

### Added — Phase 4 W5, the runtime gates (plan: [phases/PHASE_4_PLAN.md](phases/PHASE_4_PLAN.md))
- **The runtime is proven on real targets.** t1's two on-device gates, ported to CodeForge's host, pass with the runtime's install and command tests on emulators with Android 8.0, 8.1, 9, 14 and 16, in every phase gate from now on. They also pass on a physical Google Pixel 8a with Android 14 in Firebase Test Lab.
- **On the Pixel 8a,** a mid-range phone, the first install took 13.6 s (17.6 s through the app's own start path), within the 60 s budget. A warm start took 73 ms, within 100 ms. Every program came from the app, all seven tools matched their pins, and no command left a process behind.
- **minSdk 26 is confirmed** ([ADR-0007](adr/0007-min-sdk.md), Accepted): Android 8.0 and later.
- **Fixed: the runtime could not install on Android 8.0 to 12L.** t1's installer reads its manifest with a Java method Android added only in Android 13, and nothing at build time said so. The gates measured the crash on Android 8 and 9. CodeForge now installs through the same kernel steps without that call, and leaves t1's files untouched.
- **CI now checks the API floor on every push:** every method, field and class the app's own and vendored code uses must exist on Android 8.0, sit behind a version check, or be vendored code the app never calls.
- **Measured on the phone:** the session store's safer sync mode, `FULL`, cost about 0.1 ms per change ([ADR-0008](adr/0008-persistence.md)). Whether to switch to it is the owner's call. *(Decided on 2026-11-18: `FULL`; above.)*
- **CI found two faults of its own and fixed them:** the app and its test APK came from two builds signed with different keys, and one leg's evidence overwrote another's. A check now compares the signatures before a device is spent, so no physical test was used on either fault.
- Verified by CI 44233761227, 44239443972 and 44244875981 (`+866: All tests passed!`; 105 Kotlin tests, 4 of them new, none skipped; 22 kernel tests; the API floor with no violation), phase gate 44239443885 (five runtime legs, 16 of 16 tests each, and every emulator group on its first attempt), and Test Lab in CI 44240926191 (17 of 17 tests on the Pixel 8a, 1 of the day's 5 tests).

### Added — Firebase Test Lab connected (2026-11-17)
- **CI reaches Test Lab's real phones.** A Robo crawl of the debug APK passed on a Google Pixel 10 (API 36) in 192 s (CI 44167128978). Its results went to Test Lab's own bucket, on the no-cost plan without billing, as expected. W5's arm64 gates build on this.
- **The key's account needed the Editor role on the project itself.** The owner's key is the Firebase Admin SDK account's, which on its own can't use Test Lab, so listing the phones was refused (403) until the owner added the role and enabled the two APIs.
- **A refused key now explains itself at no cost:** when listing fails, `app/tool/ci/testlab_diagnose.py` reports the key's account, its roles on the project and the two APIs, with one hint, and prints no id. Plain CI runs the self-tests of both Test Lab scripts on every push.
- `FIREBASE_PROJECT_ID` can be a repository variable or a secret.
- **Spending Test Lab runs** (the owner's rule): a change passes plain CI first, and only a separate commit after it uses Test Lab ([BUILD_AND_RELEASE.md §4](BUILD_AND_RELEASE.md)). Today's runs used 1 of the 5 free physical-device tests; the two refused checks used none.

### Added — Phase 4 W4, commands, tools and versions in the UI (plan: [phases/PHASE_4_PLAN.md](phases/PHASE_4_PLAN.md))
- **The runtime runs commands.** The host runs a program of the runtime through a small launcher of CodeForge's own (`libcodeforge-spawn.so`). The answer is typed: the exit code or signal, stdout and stderr apart (each capped, with its full size), the time taken, and why it failed if it did. The app uses it only for its own checks for now; running your code comes with Phase 5.
- **Every command ends with its whole process tree.** That includes a child left running, a process that left the group and a double-forked daemon, whether the command exits, runs past its time limit or is stopped. The emulator gate found none left.
- **A command's environment is built from nothing:** up to six of Android's system locations, and the runtime's own variables, with HOME, TMPDIR and XDG in the runtime's folder. Nothing else of the app's process reaches it. The interpreters' homes are set explicitly, and the only preload is CodeForge's.
- **Settings → Linux runtime → Tools** runs node, python, git, bash, perl, ruby and rg once each, and compares each version with its pinned package. On the emulator all seven matched: node 26.13.1, python 3.14.10, git 2.56.1, bash 5.3.9, perl 5.44.0, ruby 4.0.9 and rg 15.2.0. A **Languages** section names what the runtime can execute.
- **The capability model:** JavaScript, Python and shell scripts are *executable* once the runtime is ready. Only the flag changes, and the language chip says so in its tooltip; shell scripts are recognised by extension or `#!` line.
- **CodeForge writes its own environment, runner and probes** instead of vendoring t1's, which need its apt shape, preload `termux-exec`, and end only a command's first process ([native/PROVENANCE.md](../native/PROVENANCE.md)).
- **The security review of the new boundary** is in [SECURITY.md §2.1](SECURITY.md): eight threats with their mitigations and proofs, and the limits that come before Phase 5 runs your code.
- **CI** now fails, rather than skips, the runner's real-process tests when it lacks a C compiler, and counts skipped Kotlin tests (none).
- Verified by CI 43830252596, 43833197358 and 43835601536 (`+866: All tests passed!`; 101 Kotlin tests, 30 of them new, none skipped; 22 kernel tests; 16 launcher tests), and phase gate 43837693816 (every group on its first attempt; 12 instrumented runtime tests; the seven tools *ok* in Settings; `node` through `exec` printing 42). The gate's cold start was 1,250 ms, within the 1,500 ms budget but above W3's 847 ms; the emulator was slower throughout that run (PHASE_4_PLAN *As built (W4)*).

### Added — Phase 4 W3, the runtime installs, starts warm and audits (plan: [phases/PHASE_4_PLAN.md](phases/PHASE_4_PLAN.md))
- **The app carries the sealed runtime.** A build for one ABI carries that ABI's payload: Termux's bootstrap with the pinned packages, 13,894 files for x86_64. Its 535 programs, 251 distinct executables, ship as native libraries, so they run from the app's own library folder, never from its data.
- **It installs when a workspace opens,** off the UI thread, while the editor works, with progress in the status strip. Every file is verified while it is written. A damaged payload fails with a typed reason, and nothing is marked installed. On the CI emulator the install took 3.5 s, and 6.6 s through the app.
- **Later starts extract nothing:** 18 ms on the emulator, within the 100 ms budget. When an app update moves the libraries, the links follow them.
- **Every start checks that every program comes from the app** (t1's exec audit). The gate found none outside it. A program outside it would mark the runtime degraded, and the app says so.
- **Settings → Runtime** shows the state, the payload with its pinned tool versions, the install and start times, the space used and the program check. It offers *Install now*, *Reinstall* and a report to copy. The status strip shows the runtime's state.
- **Less of t1 is vendored than planned:** `HarnessConfig`, `HarnessPaths` and the payload installer, with their packages renamed, and the preload's two C files unchanged. The other classes the plan listed would need edits to drop t1's apt shape, and vendored files are never edited, so the host is CodeForge's own code. Three classes move to W4 ([native/PROVENANCE.md](../native/PROVENANCE.md)).
- **Sizes:** the release x86_64 APK is 149.4 MB (24.6 MB before) and the arm64 phone APK 164.2 MB. An arm64 device downloads 147.3 MB of the app bundle, 73.7% of Play's 200 MB limit. The 32-bit ARM build is dropped.
- **CI checks what each APK carries,** and builds the instrumented tests on every run. The phase gate has a runtime group, and its time limit is 100 minutes.
- **Gradle's own report** in `app/android/build/` is ignored, after a bootstrap run had committed it.
- Verified by CI 43807290310, 43808489952 and 43815154032 (`+857: All tests passed!`; 71 Kotlin tests, 27 of them new; 22 kernel tests), and phase gate 43808489945 (every group on its first attempt; the runtime's 6 instrumented tests and the pair through the app).

### Added — Firebase Test Lab connection check (2026-11-15)
- The owner created CodeForge's Firebase project, on the no-cost plan. A commit with `[testlab]` in its subject line now runs a crawl of the app on a real arm64 phone in Test Lab, picked for spare capacity and the newest supported Android version. It proves the CI connection before W5's runtime gates rely on it.
- **Correction:** the service account needs the Editor role. Firebase requires it for tests that keep their results in Test Lab's own bucket, which is the only option without billing. The narrower pair of roles named before works only with a bucket of one's own.

### Added — Phase 4 W2, provenance, pins and the sealed-runtime kernel (plan: [phases/PHASE_4_PLAN.md](phases/PHASE_4_PLAN.md))
- **t1's sealed-runtime kernel is vendored** (`native/sealed-runtime/`), from t1 `d9789a2`, now Apache-2.0 like CodeForge. Its 8 classes and 3 test classes differ from t1 only in their package, and its 22 tests run in CI.
- **Every input of the runtime is pinned** (`runtime/pins.json`): the Termux bootstrap for each ABI and 50 packages per ABI, each by version and SHA-256. A build takes exactly those files, and stops when one is gone, naming the package. Re-pinning is a deliberate `[repin]` commit.
- **The payload is consistent.** The first resolution left the bootstrap's `curl` and `xz-utils` beside newer libraries that they require at exact versions. Resolving now brings such packages along, and the check covers the whole payload.
- **[native/PROVENANCE.md](../native/PROVENANCE.md)** records every vendored file with both hashes, and CI proves that each one differs from t1 only by its recorded change.
- **The notices are drafted.** [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) lists the userland's 112 package versions with their licences, read from the packages' own licence files. [SOURCE_OFFER.md](../SOURCE_OFFER.md) lists the 52 that are copyleft. W7 completes both.
- **CI has a runtime job:** the script tests, the provenance and pins checks, the fetch for both ABIs, a live check that a missing pinned package fails the build, the payloads and the notices.
- Verified by CI 43401882656 (`+846: All tests passed!`; 22 kernel tests; 44 Kotlin tests) and 43403453442.

### Changed — Phase 4 W1, toolchain (plan: [phases/PHASE_4_PLAN.md](phases/PHASE_4_PLAN.md))
- **Flutter 3.50.0**, with the Android pins of its template: Kotlin's Gradle plugin 2.4.20 and Gradle 9.5.0, and Android Gradle Plugin 9.3.3, the latest patch of the template's 9.3 line, because 9.3.1's lint crashes release builds on JDK 17. Upgraded together as the owner decided.
- **The Material widgets come from `package:material_ui`** (1.10.0), because Flutter 3.50 deprecates the framework's copy. All 87 files that imported it moved, by Flutter's own fix, and analysis now flags any new import of the old library. The app looks the same: none of the 26 golden images changed.
- **Screens still change without a transition.** The router builds the same transition-free pages go_router used before; go_router would otherwise have switched to Material's transitions once the app used `material_ui`.
- **Release builds work on Flutter 3.50.0.** Its Dart compiler crashes when building a release or profile app containing one shape of code ([dart-lang/sdk#64917](https://github.com/dart-lang/sdk/issues/64917)), which Home's folder reconnect had; that code is restructured, with the same behaviour.
- **CI builds a release APK on every run**, so a failure that only release builds show is caught there, not first in the phase gate. The phase gate keeps the logs of its builds with its evidence.
- **CI uses the Node 24 versions of GitHub's actions** (checkout, setup-java, cache, upload-artifact, download-artifact, setup-node), each read against its release notes.
- The debug APK is about 1.9 MB smaller: 175,890,252 bytes, from 177,806,969 at Phase 3's exit.
- **The watch gate waits for its last notice** before it ends: it once failed on a snack bar still animating at teardown, after every check had passed.
- **Cold start on the CI emulator: 879 ms** with the release build (1302 ms at Phase 3's exit; 793 ms with Skia). The exit phone session now uses W1's build ([PHASE_3_PHONE_CHECKLIST.md](phases/PHASE_3_PHONE_CHECKLIST.md)).
- Verified by CI 43373527631 (`+846: All tests passed!`; analysis clean; 44 Kotlin tests), 43375227087, 43379964388 and 43384226740, and phase gate 43384226759 (every group on its first attempt). Gates 43375227077 and 43379964330 found the release-build and test-timing problems fixed here.

### Licence decided (2026-11-12)
- **CodeForge is licensed under the Apache License 2.0** (`LICENSE`; the owner's decision, [ADR-0011](adr/0011-license.md) path B). By ADR-0006's rule the terminal frontend is therefore xterm.js: Termux's GPLv3 terminal modules are never vendored, and Phase 5 writes the PTY. t1 takes the same licence before Phase 4 vendors its code.

### Phase 4 planned (2026-11-12)
- [PHASE_4_PLAN.md](phases/PHASE_4_PLAN.md): runtime integration in seven work packages, starting with the toolchain upgrade (Flutter 3.50.0, AGP 9.3.1, Kotlin 2.4.20, Gradle 9.5.0, and the move to `package:material_ui` that 3.50 requires). The vendoring waits for the licence decision (ADR-0011). Found while planning: t1's code was merged as PR #229; Firebase Test Lab shuts down on 2027-09-30.

### Phase 3 accepted (2026-11-12)
- The owner accepted Phase 3 and decided: the exit phone session runs after the next slice of work; G7's cold start is judged by that session's phone figure, and Impeller stays; FULL against NORMAL (ADR-0008) moves to Phase 4's Firebase Test Lab runs; Flutter 3.50.0, the Android Gradle Plugin and Kotlin's Gradle plugin are upgraded together ([PHASE_3_REPORT.md](phases/PHASE_3_REPORT.md) §1).

### Changed — Phase 3 W7, documentation and phase exit (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md); report: [phases/PHASE_3_REPORT.md](phases/PHASE_3_REPORT.md))
- **What's still to come names the right phase:** Settings no longer lists folders as coming (they open from Home since Phase 3), and gives extensions Phase 8. The workbench's panels say search arrives in Phase 4, source control in Phase 7, extensions in Phase 8, and running in Phase 5 with debugging in Phase 9. The status bar's branch chip says Git arrives in Phase 7. The search panel points to Go to File for finding a file by name.
- **Phase 3's report** ([PHASE_3_REPORT.md](phases/PHASE_3_REPORT.md)): every gate with its evidence, the measurements, what is not reliably met (the release cold start on the emulator with Impeller, over the budget in two of five gates), and four decisions for the owner.
- **One phone checklist for the exit session** ([PHASE_3_PHONE_CHECKLIST.md](phases/PHASE_3_PHONE_CHECKLIST.md)): every check parked since Phase 1, about 75 minutes on the exit gate's profile APK.
- **Docs synced** with Phase 3 as built: architecture (the broker, Pigeon, the data model), editor files, security (the storage review done), runtime storage model, tech stack, performance, design system, roadmap and README.
- W7 verified by CI 43284276980 (`01:38 +846: All tests passed!`) and phase gate 43284276984 (every group on its first try; cold start 1302 ms).

### Added — Phase 3 W6, tests, performance and quality (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Impeller:** the app now draws with Impeller, Flutter's default renderer, instead of Skia, which Flutter 3.47 deprecates as an opt-out. Every phase-gate group passed with it on the CI emulator. There, with software graphics, it starts the app 0.3 to 0.5 s slower than Skia, and in two of four runs over the 1.5 s budget. The phone check before the phase ends decides.
- **No pause when a very large file is first edited or restored:** the fingerprint CodeForge keeps of a file's saved text, to know after a restart whether the file changed, is taken in the background for files of 64 KiB and more. On the emulator, the screen kept drawing while 10 MiB was fingerprinted (13 or 14 frames, at most 96 to 140 ms apart); before, it stopped for 260 to 280 ms.
- **Log viewer** (Settings → Developer, in debug and profile builds): this session's log, newest first, narrowed by level and by tag, following new entries and copying what it shows. Entries are redacted as everywhere else.
- **Failures inside the app's state are logged**, redacted like every other entry, so a problem that shows no message still leaves a trace in the log.
- **Measured on the emulator,** in three runs: a project of 10,000 files opened in about 0.3 s, and Go to File indexed it in 0.21 to 0.24 s. A folder of 1,000 files from shared storage was listed in 0.48 to 0.58 s. Writing or reading 10 MiB took 0.03 to 0.08 s in a project, and 0.08 to 0.16 s in a folder from shared storage.
- **Quality checks:** a CI check fails the build if the app ever declares a storage permission or its backup settings drift from ADR-0012; golden tests that fail commit their images back, so a difference can be seen without downloading anything; the editor benchmark's driver reconnects when its connection to the page drops, no longer waits without limit on a page that stops answering, and talks only to CodeForge's own WebView, never another app's. Between them, these had cost two gates one engine's figures and stalled a third for half an hour.
- **Accessibility:** the automated sweep now covers Home's dialogs, a recent's actions, the explorer's menu, Settings → Privacy and the log viewer, and Home's dialogs are checked beside the keyboard at every screen size; four new goldens show Home's recents, the explorer's menu, the changed-on-disk banner and Privacy.
- W6 verified by CI 43247964184 (`+839: All tests passed!`, goldens `+26: All tests passed!`, Kotlin 44 of 44, the manifest check passed), CI 43256861484 and 43270593998 (the benchmark driver), phase gate 43238952262 (Impeller, every group on its first try), phase gate 43247963954 (every group on its first try, with the measurements; its benchmark driver missed CodeMirror), phase gate 43256861510 (both engines driven; adb stalled, and CodeMirror passed on its second attempt) and phase gate 43270594252 (every group on its first try, both engines driven; cold start 1527 ms, over the budget).

### Added — Phase 3 W5, outside changes (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Files changed by other apps show as it happens:** when a formatter, git, a sync app or another editor changes an open file that has no unsaved changes, the editor shows the new text, keeps the cursor and scroll as close as it can, and says the file was reloaded. On the emulator the new text showed 0.6 to 0.8 s after the write, in a project and in a folder from shared storage.
- **Unsaved text is never overwritten:** if you were typing, or the file had unsaved changes, your text stays. A banner over the editor says the file changed on disk and offers *Keep mine* or *Use the file*, which asks first; typing goes on meanwhile. Saving before you choose asks whether to overwrite the other app's version.
- **Deleted files:** an open file deleted by another app closes its tab, with a notice, when it has no unsaved changes; with unsaved changes the tab stays, marked deleted on disk, until you save it again or close it.
- **The explorer and Go to File follow:** files and folders that other apps create or delete appear and disappear in the folders the explorer shows, and Go to File's list follows. A tool that rewrites many files at once refreshes each folder once.
- **Your own saves** cause no reload and no question.
- **In the background** nothing is checked; coming back catches up (on the emulator, within a second).
- **What is watched:** the workspace's top folder, the folders of open files and the expanded folders, up to 64; open files are also compared with their files every 5 seconds, for storage that does not report changes.
- **Tests:** the watching and every case above, over an in-memory workspace whose changes made "by another app" are reported, and in the workbench; the file services' new checks; the editor page's guarded replace, with protocol fixtures on both sides. A new phase-gate group, `watch`, changes files behind the app's back on the emulator, in a project and in a folder picked in Android's real picker, sends the app to the background and back, and times every reload from the write.
- W5 verified by CI 43228855253 (`+809: All tests passed!`, goldens `+22: All tests passed!`, Kotlin 44 of 44) and phase gate 43228855243, which passed every group on its first try (gate G4; the new `watch` group on a project and on a folder from shared storage). The gate before it, 43222339848, passed every group too, on the code before one fix found in review: coming back from the background now tries again the watches that failed.

### Added — Phase 3 W4, explorer operations and navigation (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Files and folders from the explorer:** New File and New Folder in the selected folder; Rename, also of the case alone; Move to…, with a chooser of the workspace's folders; Duplicate (`x copy.ext`, then `x copy 2.ext`); Copy Path; and Delete, which names the item, counts a folder's files and says that it can't be undone (on shared storage, that Android keeps no bin there). A name that is taken is never overwritten: the dialog asks for another. Items offer only what their storage allows, and a folder granted for reading only offers no changes.
- **Where to find them:** a long-press menu on every row, a ⋯ button on the selected row, and on a hardware keyboard the context-menu key or Shift+F10, with the arrow keys moving through the tree, Enter opening, F2 renaming and Delete deleting.
- **Open files follow every change:** a rename or a move keeps the tab, its unsaved text and its undo history, re-highlights it for a new extension, and moves its tab and unsaved text in the app's database in one transaction, so a crash in between finds the text under the old name or the new one. Deleting a clean open file closes its tab; deleting a file with unsaved text keeps the tab, its name struck through, with a notice that the file was deleted and the text is still there, until Save writes it again.
- **The tree** builds only the rows on screen (fewer than 60 at 10,000 entries), and each file shows a glyph for its kind: 20 kinds, from Dart to lock files, and a plain page for the rest.
- **Icons:** the app's icons are Material Symbols Rounded, as the design system specifies, bundled as a 14 KB font of the 63 the app uses.
- **Go to File** (Ctrl+P, or in the command palette): type a few letters of a file's name or path to find it. It skips `.git` and `node_modules`, searches up to 50,000 files and says when there are more, and follows the explorer's changes.
- **Save logs:** About → Recent logs → *Save* writes the logs, with secrets removed as always, to a file you pick in Android's file picker.
- **Tests:** the operations on a real folder, and through the storage broker for folders from shared storage; the open documents following them, the explorer's menus, dialogs and keys, the fonts against the code that names their glyphs, Go to File's matching and index, and Save logs. A new phase-gate group, `explorer`, runs every file operation on the emulator in a project and in a folder picked in Android's real picker, checks each on disk, and saves a file through Android's create-document picker.
- W4 verified by CI 43166674651 (`+773: All tests passed!`, goldens `+22: All tests passed!`, Kotlin 44 of 44) and phase gate 43183687317, which passed every group on its first try (gate G3; the new `explorer` group on a project and on a folder from shared storage). The two gates before it, 43166674715 and 43171738801, passed every group but the restore pair's part B: its check of the project's restored scroll assumed that the tree builds every row, and then measured a row before the frame that moved it.

### Added — Phase 3 W3, projects, recents and state (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Projects:** *New Project* on Home creates one in the app's own storage, empty or with the demo project's files. From its menu a project is renamed (its tabs and unsaved text follow) or deleted, after a question that says how many files it deletes and, when there are any, how many files' unsaved changes it discards.
- **Home is the launcher:** New Project, Open Folder, the demo project, and the recents. The recents list every project and folder opened, most recent first, each with its kind, its place and whether it is available, missing, or no longer accessible.
- **Reconnect** reopens the folder picker at a folder's old place. A different folder replaces the entry only after you agree. **Remove from recents** gives the folder's access back to Android; its files stay.
- **Each workspace keeps its tabs, unsaved text, expanded folders and explorer scroll** when you switch, and a cold start brings back the last workspace with all of it. A workspace that went missing or lost its access opens Home instead, which says so.
- **Database schema v2,** the first migration: data written by earlier builds opens with nothing lost, and folders opened before find their places again, from the app's grants or the folder that was open ([ADR-0008](adr/0008-persistence.md)).
- **Tests:** project storage on a real folder, the switching and the recents, Home's launcher, the migration from a v1 file, and the explorer's view. The phase gate's restore pair now opens a folder through Android's real picker, leaves unsaved text in it and in a project, and after the process death checks both, switching between them. The keyboard step records which window has focus around each tap.
- W3 verified by CI 43069846481 (`+687: All tests passed!`, Kotlin 44 of 44) and phase gate 43076652650, which passed every group on its first try (gates G2 and G5; the restore pair with a folder workspace). The gate before it, 43069846571, passed every group but the keyboard test. Its new focus record showed Android's *Application Not Responding* dialog for System UI holding the window focus, so the injected tap never reached the app. The gate now hides Android's error dialogs.

### Fixed — CI (2026-11-11)
- **The Flutter pin is enforced.** CI had installed the latest stable Flutter rather than `.flutter-version`'s 3.47.9, because `subosito/flutter-action` does not read that file as a version. The two were the same until Flutter 3.50.0 reached the stable channel. 3.50.0 refuses the app's Android Gradle Plugin, so debug builds failed on the runners that got it. The workflows now pass the pinned version and fail if another is installed ([BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md) §3). Verified by CI 43088413162 and phase gate 43088413208, which passed every group on its first try, both on 3.47.9.
- A failed debug build or Kotlin test run now says why in an annotation, readable without the logs.

### Decisions by the owner on the open items from Phases 0–2 (2026-11-11)
- **Licence (ADR-0011):** decided by Phase 4's start. Until then: no licence file, nothing GPL-derived vendored, no binary release.
- **Terminal (ADR-0006):** the ADR's rule stands: Termux's terminal view if the licence is GPLv3 and it passes Phase 4's arm64 gate, otherwise xterm.js.
- **minSdk (ADR-0007):** stays 26, to be verified on API 26–28 emulators in Phase 4; a raise to 29 needs the owner's sign-off.
- **arm64 hardware (ADR-0009, amended):** Firebase Test Lab's real phones run the tests that need no computer attached, from Phase 4.
- **Play Console (ADR-0010):** prepared at Phase 4, with the closed test that new personal accounts need started well before Phase 10.
- **t1:** the owner merges PR #81 now; t1's licence follows ADR-0011.
- **Added to Phase 3** ([phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md) §0): *Save logs to a file* and Material Symbols Rounded icons (W4); a gate run with Impeller before W6 measures anything; the save digest off the UI isolate, the benchmark driver's reconnect, golden diff images, a debug log viewer and a `ProviderObserver` (W6); one phone session with every parked check at the exit (W7).
- **Placed:** search across files in Phase 4; full support for other text encodings in a later phase.
- **Unchanged:** the emulator gate runs once per work package, with no nightly run; all work stays on the working branch until v1 or later; undo history after a process death stays a known limitation; the keys flake is diagnosed in W3.

### Decisions by the owner at Phase 2's acceptance (2026-11-10)
- Phase 2 accepted, with the phone checks parked ([phases/PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md)).
- Android backup becomes an offer to the user, off by default. Phase 3 W1 builds the switch.
- The on-disk log sink is built in Phase 3.
- The parked large-file checks become phone-only: a Developer action that writes the gate's files, and a plain-text pass in the benchmark, in Phase 3 W1.
- Phase 3 planned: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md).

### Added — Phase 3 W2, folders from shared storage (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Open Folder** on Home: Android's folder picker opens a folder on the device as the workspace, and *Continue in <folder>* reopens it. A cold start reopens it too. The app asks for no storage permission: the picker gives it that folder and nothing else.
- **Files in folders** open, edit and save like the demo project's: UTF-8 text only, byte-order mark and line endings kept, up to 10 MiB. A file changed by another app is not overwritten without asking, also where the folder's storage reports no modification time.
- **Saves in folders are not atomic,** because Android's document storage can't replace a file in one step. A document stays unsaved, with its text kept, until the write is confirmed, and a failed save says the file on disk may be incomplete.
- **Each workspace keeps its own tabs and unsaved text** when you switch between the demo project and a folder.
- **A folder that is gone, or whose access was taken back, says so,** on Home and in the explorer, without a crash.
- **The storage broker,** the Android host's only code that touches shared storage, behind a typed Pigeon API: every path checked again in Kotlin and walked from the folder's root, names Android's storage would change detected and undone, size limits whatever a provider claims, and a time limit on every call. Its security review is SECURITY §4.1.
- **Tests:** 37 Kotlin unit tests against an in-memory provider with the quirks of Android's own; Dart tests of the folder file service, the switching and Home. The phase gate gains a `folders` group: the real picker, driven from the host, and every listing, read, write, create, rename, move, copy and delete checked on disk, then a process death, a deleted folder and a released grant.
- W2 verified by CI 43007795037 (`+631: All tests passed!`, Kotlin 44 of 44) and phase gate 43007795087. Its `folders` group passed on its first try in both attempts (gate G1). Attempt 2 passed every group; attempt 1 failed only the W6 keyboard test at its first step, as W1's first attempt did.

### Added — Phase 3 W1, owner items and carry-overs (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Android backup is now the user's choice, off by default** ([ADR-0012](adr/0012-backup-opt-in.md)):
  - Settings → Privacy → *Back up with Android*, off. It says what Android copies (projects, unsaved text, settings), where (the user's Google Drive) and on what terms, and the row shows the last pass Android ran.
  - A backup agent decides on every pass:
    - **on:** the projects, the database and the settings, never the logs;
    - **off:** nothing, so Android keeps no backup;
    - **off after a backup with everything:** only the switch, which replaces it.
  - A device-to-device transfer follows the same switch.
- **Log file:**
  - The app's log records also go to two rotating files of at most 1 MiB each, in the folder Android never backs up. Errors are written at once, so a crash's last records survive it.
  - Settings → About → Recent logs → *Copy* includes the previous session's records.
  - Document URIs are cut to their authority in every record.
- **Settings → Developer → *Create large test files*** (debug and profile builds) writes the large-file gate's seven files into the workspace, byte for byte, so the large-file policy can be tried on a phone.
- **The engine benchmark** also measures its 1 MiB file as plain text, the path the large-file policy takes.
- **Accessibility:** TalkBack says which tab is selected and which has unsaved changes.
- **Saves keep the file's permission bits:** an executable script stays executable.
- **CI:** the Android host's Kotlin unit tests run on every push.
- **Phase gate:** a `backup` group checks, with Android's local transport, that by default a backup holds nothing; that with the switch on a reinstall restores the project and its unsaved text but not the logs; and that with it off a reinstall gives a fresh app. The restore pair also checks that the log file survives a process kill.
- W1 verified by CI 42862715832 (`+607: All tests passed!`, Kotlin 7 of 7) and phase gate 42862715744. On its second attempt every group passed on its first try. The first attempt failed only the W6 keyboard test, once: a tap that did not focus the editor, cause unknown. In both attempts the default backup was declined, the on and off backups succeeded, and the reinstalls brought back exactly what ADR-0012 says (gate G6).

### Added — Phase 2 (2026-11-10) · evidence: [phases/PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md) (plan: [phases/PHASE_2_PLAN.md](phases/PHASE_2_PLAN.md))
- **W1 editor page** (`editor/`): a CodeMirror 6 page in TypeScript speaking protocol v1, validated in both directions, with batched incremental change sets and highlighting for JavaScript/JSX, TypeScript/TSX, Python, JSON, HTML, CSS and Markdown. It builds to one self-contained, reproducible HTML file with a hash-pinned CSP, and comes with a runtime licence gate, a bundle verifier and a CI `editor` job.
- **W2 host and bridge:** the editor runs in the app, in the Android System WebView (`webview_flutter` 4.14.1) behind an `EditorSurface` interface. The page is checked against its manifest SHA-256 before it loads, and the WebView is locked down: no navigation, no file or content access, no dialogs, remote debugging only in debug builds.
- **Protocol and host:** a Dart mirror of protocol v1 is proven against the shared fixtures. The host correlates requests and responses with timeouts and rate-limits the page. It keeps a shadow copy of every open document, applies only exactly fitting changes (anything else triggers a snapshot resync), and reopens every document from the shadows whenever the page restarts.
- **Editor tabs drive the editor:** opening a tab opens its document, and typing marks the tab dirty. Save writes the editor's text: the tab strip's Save button, the palette's Save File, or Ctrl+S while the editor has focus. Typing during a save keeps the tab dirty.
- The editor's appearance follows the app theme, the editor font size and the system text scale. The page's npm licences appear on the app's licences page.
- Tests: the protocol contract on both sides, editor core and host units, page verification, editor widget tests, and an emulator test of the real page in the WebView, now part of the phase gate.
- **W3 engine benchmark:** CodeMirror 6 and Monaco 0.57.0 benchmark pages at identical scope (`editor/bench/`: six-language highlighting, find/replace, a stub completion popup), built with the editor page's kit and verified by hash before they run. The phase gate runs both in the real WebView: 3 fresh runs per engine, then a DevTools driver (`editor/tool/bench_cdp.mjs`) for input → frame latency, 9 composition cases (CJK, Hangul, emoji, autocorrect, cancel) and process memory. The merged results, with every ADR-0004 budget checked, go to `app/ci-results/gate/editor_bench.json`. The first emulator results (phase gate 42206498197) are recorded in ADR-0004.
- **Settings → Developer** (debug and profile builds only): *Editor benchmark* runs the same suite on a device plus a typing check through the real keyboard, and copies the results as JSON. *Frame timing* records frame build and raster times against the 16.7 and 32 ms lines. The phase gate also publishes a profile arm64 APK carrying the benchmark pages (artifact `codeforge-phone-profile-arm64`) for phone runs.

- **W4 real files and tabs:** the editor opens, edits and saves real files in an app-private workspace folder. The first run writes the demo project there. Saves are atomic (temp file, flush, rename), so an interrupted save leaves the old file. A file keeps its byte-order mark and CRLF or LF line endings. Binary files, invalid UTF-8 and UTF-16 are refused with a reason, never converted. A file changed on disk since it was opened is not overwritten without asking. Paths cannot leave the workspace, through `..` or through symbolic links.
- **Documents and tabs:** many open files, each keeping its own cursor, scroll and undo; dirty dots that clear when undo returns to the saved text; Save As (the tab follows, with its history) and New File; closing an unsaved tab asks Save / Don't Save / Cancel; Close others; tabs reopen after a restart. Language detection adds file names (`.babelrc`, `.eslintrc`) and shebangs (`node`, `deno`, `bun`, `python`, `pypy`). The status strip shows line endings and BOM.
- **Shortcuts:** Ctrl+S, Ctrl+Shift+S, Ctrl+N, Ctrl+W, Ctrl+Tab / Ctrl+Shift+Tab and Ctrl+Shift+P work whether the editor or the app has the keyboard.
- W4 verified by CI 42238016497 (`+431: All tests passed!`) and phase gate 42238016973, where the on-device file and tab checks and the restore pair passed on attempt 1 (gates G2 and G3).

- **W5 zero-loss editing:** unsaved text survives the app being killed and a crash of the editor's renderer. A hot-exit journal in the new app database keeps each unsaved document as a snapshot plus the editor's change sets since, written as you type. The next start replays it and reopens the document still unsaved, with its cursor and scroll. A file that changed or was deleted meanwhile keeps both texts and asks: keep my changes, or use the file. A banner says when unsaved changes cannot be backed up.
- **App database** (`codeforge.sqlite`, Drift 2.35.3, schema v1): workspaces, open tabs with each tab's cursor and scroll, and the journal. It opens lazily in a background isolate, and SQLite comes from the `sqlite3` package's prebuilt, hash-checked libraries. A migration test harness starts with v1.
- Tests: journal replay against the live text for randomized edit sequences; the journal's write order, failure recovery and timers; the database on real SQLite, including a v1 fixture through drift_dev's schema verifier; process death, conflicts, deleted files and damaged journals in controller and widget tests. The emulator gate gains an edit pair: type without saving, crash the WebView renderer, force-stop, relaunch, then check the text, the dirty dot and the cursor.
- W5 verified by CI 42386742434 and 42388617576 (`+478: All tests passed!`) and phase gate 42386742421. There the edit pair restored 262 unsaved characters, the cursor and the dirty dot after a renderer crash had killed the app, and a rotation to landscape and back kept the page (gate G4).

- **W6 find, replace and go to line:** a find bar over the editor (Ctrl+F, Ctrl+H, or the palette) with match case, whole word and regular expressions. It shows a live match count and steps between matches, and replace all is one undo step. Go to line (Ctrl+G) takes `42` or `42:7`.
- **Symbol toolbar:** a row of 48 dp keys on the soft keyboard: Tab, Shift+Tab, symbols for the file's language, Undo, Redo, the cursor arrows and a hide-keyboard key. Pairs put the cursor between them, and a long press gives the other variant. Settings → Appearance offers Compact, Off or your own keys. Tapping a key never closes the keyboard.
- **Hardware keyboards:** Tab and Shift+Tab indent and outdent. The app's shortcuts work while the editor has the keyboard: save, find, replace, go to line, undo, redo, the palette, and close, next and previous tab. The toolbar steps aside while a hardware keyboard is in use and the soft keyboard is down.
- Tests: the page's search session, Tab and paired inserts (vitest); the toolbar, presets, focus and keys in the workbench (widget tests); and on the emulator, the real find bar over the real page, plus real touches on the toolbar and key chords from the emulator's own keyboard.
- W6 verified by CI 42437560827 (`+512: All tests passed!`) and phase gate 42437560830 for find, replace and go to line (gate G5). The toolbar and keyboards were verified by CI 42517731644 (`+539: All tests passed!`) and phase gate 42517731718, where every touch, key and shortcut passed on attempt 1 (gate G6).

- **W7 large files:** a document over 512 KiB that would be highlighted opens as plain text, so typing stays fast. A banner says what that turns off (highlighting, folding, syntax-aware indentation and comment toggling) and offers *Highlight anyway*, or it can be dismissed; the language chip turns amber. A plain `.txt` loses nothing and gets no banner.
- The phase gate measures large files on the emulator: opening, scrolling, typing, memory and saving at 1, 5 and 10 MiB, as JavaScript and as plain text, with the session store's write costs and a release build's memory with a 1 MiB file restored (EDITOR_ARCHITECTURE.md §10).
- **Dialogs beside the keyboard:** every alert dialog scrolls its title and content above its buttons, with tighter margins when the keyboard leaves little room. On a phone in landscape with the keyboard up, the field and the buttons stay in view.
- Tests: the protocol contract runs on both sides, so a message type that the app and the page do not both know fails CI. Every dialog is checked beside the keyboard at each gate size, at normal and 1.3× text, and the accessibility sweep covers the find bar, the dialogs and the file menu. Goldens show find and replace, the large-file banner, and go to line beside the keyboard.
- W7 verified by CI 42616081306 and phase gate 42616081317 for the measurements, CI 42659207677 (`+552: All tests passed!`) and phase gate 42659207710 for the policy (gate G7), and CI 42678576228 (`+563: All tests passed!`) and phase gate 42676631509 for the quality suite (gate G8).

- **W8 phase exit:** [PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md) records every gate with its run ids, the ADR-0004 tables, the large-file numbers, the artifacts, the parked owner checks and the full gate history. The review found two gaps, both listed in the report: Android Auto Backup (see Changed), and tab state that TalkBack doesn't hear. Phase 2 is built and CI-verified, and awaits the owner's acceptance. The final tree is CI 42678576228 (`+563: All tests passed!`, editor job 187/187) and phase gate 42676631509 (all 11 groups on attempt 1).

### Fixed — Phase 2
- **Text fields with a label were 47 dp tall**, under the 48 dp touch target: the theme made them dense. They are no longer dense, so Material keeps every text field at least 48 dp tall. Found by the W7 accessibility sweep (CI 42665305010).
- **Editor commands in the moment after the editor page starts could fail** with "no document is active". The host reports ready when the page announces itself and reopens the documents just after that. A toolbar key, shortcut, save or snapshot sent in between reached a page with no document. Such commands now wait for the reopen. Found by the W5 zero-loss gate (phase gate 42379885027, `edit_a`).
- **Rotating the phone reloaded the editor page**, which cost every open document its undo history. Text, cursor and scroll were restored from the host's copies. Portrait and landscape use different workbench layouts, and the editor pane was rebuilt in each. It now moves between them under one key.
- **Selected text on the cursor's line was invisible**, in the editor and in the benchmark page: the copy menu and handles appeared, but no highlight. The active line's opaque background covered CodeMirror's selection layer. A line is now highlighted only around a plain cursor, as in VS Code (`editor/src/editor/active_line.ts`). The owner found this in the W3 phone run. Verified in CI 42216855073 and phase gate 42216855184.

### Changed — Phase 2
- **SECURITY.md §4 corrected: Android Auto Backup is on.** The manifest leaves Android's default in place. So when the user has device backup turned on, Android copies the workspace, any unsaved text and the settings to the user's own Google Drive, end-to-end encrypted on Android 9+ with a screen lock. The section had said there was no cloud sync by default. Opting out is an owner decision (PHASE_2_REPORT §1).
- Docs synced at the Phase 2 exit:
  - EDITOR_ARCHITECTURE: its status, and `search.state` in §2's protocol list;
  - ADR-0004: its status;
  - SECURITY §3: the shipped page's hashes, and renderer crashes recovered by the journal;
  - TESTING: totals, CI and the manual checks;
  - BUILD_AND_RELEASE §2.2: the editor job and the gate's groups;
  - ARCHITECTURE §2.7, TECH_STACK, PERFORMANCE §4, ROADMAP and README.
- **Files over 10 MB are refused** (was 16 MB), before they are read: 10 MiB is the largest size the phase gate measured end to end. The message gives the file's size and the limit.
- **Open tabs moved from the shell envelope to the app database**, imported once on the first W5 start; each tab now also gets back its cursor and scroll (ARCHITECTURE.md §2.6 has the migration note).
- **ADR-0008 amended:** buffer journals live in SQLite, not files, because a snapshot must replace the changes it covers in one transaction.
- CI: bootstrap mode generates Drift's code and migration helpers and commits them; every run checks the committed copies are current, and the phase gate generates them before building. Dependency resolution output is kept for the diagnostics commit.
- **ADR-0004 accepted: CodeMirror 6** is the editor engine. It was measured against Monaco on the CI emulator and on the owner's low-end phone (realme C51), where it met the cold-load and typing budgets. Large-file typing and scrolling, memory, and selection handles at line boundaries are carried to W6/W7.
- Phase 1's parked G6 check is complete: 3.4 % of navigation frames over 32 ms on the owner's phone (budget 5 %).
- The benchmark's typing check now says what to do and shows each result (match, or where the text differs and what the editor holds) next to its buttons.
- The workbench's read-only code preview and its banner are replaced by the real editor. The symbol toolbar stays visible but disabled until W6. The workspace goldens change accordingly.
- The palette's save command is now "Save File" (category File). The demo "simulate edit" command is removed.
- SECURITY.md §3 now describes the WebView exactly as configured, including what happens when its renderer crashes. EDITOR_ARCHITECTURE.md §2 lists the real protocol v1 types.
- CI: every test run is time-bounded (2 minutes per widget test; 10 and 15 minutes for the golden and full runs). Golden generation runs only the golden suites and keeps its log, and failing tests leave their last lines as a check-run annotation.
- The editor workspace's page building is shared (`editor/tool/page_kit.mjs`) by the editor page and the benchmark pages; the editor's colour palette moved to `src/editor/palette.ts` so a page can use it without CodeMirror. The editor job's `npm run ci` also builds the benchmark pages. Test builds show the Developer section at the end of Settings.
- EDITOR_ARCHITECTURE.md §4 now describes the WebView as built (inline page, hash-pinned CSP) instead of the Phase 0 asset-loader plan.
- Protocol v1 gains `doc.setLanguage`, and snapshots report the active document's scroll position.
- The editor tabs controller is replaced by `DocumentController`; the in-memory file service fake is gone from the app (tests have their own). The explorer lists the real workspace folder and offers New File. Features reach files only through application controllers, which the import lint now enforces.
- The empty editor offers New File instead of reopening the demo file.

### Added — Phase 1 (2026-11-06) · evidence: [phases/PHASE_1_REPORT.md](phases/PHASE_1_REPORT.md)
- Flutter app (`app/`, `dev.codeforge.app`): pinned toolchain (Flutter 3.47.9; AGP 9.1.0 · Gradle 9.3.1 · Kotlin 2.4.0 from the template; compile/target 36, minSdk 26).
- "Forge" design system: colour/spacing/radius/motion/typography tokens (bundled Inter + JetBrains Mono), dark and light themes, components (buttons and icon buttons, banner, empty state, status chip, file-tree row, settings tiles, and workbench chrome: activity bar, nav rail, tab strip, status strip, symbol toolbar), debug-only gallery.
- Screens: home with a first-run welcome, adaptive workbench (compact, medium, expanded; portrait and landscape) with a demo-workspace explorer and honest Search/Run/Git/Extensions placeholders, a terminal panel (laid out at closed/peek/half/full stops; the top bar toggles closed ↔ half), editor tabs on a demo workspace, command palette (Ctrl+Shift+P), settings (appearance, about).
- Services as interfaces with in-memory fakes; Riverpod controllers; versioned, tolerant `shared_preferences` envelopes for settings and shell layout; restore of the last route, theme and panel state after process death.
- Navigation: deep links resolve; unknown locations land on home; system and predictive back return home from top-level destinations and leave the app only from home.
- Keyboard-safe layouts: with the soft keyboard up the terminal yields (hidden below 60 dp), and the editor pane, nav rail and command palette never overflow. This was found by the emulator phase gate, which caught a real overflow that no widget test covered.
- CI: `ci.yml` (format, analyze, import-boundary lint, license gate, lockfile drift, tests with coverage, debug APK with SHA-256) and `phase-gate.yml` (KVM-accelerated API 36 emulator: smoke, process-death restore pair, release cold-start sampling, `perf.json`), with committed evidence under `app/ci-results/`.
- Tests: unit, widget, accessibility (Android tap-target + labeled-target guidelines, 48 dp ink targets, 1.3× text scale), soft-keyboard insets, WCAG contrast gate, typography tokens, goldens (gallery in both themes; home and workspace at six gate sizes in dark plus two light spot checks; settings), integration.

### Changed — Phase 1
- UI_DESIGN_SYSTEM v1.1: light-theme ember accent `#E85D2A` → `#B93E0C` (2.98:1 → 4.78:1) and AA-compliant semantic colours; chrome bars are 48 dp touch rows plus a 1 px hairline; status chips are display-only.
- TECH_STACK: Android build pins are now the CI-proven template defaults (Phase 0 candidates were AGP 8.13 / Gradle 9.2.1 / NDK 27.2); the emulator gate uses `google_apis` + KVM instead of `aosp_atd` + software emulation.
- Rendering uses Skia in Phase 1 (Impeller disabled pending hardware validation).

### Added — Phase 0 (2026-11-05)
- Complete Phase 0 technical audit of the existing Linux environment (`m-cyber12/t1` @ `0e26d7a`, PR #81): sealed execution model, runtime versions, sizes, CI evidence, license findings — `docs/EXISTING_RUNTIME_AUDIT.md`.
- Phase 0 report with spec corrections, risk register, and acceptance status — `docs/PHASE_0_REPORT.md`.
- Architecture, tech stack (versions verified 2026-11-05), repository structure, runtime integration, editor/terminal/LSP/extension designs, security model, testing strategy, performance budgets, build/release design, UI design system v1.
- 11 Architecture Decision Records (`docs/adr/`).
- Detailed Phase 1 MVP implementation plan — `docs/phases/PHASE_1_PLAN.md`.
- Project process docs: README, AGENTS.md, CONTRIBUTING.md, ROADMAP.

### Decisions locked by owner (2026-11-05)
- minSdk 26 (reconciliation gate ADR-0007 in Phase 4); distribution GitHub-first + Play-compatible; license pending (ADR-0011).

### Notes
- Phase 0 was analysis-only by instruction; CI became the build authority in Phase 1.
- Phase 1 known limitations (details in the report): navigation frame-time profiling (G6) is carried to Phase 2; cold start is measured on a CI emulator, not hardware; the TalkBack spot-check is an owner action on a device.
