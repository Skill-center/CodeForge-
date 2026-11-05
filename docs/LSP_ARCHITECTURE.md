# LSP Architecture

**Status:** Phase 0 design seed · Implementation Phase 6 · Full spec finalized at Phase 6 start

---

## 1. Topology

LSP servers run as **child processes of the sealed runtime** (Node 26 / Python), never in WebViews, never in the Flutter isolate:

```
CM6 (WebView) ──bridge──► EditorService (Dart) ──► LspService (Dart client)
                                                        │ Pigeon + EventChannel
                                                 Kotlin LspHost
                                                        │ stdio pipes (JSON-RPC 2.0)
                                          ┌─────────────┼─────────────┐
                                     pyright-langserver  typescript-   clangd (pack,
                                     (sealed node)       language-server  Phase 9+)
                                                         (sealed node)
```

- **Dart owns the LSP client state machine** (initialize handshake, capability negotiation, document version sync, request cancellation, restart policy). Kotlin is a dumb-but-supervised pipe host: spawn, env, cwd, stdio framing, exit events. This keeps the protocol logic unit-testable on the host JVM-free (fake transport).
- JSON-RPC framing (`Content-Length`) parsed in Kotlin (bytes) → complete messages to Dart; Dart never sees partial frames.

## 2. Server candidates & compatibility gate (first task of Phase 6)

| Server | Runs on | Risk | Fallback |
|---|---|---|---|
| **Pyright** | sealed Node 26 | npm install must be pure-JS (it is); memory on low-RAM devices | Python: syntax-only + jedi-based lightweight completion (spike) |
| **typescript-language-server** + tsserver | sealed Node 26 | TS 7 native-port era: pin TS 5.9.x server line until verified | JS/TS: CM6 built-in hinting only |
| JSON / HTML / CSS language servers | sealed Node 26 | low | CM6 linting basics |
| clangd | build-tools pack | only when pack installed; ARM64 binary from Termux | diagnostics off, editor still works |

**Gate:** each server must pass a smoke suite (initialize → didOpen → completion → diagnostics → shutdown) on an arm64 device under the sealed runtime before its language flips `analyzable: true` in the capability model. Failure = graceful syntax-only mode with a visible status chip, never a broken editor (spec §6.6).

## 3. Document sync & performance

- Incremental `didChange` (CM6 change sets → LSP ranges) with version numbers; debounce 200 ms; diagnostics pushed to editor gutter + Problems panel (Phase 9).
- One server per language per workspace; idle shutdown after 10 min unused; restart-on-crash with backoff (max 3, then offer manual restart); memory cap monitored via runtime tools.
- Budgets: completion p95 ≤ 300 ms warm; diagnostics ≤ 1 s after save; server RSS tracked in PERF suite.

## 4. Security

Servers get workspace-scoped cwd/env, no credentials; `workspace/configuration` responses sanitized; server stderr logged (bounded); no network access required by servers (offline-first) — extension downloads happen only at install time via the runtime's package rules (SECURITY.md §2).
