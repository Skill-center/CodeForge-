# Phase 2 Implementation Plan — Workbench & Editor Engine

**Status:** **In progress** (started 2026-11-06) · Prerequisite: Phase 1 accepted on 2026-11-06 ([report](PHASE_1_REPORT.md)), with the phone checks parked · Blocks: nothing external (no runtime, licence decision or phone is needed to start)
**Spec reference:** §8 Phase 2, §4.4, §6.1, §6.3 · **Architecture:** [EDITOR_ARCHITECTURE.md](../EDITOR_ARCHITECTURE.md), [ADR-0004](../adr/0004-editor-engine.md) (engine), [ADR-0008](../adr/0008-persistence.md) (persistence) · **Security:** [SECURITY.md](../SECURITY.md) §3 · **CI:** [BUILD_AND_RELEASE.md](../BUILD_AND_RELEASE.md)

---

## 0. Carried in from Phase 1 and the owner

- **The phone checks are parked** ([ROADMAP.md](../ROADMAP.md), "Parked owner checks"). That changes how the ADR-0004 engine gate runs. It runs on the KVM emulator in the phase gate, and the decision is recorded as **accepted on emulator evidence**, with the arm64 confirmation parked. The spec says the final selection rests on Android device testing, so the ADR names the phone run as the condition for calling it final. A debug-only benchmark screen in the app turns that phone run into a one-tap job.
- **Phase 1 carry-overs:**
  - 48 dp symbol-toolbar keys.
  - Feature → service access goes through controllers (ARCHITECTURE §2.4).
  - The keyboard-visibility and hardware-keyboard providers (Phase 1 plan 2.5).
  - An on-disk log sink.

## 1. Objectives

1. Integrate the editor engine in a hardened WebView, behind an engine-agnostic protocol. It is CodeMirror 6 unless the gate says otherwise.
2. Edit real files: open, edit, save and save-as UTF-8 text files in an app-private workspace on the device, written atomically.
3. Support many open documents and tabs. Each document keeps its own cursor, scroll position, selection and undo history.
4. Never lose text across lifecycle changes, process death or WebView renderer crashes.
5. Deliver the mobile editing essentials of spec §4.4:
   - syntax highlighting for the initial languages, and language detection;
   - find/replace, undo/redo and go to line;
   - the symbol toolbar, Tab/Shift+Tab and hardware-keyboard shortcuts;
   - keyboard-safe layouts.
6. Measure large-file performance, and set a large-file policy from the numbers.

## 2. MVP 2 definition (spec)

"A functional code editor that opens and edits real local source files."

**Scope decision.** In Phase 2, "real local files" means files in the device's app-private storage:
- The workspace is a directory under the app's documents directory. The app creates it and seeds it: the demo project becomes real files on first run.
- The user extends it with New File and Save As.
- Opening folders elsewhere on the device through the Storage Access Framework is Phase 3 (spec: Workspace & File Management). Phase 2's `FileService` is the seam it plugs into.

## 3. Technical implementation (workstreams)

### W1 — Editor workspace & protocol (1 session) 🔑 critical path

**Toolchain:** `editor/` uses TypeScript 5.9.3, esbuild 0.28.2, vitest 5.1.0 and happy-dom 21.0.4. Versions are exact pins with a committed `package-lock.json`, installed with `npm ci`, on Node 24 LTS in CI.

**Protocol (`src/protocol/`):**
- Envelope `{v: 1, id, type, payload}` and a validator for every message type.
- JSON fixtures in `test/fixtures/protocol/`, shared with the Dart tests.

**Editor (`src/codemirror/`):**
- One `EditorView`, with one `EditorState` per document.
- Languages: JavaScript/TypeScript (including JSX/TSX), Python, JSON, HTML, CSS and Markdown.
- Line numbers, active line, bracket matching, auto-close, auto-indent, folding, search and history.
- Forge dark and light themes, taken from the design tokens.
- Change sets are batched: at most every 150 ms, and also on blur, save and tab switch.

**Build output:**
- One self-contained HTML document (inline JS and CSS) plus a manifest of sizes and SHA-256 hashes.
- It is written to `app/assets/editor/`, gitignored and built by CI.
- CSP: `default-src 'none'; script-src 'sha256-…'; style-src 'unsafe-inline'`.

**Why inline:** `webview_flutter_android` 4.14.1 exposes no request interception, so `WebViewAssetLoader` is unreachable. A self-contained document with a hash-pinned CSP makes zero requests, and the WebView itself enforces bundle integrity. SECURITY.md §3 is updated to match.

**CI:** an `editor` job (typecheck, vitest, build, gz size budget), plus a bundle step before every Flutter build.

### W2 — WebView host & bridge (1 session)

- `webview_flutter` 4.14.1, behind an `EditorSurface` interface: the WebView implementation for the app, and a Dart fake for widget tests.
- **Hardening:**
  - The page is loaded with `loadHtmlString` under `https://appassets.androidplatform.net/`.
  - Every navigation is refused.
  - File and content access are off.
  - There is one JavaScript channel, taking one JSON string that is validated, size-capped and rate-limited.
  - WebView debugging is enabled in debug builds only.
- **Dart mirror of the protocol:**
  - Uses the shared fixtures, so the contract is tested on both sides.
  - Correlates requests with responses, with timeouts.
  - An unknown type or version is rejected and logged.
- **Recovery:** after a renderer crash or a reload, the page is rebuilt and documents reopen from Dart's shadow buffers.

### W3 — Engine gate, ADR-0004 (1–2 sessions) → gate G1

**The harness:** benchmark pages for CM6 and Monaco 0.57.0 at identical scope:
- highlighting for JS/TS/Python/JSON/HTML/CSS;
- find/replace;
- a stub completion popup.

Both pages load the same way. Monaco runs without web workers, and that is documented.

**Metrics:**
- **Cold load:** time to first paint.
- **Input latency:** input → frame for 60 keys sent through the DevTools protocol, as p50 and p95.
- **1 MB file:** open time and the share of scroll frames over 32 ms.
- **Memory:** renderer + app after a scripted editing session. It is shorter than the ADR's 10 minutes so the gate stays fast, and that is stated with the numbers.
- **Size:** the shipped gzip size.
- **Composition:** correctness driven by DevTools `Input.imeSetComposition` / `Input.insertText`, including CJK and emoji.

**Where it runs:**
- In the phase gate on the KVM emulator. Results go to `app/ci-results/gate/editor_bench.json`.
- The same harness sits behind a debug-only Settings → Developer → Editor benchmark screen, for the parked phone run.

**Decision:** ADR-0004 records it with the raw numbers. If CM6 fails the composition suite, work stops for a reassessment (EDITOR_ARCHITECTURE §5).

### W4 — Real files, documents & tabs (2 sessions)

**`FileService`, on `dart:io`:**
- Scoped to the workspace root: paths are canonicalised, and `..` or symlinks can't escape it.
- Atomic writes: temp file, flush, then rename.
- UTF-8, preserving the BOM and line endings.
- Binary and invalid UTF-8 files are refused as text, never corrupted.

**Workspace actions:**
- On first run, the demo project is written as real files.
- New File, Save, and Save As (inside the workspace).
- Closing a dirty document asks Save / Don't Save / Cancel.

**`DocumentController`:**
- Tracks open documents and their versions.
- Dirty state compares against the saved text, so undoing back to it clears the dirty mark.
- Holds the shadow buffer, which applies CM6's change sets.

**Tabs:**
- Open, activate, close and close others; dirty dots; reopen order.
- Language detection by file name, extension and shebang.

**Workbench:** the editor pane hosts the real editor, and the Phase 1 demo code view is retired.

### W5 — Zero-loss persistence (1–2 sessions)

**Drift 2.35.3 (ADR-0008):**
- The first schema covers workspaces, open tabs (order, active tab, cursor and scroll) and journal metadata.
- A migration test harness from v1.
- Codegen runs in the CI bootstrap, which commits the generated files back. Plain runs check that the generated files are up to date.

**Hot-exit journal for dirty documents:**
- A full snapshot on pause, on tab switch and every few seconds, plus an append-only change log between snapshots.
- On cold start the journal is replayed, and the document reopens dirty with its unsaved text.
- If the file changed on disk meanwhile, both texts are kept and the user is asked.

**Emulator gate:** a new `edit_a` / `edit_b` pair. `edit_a` types unsaved text, the process is killed, and `edit_b` relaunches and checks the exact text, the dirty marker and the cursor.

### W6 — Editing features & keyboards (2 sessions)

**Editing:**
- Find/replace (case, whole word, regex, replace all) in a Forge-styled panel.
- Go to line.
- Undo/redo from the toolbar and from shortcuts.

**Symbol toolbar:**
- Wired to the editor, with presets per language and user-customisable keys.
- Paired inserts put the cursor between the pair.
- Keys for Tab/Shift+Tab, cursor arrows, undo/redo and hide keyboard.
- 48 dp keys.
- Taps never take focus from the WebView, so the IME stays up.

**Hardware keyboard:**
- Editor shortcuts live in the CM6 keymap.
- App shortcuts (palette, save, close tab, next tab) are caught in the WebView while it has focus and forwarded over the bridge.
- Keyboard-visibility and hardware-keyboard providers.
- The toolbar collapses when a hardware keyboard is attached.

**Layout:** the Phase 1 keyboard-safe rules are extended to the real editor at every breakpoint.

### W7 — Large files, tests & quality (continuous + 1 session)

- **Large files:** measure open, scroll, typing and memory at 1, 5 and 10 MB on the emulator. Set a policy from the numbers, for example plain-text mode above one threshold and a refusal with a clear message above a hard cap.
- **Tests:** the test pyramid in §6, per-layer coverage, and goldens for the new chrome.

### W8 — Documentation & phase exit (0.5 session)

PHASE_2_REPORT.md with run ids, ADR-0004 accepted with numbers, and the documents in §7.

## 4. Deliverables

- **Editor:** the `editor/` workspace, with its bundle shipped in the APK. The benchmark harness goes into debug builds only.
- **Flutter:**
  - the WebView `EditorSurface` and the protocol;
  - the real `FileService`, `DocumentController` and tabs;
  - find/replace, the symbol toolbar and shortcuts;
  - the Drift database and the journal.
- **CI:** the `editor` job, and a phase gate with the editor benchmark, the kill-mid-edit pair and the large-file numbers.
- **Docs:** see §7.

## 5. Acceptance criteria (measurable gates)

| Gate | Criterion | Evidence |
|---|---|---|
| **G1 Engine** | CM6 within the ADR-0004 budgets on the KVM emulator: cold load ≤ 800 ms; input → frame p95 ≤ 32 ms; a 1 MB file opens without OOM, with < 5 % of scroll frames over 32 ms; memory ≤ 250 MB; bundle ≤ 1.5 MB gz; 0 composition corruptions. Monaco is measured with the same suite | `editor_bench.json` + gate run id; ADR-0004 updated |
| **G2 Files** | open, edit, save and save-as real files; atomic writes (an interrupted save leaves the old file intact); BOM and CRLF preserved; binary and invalid UTF-8 refused | `FileService` tests on a real temp dir + emulator smoke |
| **G3 Tabs** | ≥ 10 open documents; switching keeps each one's cursor, scroll, selection and undo; dirty dot + close prompt; tabs reopen after restart | widget + integration tests |
| **G4 Zero loss** | type without saving → process death → relaunch: identical text, still dirty, cursor restored. The same holds after a renderer crash and after rotation. Journal replay equals the live text for randomized edit sequences | emulator pair + property tests |
| **G5 Editing** | highlighting for the six initial language families; detection by extension and shebang; find/replace including regex; undo/redo; go to line; bracket matching, auto-close, auto-indent, folding | vitest + integration |
| **G6 Keyboards** | the toolbar inserts at the cursor without closing the IME; 48 dp keys; Tab/Shift+Tab; hardware shortcuts (save, find, undo/redo, palette, close and next tab) work while the editor has focus | widget tests + emulator key injection |
| **G7 Large files** | open, scroll, typing and memory measured at 1, 5 and 10 MB; the large-file policy is implemented and tested | perf JSON + tests |
| **G8 Quality** | CI green (Flutter and editor jobs); protocol contract tests on both sides; the accessibility suite covers the new chrome; no overflow, including with the keyboard up | run ids |
| **G9 Docs** | docs synced; PHASE_2_REPORT with run ids | review |

**Definition of done:** every gate is green with cited evidence, no critical issue is open, and the owner accepts the report. The phone confirmations (ADR-0004 on arm64 and the Gboard matrix) stay on the parked list. They don't block acceptance unless the owner decides otherwise.

## 6. Tests

| Layer | Tool | Phase 2 additions |
|---|---|---|
| JS unit | vitest + happy-dom | protocol validation, change-set batching, the language-detection table, search semantics, theme tokens |
| Bridge contract | vitest + Dart test, shared fixtures | every message type round-trips; an unknown version or type is rejected |
| Dart unit | flutter_test | `FileService` on real temp dirs (atomic save, BOM/CRLF, binary refusal, path escapes); the shadow buffer; journal replay (property tests); Drift migrations |
| Widget | flutter_test + fake `EditorSurface` | tabs, close prompts, the toolbar, shortcuts, the find panel, keyboard-safe layouts |
| Integration (emulator) | integration_test + gate scripts | real WebView edit/save, the kill-mid-edit pair, the engine benchmark, the composition suite, large files |

## 7. Documentation

Updated in W8:
- EDITOR_ARCHITECTURE (as built);
- ADR-0004 (the decision and its numbers);
- SECURITY §3 (the inline document and its CSP hash);
- TESTING, BUILD_AND_RELEASE (the editor job), ARCHITECTURE and TECH_STACK;
- CHANGELOG, ROADMAP and README;
- the new PHASE_2_REPORT.

## 8. Known limitations (planned) and out of scope

**Out of scope:**
- the SAF folder picker, file watching, and explorer create/rename/delete beyond New File (Phase 3);
- the runtime and run buttons (Phases 4–5);
- LSP completion, diagnostics, go to definition and formatting (Phase 6);
- the minimap (later, as a tablet option);
- multiple editor groups (Phase 9).

**Planned limitations:**
- The workspace lives in app-private storage.
- Text is UTF-8 only: other encodings are refused, not converted.
- Engine numbers are indicative of an emulator until the parked phone run.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| WebView IME quirks (Gboard composition, autocorrect) corrupt text | CM6, chosen for its native contentEditable handling; the composition suite on the emulator; the stop-and-reassess rule; the manual Gboard matrix, parked for the phone |
| Toolbar taps steal focus and close the IME | the toolbar is excluded from focus, and an emulator test checks that the IME stays up |
| Hardware shortcuts never reach Flutter while the WebView has focus | handle them in the CM6 keymap and forward them over the bridge |
| Monaco's bundle is huge and wants workers | a benchmark-only build that never ships in release; workers disabled, and noted |
| Large documents crossing the bridge | full text only on open and recovery, change sets otherwise; size caps; the large-file policy |
| Drift codegen without a local Dart toolchain | the CI bootstrap commits the generated code; plain runs check it's up to date |
| Emulator numbers differ from phone numbers | stated as indicative; the phone run is parked, with a one-tap harness |
| Bugs that lose data | atomic writes, journal property tests, the kill-mid-edit gate, and never auto-overwriting on conflict |
