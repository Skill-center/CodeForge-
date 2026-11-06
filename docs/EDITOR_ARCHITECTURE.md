# Editor Architecture

**Status:** Design proposed; engine choice gated by device benchmark (ADR-0004) · Implementation Phase 2

---

## 1. Engine decision: CodeMirror 6 primary, Monaco challenged

Spec §3 requires evaluating Monaco first, then choosing on **actual Android device testing**. Desk evaluation (2026-11-05):

| Criterion | Monaco 0.57.0 | CodeMirror 6.43.x |
|---|---|---|
| Mobile browser support | **Upstream README: not supported** (mobile browsers/mobile web frameworks) | Built around native selection/editing; mobile + IME a design goal |
| Bundle (core+1 language) | multi-MB; full published build ~24 MB pre-shake | ~400 KB min / ~135 KB gz; minimal ~75 KB gz |
| Touch/IME architecture | custom hidden textarea hacks tuned for desktop | contentEditable/native-selection based; Android IME behaves like a text field |
| Workers | language services need worker plumbing in WebView | Lezer parsers run in-process, incremental |
| VS Code feature parity | closest (it IS the VS Code editor) | needs assembly: completion/hover/diagnostics wired to our LSP client |
| Accessibility | paging screen-reader mode | first-class a11y goal |
| License | MIT | MIT |

Sources: Monaco README/upstream docs; 2026 comparisons ([pistack](https://www.pistack.xyz/posts/2026-08-22-browser-code-editors-monaco-codemirror-ace-comparison/), [portalzine](https://portalzine.de/javascript-code-editors-that-transform-textareas-a-comprehensive-comparison/)). Desk verdict: **CM6 is the only credible mobile-first candidate**; Monaco's mobile-unsupported status is disqualifying unless the device gate surprises us.

### The gate (Phase 2, before editor workstream 2)

Both engines built with identical scope (JS/TS/Python/JSON/HTML/CSS highlighting, completion UI stub, find/replace). Measured on a mid-range arm64 device + low-memory device:

| Metric | Budget (pass/fail) |
|---|---|
| Cold bundle load → first paint | ≤ 800 ms mid-range |
| Keystroke → glyph latency (p95, 60 keys) | ≤ 32 ms |
| IME correctness suite (Gboard: composing, autocorrect, swipe, CJK, emoji) | 0 corruption/lost-char events |
| 1 MB file open + scroll | no OOM; scroll jank < 5% frames > 32 ms |
| WebView RSS after 10 min editing | ≤ 250 MB |
| Bundle size (gz, shipped) | ≤ 1.5 MB |
| Selection handles, copy/paste, undo/redo | all pass manual matrix |

CM6 must pass all; Monaco is given the same suite for the record. Result + raw numbers recorded in `docs/phases/PHASE_2_REPORT.md`; ADR-0004 flips to Accepted with the winner. **If CM6 fails the IME suite, we stop and reassess (custom Flutter editor fallback study) rather than ship a corrupting editor.**

## 2. Integration topology

```
Flutter (Dart)                      WebView (bundled assets only)
┌──────────────────────┐   JS bridge ┌─────────────────────────────┐
│ EditorService        │◄───────────►│ protocol.ts (validated)     │
│  tab/document model  │  messages   │ CM6 EditorState per doc     │
│  dirty state, saves  │             │ one EditorView, swapped     │
│  undo persistence    │             │ mobile extensions:          │
│  LSP routing (Ph. 6) │             │  symbol toolbar hooks,      │
└──────────┬───────────┘             │  indent/fold/brackets,      │
           │ Pigeon                  │  search panel, completions  │
┌──────────▼───────────┐             └─────────────────────────────┘
│ Kotlin StorageBroker │  file I/O (workspace-scoped, validated)
└──────────────────────┘
```

- **One WebView, many documents.** CM6 `EditorState` per open tab; switching tabs swaps state into the single `EditorView` (cheap, keeps scroll/undo per state). Avoids N WebViews (memory, R6).
- **Dart owns truth for persistence; CM6 owns truth for live editing.** On open: Dart reads file → `doc.open(id, text, language, version)`. While editing: CM6 applies changes locally at 60 fps and emits **change sets** (CM6 `ChangeDesc` JSON: retain/insert/delete spans) debounced ~150 ms + on blur/save/tab-switch. Dart applies them to its shadow buffer (crash-safe journal). On save: Dart writes atomically (tmp+rename), bumps version, acks. External file change: Dart sends `doc.replace` with the new text and version (W4 adds the conflict prompt).
- **No full-document sync per keystroke** (spec §6.3). Full text moves only on open, save-conflict resolution, and recovery.
- **Protocol v1** (`editor/src/protocol/` ↔ `app/lib/core/editor/protocol.dart`): envelope `{v: 1, id, type, payload}`, strict on both sides (unknown type, version or field → rejected and logged). Host → editor: `editor.configure`, `doc.open/activate/close/replace/flush/snapshot`, `cmd.insert/exec/gotoLine`, `search.set`. Editor → host: `editor.ready`, `doc.changed`, `doc.viewState`, `editor.history`, `editor.focus`, `ime.composition`, `app.shortcut`, `editor.log`, and `response` (correlated by id, with timeouts). Contract tests: the same JSON fixtures (`editor/test/fixtures/`) run in vitest and in `app/test/core/editor_protocol_test.dart`. Later phases add types (external changes in W4, LSP passthrough in Phase 6), each with fixtures on both sides.
- **Host and recovery** (`app/lib/application/editor/editor_host.dart`): the host keeps a shadow copy of every open document and applies each `doc.changed` to it only if it follows on exactly (base version, lengths); anything else is refused and the shadow is rebuilt from a snapshot. Whenever the page announces `editor.ready` (first start, reload, restart), the host replays the configuration and reopens every document from its shadow, selection and scroll included. A WebView renderer crash cannot be caught (the plugin exposes no `onRenderProcessGone`), so it ends the app process; unsaved text then comes back from the journal once W5 lands (until then it is lost in this one case).

## 3. Mobile editing experience (spec §4.4)

- **Symbol toolbar** (Flutter widget above IME): customizable row — `Tab ⇥ {} [] () ; : = > < " ' | & $ # ~ \` _ /` + undo/redo + cursor arrows + dismiss-keyboard. Long-press for paired variants. Config per language; hardware keyboard attached → toolbar collapses to a slim strip.
- **IME integration:** CM6 runs in contentEditable mode; Flutter side uses `SystemChannels.textInput` awareness only for toolbar insets — the WebView owns its IME session (no double-IME). Tested matrix: Gboard swipe, voice, CJK, RTL, emoji, physical keyboard.
- **Shortcuts (hardware):** Ctrl+S/P/F/H/Z/Y/Shift+Z, Ctrl+G, Ctrl+/, Ctrl+D, Alt+↑/↓ handled in CM6 keymap; app-level (Ctrl+Shift+P palette, Ctrl+W close tab) handled in Flutter via `HardwareKeyboard`/`Shortcuts`.
- **Tabs & dirty state:** Flutter tab strip (scrollable, close buttons, dirty dot); state in EditorService; restoration after process death from journal (Phase 2 acceptance: kill mid-edit → reopen → zero loss).

## 4. WebView hardening (summary; full: SECURITY.md)

`WebViewAssetLoader` origin only; CSP `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'`; `setAllowFileAccess(false)`, `setAllowContentAccess(false)`, no geolocation, no third-party cookies; JS bridge = one `@JavascriptInterface` method taking a JSON string, schema-validated, rate-limited, workspace-scoped; no `eval` of remote content; bundle integrity hash checked at load (recorded at build).

## 5. Fallback posture

If WebView editing proves unreliable on target devices after the gate, the documented fallback is a **native Flutter editor surface** (custom render of a rope/text-buffer with CM6-like keymaps) — a major investment, deliberately out of scope unless the gate forces it. We do not silently degrade to a plain TextField and call it an IDE.
