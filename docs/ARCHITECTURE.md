# CodeForge Architecture

**Status:** Accepted for Phase 1 · as built through Phase 2 in §2.4–§2.7 · Decisions recorded in [adr/](adr/) · Audit basis: [EXISTING_RUNTIME_AUDIT.md](EXISTING_RUNTIME_AUDIT.md)

---

## 1. System overview

CodeForge is a **Flutter application with a Kotlin/Java Android host** that embeds the audited t1 sealed runtime. Five concentric layers, strict dependency direction (outer → inner, never reverse):

```
┌────────────────────────────────────────────────────────────────┐
│ FLUTTER UI (Dart)                                              │
│  design_system/   workbench shell   feature screens            │
│  (widgets only — no business logic, no platform calls)         │
├────────────────────────────────────────────────────────────────┤
│ APPLICATION CORE (Dart)                                        │
│  Riverpod controllers · GoRouter · command registry            │
│  workspace state · settings · error handling · logging         │
├────────────────────────────────────────────────────────────────┤
│ SERVICE LAYER (Dart interfaces + fake/native implementations)  │
│  FileService · EditorBridge · TerminalService · RuntimeService │
│  GitService · LspService · SearchService · ExtensionService    │
├────────────────────────────────────────────────────────────────┤
│ PLATFORM BOUNDARY                                              │
│  Pigeon (request/response, typed) · EventChannel (streams)     │
│  WebView JS bridge (editor/terminal frontend, validated)       │
├────────────────────────────────────────────────────────────────┤
│ ANDROID HOST (Kotlin) + VENDORED RUNTIME (Java/C)              │
│  RuntimeHost · SessionRegistry · StorageBroker · WebView host  │
│  sealed-runtime · harness-core (subset) · PTY JNI · preload    │
│  sealed userland: node 26 · python · git · bash · perl · ruby  │
└────────────────────────────────────────────────────────────────┘
```

### 1.1 Process & component model

- **One Android app process** hosts: the Flutter engine, Kotlin host services, and child Linux processes (shell, node, python, git, LSP servers) spawned via the PTY/exec layer. Child processes are **not sandboxed from the app** — same UID. We say so plainly (SECURITY.md); isolation claims are limited to what Android actually provides (app sandbox vs. the rest of the OS, SAF consent for shared storage, WebView renderer isolation).
- **WebViews are renderers, not authorities.** The editor WebView (CodeMirror 6) and optionally a terminal WebView (xterm.js fallback) load only bundled local assets via `WebViewAssetLoader` (`https://appassets.androidplatform.net/`), with a strict CSP, no network, no file access, and a single validated message bridge. All filesystem/process power lives in Kotlin/Dart services; the bridge enforces an allowlist of operations scoped to the open workspace.
- **LSP servers and tools run as runtime child processes** (node/python from the sealed userland), supervised by the Kotlin host, spoken to over stdio JSON-RPC piped through the platform boundary. Never inside a WebView.

### 1.2 Communication contracts

| Channel | Mechanism | Payload | Direction |
|---|---|---|---|
| Dart ↔ Kotlin commands | **Pigeon** generated typed APIs (v29.x) | request/response, versioned schema | both |
| Kotlin → Dart events | **EventChannel** | runtime state, process output, file-change events, diagnostics | push |
| Dart ↔ editor WebView | `webview_flutter` JS bridge + `postMessage` | incremental document deltas (CM6 change sets), never whole-file-per-keystroke | both |
| Kotlin ↔ Linux processes | PTY (JNI) / `ProcessBuilder` + pipes | bytes / JSON-RPC (LSP) | both |
| Dart ↔ JS schema | shared JSON schema in `packages/bridge_protocol/` (Dart) + `editor/src/protocol/` (TS), contract-tested both sides | one source of truth for message shapes | — |

Rules: every bridge message carries `protocolVersion`, `requestId`, `type`; unknown types/versions are rejected and logged, never silently ignored. Bridge handlers validate paths against workspace roots (canonicalized, symlink-aware) before any I/O.

## 2. Flutter application structure (feature-first Clean Architecture)

```
app/lib/
├── main.dart                    # bootstrap only: error zone, ProviderScope, runApp
├── bootstrap/                   # startup sequence, lifecycle observers, DI wiring
├── design_system/               # tokens, themes, typography, spacing, components
│   ├── tokens/                  # color/spacing/radius/motion/elevation constants
│   ├── theme/                   # ThemeData builders (dark primary, light)
│   └── components/              # CfButton, CfNavBar, CfPanel, CfListItem, CfSheet…
├── core/
│   ├── errors/                  # Failure taxonomy, Result<T>, error reporting
│   ├── logging/                 # structured logger, ring buffer, redaction
│   ├── utils/                   # pure helpers
│   └── platform/                # PlatformInfo, breakpoints, keyboard detection
├── services/                    # abstract interfaces + impls (one dir per service)
│   ├── files/  editor/  terminal/  runtime/  git/  lsp/  search/  settings/
│   └── …/fake/                  # in-memory fakes for tests & pre-integration phases
├── features/                    # one dir per feature, same internal shape
│   ├── home/  workbench/  explorer/  editor/  terminal/  search/
│   ├── source_control/  extensions/  run_debug/  settings/
│   └── <feature>/
│       ├── presentation/        # screens, widgets (consume controllers only)
│       ├── application/         # Riverpod controllers/notifiers, feature state
│       └── domain/              # entities, value objects (pure Dart)
└── routing/                     # GoRouter config, guards, deep links, shell routes
```

**Dependency rules** (enforced by review + CI import lint):
1. `presentation` never imports services directly — only `application` providers.
2. `application` depends on service **interfaces**, never Kotlin/Pigeon types.
3. `services/*/native` is the only place Pigeon/EventChannel types appear.
4. `design_system` imports nothing from features; features import design_system.
5. `domain` is pure Dart (no Flutter imports) — unit-testable on the host.

### 2.1 State management (Riverpod 3.x)

- Controllers are `Notifier`/`AsyncNotifier` with immutable state (`freezed`-style sealed classes; we start with hand-written immutables + `copyWith` to keep codegen surface small, revisit if boilerplate grows).
- Scoping: app-level (settings, runtime status), workspace-level (open project, tabs, layout), session-level (terminal sessions, LSP connections) via provider families and `autoDispose`.
- No `StatefulWidget` business logic; widgets watch providers and dispatch intents.

### 2.2 Navigation (GoRouter 18.x)

- Shell route for the workbench (adaptive scaffold owns activity destinations: Explorer / Search / Source Control / Extensions / Run & Debug / Settings).
- Routes: `/` (home/project picker), `/workspace` (workbench shell), `/settings/*`, `/onboarding` (first-run runtime status, Phase 4+).
- State restoration: current workspace + active activity + open tabs persisted (Phase 2+ via Drift); URL strategy keeps deep links testable.

### 2.3 Error handling & logging

- `Result<T>` / typed `Failure` hierarchy (`StorageFailure`, `RuntimeFailure`, `BridgeFailure`, `ProcessFailure`, …) mirrors t1's typed provisioning errors — never bare exit codes across the boundary.
- Central error zone in `bootstrap/`; UI shows actionable messages with a "details" sheet (log excerpt), pattern proven in t1's provisioning UI.
- Structured logs (level, tag, event, fields) to a bounded on-disk ring buffer; secrets (tokens, keys) redacted at the logger, not at call sites.

### 2.4 As built in Phase 1 (deltas from the plan in this document)

- **Layout of `lib/`:** app-level Riverpod controllers and the GoRouter configuration live in `lib/application/` (one shared layer) instead of per-feature `application/` folders plus a top-level `routing/`; features (`home`, `workbench` + `panels`, `palette`, `settings`) are flat `presentation`-only folders. Splitting a feature into presentation/application/domain happens when it gains real domain logic. The editor (Phase 2 W2) did not need a split folder, because its parts map onto the existing layers: the protocol mirror and document model in `core/editor/` (pure Dart), the WebView surface and page verification in `services/editor/`, the editor host in `application/editor/`, and the widgets in `features/workbench/panels/`. The import lint already enforces those boundaries. The W3 engine benchmark follows the same split: the benchmark pages and their WebView in `services/editor/bench/`, the frame timing recorder in `services/perf/`, the runner in `application/bench/`, and the developer screens in `features/settings/developer/`. The CI import lint (`tool/lint_imports.dart`) enforces what exists today: `design_system` and `services` never depend upward (on features, application or each other), `core` stays pure Dart, and a feature reaches another feature only through the workbench (the panel composition root) or the shared palette. **Gap vs. rule 1:** Phase 1 features still import service-layer value types (`settings_model`, `shell_state`, `contracts`), and home, the workbench and the explorer call the `FileService` provider (`application/providers.dart`, backed by the in-memory fake) directly rather than through a controller. Routing that access through application controllers, and adding the rule to the lint, is a Phase 2 task, done before real file I/O replaces the fake. **Done in W4** for file access (§2.5); the value-type imports remain.
- **Routes:** `/`, `/workspace`, `/settings`, `/settings/appearance`, `/settings/about` (and `/settings/gallery` in debug builds; `/settings/editor-benchmark`, `/settings/frame-timing` and, since Phase 3 W6, `/settings/logs` in debug and profile builds). The workbench is a plain route whose activities (Explorer, Search, …) are in-page panels, not a `StatefulShellRoute` — nothing behind them is navigable yet. Top-level destinations are reached with `go()`; on `/workspace` and `/settings` a `PopScope` turns system/predictive back into "go home" (matching their back arrows), home lets back leave the app, and unknown locations land on home (`onException`). Covered by `test/widget/navigation_test.dart`.
- **Persistence (Phase 1):** two versioned `shared_preferences` envelopes — `codeforge.settings.v1` (write-through) and `codeforge.shell.v1` (last restorable route, activity, terminal stop, panel sizes; 400 ms debounce, flushed on pause and dispose) — decoded tolerantly (corrupt or future payloads fall back to defaults per field). Open tabs are intentionally not persisted until the editor exists (Phase 2, Drift).
- **Renderer:** Impeller, Flutter's default, since Phase 3 W6; Skia (Impeller disabled in the manifest) in Phases 1–2 — see TECH_STACK.md §1.
- **Errors & logging:** `Result<T>` (`Ok`/`Err`) and the sealed `Failure` family (`StorageFailure`, `BridgeFailure`, `RuntimeFailure`, `ProcessFailure`, `UnexpectedFailure`) as planned; the error zone is `lib/bootstrap.dart` (`runZonedGuarded`, `FlutterError.onError`, `PlatformDispatcher.onError`). The logger keeps a bounded **in-memory** ring buffer (500 records) with redaction at the logger and an injectable sink (debug console). The on-disk sink and the user-facing "details" sheet arrive with the storage layer in Phase 2.
- **Workbench panels (phone):** the explorer is a draggable sheet as planned, but the terminal is a fixed-stop panel above the status strip, not yet the draggable bottom sheet of §5. The top bar toggles it closed ↔ half and its header closes it. Peek and full are laid out and overflow-tested but have no control until the real terminal arrives (Phase 5).
- **Soft keyboard:** the workbench sizes its terminal from the height the Scaffold actually leaves the body, never from the screen. While the IME is up, `MediaQuery.viewInsets` reads 0 inside the body, and screen-based sizing squeezed the editor until it overflowed (found by phase gate 42110297015). The terminal yields first and hides below 60 dp; the editor pane, nav rail and command palette never overflow (`test/widget/keyboard_insets_test.dart`). The floating symbol toolbar above the IME (§5) arrives with the editor in Phase 2.

### 2.5 As built in Phase 2 W4 (files, documents, tabs)

- **`FileService` contract** (`lib/services/contracts.dart`): `openWorkspace`, `listDirectory`, `readText` → `TextFile` (text with `\n` breaks, its `TextFormat` (line ending and BOM), a `FileStamp` (modified time and size), and whether line endings were mixed), and `writeText(path, text, format:, mode: replace | createNew, expected: stamp)` → the new stamp. Failures are a `FileFailure` carrying a `FileProblem`. Paths are workspace-relative strings checked by `core/files/workspace_path.dart`. Details: EDITOR_ARCHITECTURE.md §6.
- **On `dart:io`, not a Kotlin broker.** For an app-private folder, Dart's own file API is direct, needs no channel call per operation, and is tested on a real temporary folder by plain `flutter test`. Kotlin supplies only the folder: MainActivity answers `filesDir` on the `dev.codeforge/paths` MethodChannel (`lib/services/platform/app_directories.dart`). A single method does not justify Pigeon yet. The Kotlin `StorageBroker` of §3 arrives with SAF folders in Phase 3, whose `content://` documents `dart:io` cannot open, behind the same contract.
- **Controllers:** `WorkspaceController` (the open workspace and explorer listings, refreshed after writes), `DocumentController` (documents and tabs; EDITOR_ARCHITECTURE.md §6) and `workbenchIntentsProvider` (palette commands and shortcuts from Flutter or the editor page, carried out by the workbench screen, which can show dialogs). No feature reads `fileServiceProvider`; `tool/lint_imports.dart` fails the build if one does. Features still import service value types (`FileEntry`, `WorkspaceRef`, the settings and shell models).
- **Persistence:** open tabs and the active tab joined the `codeforge.shell.v1` envelope; restored paths are re-validated. **Migration:** none needed, so the schema version stays 1. Envelopes written before W4 decode with no tabs (the workbench then opens `main.js`), and earlier builds ignore the new fields. Drift (ADR-0008) takes tabs over in W5, together with the journal of unsaved text.
- **Fakes:** the app no longer ships an in-memory file service; widget tests use `test/support/memory_file_service.dart`, which applies the production path rules and codec.

### 2.6 As built in Phase 2 W5 (zero-loss persistence)

- **`SessionStore` contract** (`lib/services/storage/session_store.dart`): `touchWorkspace`, `loadTabs` / `saveTabs` (order, active tab, selection, scroll), `loadJournal`, `writeSnapshot(snapshot, restart:)`, `appendChange`, `discardJournal`. Every call returns a `Result`. `DriftSessionStore` implements it over the Drift database (`app_database.dart`, schema v1: `workspaces`, `open_tabs`, `journal_documents`, `journal_changes`). `MemorySessionStore` stands in for it in tests.
- **Opening the database.** `sessionStoreProvider` opens `<filesDir>/codeforge.sqlite` lazily, on its first use, in a background isolate (`NativeDatabase.createInBackground`). The folder comes from the same `dev.codeforge/paths` channel as the workspace. WAL mode and `synchronous = NORMAL` are set when it opens. A failure to open or write becomes a logged `StorageFailure`, and the editor shows it as a banner ("Unsaved changes are not being backed up, so a crash would lose them. Save your files to keep them safe."); it never crashes the app. SQLite comes from the `sqlite3` package's build hook (a prebuilt, hash-checked library per ABI), so there is no `sqlite3_flutter_libs` and no NDK build.
- **The hot-exit journal** (`lib/application/documents/document_journal.dart`), owned by `DocumentController`, writes what EDITOR_ARCHITECTURE.md §7 describes. All writes go through one queue, in the order they were asked for. Each snapshot replaces the document's stored changes in one transaction.
- **Lifecycle.** Unsaved text reaches the database as it is typed, so nothing waits for a lifecycle event. On pause, `app.dart` still runs `DocumentController.checkpoint()` (flush the page, snapshot every journal with new changes, save tabs), but only if the controller exists. A renderer crash is a process death: webview_flutter_android 4.14.1 does not expose `onRenderProcessGone`, so Android ends the app with its renderer, and the next start restores from the journal. Rotation keeps the process (the manifest handles orientation changes) and the editor page: the workbench moves its editor pane between the portrait and docked layouts under one `GlobalKey`, so the page does not reload. The journal is not involved.
- **Codegen.** drift_dev 2.35.2 and build_runner 2.17.1 are dev dependencies. CI generates their output (ADR-0008 amendment), so the authoring sandbox, which has no Dart SDK, never needs it.
- **Migration notes (stored data).**
  - *Tabs leave the shell envelope.* W4 stored open tabs and the active tab in `codeforge.shell.v1`. On the first W5 start, when the database has no tabs for the workspace, the envelope's tabs are imported once and the envelope's tab fields are cleared. The envelope's schema version stays 1: the fields remain, empty, so a W4 build reading the envelope finds no tabs and opens `main.js`. W4 envelope tabs carry no selection or scroll, so they import with the cursor at the start.
  - *The database is new.* Schema v1 is the first version and no older database exists, so there is no migration yet. ADR-0008's amendment gives the rule for every later version.

### 2.7 As built in Phase 2 W6–W7 (keyboards, find, large files, dialogs)

- **Keyboards** (`lib/application/keyboard_state.dart`):
  - `softKeyboardVisibleProvider` reads the window's bottom inset, which a Scaffold body cannot read itself.
  - `hardwareKeyboardProvider` follows a `HardwareKeyboardSource`. On Android that is `MainActivity` reporting its configuration over the `dev.codeforge/keyboard` MethodChannel (`lib/services/platform/hardware_keyboard.dart`); tests replace it.
  - The symbol toolbar reads both (§5).
- **Find and replace** (`lib/application/editor/find_controller.dart`) drives the page's single search session over protocol v1 (`search.set`, `search.state`) and follows the active tab (EDITOR_ARCHITECTURE.md §8).
- **Large files** (EDITOR_ARCHITECTURE.md §10):
  - The policy is pure Dart in `lib/core/editor/large_files.dart` (`plainTextAboveChars`, `opensAsPlainText`).
  - The refusal size, `maxTextFileBytes` (10 MiB), lives with the codec (`lib/core/files/text_codec.dart`). `LocalFileService` checks it with `stat` before reading.
  - `DocumentController` decides between plain and highlighted text at open, at restore and on Save As, never while typing. The editor pane shows the banner.
- **Dialogs** (`lib/design_system/components/dialogs.dart`):
  - `CfAlertDialog` is the design system's alert dialog, and the app's six alert dialogs use it. It scrolls its title and content above pinned actions, and tightens its margins when the keyboard leaves less than 480 dp.
  - The command palette stays a plain `Dialog`.
  - Text fields are not dense, so Material keeps them at least 48 dp tall.

## 3. Android host structure

```
app/android/
├── app/src/main/kotlin/dev/codeforge/host/
│   ├── MainActivity.kt          # FlutterActivity + channel registration only
│   ├── RuntimeHost.kt           # owns SealedInstaller lifecycle, ExecAudit at startup
│   ├── SessionRegistry.kt       # PTY/process sessions, lifecycle, termination
│   ├── StorageBroker.kt         # SAF + app-private paths, workspace scoping
│   ├── WebViewHost.kt           # asset loader, CSP, bridge validation
│   └── channels/                # Pigeon impls, EventChannel producers
├── (Phase 4) vendored modules under native/:
│   sealed-runtime/  harness-core/ (subset)  terminal-emulator/  [terminal-view/]
└── pack_buildtools/             # Play Feature Delivery module (Phase 4/10)
```

As built (Phase 2): the package is `dev.codeforge.app`, and `MainActivity.kt` registers one channel, `dev.codeforge/paths` (§2.5). The other files above arrive with their phases.

The host is a **thin orchestration layer**: it contains no provisioning logic of its own — that lives in the vendored, JVM-tested modules. `harness-core`'s rule carries over: *UI never contains provisioning logic; provisioning never contains UI.*

## 4. Data architecture

| Data | Store | Introduced | Notes |
|---|---|---|---|
| App settings (theme, font, keymap) | shared_preferences | Phase 1 | typed wrapper, schema version key |
| Workspace registry, tabs, layout, sessions | **Drift (SQLite)** | Phase 2 | versioned schema, migrations tested; one DB per app, workspace-scoped rows |
| Editor buffers (crash-safe) | **Drift (SQLite)**: a snapshot and an append-only change log per unsaved document | Phase 2 (W5) | hot-exit journal; ADR-0008 amendment, EDITOR_ARCHITECTURE.md §7 |
| Runtime state (installed payload manifest, markers) | files in runtime root (t1 layout) | Phase 4 | dpkg/manifest is source of truth, mirrored into RuntimeService |
| Credentials (Git tokens, SSH keys) | Android Keystore-backed encrypted store | Phase 7 | never in plain prefs, never logged |
| Extension manifests/permissions | Drift + files | Phase 8 | signed manifest hash, explicit grants |

As built (W4): workspace files live in `<filesDir>/workspaces/demo`. As built (W5): open tabs, the active tab, each tab's cursor and scroll, and the journal of unsaved text live in `<filesDir>/codeforge.sqlite` (schema v1, §2.6). The shell envelope keeps the route, layout and terminal state. Since Phase 3: projects live in `<filesDir>/workspaces/<name>`, one folder each, and folders from shared storage are reached through the storage broker (W2, SECURITY §4.1). Schema v2 (W3, ADR-0008) adds each workspace's kind and place, which Home's recents show, and each workspace's explorer view. The shell envelope also names the open workspace.

Backward compatibility rule (spec §12.19): every schema change ships a migration + a migration test; workspace data written by version N must open in N+1.

## 5. Adaptive workbench model

One `WorkbenchLayout` value drives everything; breakpoints: **compact < 600 dp**, **medium 600–840 dp**, **expanded > 840 dp**.

| Form factor | Layout |
|---|---|
| Phone portrait (compact) | Editor-first. Bottom activity bar (5 destinations + overflow). Explorer as full-height sheet. Terminal as bottom sheet (peek → half → full). Floating symbol toolbar above IME. |
| Phone landscape (compact height) | Icon rail left, editor center, terminal collapsible bottom panel, tab strip scrolls. |
| Tablet (medium/expanded) | Persistent explorer sidebar, editor group center, integrated terminal panel, resizable dividers; optional minimap; multi-editor groups from Phase 9. |

Layout state (panel sizes, active activity, sheet positions) is part of workspace state restoration. A hardware keyboard puts the symbol toolbar away while the soft keyboard is down; if the soft keyboard comes up beside it, the toolbar comes back with it (W6). Desktop-style shortcuts work while the editor has the focus.

## 6. Threading & lifecycle

- Flutter UI: main isolate. Heavy pure-Dart work (search indexing of small trees, diffing) in isolates; **all process I/O in Kotlin** (bounded thread pools), streamed to Dart via EventChannels with backpressure (coalesced chunks, max event rate).
- Runtime child processes owned by `SessionRegistry`; foreground-service notification while sessions run (Phase 4+); all children killed on workspace close/app task removal unless user opts into persistence; no orphaned processes (process-group kill, verified by tests).
- WebViews: created lazily, one editor WebView reused across tabs (CM6 states swapped), destroyed on background memory pressure with state persisted first. *As built in Phase 2: one editor WebView, reused across tabs. It is not destroyed under memory pressure. If Android kills its renderer, the app process ends with it (webview_flutter_android 4.14.1 has no `onRenderProcessGone`), and the journal restores unsaved text on the next start (§2.6).*

## 7. What Phase 1 builds vs. later

Phase 1 ships the **entire UI skeleton with fake services** — every screen navigable, every layout adaptive, theme system real, zero native runtime. Service interfaces are defined in Phase 1 so Phases 2–7 swap fakes for real implementations without touching presentation code. This is the dependency-inversion payoff: the risky native work proceeds in parallel with zero UI churn.

**Phase 2** swapped in the first real implementations:
- the `dart:io` `FileService` (§2.5);
- the WebView `EditorSurface`, with CodeMirror 6 behind protocol v1 (EDITOR_ARCHITECTURE.md);
- the Drift session store with the hot-exit journal (§2.6).

The workbench's demo code view gave way to the real editor pane. Features still reach files only through controllers, and the import lint enforces it. The exit report is [PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md).
