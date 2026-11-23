# Phase 6 Plan — Language Intelligence

**Status:** **Built, for the owner's acceptance** ([report](PHASE_6_REPORT.md)): W1 to W7 done, and the exit gate, 45225412011, passed whole (PHASE_6_REPORT §4). Proposed on 2026-11-21, the day Phase 5 was accepted. **The owner chose (a) on 2026-11-22** (§10, item 2): servers for Python and for JavaScript/TypeScript. **W1 done on 2026-11-22** (phase gate 44977463887: both servers pass the smoke suite on API 26 to 36 and on Test Lab's Pixel 8a; see *As built (W1)* and ADR-0015). **W2 done on 2026-11-22** (CI 44994907490; phase gate 44995822826, with Test Lab's Pixel 8a 39 of 39 in the same run; see *As built (W2)*). **The memory budget decided on 2026-11-22:** (b), a budget of each server's own, 300 MB of PSS (§10, item 3). **W3 done on 2026-11-22** (CI 45020136733, and 45027761446 on the final code; phase gate 45029118568, with Test Lab's Pixel 8a 40 of 40 in the same run; see *As built (W3)*). **W4 done on 2026-11-22** (CI 45065692542; phase gate 45067383709, with Test Lab's Pixel 8a 41 of 41 in the same run; see *As built (W4)*). **W5 done on 2026-11-23** (CI 45131313756, and 45133675713 on the final code; phase gate 45135282059, with its new `lsp` group and Test Lab's Pixel 8a 41 of 41 in the same run; see *As built (W5)*). **W6 done on 2026-11-23** (CI 45180564110; phase gate 45182761593, with Test Lab's Pixel 8a 42 of 42 in the same run and every language budget met; see *As built (W6)*). **W7 done on 2026-11-23** (CI 45204541929 for its code: a silent server restarted, and the total recorded with a terminal open; the docs synced, LSP_ARCHITECTURE as built, ADR-0015's last *As built*, SECURITY §2.3, PHASE_6_REPORT and PHASE_6_PHONE_CHECKLIST; see *As built (W7)*) · **Spec reference:** §8 Phase 6 (language intelligence), §6.3 (no full-document sync per keystroke), §6.5 (the capability model), §6.6 (a failing server never breaks the editor), §7 (security) · **Architecture:** [LSP_ARCHITECTURE.md](../LSP_ARCHITECTURE.md) (the Phase 0 seed this phase finalizes), [EDITOR_ARCHITECTURE.md](../EDITOR_ARCHITECTURE.md), [RUNTIME_INTEGRATION.md](../RUNTIME_INTEGRATION.md), [SECURITY.md](../SECURITY.md) §2, [ADR-0004](../adr/0004-editor-engine.md) (CodeMirror 6), [ADR-0005](../adr/0005-sealed-runtime.md), [ADR-0013](../adr/0013-folders-and-the-runtime.md) (a folder runs in a copy), [ADR-0014](../adr/0014-pty-and-sessions.md) · **Builds on:** Phase 5 ([report](PHASE_5_REPORT.md)): the launcher's sessions and limits, the editor protocol, Run and the folders' copy

---

## 0. Carried in from Phase 5 and the owner

**From Phase 5** (PHASE_5_REPORT §9.2, §10):
- **What a process can be today.** The launcher (`libcodeforge-spawn.so`) runs three kinds:
  - one-shot commands: stdin closed, output read up to a cap of 1 KiB to 1 MiB, a deadline of 100 ms to 10 min (SECURITY §2.1);
  - the same with stdout streamed line by line, which search uses;
  - terminal sessions on a pseudo-terminal (ADR-0014).

  Each leads its own session and process group, is ended with its whole tree, and runs under the limits SECURITY §2.2 measured: 4 GiB file size, 2,048 processes, OOM score 800. A language server fits none of these. It lives as long as the editor needs it, reads framed requests on stdin, and writes framed answers of any length on stdout.
- **No LSP service exists yet.** ARCHITECTURE's diagram has shown `LspService` since Phase 0, but `services/contracts.dart` has none, and there is no fake either.
- **The editor protocol v1** is strict and versioned: each new message type comes with fixtures that both vitest and Dart run (EDITOR_ARCHITECTURE §2). The page's bridge takes messages of up to 32 Mi characters, at a sustained 120 a second.
- **Memory, and the line it leaves.** On Test Lab's Pixel 8a (exit gate 44900930980):
  - the app with the editor open took 452.7 MB of PSS;
  - the open terminal took 44.6 MB more;
  - once settled after a 10 MiB flood, it took 130.2 MB more, 583 MB in all.

  PERFORMANCE allows 600 MB for the editor, a terminal and one language server, counted as RSS, a different measure. A language server is a process of its own, and its memory comes on top.
- **Size:** the base module is 148.0 MB per device, 74.0 % of Play's 200 MB (exit gate 44900930980).
- **Node loads a native addon from the app's storage** on every Android version measured (Phase 5 W7). Play's rule on downloaded executable code is the owner's to review (ROADMAP's queue). The servers this plan ships are JavaScript inside the APK, so they add nothing to that question (*Verified*, below).
- **Pending with the owner, non-blocking:**
  - PHASE_5_PHONE_CHECKLIST, and the Phase 3 and Phase 4 checklists, on the exit gate's APK (kept until 2026-12-21);
  - the first release: the keys and the licence review;
  - Play's account, testers, forms and special-use declaration;
  - what runs the arm64 tests after Test Lab.

**The owner's standing rules:**
- **Test Lab:** a change goes through plain CI first. Only then does a separate commit with `[testlab]` in its subject run it on the phone. The free plan gives 5 physical-device tests a day, and Firebase counts the day from midnight Pacific time (09:00 in Frankfurt in winter).
- **No nightly CI** (2026-11-11): the emulator suite and the runtime gates run in the phase gate, once per work package.
- **CI and the phase gate are one workflow;** a `[phase-gate]` push gives one run.
- **t1's code may be changed,** as recorded patches in `native/patches/`.
- **No public binary before the licence review** (2026-11-18).

**Verified while planning (2026-11-21),** from the npm registry and PyPI:
- **Pyright** 1.1.414:
  - MIT; 19.5 MB in 5,423 files, 5.9 MB once compressed file by file, as an APK stores it;
  - no dependency but macOS's optional `fsevents`, no install script, no native file;
  - runs on node 14 or later, with `pyright-langserver` as its server.
- **TypeScript:**
  - `latest` is **7.0.2, the native port:** a 2.5 MB launcher and one binary package per platform. Of the 20 packages (Linux, macOS, Windows, the BSDs, AIX, SunOS), **none is for Android**. The Linux arm64 one is 26.7 MB.
  - **6.0.3 is the last JavaScript line,** with `tsserver`: Apache-2.0, 24.3 MB in 140 files, 4.6 MB compressed, no native file.
- **typescript-language-server** 6.1.0: Apache-2.0, no dependencies, node 22.22.2 or later, 0.5 MB compressed. It drives `tsserver`, so it pairs with TypeScript 6.0.3. Its one script, `prepare`, runs only in its own repository.
- **Together,** Pyright, TypeScript 6.0.3 and typescript-language-server add 11.0 MB compressed: about 159 MB per device, 79.5 % of Play's limit. Each tarball matched the registry's SHA-512.
- **Later candidates:**
  - basedpyright 1.40.2 (MIT, Pyright's community fork, 7.8 MB compressed);
  - vscode-langservers-extracted 4.10.0 (MIT: JSON, HTML, CSS);
  - bash-language-server 5.8.1 and yaml-language-server 2.0.0 (MIT).
- **Python servers written in Python:**
  - jedi-language-server 0.47.0 is pure Python and small: about 5 MB of wheels with jedi 0.20.1. But one of its dependencies, docstring-to-markdown, is LGPL-2.1-or-later.
  - python-lsp-server 1.15.0 needs ujson, a C extension with no Android wheel, so it can't be installed without a compiler.
- **In the page:**
  - `@codemirror/autocomplete` 6.20.4 is already there;
  - `@codemirror/lint` 6.9.8 (MIT) draws diagnostics;
  - `@codemirror/lsp-client` 6.3.1 (MIT) is an LSP client that runs inside the page (W4 weighs it).

## 1. Objectives

1. **At least one full language server** (ROADMAP): completion, diagnostics, go to definition and rename, on the sealed runtime's node, offline.
2. **Proven before anything is built on it.** Each server passes a smoke suite on every target, API 26 to 36 and an arm64 phone, before its language becomes *analyzable* (LSP_ARCHITECTURE §2).
3. **Inside the budgets** (PERFORMANCE §2):
   - completion within 300 ms at the 95th percentile, warm;
   - diagnostics within 1 s of a save;
   - memory measured with the editor and a terminal open.
4. **Never a broken editor** (spec §6.6). A server that fails to start, crashes or hangs is restarted with backoff. After three crashes its language falls back to syntax-only, with a chip saying so and offering *Restart*. Editing never waits on a server.
5. **Sealed like the rest of the runtime.** The servers ship in the APK, pinned with their integrity hashes, verified when they install, and listed in the notices. Nothing is downloaded at run time.

## 2. MVP 6 definition (ROADMAP)

ROADMAP's row:
- at least one full LSP, Pyright or the TypeScript server, under the sealed node;
- completion, diagnostics, go to definition and rename;
- restart on a crash;
- completion within 300 ms at p95;
- the compatibility spike first.

**In scope:**
- the spike;
- the servers in the payload;
- the host's server processes;
- the LSP client;
- completion, diagnostics, definition, rename and hover in the editor, for projects, and for folders through ADR-0013's copy;
- the language gate on real targets.

**Out of scope:**
- signature help, code actions and quick fixes, formatting, find references, semantic highlighting, inlay hints, and a scan of the whole workspace for problems (later phases);
- servers for JSON, HTML, CSS, YAML and shell (later candidates, §0);
- TypeScript 7's native server (§8);
- clangd (the build-tools pack);
- the git UI (Phase 7), extensions (Phase 8) and debugging (Phase 9).

## 3. Technical implementation (work packages)

### W1 — The compatibility spike (1–2 sessions) 🔑 first → G1

ROADMAP and LSP_ARCHITECTURE §2 put it first, and every later package builds on its answer.

- **The candidates:**
  - Pyright 1.1.414, for Python;
  - typescript-language-server 6.1.0 with TypeScript 6.0.3, for JavaScript and TypeScript.

  basedpyright is measured only if Pyright fails. TypeScript 7 is not a candidate (§8).
- **On the device before the payload carries them.** The instrumented test's assets carry the pinned tarballs, which CI fetches and checks against the registry's SHA-512. The test unpacks them into the runtime's home, and the runtime's node runs them. That is JavaScript run by node, as Run runs a user's script, with no new program.
- **The smoke suite,** for each server, on fixtures of two files:
  1. `initialize` and `initialized`;
  2. `didOpen` of a file with an error and an import from the other file;
  3. the error in `publishDiagnostics`, with its range;
  4. completion offering a known member;
  5. definition across the two files;
  6. `prepareRename` and `rename` across both;
  7. a `didChange` that fixes the error, and the diagnostics cleared;
  8. `shutdown` and `exit`, with no process left.

  Python's fixture also imports `pip`, the one third-party package the runtime ships. Pyright finds such packages by asking the Python on the PATH for its search paths, so node has to start the runtime's python.
- **A small Kotlin driver** in the test speaks JSON-RPC over the server's pipes, with timeouts. Its framing is W3's, written test-first and kept.
- **Measured** on every runtime leg (API 26, 27, 28, 34 and 36) and on Test Lab's Pixel 8a, on the fixture and on a generated project of about 200 files:
  - the time from start to `initialize`'s answer, and to the first diagnostics;
  - completion warm, 50 times: the median, the 95th percentile and the maximum;
  - the server's memory (PSS and RSS of its process tree, from `/proc`), idle after the first analysis and after the completions;
  - its shutdown.
- **The outcome:**
  - ADR-0015 (language servers) records the choice with these numbers, and LSP_ARCHITECTURE §2 its table.
  - A server ships only if it passes on every target.
  - If a server's memory puts the app past PERFORMANCE's 600 MB with the editor and a terminal, W1's report brings the numbers to the owner with options (§10, item 3), as Phase 5's W6 did.

**As built (W1):**
- **G1 met.** `LanguageServerTest`'s 4 tests passed on every runtime leg (API 26, 27, 28, 34 and 36) and on Test Lab's Pixel 8a with Android 14, in phase gate 44977463887 (Test Lab in the same run: 36 of 36 tests). The rest of the gate passed too: every emulator group at its first attempt, and the cold start at 1,169 ms. The evidence is in `bf8f7f1`, `932dab3` and `1a7c870`. [ADR-0015](../adr/0015-language-servers.md) records the choice with the numbers: **Pyright 1.1.414, and typescript-language-server 6.1.0 with TypeScript 6.0.3.**
- **On the phone:**
  - **First diagnostics:** Pyright 1.21 s on two files and 1.51 s on 200; TypeScript 2.46 and 2.77 s.
  - **Completion after an edit, at the 95th percentile:** Pyright 43 and 56 ms; TypeScript 93 and 60 ms. That is within a third of the 300 ms budget.
  - **Memory (PSS of the server's process group) after the completions:** Pyright 167.1 and 210.1 MB; TypeScript 246.7 and 255.2 MB.
- **Memory is past what PERFORMANCE planned.** With the editor and an open terminal (497.3 MB in Phase 5's exit gate), a server takes the app to about 665 to 753 MB, against 600 MB. The numbers and a recommendation go to the owner (§10, item 3).
- **Also found:**
  - Pyright resolved `import pip` on every target, so node starts the runtime's python.
  - The launcher's command mode hands a server its stdin unchanged.
  - The largest message was 37,991 bytes, the TypeScript project's 199 diagnostics.
  - Each server exited with 0 after `exit`, and nothing of its group was left.
- **Built:**
  - `app/tool/ci/language_servers.json`, the spike's pins with the registry's SHA-512.
  - `fetch_language_servers.py`. It checks each tarball's integrity and refuses native code, links and paths outside the package. Its 15 self-test cases run with the gate's other scripts.
  - `LanguageServerTest`, with the legs and Test Lab fetching the servers before they build the test APK, and expecting its 4 tests.
  - Plain CI 44976282000 compiled it before the gate ran.
- **As planned, with one addition:** completion is timed both repeated (the servers cache the answer) and after an edit (as typing does). W6 judges the budget on the second.

### W2 — The servers in the payload (1 session) → G2

- **Pinned.** `runtime/language-servers/` holds a `package.json` and a version 3 lockfile. The lockfile names the chosen servers at exact versions, and lists every package in the closure with its `resolved` URL and its SHA-512 `integrity`. CI checks that:
  - no install script runs, and none is needed;
  - there is no native code: no `.node` file and no ELF anywhere;
  - every licence is on an allowlist (MIT, Apache-2.0, BSD, ISC); anything else fails;
  - a change to the lockfile carries `[repin]`, as a change to the payload's pins does.
- **Built.**
  - `npm ci --ignore-scripts --omit=optional --omit=dev` installs from the registry into a staging folder, verifying each hash, and the result is cached under the lockfile's hash.
  - Each server goes into an archive of its own beside the userland's, with a manifest of paths, sizes and SHA-256s, as the sealed manifest has.
  - Both ABIs carry the same archives, since they hold only JavaScript.
- **Installed lazily.**
  - A language's server is extracted and verified the first time a file of that language opens with the runtime ready, off the UI thread, with its progress in the status strip.
  - A verified server is reused at later starts.
  - A server that fails its check never runs: the language stays syntax-only, with a chip saying why.
  - So the first install's 13,892 files don't grow by Pyright's 5,423.
- **The notices.** THIRD_PARTY_NOTICES gains a section written from the lockfile (each package with its version, licence and text), and the app's licence page lists them. CI fails when the section is stale. Nothing is copyleft, so SOURCE_OFFER is unchanged.
- **Size:** `check-bundle-size.py`'s limit holds, and the figure is recorded (about 159 MB per device, by §0's estimate).
- **Provenance:** native/PROVENANCE.md gets rows for the new files under `runtime/`.

**As built (W2):**
- **G2 met** (CI 44994907490; phase gate 44995822826, whole: every emulator group at its first attempt, the cold start at 873 ms, no ANR; Test Lab's Pixel 8a 39 of 39 in the same run; evidence `cfa7ae6`, `91db062` and `10030555`).
- **Pinned:** `runtime/language-servers/` holds `package.json`, npm's version 3 lockfile and `bundled.json`.
  - `language_servers.py check` holds them to:
    - exact versions on the npm registry, each with a SHA-512;
    - a licence allowlist: 0BSD, Apache-2.0, BlueOak-1.0.0, BSD-2-Clause, BSD-3-Clause, ISC and MIT;
    - no install script in anything that ships.
  - The one package with an install script, Pyright's optional `fsevents` for macOS, never ships.
  - CI fetched and verified all 61 tarballs.
- **Built:** one archive and manifest per server, reproducible, with native code refused.
  - Pyright is 6.06 MB with 5,423 files, the TypeScript server 5.15 MB with 145.
  - The release x86_64 APK grew from 150,023,619 to 161,533,268 bytes.
  - The base module is 158.3 MB on arm64, 79.2 % of Play's 200 MB (148.0 MB at Phase 5's exit).
  - The APK check requires each archive, stored as it is.
- **Installed when first asked for:** every file is verified against its manifest, no other file is allowed, and the folder is then renamed into place with a marker.
  - First install on the emulators: Pyright 0.83 to 2.48 s, the TypeScript server 0.26 to 0.75 s.
  - First install on the Pixel 8a: 3.65 s and 0.51 s.
  - Reuse at a later start: 0 to 5 ms.
- **Damage refused:** an archive with one byte changed was refused as `damaged` on every target (the zip's CRC check caught it). Nothing was left in place, and the APK's own archive installed afterwards.
- **The notices:** THIRD_PARTY_NOTICES §6 lists 61 package versions, 3 shipped and 58 bundled inside them. The app's licence page shows their 42 distinct texts. CI checks both.
- **Differs from the plan:**
  - **No npm in the build.** The plan had `npm ci --ignore-scripts`. Instead `language_servers.py` reads the lockfile itself, downloads each tarball and checks its SHA-512, so an APK build needs only Python, as the payload's does. npm is needed only to re-pin (`lock`, which CI runs for a [repin] commit).
  - **The bundled packages weren't planned.** Pyright and typescript-language-server bundle 58 npm packages into their JavaScript, without those packages' licence texts. `bundled.json` pins them from the source maps (pnpm's store paths give the versions), and their own tarballs give the texts. Two of them, `@yarnpkg/fslib` and `@yarnpkg/libzip` (BSD-2-Clause), ship no licence file. THIRD_PARTY_NOTICES names them for the licence review.
  - **What asks for a server, and its progress, move.** The installer is built and tested. W3's `LspHost` asks it for a server before starting one, and W4 shows the progress in the status strip. No `LspService` exists before then.
  - **The cache.** CI's runtime job caches the tarballs under the pins' hash. The APK builds download the three shipped tarballs (9.3 MB) from the registry, which keeps every version.
- **Tests:**
  - `runtime/tests/test-language-servers.py` (22);
  - `LanguageServersTest` (14, JVM);
  - `LanguageServerInstallTest` (3, on every leg and the phone);
  - `test/services/language_server_licenses_test.dart` (3);
  - 3 new self-test cases in `check_runtime_apk.py`.
  - `LanguageServerTest` now runs the servers as installed from the app's assets, and W1's test-APK fetch is gone.
  - Counts: `+1093: All tests passed!` and 202 Kotlin tests (CI 44994907490).

### W3 — The host: a server's process and its messages (1–2 sessions) → G3

- **The process:**
  - The launcher runs a server as it runs a command: in its own session and process group, as subreaper, ended with its tree, under the session limits but with no CPU-time limit and no deadline.
  - Its stdin stays open for the host, its stdout is read as framed messages, and its stderr goes to a bounded log (the last 64 KiB) that is shown when the server fails.
  - **Decided at W3's start, with a test:** the launcher's command mode with stdin kept open, or a pipe mode beside its terminal mode. The ADR records which.
- **`LspHost`** (Kotlin):
  - starts a server for a language and a workspace, sends it messages, and stops it;
  - reports its exit, with the code or signal and its stderr's tail;
  - runs at most 2 servers at once, one per language, and refuses a third with a typed failure;
  - samples the server's memory from `/proc` every 10 s while it runs.
- **Framing in Kotlin** (LSP_ARCHITECTURE §1):
  - `Content-Length` headers are parsed from bytes, and a message goes to Dart only when it is whole, so Dart never sees part of one.
  - A message over 16 MiB, a bad header or invalid UTF-8 ends the server as broken, and Dart restarts it.
  - Messages reach Dart through a Pigeon Flutter API, as the terminal's output does.
- **Where a server runs, and with what:**
  - The host names the working directory and the root from ids: a project's folder, or a folder's copy (ADR-0013). Never a path from Dart (SECURITY T3).
  - The environment is the runtime's (E2), with `NODE_OPTIONS` carrying the heap cap W1 sets.
  - No credentials. The servers need no network.
- **Lifetime:**
  - Servers don't hold the foreground service. If Android ends the app, they end with it, and they start again with the next file of their language.
  - A server with no open document of its language for 10 minutes is stopped.
- **Tests:**
  - **JVM:** the framing (part of a message per read, several per read, the size cap, a bad header, a character split across reads), and `LspHost` against a stub server.
  - **Instrumented, on every runtime leg and the phone:** `LanguageServerTest`. It is W1's smoke suite through `LspHost`, plus the server killed with `SIGKILL`: the exit reported and the tree gone.

**As built (W3):**
- **G3 met** (CI 45020136733, which committed the counts, and plain CI 45027761446 on the final code; phase gate 45029118568, whole: every emulator group at its first attempt, the cold start at 1,094 ms, no ANR of CodeForge's (2 of Google Play services' at boot); Test Lab's Pixel 8a 40 of 40 in the same run; evidence `9a9c54eb`, `3ec23610` and `28fb037f`). The first gate, 45021556836, failed only its sessions group, on a log line W3 had changed (below).
- **Decided at W3's start: the launcher's command mode, with stdin open.** No new mode was needed. W1 had already run both servers through the command mode on every target, and `LspHostTest` runs the real launcher, compiled from `native/runtime-core`, against a stub server: messages both ways, the exit's code or signal, the tree ended. ADR-0015 records it.
- **The framing** (`runtime/LspFraming.kt`): `LspFrameReader` reads LSP's base protocol from bytes and hands over whole messages only, however the server's writes split them.
  - Header lines end in CR LF, at most 8 KiB each and 16 in all, and `Content-Length` is required.
  - A message is at most 16 MiB and must be valid UTF-8.
  - Anything else is a typed `LspFramingException` (`bad_header`, `too_large`, `truncated`, `bad_utf8`) and ends the server as `broken`.
- **`LspHost` and `LanguageServerProcess`** (`runtime/LspHost.kt`):
  - **The process.** A server starts through the launcher as a command does: in its own session and process group, under the sessions' limits (no CPU-time limit), with no deadline and stdin open. Its program is the runtime's node running the server's entry, which W2's `LanguageServers` installs on the first start.
  - **The registry.** A third session kind, `LANGUAGE_SERVER`, so an install ends the servers with the terminals before it touches the prefix.
  - **The threads.** Each server has a reader, a stderr reader and a writer. The writer's queue holds 32 MiB, past which a send is refused as `queue_full`, so a sender never blocks on a server that has stopped reading. The last 64 KiB of stderr are kept.
  - **How it ended:** `exited` with its code, `signaled` with the signal, `stopped`, `memory`, `broken` with the framing's reason, or `lost` with why. Each exit carries the stderr tail and what the launcher ended of the tree.
  - **Limits.** At most 2 servers, one per server id (each language has one server). A second start of the same server is refused as `already_running` with the running one's handle, and a third server as `too_many`.
  - **The workspace.** A project's name or a copy's id, resolved as a terminal's folder is (E3), never a path.
  - **The environment** is the runtime's (E2) plus `NODE_OPTIONS=--max-old-space-size=256`, a backstop rather than the budget. No credentials.
  - **Memory.** Each server's process tree (PSS, RSS, processes) is read from `/proc` every 10 s.
  - **Low memory.** Android's warnings (`onTrimMemory` at `RUNNING_LOW` and above, except `UI_HIDDEN`, and `onLowMemory`) stop every server first, ended as `memory`, and then trim the hidden terminals' buffers.
- **The boundary to Dart.** `pigeons/lsp_api.dart` generates `LspApi` (start, send, stop, servers) and `LspEvents` (received, exited). `lsp/LanguageServerHost.kt` serves them over the process's hub. A server belongs to the engine that started it and stops when that engine goes, including one whose start finishes after the engine has gone. Logs name a server by its handle and id, never a message or a path.
- **Measured** (gate 45029118568), through `LspHost`:
  - **A second Pyright while one ran** was refused as `already_running`, with the running one's handle, on all five legs and the phone.
  - **SIGKILL to the server's node** was reported as `signaled` with signal 9 within 3 to 7 ms on the emulators and 226 ms on the phone, and nothing of its group was left.
  - **The smoke suite:** all four cases exited 0 on every target, 7 to 86 ms after `exit`.
  - **The phone's completion after an edit, p95:** Pyright 83.3 ms on two files and 111.9 ms on 200, the TypeScript server 33.9 and 59.3 ms. All are within the 300 ms budget, which W6 judges.
  - **The phone's PSS after the suite:** Pyright 165.2 MB on two files and 195.6 MB on 200, the TypeScript server 238.7 and 254.8 MB. All are under (b)'s 300 MB, which W6 judges.
  - **Pyright got slower on the phone, for a reason not yet known.** Its completion with no edit took 20.6 ms at p50 on two files and 18.7 ms on 200 (17.9 and 33.0 ms in the first gate), against 8.0 and 5.1 ms in W2's gate. After an edit, its p95 went from 62.4 and 58.0 ms in W2 to 83.3 and 111.9 ms. W1 and W2 had agreed closely.
    - Message counts were the same as W2's, and the phone's other figures in the same runs barely moved (the terminal's echo p50 went from 3.4 to 4.0 ms).
    - The emulators show no consistent shift, and the TypeScript server's moved both ways (its two-file case with no edit took 10.4 and 26.5 ms in the two gates, against 19.3).
    - Locally, with node 22 on x86_64, Pyright's latency was the same with heap caps from none down to 80 MB, so the cap is unlikely to be the cause. The phone runs node 26 on arm64, so W4 measures it there too.
    - W4 times each stage of a request (the host's queue, the server, the delivery to Dart). W6 judges the budget on the phone through Dart's client.
- **Differs from the plan:**
  - **The 10-minute idle stop moves to W4.** It depends on which documents are open, which only Dart knows. The host gives W4 what it needs: `stop` and the list of servers.
  - **One per server, not per language.** That is the same today, since each language has one server. The TypeScript server's two languages count once.
  - **A bug the JVM tests caught before the gate.** `send` and `stop` through the host answered `no_such_server` on success, because a Kotlin elvis took the success's null for a missing server. `LspHostTest` caught it on its first run, and CI 45018943282 has the fix.
  - **A log line the emulator gate reads.** W3 had added the stopped servers to the memory-pressure line in which `emulator_gate.sh` counts the terminals' trimmed buffers. The first gate (45021556836) found no count where 2 buffers were trimmed and failed its sessions group. The line is as it was again, and the servers have a line of their own (4088f6ce). That gate's runtime legs and Test Lab had passed.
- **Tests:**
  - `LspFramingTest` (11, JVM).
  - `LspHostTest` (12, JVM): the real launcher and installer, with a Python stub server that misbehaves on request. It writes messages in bursts and in seven-byte pieces, reports its environment and folder, writes 70 KiB of stderr, exits with a code, is killed with SIGKILL, writes garbage, a 20 MB header and bad UTF-8, starts a child, and stops reading.
  - `LanguageServerTest` (5, on each runtime leg and the phone): W1's smoke suite now goes through `LspHost`, as the app runs servers. Test e refuses a second Pyright and then kills the running one with SIGKILL. The gates require `lsp_crash=signaled:9`.
  - Counts: `+1093: All tests passed!` and 225 Kotlin tests (CI 45020136733).

### W4 — The client in Dart: sessions, document sync, restart (2 sessions) → G4

- **`LspService`** joins `services/contracts.dart`, with its Pigeon implementation in `services/lsp/native/` and a fake for tests.
- **Dart owns the protocol,** as LSP_ARCHITECTURE §1 planned:
  - a server's session outlives the editor's page, which reloads after a renderer crash and is let go in the background (Phase 5 W5);
  - the shadow documents and their versions are already Dart's (EDITOR_ARCHITECTURE §2);
  - diagnostics feed Flutter's UI as well as the page;
  - the state machine can be tested with a fake transport.

  `@codemirror/lsp-client` puts the client in the page, and for those reasons it is not chosen. ADR-0015 says so.
- **JSON-RPC 2.0:**
  - ids, a timeout per request (2 s for completion, 10 s otherwise), and `$/cancelRequest` when the user moves on;
  - the server's own requests answered: `workspace/configuration` with sanitized settings, `client/registerCapability`, `window/workDoneProgress/create`;
  - its log messages into the app's log, bounded.
- **The session:**
  - `initialize`, with the client's capabilities, in UTF-16 positions. Dart and CodeMirror both count in UTF-16, so nothing is converted.
  - One workspace folder: the project, or the folder's copy.
  - `shutdown` and `exit` when it ends.
- **Document sync:**
  - `didOpen` when a document of the language is first shown.
  - `didChange` from the editor's change sets, which the page already sends in batches of about 150 ms: incremental ranges, applied in order with their versions.
  - Before a request, everything up to the version the page names is sent first, so the server answers about the text on screen.
  - `didSave`, and `didClose` when the tab closes.
  - Files changed outside the app, from Phase 3's watcher, as `didChangeWatchedFiles`.
  - Full text only when a document opens, and after a resync (spec §6.3).
- **Restart:**
  - after an exit or a broken message, the server starts again after 1 s, 2 s, then 4 s, at most 3 times in 5 minutes;
  - after that the chip offers *Restart*;
  - every open document is opened again in the new server;
  - requests in flight fail as *restarting*, and completion falls back to the editor's word completion meanwhile.
- **The idle stop** (moved from W3): a server with no open document of its language for 10 minutes is stopped through `LspApi.stop`.
- **Timing:** each request's stages are timed (the host's queue, the server, the delivery to Dart), and Pyright is measured on the phone with and without the heap cap. W3's gates found it slower there, for a reason not yet known (*As built (W3)*).
- **The capability model:** a language is *analyzable* while its server is installed, verified and running. The status strip's chip names the server's state: starting, ready, analysing, restarting, or off, with the reason.
- **Tests,** in Dart against the fake transport:
  - the handshake, and versions in order;
  - change sets to ranges, with surrogate pairs and CRLF;
  - cancellation and timeouts;
  - the restart backoff and its cap;
  - diagnostics routed by URI, and the URIs of projects and copies.

**As built (W4):**
- **G4 met** (CI 45065692542, which committed the counts: `+1179: All tests passed!`, 228 Kotlin tests, analyze clean; phase gate 45067383709: `LanguageServerTest` 6 of 6 on every runtime leg, every emulator group at its first try in the emulator job's second attempt, the cold start at 1,302 ms (record-only) and no ANR of CodeForge's (2 of Google Play services' at boot); that job's first attempt had failed only its keys group, whose first tap met a black screen while System UI's keyguard hung 20 s at boot (its screenshot is in `151caf32`), so that job alone was run again; Test Lab's Pixel 8a 41 of 41 in the same run; evidence `4f5ded29`, `8b91b9f3` and `171a8582`). The first CI run, 45063872382, failed on a test's missing import and on one widget test's count (below).
- **The service** (`services/contracts.dart`): `LspService` starts a server by its id in a workspace named, never a path; carries whole JSON-RPC messages; stops a server; lists those that run; and streams their messages and exits.
  - `PigeonLspService` (`services/lsp/native/`) is the only Dart that sees the generated types.
  - `FakeLspService` reports no host, so tests and other platforms show no server chip.
- **What the host says since W4** (`pigeons/lsp_api.dart`, `lsp/LanguageServerHost.kt`, `runtime/LspHost.kt`):
  - A start names the workspace's folder as the server sees it (absolute, links resolved), the runtime's programs and the server's own folder. Dart builds every URI and the servers' options from them, and still never sends the host a path.
  - A send answers once its message is written to the server's stdin, with when, and each message comes with when the host read it whole. Both are on the monotonic clock (Kotlin's `System.nanoTime`, Dart's `Timeline.now`). A message still queued when its server ends is told it was not written.
  - A start may go without the heap cap, for the measurement below.
- **JSON-RPC** (`application/lsp/lsp_connection.dart`):
  - numbered requests, each with its timeout (2 s for completion, 10 s otherwise, `initialize` included), and `$/cancelRequest` when one runs out or is called off; an answer that comes later is dropped;
  - the server's errors fail the request with their code (`RequestCancelled` as cancelled);
  - each request's time split into the host's queue, the server and the delivery.
- **The client** (`application/lsp/language_client.dart`), one per server:
  - **The session:** `initialize` offers UTF-16 positions only and one workspace folder, the root the host named; then `initialized`.
    - Pyright's settings come from a fixed table through `workspace/configuration`: the runtime's python, and `openFilesOnly`.
    - The TypeScript server gets the APK's `tsserver.js`, one tsserver process and no typings fetched.
    - Registrations, progress tokens and the workspace's folders are answered. `workspace/applyEdit` is refused, and anything else gets MethodNotFound.
    - Its log lines go to the app's log, 20 a minute at most.
  - **Documents:**
    - `didOpen` with the whole text when a document is first shown;
    - each of the editor's change sets as ranges, last first, computed against the text before it (`core/lsp/text_sync.dart`), with LSP's version growing with the editor's;
    - the whole text after a resync, or when an edit does not follow what the client holds;
    - `didSave` to a server that asked for it, and `didClose` with the tab;
    - the files Phase 3's watcher finds changed, as `didChangeWatchedFiles`, matched against each server's own globs (`core/lsp/lsp_glob.dart`).
    - A request about a document waits until the edits up to the version the page names have gone out.
  - **Restarts:** an exit, a crash, a broken message or a failed `initialize` restarts the server after 1 s, 2 s, then 4 s.
    - A fourth within five minutes gives up, and only the user's *Restart* starts it again.
    - Requests in flight fail as restarting, and every open document is opened again.
    - A server stopped to free memory waits for the next document shown.
  - **The idle stop:** ten minutes with no open document send `shutdown` and `exit`, and the host's stop follows 2 s later if the server has not ended.
  - **Diagnostics** are routed by URI to their document's workspace path, and go with its tab or with its server.
- **In the app** (`application/lsp/lsp_controller.dart`):
  - Servers run in projects once the runtime is ready. Folders follow with W5, through their copies.
  - The status strip's chip names the active file's server and its state: starting, ready, analysing, restarting, or off, with why. Once the client has given up, a tap restarts it.
  - A language is *analyzable* while its server runs (`core/editor/capabilities.dart`).
  - The integration tests turn servers off (`languageServersEnabledProvider`), so the phase gate's groups measure what they did. W6's `lsp` group turns them on.
- **Measured** (gate 45067383709): `LanguageServerTest` f runs Pyright's 50 completions after an edit on the two-file project four times, alternating the host's heap cap and none, and splits each request into its stages.

  | Pixel 8a, ms | capped 1 | no cap 1 | capped 2 | no cap 2 |
  |---|---|---|---|---|
  | Total, p50 / p95 | 58.2 / 83.4 | 55.3 / 84.5 | 58.8 / 85.0 | 54.8 / 82.2 |
  | The host's queue, p50 / p95 | 3.0 / 6.1 | 3.2 / 6.1 | 3.2 / 6.0 | 2.7 / 5.6 |
  | The server, p50 / p95 | 33.9 / 53.4 | 31.1 / 55.2 | 32.3 / 65.7 | 31.4 / 51.7 |
  | The delivery, p50 / p95 | 0.58 / 2.55 | 0.60 / 1.17 | 0.68 / 1.90 | 0.67 / 7.54 |
  | PSS after (MB) | 162.1 | 163.3 | 163.9 | 165.8 |

  - **The heap cap is not why Pyright got slower:** the phone's totals were the same with it and without it, as on the five emulators. The cap stays.
  - **The server takes most of a request:** 31 to 34 ms at p50 on the phone, and 7 to 17 ms on the emulators.
  - **The host's queue costs about 3 ms on the phone** (2.7 to 3.2 ms at p50), against 0.05 to 0.2 ms on the emulators: the hand-off to the server's writer thread. The delivery to the listener takes 0.6 ms.
  - **About 20 ms of the phone's median lie after the delivery,** in the test's own client: the stages' medians add up to 35 to 38 ms of a 55 to 59 ms total. That is its JSON parse and its waiting thread's wake, with messages of at most 6.9 KB. The app's path differs there: the host posts each message to Dart's main thread, and the client times its delivery itself. W6 measures it on the phone.
  - **W4 does not settle why W2's figures were lower;** it rules out the heap cap and shows where the time goes now.
  - The rest of the phone's figures held. Pyright's completion after an edit took 85.4 ms at p95 on two files and 95.4 ms on 200, and the TypeScript server's 79.6 and 45.1 ms. PSS after the suite was 165.8 to 257.6 MB. A server killed with SIGKILL was reported as signaled in 17 ms.
- **Differs from the plan:**
  - **The host changed too.** Timing a request's stages needs when the host wrote it and read the answer, and the URIs need the root as the server sees it. So the Pigeon API grew (above), rather than Dart guessing either.
  - **Folders wait for W5.** A folder's server works in its copy (ADR-0013), which W5 keeps in step. W4 tests the URIs of copies, and the chip says folders are not served yet.
  - **`didChangeWatchedFiles` from listings.** Phase 3's watcher reports folders, not files, so each folder listed again is compared with its last listing: files created, deleted, or changed in size. A file rewritten at the same size outside the app is missed unless it is open, when its reload resyncs it.
  - **Off in the integration tests,** so the other groups' figures stay comparable (above).
  - **What CI caught:** the first run (45063872382) failed on a test's missing import, and on a widget test that had not counted the TypeScript server the demo's `main.js` starts.
- **Tests:**
  - 86 new Dart tests: `lsp_text_sync_test` (12), `lsp_uri_test` (11), `lsp_connection_test` (11), `language_client_test` (31), `lsp_controller_test` (7), `lsp_service_test` (8), `lsp_chip_test` (5), and one in `capabilities_test`. They run against the scripted host (`test/support/scripted_lsp_service.dart`) on a clock moved by hand.
  - `LspHostTest` 15 (3 new: a send told when written, messages dropped when the server ends, a start without the heap cap) and `LanguageServerTest` 6 (f new).
  - Counts: `+1179: All tests passed!` and 228 Kotlin tests (CI 45065692542).

### W5 — In the editor: completion, diagnostics, definition, rename, hover (2 sessions) → G5

- **The editor protocol v1 grows,** each new type with fixtures in vitest and Dart:
  - from the host: `diag.set`, a document's diagnostics;
  - from the page: `lsp.complete`, `lsp.resolve`, `lsp.hover`, `lsp.definition` and `lsp.prepareRename`, each answered through `response` within its timeout;
  - `doc.applyEdits`: one undoable change to a document, refused if the document has moved past its base version.

  The bridge's caps are checked against the largest completion list the servers gave in W1.
- **Completion:**
  - CodeMirror's autocomplete, with the server as an asynchronous source, triggered as the user types and by the server's trigger characters;
  - each item's kind shown as an icon, its documentation fetched when it is selected, its text edit applied, and at most 200 items shown;
  - the editor's own word completion while the server isn't ready.
- **Diagnostics:**
  - underlines and gutter marks through `@codemirror/lint` 6.9.8, a new dependency with AGENTS §5's justification paragraph. A tap on an underline shows the message.
  - The file's counts in the status strip.
  - A *Problems* sheet listing the open files' diagnostics; a tap goes to the line.
- **Go to definition:**
  - from the long-press menu, the symbol toolbar, and F12 on a hardware keyboard;
  - it opens the file at the place, in the same workspace;
  - a definition in the server's own files (Python's stubs, TypeScript's `lib.d.ts`) opens read-only.
- **Rename:**
  - a dialog for the new name, filled in from `prepareRename`;
  - the server's edit is applied all or nothing. Open documents change through `doc.applyEdits`, each as one undoable change. Closed files are written atomically through `FileService`, and a folder's through the broker.
  - If any file changed after the edit was computed, nothing is written, and the user is told why.
  - A summary lists the files changed.
- **Hover:** a long press shows the server's hover text, with code blocks in the monospace font.
- **Folders:**
  - Analysis runs on ADR-0013's copy, refreshed incrementally when the folder opens and after each save.
  - Open documents come from the editor, so the copy only has to be fresh for the closed files the server reads.
  - A place in the copy maps back to the folder's document.
- **Settings:**
  - Settings → Editor turns each language's server on or off;
  - Settings → Linux runtime shows each server's version, state and memory, with *Restart*.
- **Tests:** widget tests for the chip, the Problems sheet and the rename dialog, with goldens at the three breakpoints.

**As built (W5):**
- **G5 met** (CI 45131313756, which committed the counts: `+1281: All tests passed!`, 228 Kotlin tests, analyze clean; CI 45133675713 on the final code, whose only change was the `lsp` group's test; phase gate 45135282059: the emulator's new `lsp` group passed at its first attempt (`+1: All tests passed!` in 43 s), as did every other group, with the cold start at 886 ms and no ANR or crash (`keys_events`, counted after the keys group); `LanguageServerTest` 6 of 6 on every runtime leg; Test Lab's Pixel 8a 41 of 41 in the same run; evidence `87e16566`, `55b5bba1` and `134fd8f8`). The first CI run, 45115097753, failed five tests and one warning (below).
- **The protocol** (`editor/src/protocol/` and `app/lib/core/editor/protocol.dart`, with 31 new shared fixtures):
  - **From the host:** `diag.set`, a document's diagnostics at a version, at most 1,000, which the page maps through the edits made since and refuses as `stale` when it can no longer map from that version; `doc.applyEdits`, a rename's edits to open documents, each document's as one undo step, all or nothing (refused as `stale` when any document moved past its base version or holds edits not yet sent); and `response`, the answer to one of the page's requests.
  - **From the page:** `lsp.complete`, `lsp.resolve`, `lsp.hover`, `lsp.definition` and `lsp.prepareRename`, each answered once, with a result checked against its request on both sides (`PAGE_RESULTS`, `validatePageResult`); and `lsp.cancel`.
  - The error codes `unavailable` (no server can answer now; completion falls back to words), `timeout`, `cancelled` and `server_error`; the commands `goToDefinition`, `renameSymbol`, `showHover`, `startCompletion` and `acceptCompletion`; the shortcut `problems`.
  - **The caps against W1 to W4's answers:** the largest completion list had 26 items and the most diagnostics were TypeScript's 199. An answer carries at most 200 items (the plan's 200 shown, trimmed in Dart), a document at most 1,000 diagnostics, and a rename at most 64 documents of 10,000 edits each.
- **The page** (`editor/src/editor/lsp.ts`, `markdown.ts`, `requests.ts`; `bridge.ts`):
  - **Completion:** CodeMirror's autocomplete with the server as its source, as a name is typed and after the server's trigger characters (`.` until it names them). Each item shows its kind's icon, the server's order breaks ties, and its documentation is fetched when it is selected. Its edit lands where its word is now, with any edits that come with it (an import) when they lie before the word. At most 200 are drawn. While no server can answer, the document's own words stand in (`completeAnyWord`).
  - **Diagnostics** through `@codemirror/lint` 6.9.8, which lang-javascript already brought in and which is pinned now: underlines, gutter marks, unused code faded, deprecated names struck through, and F8 to the next. A tap on an underline shows its messages: lint's own tooltip waits for a mouse to hover, which a finger never does.
  - **The symbol menu:** a long press shows the diagnostics there, the server's hover text with code in the editor's font, and *Go to definition* and *Rename…*. It opens on the WebView's `contextmenu`, which is not cancelled, so the word is still selected for copying. A mouse's hover shows the hover text; F12 and F2 do as the menu does.
  - **No server text reaches the DOM as HTML:** the documentation's Markdown is drawn node by node with `textContent`.
  - The bridge times each request out a second after the host's own limit, and cancels at the host what it gives up.
- **The host** (`application/editor/editor_host.dart`; `application/lsp/lsp_features.dart` and `rename.dart`; `core/lsp/lsp_answers.dart` and `workspace_edit.dart`):
  - **Requests** go to the document's server once every edit before them has gone out: completion within 2 s, documentation and hover within 3 s, definition and rename's check within 10 s. Completion lists are filtered by the typed word and trimmed to 200 in the server's order, and marked incomplete when trimmed. Snippets become text, and InsertReplaceEdits and a list's default range are read.
  - **Definition** opens the file at the place, in the same workspace. A place in the server's own files (Pyright's stubs, TypeScript's `lib.d.ts`, a package in the runtime) opens read-only in a sheet, read only under the server's folder and the runtime's programs, with links resolved first, 8 MiB at most.
  - **Rename:** `prepareRename` checks the place, and the dialog starts from the server's name. Every file's new text is then worked out first. An open document's comes from the editor's text, which must be at the version the server computed it for and must not have moved while it did. A closed file's comes from disk, and one stamped after the request is refused. Every edit must fit its file and replace the old name. Closed files are written next, atomically in a project and through the broker in a folder, each only if it is still as read. Then the open documents change together, one undo step each. A failure in either step gives the files already written their old text back. The servers hear of the files written, and a summary names every file. A server that would rename or delete files is refused.
  - **Diagnostics** of the open documents go to the page (`diag.set`), to the status strip's new problems chip (the active file's count, with the worst severity's icon) and to the *Problems* sheet (each open file's, by line; a tap goes there; Ctrl+Shift+M opens it). They are sent again after the page restarts (`PageSynced`), and go with the server that found them. A set found in a version older than the server holds is dropped.
- **Folders** are analysed through their copy (ADR-0013). It is brought up to date before any server starts in it, and again after each save, each change from outside the app and each file a rename writes, before the servers hear of them. A place in the copy is the same path in the folder.
- **Settings:** Settings → Editor turns each language's server on or off. `languageServersEnabledProvider` follows it now, and the integration tests still override it. Settings → Linux runtime shows each server's packages, state and memory (read every 10 s), with *Restart*.
- **Elsewhere:** the symbol toolbar has *Go to definition* for a language a server analyses, and the palette has Go to Definition, Rename Symbol…, Show Symbol Info and Show Problems.
- **The phase gate's `lsp` group** (`integration_test/lsp_test.dart`, in the build with the x86_64 payload): one test of nine steps in the real app, with the real servers and the real editor page. In gate 45135282059 it passed in 43 s:
  - **Diagnostics:** Pyright's error in `main.py` was listed (1) and underlined (1) 3,080 ms after the three files were written, with Pyright running at 1,900 ms, its first install (887 ms) included. The fix, made in the editor and not saved, cleared both in 476 ms.
  - **Completion** after `gre` offered 9 items through the page, and `greet` was taken into the text. **Hover** answered with 52 characters. **Definition** opened `people.py` at `greet`.
  - **Rename** of `greet` to `welcome` through the dialog: "Renamed greet to welcome in 3 files: main.py, other.py, people.py". The closed `other.py` was written, and one undo in each of the two open documents took it back there.
  - **TypeScript** listed 2 errors in `broken.ts`, and completion after `console.lo` offered 2 items.
  - **A killed server:** Pyright, killed with SIGKILL while an error stood only in the editor's text, was back 2,318 ms later with its documents and reported that error again.
  - **Three crashes:** at Pyright's fourth end, after three restarts, the chip offered *Restart*. The editor still edited, completion fell back to words, and *Restart* brought Pyright back.
  - **A folder** (`cf-gate`, picked in Android's picker): Pyright ran in its copy (`folder-6e871…`) as the only server, found only the deliberate error (the import resolved in the copy), and a definition opened the folder's `lsp_people.py`.
- **Differs from the plan:**
  - **The `lsp` group came with W5,** not W6, as G5's evidence. W6 adds its budgets and the phone.
  - **"Three crashes":** W4's backoff restarts a server three times within five minutes and gives up at the fourth end. The group shows *Restart* offered after the third restart, with the editor still editing and completion falling back to words.
  - **Read-only definitions open in a sheet,** not a tab: a tab is a workspace file, with saves, the journal and the watcher.
  - **A rename's closed files are not undone by the editor's undo;** the summary names them. Each open document takes one undo.
  - **`doc.applyEdits` carries every open document** in one message, so the page applies them all or none. Each still makes one undo step.
  - **What CI caught:** the first run (45115097753) failed five tests and one warning. The host's tests counted the new `PageSynced`, and the rename test expected file changes for a server that had not asked for them. A two-taps test met a settings row that was no longer built. Settings → Editor did not stop a server at once, because Riverpod 3 pauses a provider nobody listens to (the screen listens now). And the workspace switch had an unreachable default.
- **Tests:**
  - 102 new Dart tests: `lsp_answers_test` (15), `workspace_edit_test` (11), `lsp_server_versions_test` (2), `lsp_features_test` (18, through the host), the widget tests' `lsp_features_test` (7), `lsp_golden_test` (6 goldens: the Problems sheet and the rename dialog at 412×915, 800×1280 and 1280×800), 6 in `editor_host_test`, 2 in `lsp_controller_test`, 1 in `settings_store_test`, and 34 in `editor_protocol_test` (31 fixtures).
  - vitest: 440, up from 373. `lsp.test.ts` has 32 (the bridge's requests, `diag.set`, `doc.applyEdits`, completion, definition, rename, the symbol menu and the Markdown), and `protocol.test.ts` 35 more.
  - Counts: `+1281: All tests passed!` and 228 Kotlin tests (CI 45131313756).

### W6 — The language gate on real targets (1–2 sessions) → G6

**The budgets** (PERFORMANCE §2, LSP_ARCHITECTURE §3):
- completion within 300 ms at the 95th percentile, warm, from the request in the page to the list drawn;
- diagnostics within 1 s of a save;
- the app with the editor, a terminal and a server within 600 MB, or within the owner's decision after W1. It is measured as PSS: the app, its renderer and the server's process tree.

**Where they are measured:**
- **The emulator gate's new `lsp` group,** in the real app on the sealed runtime, for each language that ships:
  - an error underlined, fixed, then cleared;
  - completion after `.`, offering a known member;
  - definition into another file;
  - a rename across two files, with one undo per open file;
  - the server killed: started again, its documents reopened, the diagnostics back;
  - three crashes: *Restart* offered, and the editor still editing;
  - a folder through its copy;
  - the figures recorded.
- **The runtime legs** run `LanguageServerTest`.
- **Test Lab's Pixel 8a** runs `phone_lsp_test.dart`, judged on the budgets, in a `[testlab]` run after CI is green.
- **For the owner's phone** (W7's checklist):
  - completion with Gboard: does its popup fight the keyboard's suggestions?
  - the long press, for hover and definition;
  - a rename;
  - the Problems sheet.

**As built (W6):**
- **G6 met** (CI 45180564110, which committed the counts: `+1286: All tests passed!`, 228 Kotlin tests, analyze clean, vitest 448; phase gate 45182761593: Test Lab's Pixel 8a, Android 14, 42 of 42, its `SyncModesTest` 5 of 5 with every budget under its line; on the emulator every group passed at its first attempt, the `lsp` group's budget run with them, with the cold start at 1,030 ms and no ANR or crash (`keys_events`); `LanguageServerTest` 6 of 6 on every runtime leg; evidence `027db445`, `698f2ca9` and `f82b52a0`).
- **The budgets on the phone,** in the real app with the real servers and the real page (a profile build), on the gate's 200-file projects (202 files each):

| | Pyright | TypeScript | Budget |
|---|---|---|---|
| Completion after an edit, from the page's request to the list drawn: p50, p95, slowest | 69.7, **139.0**, 161.0 ms | 45.8, **64.5**, 72.5 ms | p95 within 300 ms |
| Of which, the request to the host's answer: p95 | 116.0 ms | 48.1 ms | — |
| Diagnostics after a save: p50, p95, slowest | 405.2, **476.9**, 490.4 ms | 542.2, **657.7**, 658.9 ms | within 1 s, at p95 |
| The server's process tree: PSS (RSS), processes | **169.9 MB** (197.9), 2 | **246.5 MB** (299.6), 3 | 300 MB of PSS each |
| Running, then the first error listed, after the file opened | 1,554 ms, then 2,608 ms | 915 ms, then 2,318 ms | recorded |

  - Pyright's lists held 26 items (the median), TypeScript's 3. Every list was drawn, and no frame was waited for in vain (`undrawn=0`, `throttled=0`).
  - **The total, recorded** (the owner's decision of 2026-11-22: each server has a budget of its own, and the app keeps its own): the app with the editor open held 428.3 MB of PSS and its renderer 83.1 MB, 511.4 MB together; with both servers, 927.7 MB.
- **How each is measured** (`app/integration_test/phone_lsp_test.dart`, one test):
  - **The project:** `lsp-gate`, created through the workspace switcher and filled before it opens with both languages' 200 modules, from `LanguageServerTest`'s generators ported to Dart: `pkg/` and `main.py` for Pyright, `src/` and `tsconfig.json` for TypeScript. Each server reads only its own language's files, so the two run side by side in one project, as many as the host allows.
  - **Completion:** 50 times after 5 to warm up. A comment line is typed at the end of the file, the cursor goes after `thing.` (line 203), and completion is asked as Ctrl+Space asks it (`startCompletion`). The page times each list from its request to the end of the frame that draws it. The clock starts in the completion source, before the edits not yet sent go out ahead of the request, and stops in a task posted from the next animation frame once CodeMirror's open list holds the answer's options (the editor benchmark's `afterPaint`). CodeMirror's own 50 ms before it calls the source is outside. The test does not focus the editor, so no input method takes part; W7's checklist tries Gboard with it.
  - **Diagnostics:** 20 saves after 4 to warm up, each straight after a line is typed. Every other one adds an error (`wrong_N = missing_N`, `export const wrongN: number = "xN";`), and the next comments it out. Each is timed from the save to the page's acceptance of the set with the expected count (`diag.set`, through the host's `diagnosticsShown`). The save sends the typed line first, so the server's analysis of it is inside the time. The save itself took 29.1 ms (Pyright's file) and 28.3 ms (TypeScript's) at p50.
  - **Memory:** each server's tree as `LspHost` reads it every 10 s, 12 s after the work; then the app's and its renderers' PSS through the gate (`mem lsp`: `dumpsys meminfo`, answered by `GateAnswers` on Test Lab and by folder_driver on the emulator).
- **The page's timings** (`editor/src/editor/timings.ts`): `CompletionTimings` takes the time before each request and the options its answer brings (`lsp.ts`), and an update listener sees when the open list holds them. It keeps the newest 500 times and counts the lists never drawn (closed or replaced first), the empty answers, and the frames that never came (a hidden page falls back after 1 s). It is DOM-free but for the browser's clock, which `ControllerOptions.timingClock` replaces in vitest's 4 new tests in `lsp.test.ts`.
- **The protocol:** `probe.read` from the host (`{clear?}`), answered with `{completions: [{ms, answerMs, items, trigger}], undrawn, empty, throttled}`, with 2 valid and 2 invalid fixtures that vitest and Dart both run. `EditorHost.readProbe` reads it.
- **Test Lab** (`ci.yml`): `sync_modes_test.dart` runs `phoneLspTests()` after the terminal's tests, so the judge expects `SyncModesTest:5`. It requires the six `lsp_phone_*_under_budget=1` figures and the `CODEFORGE_LSP_JSON` document, and keeps the `LSP_GATE` lines in `logcat-runtime.txt`.
- **The emulator** (`emulator_gate.sh`'s `lsp` group): once `lsp_test.dart` passes, the group runs `phone_lsp_test.dart` as well, with folder_driver answering `mem`, and records its `LSP_GATE budget` lines and its exit in `lsp.txt`, never judged. In gate 45182761593 (a debug build, API 36): completion p95 162.3 ms (Pyright) and 144.1 ms (TypeScript); diagnostics after a save p95 325.4 and 418.7 ms; PSS 168.5 and 232.6 MB; the app 424.9 MB and its renderer 114.1 MB, 940.2 MB with both servers. The `lsp` group itself passed as in W5: Pyright's first error 4,705 ms after the files were written (its install included), cleared in 446 ms, and a killed server back in 2,729 ms.
- **The runtime suite on the phone, recorded** (`LanguageServerTest`, the same run): completion after an edit p95 Pyright 88.5 ms on two files and 118.3 ms on 200, TypeScript 78.9 and 69.8 ms; first diagnostics Pyright 1,301 and 1,579 ms, TypeScript 2,326 and 2,686 ms; PSS after the suite Pyright 162.5 and 193.0 MB, TypeScript 237.0 and 257.7 MB. On the legs (API 26 to 36), first diagnostics Pyright 622 to 970 ms and TypeScript 1,086 to 1,970 ms.
- **Deviations from the plan:**
  - **Diagnostics are judged at the 95th percentile,** as completion is: the plan's "within 1 s of a save" names none. The slowest of the 20 was within the budget too (490.4 and 658.9 ms).
  - **One project holds both languages,** so the phone measures both servers in one test, running side by side. Each still reads only its own 200 modules.
  - **The emulator's figures come from a second run in the `lsp` group,** not from a step of `lsp_test.dart`: a failure there fails nothing, and the phone's run is the judge.
- **Tests:** 5 new Dart tests: 1 in `editor_host_test` (`readProbe`) and 4 in `editor_protocol_test` (the new fixtures). vitest 448, up from 440: `lsp.test.ts` 36 (4 new) and `protocol.test.ts` 4 more. Counts: `+1286: All tests passed!` and 228 Kotlin tests (CI 45180564110).

### W7 — Docs and the phase exit (1 session) → G7

- **The docs:**
  - LSP_ARCHITECTURE as built, grown from the seed;
  - ADR-0015;
  - SECURITY §2.3, the language-server boundary;
  - ARCHITECTURE (`LspService`), EDITOR_ARCHITECTURE (the protocol's new types, the lint layer), RUNTIME_INTEGRATION (the servers in the payload, *analyzable*);
  - PERFORMANCE, TESTING, BUILD_AND_RELEASE, REPOSITORY_STRUCTURE and TECH_STACK;
  - docs/store, ROADMAP, README and the CHANGELOG.
- **The exit:** PHASE_6_REPORT, PHASE_6_PHONE_CHECKLIST and the exit gate.

**As built (W7):**
- **G7 met:** the documents below are synced, LSP_ARCHITECTURE is as built, ADR-0015 has its *As built (W6)* and *(W7)*, SECURITY has §2.3, and [PHASE_6_REPORT.md](PHASE_6_REPORT.md) and [PHASE_6_PHONE_CHECKLIST.md](PHASE_6_PHONE_CHECKLIST.md) are written. §7's list, as synced:
  - LSP_ARCHITECTURE, rewritten from the Phase 0 seed into the design as built (§1 to §8); SECURITY §2.3, the language-server boundary, with threats L1 to L12, each with its mitigation and its evidence, and §2's two new bullets;
  - ADR-0015 (*As built (W6)* and *(W7)*);
  - ARCHITECTURE (§1's line on the servers, as built; a new §2.12 for `LspService`, the clients, the controller, the features and the screens; §7's Phase 6 paragraph), EDITOR_ARCHITECTURE (`LspFeatures` in its diagram; W5 and W6 had added the protocol's types and the lint layer), RUNTIME_INTEGRATION (the servers in the payload; W4 had added *analyzable*), PERFORMANCE (the status, the bundle's row, and §4's language budgets as measured), TESTING (§1.6's W7 rows, and the phone checklists) and BUILD_AND_RELEASE (§2.6's W4, W5 and W7);
  - REPOSITORY_STRUCTURE (`phone_lsp_test.dart`'s line) and TECH_STACK (the Phase 6 update, and the servers' row);
  - docs/store (the listing, the data safety form, the privacy policy and the drafts' README: the servers add no permission and send nothing), ROADMAP, README and the CHANGELOG.
  - THIRD_PARTY_NOTICES §6 needed no change: CI writes it from the pins, and it lists all 61 package versions.
- **The last pass found two promises the plan had made and no work package had kept, and W7 kept them** (CI 45204541929, `+1291: All tests passed!`, 228 Kotlin tests, analyze clean):
  1. **A silent server.** §9's risk table: "a server that answers nothing for 30 s while requests wait is restarted, counted against the backoff". W4 built a timeout per request and `$/cancelRequest`, but nothing ended a server that stayed silent. Now `LspConnection` watches a server's silence once it is asked something: each message the server writes moves the watch on, and an answer that leaves nothing waiting ends it. A request given up still counts, since a server must answer even those. After 30 s of silence (`LspClientSettings.hangTimeout`) `LanguageClient` decides. A server reporting progress is busy (`server_busy`), and its requests time out one by one. Any other is hung (`server_hung`): ended through the host and restarted as a crash is, counted against the backoff, with "Pyright did not answer for 30 s" (or TypeScript) as the reason its chip gives. Tests: 3 more in `lsp_connection_test` (14) and 2 more in `language_client_test` (33), on the clock moved by hand.
  2. **The memory with a terminal open.** §1's objective 3 has memory "measured with the editor and a terminal open", and W6 measured the editor and both servers. `phone_lsp_test.dart`'s last step now opens a terminal beside the editor, at the panel's half stop, with both servers still running. It waits for the prompt, lets the terminal settle for 15 s as the terminal's own budget does, and reads the app's memory again (`mem lsp-terminal`). It records `lsp_phone_terminal_*` figures and an `LSP_GATE budget memory_terminal` line, never judged (§10, item 3). A terminal that does not come up is noted instead, and fails nothing.
- **Differs from the plan:**
  - **The silence watch** counts from the first request that goes out, not from "while requests wait": a request given up still counts, and a server reporting progress is busy, not hung. Any message counts as speaking, so a server that logs but never answers is left to its requests' timeouts.
  - **W7 wrote code,** beyond the documents the plan gave it. Both changes passed CI first (a `[bootstrap]` run, since the Dart changed), before the documents.
- **The exit:** the documents passed CI first (`73a67dc0`, CI 45209636475). Then the exit gate, 45225412011 (the empty `d266bd16`), passed every group on its first attempt: the five runtime legs 37 of 37 each, the emulator's groups with the cold start at 1,185 ms, and Test Lab's Pixel 8a 42 of 42 with every language budget met. With a terminal open, the Pixel 8a held 917.0 MB with both servers (PHASE_6_REPORT §4, §7.1). Evidence `397fe0ae`, `20c21863` and `0f771df5`.

## 4. Deliverables

- The spike's driver and its numbers, and ADR-0015.
- `runtime/language-servers/` with its lockfile, its checks and the servers' archives, and the notices' new section.
- The launcher's server mode (or its command mode with stdin kept open), `LspHost` with its framing, and its Pigeon API.
- `LspService` and the Dart client, and the capability model's *analyzable*.
- The editor protocol's new types: completion, diagnostics with the Problems sheet, definition, rename and hover. The settings.
- `LanguageServerTest` on the legs, the `lsp` gate group, and `phone_lsp_test.dart` in Test Lab.
- SECURITY §2.3, PHASE_6_REPORT and PHASE_6_PHONE_CHECKLIST.

## 5. Acceptance criteria (measurable gates)

| Gate | Criterion | Evidence |
|---|---|---|
| **G1 Compatibility** | Each candidate passes the smoke suite under the sealed runtime on API 26 to 36 and the arm64 phone. Its start, first diagnostics, completion latency and memory are recorded. ADR-0015 records the choice with the numbers | the runtime legs, Test Lab, ADR-0015 |
| **G2 Payload** | The servers are pinned with their integrity hashes, carry no install script and no native file, and their licences pass the allowlist. They install lazily and verified, and a damaged archive is refused with a typed failure. The notices list them. The bundle stays within Play's limit, with its figure recorded | CI, the runtime legs |
| **G3 Host** | The framing passes its JVM tests. A server starts, talks, stops, and is ended with its tree. A crash is reported with its stderr's tail, and a third server is refused. `LanguageServerTest` passes on API 26 to 36 and the phone | CI, the runtime legs, Test Lab |
| **G4 Client** | The client's tests pass against the fake transport: the handshake, ordered versions, change sets to ranges, cancellation, timeouts, and the restart backoff with its cap | CI |
| **G5 Editor** | In the real app: completion; diagnostics underlined, listed and cleared; definition across files; rename across files, with undo; and hover. All for projects, and for a folder through its copy. A killed server comes back with its documents, and after three crashes the editor still edits, with *Restart* offered | the phase gate's `lsp` group, widget tests |
| **G6 Language budgets** | On the arm64 phone: completion within 300 ms at p95 warm, diagnostics within 1 s of a save, and memory within the budget as decided (§10, item 3). On the emulator: the same figures recorded | Test Lab, the phase gate |
| **G7 Docs** | The docs synced, LSP_ARCHITECTURE as built, ADR-0015 and SECURITY §2.3 written, PHASE_6_REPORT and the phone checklist written | the documents |

Each work package ends as Phase 5's did: CI green, the phase gate, a `[testlab]` run in its own commit when the phone is involved, the docs updated, a report in chat, then the owner's "next".

## 6. Tests

| New suite | Where |
|---|---|
| The lockfile's checks: integrity, no scripts, no native files, the licences (`runtime/tests/test-language-servers.py`) | CI's runtime job |
| JVM: the framing, and `LspHost` with a stub server | CI's quality job |
| Instrumented: W1's spike, then `LanguageServerTest` (the smoke suite through the host, and the crash) | the runtime legs, Test Lab |
| Dart: the client against the fake transport, the capability model, the URIs, rename's edits; widgets for the chip, the Problems sheet and the rename dialog | CI |
| vitest: the protocol's new types, the completion source, the lint layer | CI's editor job |
| Integration: `lsp_test.dart` | the phase gate |
| `phone_lsp_test.dart` | Test Lab |

## 7. Documentation

LSP_ARCHITECTURE (as built), ADR-0015 (new), SECURITY §2.3, ARCHITECTURE, EDITOR_ARCHITECTURE, RUNTIME_INTEGRATION, PERFORMANCE, TESTING, BUILD_AND_RELEASE (the lockfile and its re-pin), REPOSITORY_STRUCTURE, TECH_STACK (the servers' and `@codemirror/lint`'s pins), THIRD_PARTY_NOTICES (the servers' section, written by CI), docs/store (the listing), ROADMAP, README, CHANGELOG, PHASE_6_REPORT, PHASE_6_PHONE_CHECKLIST.

## 8. Known limitations (planned) and out of scope

- **What the servers do in Phase 6:** completion, diagnostics, definition, rename and hover. The rest of LSP waits (§2).
- **Diagnostics for open files,** as Pyright gives them by default, not a scan of the whole workspace.
- **What the servers can see:** a JavaScript project gets node's types only with `@types/node` in the project. Python sees the packages pip installed into the runtime.
- **TypeScript 7 is not used.** Its native server has no Android build. Shipping its Linux arm64 binary as one of the APK's programs, and proving it on Android, is a decision for later (ROADMAP's queue). Meanwhile TypeScript 6.0.3 checks JavaScript and TypeScript.
- **Servers end with the app,** and start again with the next file of their language.
- **One server per language,** and at most two running at once.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| A server's memory takes the app past 600 MB, when the editor alone is at 452.7 MB, and 583 MB with a terminal after a flood | Measured in W1 before anything is built on it; the heap capped from W1's numbers; idle servers stopped after 10 minutes; at most two at once; the owner decides with the numbers (§10, item 3) |
| A server starts slowly on a phone (node, then the standard library's stubs) | The chip says *starting*; the editor's word completion meanwhile; editing never waits; the start time measured in W1 |
| A server hangs while its process lives | A timeout on every request; cancellation; a server that answers nothing for 30 s while requests wait is restarted, counted against the backoff. *Built in W7, not W4* (*As built (W7)*): silence after a request, a server reporting progress busy, not hung |
| Completion lists or diagnostics too large for the bridge | Lists trimmed to 200 in Dart; documentation fetched on selection; the bridge's caps checked against W1's largest list |
| TypeScript 6.0.3 is the last JavaScript release of TypeScript | It serves JavaScript and TypeScript for now; TypeScript 7's native binary waits in ROADMAP's queue |
| Rename writes some files and not others | All or nothing, checked against each file's stamp; each open document changed as one undoable change; tested in Dart and in the gate |
| A folder's copy is stale for the files the server reads | Refreshed when the folder opens and after each save; open documents synced live from the editor |
| The servers' files slow the first install | Each language's server installs the first time it is needed, and that is measured |
| Test Lab's 5 daily tests (counted by the Pacific day), and its end on 2027-09-30 | One phone run per gate, as before; ROADMAP's queue holds the successor |

## 10. Owner actions and decisions, in order

1. **Phase 5 accepted on 2026-11-21** (the owner's "next" after PHASE_5_REPORT asked to accept it or ask for changes).
2. **Which languages get a server in Phase 6,** by W2. Each ships only if it passes W1 on every target.
   - **(a) Python and JavaScript/TypeScript:** Pyright, and TypeScript 6.0.3 with typescript-language-server. About 11.0 MB per device (79.5 % of Play's limit). One client serves both.
   - **(b) Python only:** Pyright, 5.9 MB.
   - **(c) JavaScript/TypeScript only:** 5.1 MB.
   - **The agent recommends (a).** Run already runs both languages; both servers are JavaScript under the same node; and the second costs a smoke suite, not a second client.
   - **Decided on 2026-11-22: (a),** the owner's "item a please".
3. **The memory budget, after W1's numbers,** if a server takes the app past 600 MB with the editor and a terminal:
   - **(a)** keep 600 MB, with the server's heap capped and idle servers stopped;
   - **(b)** give the server a budget of its own, beside the app's.

   The agent brings the numbers and a recommendation at W1's end.
   - **W1's numbers (2026-11-22, phase gate 44977463887; ADR-0015):** a server takes 167 to 255 MB of PSS on the Pixel 8a, idle at 142 to 219 MB. With the editor and an open terminal (497.3 MB), the app reaches about 665 to 753 MB.
   - **(a) is not reachable as stated:** it would need a server under about 103 MB beside the editor and a terminal, below what node and the standard library's stubs take idle.
   - **The agent recommends (b):**
     - each server within **300 MB of PSS** on the gate's 200-file project on the phone (Pyright measured 210.1 MB, TypeScript 255.2 MB);
     - the app's own budgets kept as they are, and the total with a server recorded, as Phase 5 recorded a flood's growth;
     - idle servers stopped after 10 minutes, at most two at once, and servers stopped first when Android warns of low memory.
   - **Decided on 2026-11-22: (b)**, the owner's "do your recommendation": each server within 300 MB of PSS on the gate's 200-file project on the phone (judged in W6), the app's own budgets as they are, and the total recorded. W3 stops servers at Android's low-memory warnings and runs at most two; W4 stops a server after 10 minutes without an open document of its language, since Dart holds the documents.
4. **Non-blocking, carried from Phase 5:**
   - the phone session: PHASE_5_PHONE_CHECKLIST, and the Phase 3 and Phase 4 checklists, on the exit gate's APK (until 2026-12-21);
   - the first release: the keys, and the licence review, which the servers' notices join;
   - Play: the account, the testers, the forms, the special-use declaration, and the rule on downloaded code;
   - what runs the arm64 tests after Test Lab.
5. **Left to the agent,** unless the owner wants them: where the client lives (Dart), the framing and its caps, the backoff, the idle time, the heap cap (measured), basedpyright as Pyright's fallback, and the UI's details.
