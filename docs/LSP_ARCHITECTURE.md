# LSP Architecture

**Status:** **As built at Phase 6's end** (2026-11-23; [PHASE_6_PLAN.md](phases/PHASE_6_PLAN.md), [PHASE_6_REPORT.md](phases/PHASE_6_REPORT.md), [ADR-0015](adr/0015-language-servers.md)). Grown from the Phase 0 seed, which planned clangd and the JSON, HTML and CSS servers too: they wait in ROADMAP's queue (§8). Since the seed, `typescript` 7 became a native port with no Android build, so the TypeScript line is 6.0.3, the last JavaScript release (PHASE_6_PLAN §0).

---

## 1. Topology

Language servers run as **child processes of the sealed runtime**, under its node, never in a WebView and never in the Flutter isolate:

```
CodeMirror 6 page (WebView): editor/src/editor/lsp.ts, timings.ts
   │  the editor protocol v1, checked on both sides (EDITOR_ARCHITECTURE §2):
   │  lsp.complete · lsp.resolve · lsp.hover · lsp.definition · lsp.prepareRename · lsp.cancel
   │  ▲ diag.set · doc.applyEdits · response
EditorHost (Dart) ──► LspFeatures · rename (application/lsp/lsp_features.dart, rename.dart)
                          │
                      LspController ──► LanguageClient, one per server (language_client.dart)
                          │                 └─► LspConnection: JSON-RPC 2.0 (lsp_connection.dart)
                      LspService (services/contracts.dart) ── PigeonLspService (services/lsp/native/)
                          │  Pigeon LspApi: start · send · stop · servers   ▲ LspEvents: received · exited
                      LanguageServerHost (Kotlin, lsp/) ──► LspHost (runtime/) ──► LanguageServers
                          │  the launcher's command mode, stdin open        (installed when first asked for,
                          │  LspFrameReader: Content-Length, whole messages   every file verified)
              ┌───────────┴───────────────┐
   node pyright-langserver       node typescript-language-server ──► node tsserver.js
   (Pyright 1.1.414)             (6.1.0)                              (TypeScript 6.0.3)
```

- **Dart owns the protocol,** as the seed planned: the handshake, capabilities, document versions, cancellation, the restart backoff, the idle stop and, since W7, the watch for a silent server. The state machine is tested against a scripted host on a clock moved by hand (`test/support/scripted_lsp_service.dart`, `fake_lsp_clock.dart`). ADR-0015 says why the client is Dart's and not `@codemirror/lsp-client` in the page.
- **Kotlin is the supervised pipe host:** it installs a server, starts it, frames its bytes, reads its memory, stops it first on low memory, and reports how it ended. Dart never sees a partial frame, and never names a path.
- **The page owns what the user sees:** CodeMirror's completion with the servers as its source, the lint layer, the symbol menu, and the timings the language gate reads.

## 2. The servers, and the gate before them

| Server | Pins | Runs as | Languages | Settings, from a fixed table |
|---|---|---|---|---|
| **Pyright** | 1.1.414 (MIT) | the runtime's node: `node_modules/pyright/langserver.index.js --stdio` | Python | `pythonPath`: the runtime's python; `diagnosticMode`: `openFilesOnly` (through `workspace/configuration`) |
| **typescript-language-server** with **TypeScript** | 6.1.0 and 6.0.3 (Apache-2.0) | the runtime's node: `node_modules/typescript-language-server/lib/cli.mjs --stdio`, which starts the APK's `tsserver.js` | JavaScript, JSX, TypeScript, TSX | one tsserver (`useSyntaxServer: never`), no typings fetched (`disableAutomaticTypingAcquisition`) |

**The gate, as planned:** each server passed a smoke suite (`initialize`, `didOpen`, completion, diagnostics, definition, rename, `shutdown`) under the sealed runtime on API 26 to 36 and on an arm64 phone before its language became *analyzable* in the capability model (`core/editor/capabilities.dart`). A language is analyzable while its server runs. A server that cannot run leaves its language with syntax colours and the document's own words for completion, with the status strip's chip saying why: never a broken editor (spec §6.6).

**Measured in W1** (phase gate 44977463887; ADR-0015 has the tables): both servers passed the suite on API 26, 27, 28, 34 and 36 and on Test Lab's Pixel 8a. On the phone, completion after an edit took 43 to 93 ms at p95, and a server 167 to 255 MB of PSS.

**Shipped since W2** (CI 44994907490; phase gate 44995822826):
- **The archives:** the APK carries each server as an archive with a manifest of every file's SHA-256 (`assets/lsp/`): Pyright 6.06 MB with 5,423 files, the TypeScript server 5.15 MB with 145. `runtime/language_servers.py` builds them reproducibly from `runtime/language-servers/`, whose npm lockfile pins every package with its SHA-512. Native code, links and paths outside a package fail the build.
- **The install:** `LanguageServers` (Kotlin) installs a server into `<runtime root>/codeforge/lsp/<id>` the first time it is asked for, never with the runtime. Every file is verified as it is written, no other file is allowed, and the folder is renamed into place whole. A failure is typed: `not_in_apk`, `damaged` or `storage`.
- **Install times:** Pyright's first install took 0.83 to 2.48 s on the emulators and 3.65 s on the Pixel 8a. Reuse at a later start takes 0 to 5 ms.

## 3. The host (W3)

**Hosted since W3** (phase gate 45029118568): `LspHost` (`runtime/LspHost.kt`) runs a server through the launcher's command mode with stdin open:
- **The process:** its own session and process group, under the sessions' limits (4 GiB file size, 2,048 processes, OOM score 800), with no deadline. `LANGUAGE_SERVER` is a third session kind, so a runtime install ends the servers before it touches the prefix.
- **The environment:** the runtime's (SECURITY E2), plus `NODE_OPTIONS=--max-old-space-size=256`. W4 measured the cap and kept it (ADR-0015).
- **The framing:** `LspFrameReader` (`runtime/LspFraming.kt`) hands over whole messages only, however the server's writes split them. Headers end in CR LF; a message is at most 16 MiB and valid UTF-8. Anything else is a typed error (`bad_header`, `too_large`, `truncated`, `bad_utf8`) and ends the server as `broken`.
- **The threads:** each server has a reader, a stderr reader (the last 64 KiB kept) and a writer. The writer's queue holds 32 MiB; past that a send is refused (`queue_full`), so nothing blocks on a server that has stopped reading.
- **The limits:** at most two servers, one per server id. A second start of the same server is refused as `already_running` with the running one's handle.
- **The workspace:** a project's name or a copy's id, resolved as a terminal's folder is, never a path.
- **The exits:** `exited` with its code, `signaled` with the signal, `stopped`, `memory`, `broken` with the framing's reason, or `lost` with why, each with the stderr tail.
- **Memory:** each server's process tree (PSS, RSS, processes) is read from `/proc` every 10 s. Android's low-memory warnings stop every server first, as `memory`, and only then trim the hidden terminals' buffers.
- **No foreground service:** a server belongs to the engine that started it, and ends with it.

**Dart reaches it** through the Pigeon API `LspApi` (start, send, stop, servers) and `LspEvents` (received, exited) in `pigeons/lsp_api.dart`. Since W4:
- a start names the folder the server works in (absolute, links resolved), the runtime's programs and the server's own folder;
- a send answers once its message is written, with when;
- each message comes with when the host read it, on the monotonic clock both sides share.

## 4. The client (W4, W7)

**Since W4** (CI 45065692542; phase gate 45067383709), Dart's `LanguageClient` (`app/lib/application/lsp/`), one per server, over the `LspService` contract:
- **JSON-RPC 2.0** (`lsp_connection.dart`): numbered requests, each with its timeout (2 s for completion, 10 s otherwise, `initialize` included); `$/cancelRequest` when one runs out or is called off; a late answer is dropped. The server's errors fail the request with their code. Each request's time is split into the host's queue, the server and the delivery, from the host's own timestamps.
- **The session:** `initialize` offers UTF-16 positions only and one workspace folder, the root the host names for a project or a folder's copy. The server's own requests are answered: its settings from the fixed table (§2), its registrations, progress tokens and workspace folders. `workspace/applyEdit` is refused, a document it asks to show is not shown, and anything else gets MethodNotFound. Its log lines reach the app's log, at most 20 a minute, each clipped to 300 characters.
- **Documents:**
  - `didOpen` with the whole text when a document is first shown;
  - then each of the editor's change sets as ranges, last first, computed against the text before it (`core/lsp/text_sync.dart`), with versions growing with the editor's;
  - the whole text only after a resync, or when an edit does not follow what the client holds;
  - `didSave` to a server that asked for it, and `didClose` with the tab;
  - files changed outside the app as `didChangeWatchedFiles`, to the servers whose globs match.

  A request about a document waits until every edit up to the version the page names has gone out, so the server answers about the text on screen.
- **Restarts:** an exit, a crash, a broken message or a failed `initialize` restarts the server after 1 s, 2 s, then 4 s. A fourth end within five minutes gives up; the status strip's chip then offers *Restart*. Requests in flight fail as restarting, and every open document is opened again in the new server. A server stopped to free memory waits for the next document shown.
- **A silent server (since W7, PHASE_6_PLAN §9):** once a server is asked something, its silence is watched. Each message it writes moves the watch on, and an answer that leaves nothing waiting ends it. A request given up still counts, since a server must answer even those. A server silent for 30 s (`LspClientSettings.hangTimeout`) is hung, unless it is reporting progress (a long first analysis, when its requests time out one by one). A hung server is ended through the host and restarted as a crash is, counted against the backoff.
- **The idle stop:** ten minutes with no open document send `shutdown` and `exit`, and the host's stop follows 2 s later if the server has not ended.
- **Status:** off, starting, ready, analysing (while the server reports progress) or restarting, with the reason, on the status strip's chip.

**In the app** (`lsp_controller.dart`), servers run in the open workspace once the runtime is ready, for the languages turned on in Settings → Editor. A folder from shared storage is analysed through its copy (ADR-0013), brought up to date before any server starts and after each save, each change from outside the app and each file a rename writes. The integration tests turn the servers off (`languageServersEnabledProvider`), so the phase gate's other groups measure what they did; the `lsp` group and `phone_lsp_test` turn them on.

## 5. In the editor (W5, W6)

**Since W5** (CI 45131313756; phase gate 45135282059, its `lsp` group), the page asks and the host answers through the servers (EDITOR_ARCHITECTURE §2 has the messages):
- **Completion** is CodeMirror's, with the server as its source, as a name is typed and after the server's trigger characters. The host asks within 2 s, filters the list by the typed word, trims it to the 200 best in the server's order, and marks it incomplete when trimmed. Snippets become plain text. Documentation is fetched when an item is selected (within 3 s). While no server can answer, the document's own words stand in.
- **Diagnostics** are underlined through `@codemirror/lint` 6.9.8, mapped through the edits made since their version (a set the page can no longer map is refused as `stale`), and listed in the status strip's problems chip and the *Problems* sheet. They go with the server that found them, and are sent again after the page restarts. At most 1,000 per document.
- **The symbol menu:** a long press shows the diagnostics there, the hover text (within 3 s) with code in the editor's font, *Go to definition* and *Rename…*. F12, F2 and F8 do as the menu does. No server text reaches the DOM as HTML: Markdown is drawn node by node with `textContent`.
- **Definition** (within 10 s) opens the file at the place. A place in the server's own files (Pyright's stubs, TypeScript's `lib.d.ts`, a package in the runtime) opens read-only in a sheet, read only under the server's folder or the runtime's programs, 8 MiB at most.
- **Rename** checks the place first (`prepareRename`, within 10 s), asks for the new name, and applies the server's edit all or nothing (within 15 s). Every file's new text is worked out first. Closed files are written only if they are still as read. Then the open documents change together, one undo step each, and a failure gives the files already written their old text back. An edit that would create, rename or delete files is refused.

**Measured since W6** (CI 45180564110; phase gate 45182761593): the page times each completion list from its request to the frame that draws it (`timings.ts`), and the host reads the times with `probe.read`. The language gate's phone test (`integration_test/phone_lsp_test.dart`) judges the budgets with them (§6).

## 6. Document sync and performance

- **Sync:** the page batches the editor's change sets for about 150 ms, and flushes them on blur, on a save, on a tab switch and before any language request. Dart sends each batch as incremental `didChange` ranges. There is no other debounce.
- **Lifecycle:** one server per server id in the open workspace, at most two at once. The idle stop after 10 minutes and the restart backoff are §4's. Memory is read every 10 s, shown in Settings → Linux runtime with each server's packages, state and *Restart*.
- **Budgets** (PERFORMANCE §2): completion p95 ≤ 300 ms warm; diagnostics ≤ 1 s after a save, judged at p95; each server's process tree ≤ 300 MB of PSS on the gate's 200-file project (the owner's decision of 2026-11-22). The app's own budgets stay, and the total is recorded.
- **Judged in W6** on Test Lab's Pixel 8a (phase gate 45182761593), in the real app on the 200-file projects:
  - completion p95 139.0 ms (Pyright) and 64.5 ms (TypeScript), from the page's request to the list drawn;
  - diagnostics p95 476.9 and 657.7 ms after a save;
  - PSS 169.9 and 246.5 MB.

  The app and its renderer held 511.4 MB, 927.7 MB with both servers. With a terminal open too, the exit gate (45225412011) measured 917.0 MB (PHASE_6_REPORT §7.1).

## 7. Security

SECURITY §2.3 reviews the boundary (L1 to L12). In short:
- **Where and with what:** a server works only in the workspace the host resolves (a project, or a copy, never a path from Dart), with the runtime's environment and no credentials.
- **What it is told:** its settings come from the fixed table (§2), not from anything the user typed.
- **What it can send back:** whole messages only, to Dart. They reach the page only as checked results.
- **What it can change:** nothing by itself (`workspace/applyEdit` is refused). A rename it computes is checked and applied by the host.
- **The network:** none is needed. TypeScript fetches no typings, and the servers ship in the APK, so nothing is downloaded at run time.

## 8. Not built in Phase 6

- **Features:** signature help, code actions, formatting, references, semantic tokens, inlay hints and workspace-wide diagnostics. Pyright analyses open files only (`openFilesOnly`).
- **Servers** (ROADMAP's queue):
  - JSON, HTML and CSS (vscode-langservers-extracted), YAML and shell;
  - TypeScript 7's native server, which needs its Linux arm64 binary among the APK's programs;
  - basedpyright, Pyright's fallback, unmeasured;
  - clangd, with the build-tools pack.
