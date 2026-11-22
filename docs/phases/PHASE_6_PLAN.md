# Phase 6 Plan — Language Intelligence

**Status:** **In progress.** Proposed on 2026-11-21, the day Phase 5 was accepted. **The owner chose (a) on 2026-11-22** (§10, item 2): servers for Python and for JavaScript/TypeScript. **W1 under way** · **Spec reference:** §8 Phase 6 (language intelligence), §6.3 (no full-document sync per keystroke), §6.5 (the capability model), §6.6 (a failing server never breaks the editor), §7 (security) · **Architecture:** [LSP_ARCHITECTURE.md](../LSP_ARCHITECTURE.md) (the Phase 0 seed this phase finalizes), [EDITOR_ARCHITECTURE.md](../EDITOR_ARCHITECTURE.md), [RUNTIME_INTEGRATION.md](../RUNTIME_INTEGRATION.md), [SECURITY.md](../SECURITY.md) §2, [ADR-0004](../adr/0004-editor-engine.md) (CodeMirror 6), [ADR-0005](../adr/0005-sealed-runtime.md), [ADR-0013](../adr/0013-folders-and-the-runtime.md) (a folder runs in a copy), [ADR-0014](../adr/0014-pty-and-sessions.md) · **Builds on:** Phase 5 ([report](PHASE_5_REPORT.md)): the launcher's sessions and limits, the editor protocol, Run and the folders' copy

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
- **The capability model:** a language is *analyzable* while its server is installed, verified and running. The status strip's chip names the server's state: starting, ready, analysing, restarting, or off, with the reason.
- **Tests,** in Dart against the fake transport:
  - the handshake, and versions in order;
  - change sets to ranges, with surrogate pairs and CRLF;
  - cancellation and timeouts;
  - the restart backoff and its cap;
  - diagnostics routed by URI, and the URIs of projects and copies.

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

### W7 — Docs and the phase exit (1 session) → G7

- **The docs:**
  - LSP_ARCHITECTURE as built, grown from the seed;
  - ADR-0015;
  - SECURITY §2.3, the language-server boundary;
  - ARCHITECTURE (`LspService`), EDITOR_ARCHITECTURE (the protocol's new types, the lint layer), RUNTIME_INTEGRATION (the servers in the payload, *analyzable*);
  - PERFORMANCE, TESTING, BUILD_AND_RELEASE, REPOSITORY_STRUCTURE and TECH_STACK;
  - docs/store, ROADMAP, README and the CHANGELOG.
- **The exit:** PHASE_6_REPORT, PHASE_6_PHONE_CHECKLIST and the exit gate.

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
| A server hangs while its process lives | A timeout on every request; cancellation; a server that answers nothing for 30 s while requests wait is restarted, counted against the backoff |
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
4. **Non-blocking, carried from Phase 5:**
   - the phone session: PHASE_5_PHONE_CHECKLIST, and the Phase 3 and Phase 4 checklists, on the exit gate's APK (until 2026-12-21);
   - the first release: the keys, and the licence review, which the servers' notices join;
   - Play: the account, the testers, the forms, the special-use declaration, and the rule on downloaded code;
   - what runs the arm64 tests after Test Lab.
5. **Left to the agent,** unless the owner wants them: where the client lives (Dart), the framing and its caps, the backoff, the idle time, the heap cap (measured), basedpyright as Pyright's fallback, and the UI's details.
