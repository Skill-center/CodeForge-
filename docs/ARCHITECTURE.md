# CodeForge Architecture

**Status:** Accepted for Phase 1 · Decisions recorded in [adr/](adr/) · Audit basis: [EXISTING_RUNTIME_AUDIT.md](EXISTING_RUNTIME_AUDIT.md)

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

The host is a **thin orchestration layer**: it contains no provisioning logic of its own — that lives in the vendored, JVM-tested modules. `harness-core`'s rule carries over: *UI never contains provisioning logic; provisioning never contains UI.*

## 4. Data architecture

| Data | Store | Introduced | Notes |
|---|---|---|---|
| App settings (theme, font, keymap) | shared_preferences | Phase 1 | typed wrapper, schema version key |
| Workspace registry, tabs, layout, sessions | **Drift (SQLite)** | Phase 2 | versioned schema, migrations tested; one DB per app, workspace-scoped rows |
| Editor buffers (crash-safe) | app-private files + Drift metadata | Phase 2 | write-ahead journaling of dirty buffers |
| Runtime state (installed payload manifest, markers) | files in runtime root (t1 layout) | Phase 4 | dpkg/manifest is source of truth, mirrored into RuntimeService |
| Credentials (Git tokens, SSH keys) | Android Keystore-backed encrypted store | Phase 7 | never in plain prefs, never logged |
| Extension manifests/permissions | Drift + files | Phase 8 | signed manifest hash, explicit grants |

Backward compatibility rule (spec §12.19): every schema change ships a migration + a migration test; workspace data written by version N must open in N+1.

## 5. Adaptive workbench model

One `WorkbenchLayout` value drives everything; breakpoints: **compact < 600 dp**, **medium 600–840 dp**, **expanded > 840 dp**.

| Form factor | Layout |
|---|---|
| Phone portrait (compact) | Editor-first. Bottom activity bar (5 destinations + overflow). Explorer as full-height sheet. Terminal as bottom sheet (peek → half → full). Floating symbol toolbar above IME. |
| Phone landscape (compact height) | Icon rail left, editor center, terminal collapsible bottom panel, tab strip scrolls. |
| Tablet (medium/expanded) | Persistent explorer sidebar, editor group center, integrated terminal panel, resizable dividers; optional minimap; multi-editor groups from Phase 9. |

Layout state (panel sizes, active activity, sheet positions) is part of workspace state restoration. Hardware keyboard presence collapses the symbol toolbar and enables desktop-style shortcuts.

## 6. Threading & lifecycle

- Flutter UI: main isolate. Heavy pure-Dart work (search indexing of small trees, diffing) in isolates; **all process I/O in Kotlin** (bounded thread pools), streamed to Dart via EventChannels with backpressure (coalesced chunks, max event rate).
- Runtime child processes owned by `SessionRegistry`; foreground-service notification while sessions run (Phase 4+); all children killed on workspace close/app task removal unless user opts into persistence; no orphaned processes (process-group kill, verified by tests).
- WebViews: created lazily, one editor WebView reused across tabs (CM6 states swapped), destroyed on background memory pressure with state persisted first.

## 7. What Phase 1 builds vs. later

Phase 1 ships the **entire UI skeleton with fake services** — every screen navigable, every layout adaptive, theme system real, zero native runtime. Service interfaces are defined in Phase 1 so Phases 2–7 swap fakes for real implementations without touching presentation code. This is the dependency-inversion payoff: the risky native work proceeds in parallel with zero UI churn.
