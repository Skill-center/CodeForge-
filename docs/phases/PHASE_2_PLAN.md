# Phase 2 Implementation Plan — Workbench & Editor Engine

**Status:** **Built and CI-verified, awaiting owner acceptance** (2026-11-10; started 2026-11-06). Exit report: [PHASE_2_REPORT.md](PHASE_2_REPORT.md) · Prerequisite: Phase 1 accepted on 2026-11-06 ([report](PHASE_1_REPORT.md)), with the phone checks parked · Blocks: nothing external (no runtime, licence decision or phone is needed to start)
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
- **Recovery:** whenever the page announces itself again (a reload or a restart), documents reopen from Dart's shadow buffers. A renderer crash cannot be caught in-app: `webview_flutter_android` 4.14.1 exposes no `onRenderProcessGone`, so Android ends the app process, and the text comes back from the W5 journal on the next start. G4 therefore treats a renderer crash as process death.

### W3 — Engine gate, ADR-0004 (1–2 sessions) → gate G1 · **done 2026-11-06: CodeMirror 6**

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

**As built (W3):**
- **Pages:** `editor/bench/` builds `codemirror.html` and `monaco.html` with the editor page's own kit (`tool/page_kit.mjs`) into `app/assets/editor_bench/`, which is gitignored and built only by the phase gate. Monaco 0.57.0 is a dev dependency and never ships in the editor page.
- **In the gate:** `integration_test/editor_bench_test.dart` runs the Settings screen on the debug APK, with 3 fresh WebViews per engine in ABBA order. It then hands each page to the DevTools driver (`tool/bench_cdp.mjs`) for input latency, the 9 composition cases and memory. Memory is the app's PSS plus its renderer's, from `dumpsys meminfo`. `tool/bench_report.mjs` writes `editor_bench.json`/`.txt` with every budget checked. A budget miss is evidence for ADR-0004, not a gate failure. How each metric is measured: EDITOR_ARCHITECTURE §1.
- **Debug and profile builds:** the developer screens exist in every build except release (`!kReleaseMode`), because the phone build is a profile build. This differs from the "debug-only" wording above. The gate also uploads the `codeforge-phone-profile-arm64` APK with the pages bundled, kept for 30 days. Steps: [PHASE_2_PHONE_CHECKLIST.md](PHASE_2_PHONE_CHECKLIST.md).
- **Frame timing:** Settings → Developer → Frame timing records build and raster times per frame (`SchedulerBinding.addTimingsCallback`). This serves Phase 1's parked G6 check of navigation frames on hardware.
- **Results** (ADR-0004 has the tables): the desk run, and phase gate 42206498197 on the emulator. On the emulator, CM6 is ahead of Monaco on every metric except engine-path typing p50, and both pass all 9 composition cases. Cold load (364.8 ms), composition and size are within budget for CM6. Its typing, input, scrolling and memory numbers are over budget, but they are bounded by the emulator's software rendering, which reached about 7 fps for both engines.
- **Phone run (2026-11-06):** the owner used a realme C51 (Unisoc T612, 4 GB) with the profile APK. On it, CM6 met cold load (217–228 ms) and typing p95 (21.7–22.4 ms). Its 1 MiB scrolling was 1.7 % and 9.8 % slow frames in two sessions, against Monaco's 36–37 %; ADR-0004 and the evidence folder have the details. G1 asks for the budgets "on the KVM emulator", where no engine can meet the frame-timed ones. The owner took the low-end phone as the reference instead: "I use a low phone for tests it means app will work on every phone".
- **ADR-0004 is Accepted: CodeMirror 6.** G1 status:
  - **Met:** cold load, typing p95, composition (9/9 on the emulator), size, and the 1 MiB file opening without OOM.
  - **Carried to W7:** CM6's mid-file typing in a 1 MiB file (133–136 ms p95 on the phone), scrolling on the low-end phone (1.7–9.8 %), and memory measured on a release-like build.
  - **Carried to W6:** the selection matrix (handle placement at line boundaries).
- **Fixed from the phone run:** selected text on the cursor's line was invisible, because the active line's opaque background covered CodeMirror's selection layer. A line is now highlighted only around a plain cursor (`editor/src/editor/active_line.ts`). The typing check now says what to do and shows each result next to its buttons. Verified by commit 58d91fa: CI 42216855073 (`+370: All tests passed!`) and phase gate 42216855184, where the editor-bridge test passed on attempt 1 and the emulator re-run kept CM6 ahead (ADR-0004).

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

**As built (W4):**
- **Files** (EDITOR_ARCHITECTURE §6 "Files"): `LocalFileService` on `dart:io` works in one app-private folder, `<filesDir>/workspaces/demo`. Paths are checked as text, then against the canonical root after resolving symbolic links, so neither `..` nor a link reaches outside. Writes go to `.<name>.cf-tmp` beside the target, are flushed, and replace it with one rename; the temp file is removed on failure. The codec is strict UTF-8: it keeps the byte-order mark and CRLF or LF, flags mixed line endings, and refuses binary files, malformed UTF-8 and UTF-16/32 with a reason. A stamp (modified time and size) stops a save from overwriting a file changed on disk without asking. Reads are capped at 16 MiB. The first run writes the demo project into `<root>.seeding` and renames it into place.
- **Documents and tabs** (EDITOR_ARCHITECTURE §6 "Documents and tabs"): `DocumentController` replaces the W2 tabs controller. Dirty means the live text differs from the saved text. Saves of one file are serialised, and an edit racing a save stays dirty. Save As keeps the editor document, so cursor and undo move with the tab, and re-highlights it with the new protocol message `doc.setLanguage` (fixtures on both sides). New File, Close with Save / Don't Save / Cancel, and Close others are built. The most recently used tab takes over when the active one closes. Tabs and the active tab persist in the shell envelope and reopen once per run. Language detection goes by extension, file name, then shebang.
- **Workbench:** Ctrl+S, Ctrl+Shift+S, Ctrl+N, Ctrl+W, Ctrl+Tab / Ctrl+Shift+Tab and Ctrl+Shift+P work from Flutter and from inside the editor page, which forwards them (§6 "Shortcuts"). The status strip shows language, line endings (amber when mixed) and BOM. The tab strip scrolls the active tab into view. The explorer lists the real folder (dotfiles hidden by default) and has New File. An empty editor offers New File.
- **Deviations from this plan:**
  - The root comes from a one-method MainActivity channel, not path_provider, whose Android side now pulls a JNI/NDK build into every APK (TECH_STACK §5).
  - Tabs persist in the `codeforge.shell.v1` envelope for now; Drift takes them over in W5 with the journal.
  - A save replaces the file, so its permission bits are not kept. That is harmless in the app-private folder and must change for Phase 3/4 (SECURITY §4).
  - The import lint now fails if a feature reads `fileServiceProvider` (ARCHITECTURE §2.5).
- **Evidence** (commit 744a149):
  - CI 42238016497: `+431: All tests passed!` (370 at W3), `flutter analyze` clean, line coverage 3432/3999 (85.8 %). It includes the `LocalFileService` suite on a real temporary folder (an interrupted save, symlink escapes, BOM/CRLF bytes, exclusive creation) and the documents widget flows. The editor workspace's `npm run ci` passed locally with 121/121 tests.
  - Phase gate 42238016973: all 6 emulator runs passed on attempt 1.
    - `editor_bridge_test`: a save writes exactly the editor's text to the device; a CRLF + BOM file survives an edit and a save byte for byte, and Save As copies it exactly. Twelve open tabs each kept their text, cursor and scroll position across switches (restored scroll tops 1088–2978 px), and a select-all selection survived a switch. Undo in one tab left the others alone, and undoing back to the saved text made the tab clean. There were 0 resyncs.
    - The restore pair: part A persisted `"openTabs":["main.js","app.py"],"activeTab":"app.py"`. After `am force-stop`, part B found both tabs reopened from the files with `app.py` active.
    - Editor ready 3821 ms after opening the workbench, and release cold start median 1284 ms (budget 1500). Both are within W3's range on the same emulator (3678–4332 ms and 1146–1322 ms).
  - The earlier gate 42233424845 had failed only in the smoke test, which checked for the workbench before the first run's file work had finished; the test now waits for it.
- **Gate status:**
  - **G2 Files:** met.
  - **G3 Tabs:** met: ≥ 10 documents with per-document cursor, scroll, selection and undo; dirty dot and close prompt; tabs reopen after restart.
- **Known limits (carried):**
  - Unsaved text does not survive process death until the W5 journal (G4).
  - UTF-8 only; app-private folder only (SAF in Phase 3); no file watching, so outside changes are caught at save time.
  - 16 MiB read cap (W7 measures large files). *W7: a 10 MiB cap, and plain text above 512 KiB (EDITOR_ARCHITECTURE §10).*
  - Permission bits are not kept on save.

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

**As built (W5):**
- **App database** (ARCHITECTURE §2.6, ADR-0008 amendment): Drift 2.35.3 over SQLite, `<filesDir>/codeforge.sqlite`, schema v1 with `workspaces`, `open_tabs` (order, active, selection, scroll), `journal_documents` and `journal_changes`. It opens lazily in a background isolate, with WAL and `synchronous = NORMAL`. SQLite comes from the `sqlite3` package's build hook (prebuilt, hash-checked), with no NDK build. `SessionStore` is the contract; `DriftSessionStore` and the tests' `MemorySessionStore` implement it.
- **Hot-exit journal** (EDITOR_ARCHITECTURE §7): `DocumentJournal` takes a snapshot at the first unsaved edit, on tab switch, on pause and every 5 s while changes arrive (documents over 512 KiB at most once a minute), and after 200 changes. The editor's change sets are appended in between, and each snapshot replaces the changes it covers in one transaction. Writes are queued in order; a failed write forces fresh snapshots, retried on the timer, and the editor shows a banner until a write succeeds.
- **Cold start:** replay stops cleanly at any damage. A document whose file is unchanged reopens dirty with its text, cursor and scroll. A file that changed, was deleted or can no longer be read meanwhile keeps the unsaved text and asks: keep my changes, or use the file. A changed file keeps both texts, and a file that is gone or unreadable closes if the user picks the file. The question is asked again after another restart until it is answered.
- **Rotation:** the manifest keeps the activity, and the editor pane now moves between the portrait and docked layouts under one `GlobalKey`. The page no longer reloads on rotation, and undo history survives it.
- **Codegen in CI:** bootstrap mode runs build_runner, `drift_dev make-migrations` and `drift_dev schema generate` (make-migrations writes the test helpers only from the second schema version on) and commits the output. Every run's "Generated code check" regenerates and compares it, and the phase gate generates before building.
- **Deviations from this plan:**
  - The journal is in SQLite, not files (ADR-0008 amended): a snapshot must replace the changes it covers atomically.
  - Tabs moved from the shell envelope to the database via a one-time import; the envelope keeps schema version 1 (ARCHITECTURE §2.6, migration notes).
  - The gate's renderer crash kills the WebView's sandboxed renderer of a running app that has restored unsaved text (the plain debug APK installed over the test build, keeping its data). webview_flutter_android 4.14.1 has no `onRenderProcessGone`, so a renderer crash is a process death.
- **Evidence** (commit b6b799b; the unreadable-file test from 515f85a):
  - CI 42386742434: `+477: All tests passed!` (431 at W4), and `flutter analyze` is clean. The committed generated code is exactly what the generators produce. Line coverage of hand-written code is 4014/4627 (86.8 %), with services at 74.7 % and 1239 generated lines excluded (BUILD_AND_RELEASE.md).
    - The 46 new tests include property tests in which replaying the journal gives the live text for randomized edit sequences. On the journal itself that is 400 seeds of up to 60 change sets each, emoji included. Through the SQLite store it is 8 seeds of 50–199 edits, with fresh snapshots in between.
    - They also cover the controller killed and restarted mid-edit: with the file unchanged, changed or deleted meanwhile, with a journal that matches the file, with a damaged journal, and with a store that cannot be written. The schema v1 check is among them.
    - Two tests reproduce the fixes: rotation with unsaved text, and a command racing the page sync.
  - CI 42388617576 on 515f85a: `+478: All tests passed!`, with the unreadable-file restore added. Another program saves the file as UTF-16 while the app is dead. The changes come back unsaved, with the question, which survives a restart until it is answered.
  - Phase gate 42386742421: all 8 emulator runs passed on attempt 1.
    - `edit_a` typed 262 characters into main.js through the real page, among them `é`, `中` and an emoji outside the Basic Multilingual Plane. The cursor was left at 44, and nothing was saved.
    - The plain app then restored that session, and its WebView renderer was killed: "app pid after the renderer kill: none, the app died with its renderer". `am force-stop` confirmed the process death.
    - `edit_b` found main.js with the same 262 characters, still unsaved, the cursor at 44 (read back from the page itself) and the dirty dot on its tab.
    - `edit_b` then rotated to landscape (the docked layout appeared) and back to portrait: "page starts 1 before and 1 after, text and cursor kept". The WebView survives the editor pane's move between layouts, so the page does not reload.
    - The editor bridge passed (page starts 2, syncs 2, resyncs 0), and the release cold start median was 1078 ms (budget 1500).
    - Phase gate 42382386682 on c8af0cf had already passed the same pair, apart from the rotation step, with identical numbers and a cold start median of 1349 ms.
  - Two earlier runs failed:
    - CI 42377268979: the migration-test helpers were missing, because `make-migrations` writes them only from the second schema version on. The bootstrap now runs `drift_dev schema generate`.
    - Phase gate 42379885027: in `edit_a`, the typing reached the page before the page had reopened main.js after starting. Document commands now wait for the page sync (EDITOR_ARCHITECTURE §6).
- **Gate status:**
  - **G4 Zero loss:** met. Unsaved typing survives process death and a renderer crash: the same text, still unsaved, with the cursor restored. It also survives rotation, without even a page reload. Journal replay equals the live text for randomized edits.
- **Known limits:**
  - Durability covers app crashes and process deaths. With WAL and `synchronous = NORMAL`, an OS crash or a power cut can lose the last transactions; W7 measures what `FULL` costs (ADR-0008).
  - The journal keeps text, cursor and scroll, not undo history: a document restored after a process death starts with an empty history. Rotation keeps the history, because the process and the page stay.
  - Documents over 512 KiB get a fresh snapshot at most once a minute, with the change log covering the time between. W7 measures large documents.
  - Text that is not valid UTF-16, such as a lone surrogate, does not pass through the database unchanged, because SQLite keeps UTF-8. CodeMirror never splits a surrogate pair and files are read as UTF-8, so the app does not produce such text. For the same reason, the store's property tests use characters from the Basic Multilingual Plane, while the gate covers an emoji on the device.
  - A conflict offers keeping the unsaved text or using the file's; there is no side-by-side comparison yet.

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

**As built (W6):**
- **Find, replace and go to line** (EDITOR_ARCHITECTURE §8): one search session in the page, driven by a Flutter find bar. It covers match case, whole word and regular expressions, counts up to 1,000 with the current match, replace one and replace all (one undo step, `$1` groups), and follows the active tab. Go to line takes `42` or `42:7`. Ctrl+F, Ctrl+H, Ctrl+G and the palette open them.
- **Symbol toolbar** (EDITOR_ARCHITECTURE §9): the editor pane's last row, on the soft keyboard. From the left it holds Tab, Shift+Tab, the symbols, Undo, Redo and the arrows, with the hide key pinned at the end.
  - Every key is a 48 dp target.
  - The rows are per language family, or Compact, Off, or the user's own keys (at most 40, of up to 8 characters).
  - Pairs leave the cursor between them; a long press gives the other variant.
  - The keys never take Flutter's focus, so the WebView keeps the keyboard.
  - The new `insertIndent` command is Tab, on the toolbar and on hardware keyboards.
- **Keyboards:** `softKeyboardVisibleProvider` reads the window's inset, and `MainActivity` reports a hardware keyboard from Android's configuration over `dev.codeforge/keyboard`.
- **Hardware keys in the editor** (EDITOR_ARCHITECTURE §9, Shortcuts):
  - Android hands every key to Flutter before the focused WebView, so the workbench's shortcuts act while the editor has the focus.
  - The editing keys (Tab, Shift+Tab, the arrows, Ctrl+arrows, Page Up/Down, Enter, Space, Escape) are kept from Flutter's app-wide defaults and go on to CodeMirror (`editorPageKeys`).
  - webview_flutter_android 4.14.1 never reports the WebView's focus. The page's own `editor.focus` report therefore moves Flutter's focus onto the platform view's node, which also makes the page Flutter's text input target.
  - The emulator gate found both of these problems: on a real device, a hardware Tab would have moved Flutter's focus instead of indenting.
- **Protocol:** W6 adds the `search.state` event, the `insertIndent` command and three forwarded shortcuts (`find`, `replace`, `gotoLine`). `PROTOCOL_VERSION` stays 1.
- **The keys gate** (`integration_test/keys_test.dart`, EDITOR_ARCHITECTURE §9):
  - The test asks for input in the device log, and the gate's injector answers with real touches (`input tap`), single keys (`input keyevent`) and chords.
  - Chords are written to the emulator's keyboard device with `sendevent`, with adbd as root on the google_apis image (a userdebug build).
  - `input keycombination` injects from Android's virtual keyboard device, so Flutter never sees the modifier held.
  - The gate turns on Android's setting for a soft keyboard beside a hardware one, then turns it off for the hardware-key steps, and restores it afterwards.
  - Each integration-test attempt is limited to 10 minutes and retried as an infrastructure failure (BUILD_AND_RELEASE.md).
- **Deviations from this plan:**
  - App shortcuts are not caught in the WebView first. Android gives keys to Flutter before the WebView, so the workbench's own shortcuts handle them. The page still forwards the same shortcuts over the bridge for any key that reaches it first.
  - The toolbar does not simply collapse beside a hardware keyboard. It steps aside while the soft keyboard is down, and comes back when a soft keyboard comes up beside the hardware one, because the user is then typing on screen again (ARCHITECTURE §5).
- **Evidence:**
  - **Step 1, find, replace and go to line** (commit d4d2256, evidence 970d248):
    - CI 42437560827: `+512: All tests passed!`, `flutter analyze` clean, format 0 changed, coverage 87.8 %.
    - Phase gate 42437560830: all 9 emulator runs passed. `editing: ok (counts 6/5/4 by option, a whole-word replace all undone in one step, $2 = $1 groups, cursor at 42 = line 3 column 7; page starts 1, syncs 1, resyncs 0)` and `00:14 +1: All tests passed!`.
  - **Step 2, toolbar and keyboards** (commit e45ea41):
    - CI 42517731644: `+539: All tests passed!`, `flutter analyze` clean, format 0 changed. Line coverage of hand-written code is 4656/5310 (87.7 %), with services at 73.4 % and 1239 generated lines excluded.
    - Phase gate 42517731718: all 10 emulator runs passed on attempt 1. The keys group reported `keys: ok (toolbar () and Tab under a finger typed at the cursor and kept the focus, soft keyboard up throughout: true; hardware keyboard attached: true, toolbar shown by the soft keyboard beside the hardware one (the input method kept a soft keyboard up with the setting off); then from the keyboard, with the soft keyboard up: Tab, Shift+Tab, Ctrl+Z, Ctrl+Shift+Z, Ctrl+S, Ctrl+Tab (g6/keys.js to main.js), Ctrl+W, Ctrl+F, Escape, Ctrl+Shift+P, Escape; resyncs 0)` and `00:37 +1: All tests passed!`. Its first check found the toolbar away beside the hardware keyboard while the soft keyboard was down.
    - The editing group still passed with the same line, the editor bridge passed (page starts 2, syncs 2, resyncs 0), and the release cold start median was 976 ms (budget 1500).
    - In phase gate 42509926650, after the setting went off and the hide key was tapped, a tap in the editor left the soft keyboard down and the toolbar out of the way.
  - **Gate runs that failed on the way:**
    - Gradle downloads stalled (42477797842, 42478331067): the distribution is now cached.
    - The injector never saw the requests (42479571017, 42482002996): it now polls `logcat -d`, and the test prints in the root zone.
    - The test binding dropped device touches (42484555140).
    - Tab never reached the page (42491602659): `editorPageKeys`, then the focus following the page.
    - Modifiers arrived released (42494656149, 42497788524): `input keycombination`. The emulator console reached nothing (42507384710), and `sendevent` needed root (42509926650).
    - The test expected the wrong next tab (42512666974, 42515305565): the workspace's `main.js` is open too, so Ctrl+Tab wraps to it.
    - A smoke test hung after install until the job's 75-minute cap (42500759166): hence the 10-minute limit per attempt.
- **Gate status:**
  - **G5 Editing:** met. Highlighting, bracket matching, auto-close, auto-indent and folding are covered by vitest; find and replace with regular expressions, undo and redo, and go to line by vitest, widget tests and the emulator.
  - **G6 Keyboards:** met. The toolbar inserts at the cursor without closing the IME, its keys are 48 dp, and Tab and Shift+Tab work. Save, find, undo, redo, the palette, close tab and next tab work from a hardware keyboard while the editor has the focus. Widget tests cover all of this, and so does emulator key injection on the real page.
- **Known limits:**
  - Selection handles at line boundaries are drawn by Android System WebView, so only a phone can check them. Phone run 1 saw a selection ending at the start of a line draw its end handle at the end of the line before. [PHASE_2_SELECTION_MATRIX.md](PHASE_2_SELECTION_MATRIX.md) is the manual matrix for selection, copy and paste, and undo and redo; it is parked and non-blocking (§5).
  - Keys from Android's virtual keyboard device whose modifier press carries no meta state (`adb shell input keycombination`) reach Flutter without the modifier. The page's forwarded shortcuts caught Ctrl+S, Ctrl+W and Ctrl+Z that way, but not Ctrl+Tab, Ctrl+F or Ctrl+Shift+P (phase gate 42509926650), for reasons not yet known. Hardware keyboards are not affected.
  - Gboard sometimes keeps a soft keyboard up beside a hardware keyboard even with Android's setting off, and the toolbar then shows with it.

### W7 — Large files, tests & quality (continuous + 1 session)

- **Large files:** measure open, scroll, typing and memory at 1, 5 and 10 MB on the emulator. Set a policy from the numbers, for example plain-text mode above one threshold and a refusal with a clear message above a hard cap.
- **Tests:** the test pyramid in §6, per-layer coverage, and goldens for the new chrome.

**As built (W7):**
- **Large files** (EDITOR_ARCHITECTURE §10):
  - **Measured on the emulator.** The phase gate's large-file group (`integration_test/large_files_test.dart` with `editor/tool/large_cdp.mjs`) opens 1, 5 and 10 MiB of the benchmark's JavaScript through the app, as `.js` and as `.txt`, after a `.js` file just under the threshold. For each file it records the open, a jump to the middle line, the page's own work, long tasks, a 3 s scroll, 60 real key events typed at the middle line, memory and a save. The same group times the session store's writes (ADR-0008) and measures a release build's memory with a 1 MiB file restored. The report is `app/ci-results/gate/large_files.txt`, with every number in `large_files.json`.
  - **Plain text above 512 KiB.** A document longer than 524,288 characters that would be highlighted opens as plain text, without highlighting, folding, syntax-aware indentation or comment toggling. A banner says what is off and offers *Highlight anyway*, and the language chip turns amber. A `.txt` file loses nothing and gets no banner. The policy decides on open, when a document comes back after a kill, and on Save As, never while typing.
  - **Why 512 KiB.** The emulator ranks the costs but cannot judge them against the budgets, because it renders in software. On the phone (W3), a highlighted 1 MiB document typed at a p95 of 133 to 136 ms against the 32 ms budget, so the line has to sit below 1 MiB. 512 KiB is where the journal already treats documents as large.
  - **Refused above 10 MiB** (was 16 MiB), before the file is read. The message gives the file's size and the limit.
  - **What the policy changed** (gate 42659207710, against 42616081317 without it): the 1 MiB `.js` file had no long tasks after the open (6 tasks, 594 ms, when highlighted) and typed like the `.txt` file of the same size (median 28 against 23.8 ms). In the same run, the highlighted 512 KiB file, half the size, typed at a median of 50.6 ms. A release build restoring the 1 MiB file took 224.5 to 227.6 MB in the three runs with the policy (236 MB when highlighted), within the 250 MB budget.
- **Quality (G8):**
  - **Dialogs beside the keyboard.** The app's six alert dialogs are `CfAlertDialog`s (`design_system/components/dialogs.dart`): their title and content scroll above pinned actions, with tighter margins when the keyboard leaves less than 480 dp. `keyboard_insets_test` opens each one beside the keyboard at the five gate sizes, at 1.0× and 1.3× text. It checks that nothing overflows, that the dialog stays in the room above the keyboard, and that its confirming action and, where it has one, its text field are in view.
  - **The accessibility sweep** now covers the open find and replace bar, the dialogs, the file menu and the large-file banner. The symbol toolbar has been in its workspace screens, wherever it fits, since W6. The sweep found a labelled text field 47 dp tall, because the theme made text fields dense. They are no longer dense, so Material keeps them at least 48 dp tall.
  - **The protocol contract runs on both sides.** The Dart test holds `protocol.dart`'s message types equal to the page validator's tables and to the shared fixtures. vitest reads the Dart tables back, checks that the fixtures cover them, and that the page's validator knows every type. The page bundle did not change.
  - **Goldens for the new chrome** (`chrome_golden_test`): find and replace with a query and the large-file banner at 412×915, and go to line beside the keyboard at 800×360.
  - **The test pyramid in §6** is in place, layer by layer (TESTING.md §1.2): vitest for the page, the bridge contract on both sides, Dart unit tests (files on real temporary folders, journal property tests, Drift migrations), widget tests over the scripted editor page, and the emulator groups.
  - **Coverage per layer**, hand-written code (CI 42678576228): core 92.3 %, design system 95.2 %, application 92.6 %, features 87.4 %, services 73.4 % and the app root 72.4 %; 4736 of 5382 lines (88.0 %). Much of what services miss is platform glue that only runs on a device (the WebView surfaces and the app's directories), and the emulator gate runs it.
- **Deviation from this plan:** the sizes are MiB, not MB. The 10 MiB files stop 128 characters short of the cap, so that they open.
- **Evidence:**
  - **Step 1, measuring** (commit 1da630f, evidence 14838fd): CI 42616081306 `+539: All tests passed!`, coverage 87.7 %. Phase gate 42616081317: all 11 emulator groups passed, with the numbers without the policy.
  - **Step 2, the policy** (commits b8430fa and 65fe2ca, evidence b303746): CI 42659207677 `+552: All tests passed!`, `flutter analyze` clean, format 0 changed. Phase gate 42659207710: all 11 groups passed on attempt 1, in the run's second attempt; the first stopped while building the debug APK, before any test.
  - **Step 3, quality** (commits ed3e50e, 8064be0, decd7ec and ea8ef61):
    - CI 42678576228 (ea8ef61): `+563: All tests passed!`, `flutter analyze` clean, format 0 changed; the editor job passed 187 tests.
    - Phase gate 42676631509 (decd7ec; ea8ef61 changed only a test and a document): all 11 groups passed on attempt 1. The release build restoring the 1 MiB file took 224.6 MB, and the release cold start median was 906 ms (budget 1500).
    - Phase gate 42665305004 (ed3e50e), before the text fields changed: all 11 groups passed on attempt 1, and the release build restoring the 1 MiB file took 227.6 MB.
  - **Runs that failed on the way:**
    - CI 42611941480 and phase gate 42611941538 (46799b1): the large-file test imported `Result` without its helpers.
    - Phase gate 42654133163 (b8430fa): the 10 MiB test files were over the new cap. CI 42654133167 timed out because the scripted editor page laid out the whole document.
    - CI 42665305010 (ed3e50e): the new sweep found the 47 dp text fields, and at 1.3× text a tap in the keyboard test landed below the screen.
    - Phase gate 42667620018 (8064be0) never started a job.
- **Gate status:**
  - **G7 Large files:** met. Open, scroll, typing and memory are measured at 1, 5 and 10 MiB (`large_files.json` in gate 42616081317 without the policy, and in 42659207710, 42665305004 and 42676631509 with it). The policy is implemented and tested in unit, controller, service and widget tests, and the gate checks it on every file it opens.
  - **G8 Quality:** met. CI is green in both jobs, the protocol contract tests run on both sides, the accessibility suite covers the new chrome (find bar, toolbar, banner, dialogs and file menu), and nothing overflows at any gate size, with the keyboard up too.
- **Known limits:**
  - ADR-0004's large-file and memory carry-overs are answered on the emulator only. The phone runs are parked (§5).
  - Not measured: minified files (very long single lines), and documents between 512 KiB and 1 MiB on a phone. The policy counts characters, not lines.
  - The emulator's scroll numbers carry no signal: 85 to 100 % of frames are over 32 ms for every file, highlighted or not, because it renders in software.
  - The session store's digest of the saved text runs on the UI isolate, once per saved text: up to 28 ms at 1 MiB and 80 to 184 ms at 10 MiB in a debug build (ADR-0008).

### W8 — Documentation & phase exit (0.5 session)

PHASE_2_REPORT.md with run ids, ADR-0004 accepted with numbers, and the documents in §7.

**As built (W8):**
- **[PHASE_2_REPORT.md](PHASE_2_REPORT.md):** every gate with its evidence and run ids, the ADR-0004 tables (§7.1), the large-file numbers, the artifacts, the parked owner checks, the deviations and the full gate history.
- **The documents in §7 are synced:**
  - EDITOR_ARCHITECTURE: its status, and §2's protocol list, which now names `search.state`;
  - ADR-0004: its status at the phase exit;
  - SECURITY: §3, with the shipped page's hashes and renderer crashes recovered by the journal, and §4, with Android Auto Backup;
  - TESTING: §1.2 totals, §5 and §6;
  - BUILD_AND_RELEASE §2.2: the editor job and the gate's groups;
  - ARCHITECTURE §2.7, TECH_STACK and PERFORMANCE §4;
  - CHANGELOG, ROADMAP and README.
- **Found while syncing: Android Auto Backup.** The manifest sets neither `android:allowBackup` nor `android:dataExtractionRules`, so Android's Auto Backup can copy the workspace, the database and the settings to the user's Google Drive. SECURITY §4 had said there was no cloud sync. Report §1 puts the choice to the owner; W8 changes no code.
- **Found in the review: tab state is visual only.** TalkBack reads each tab's file name and "Close <file name>", but not which tab is active or has unsaved changes. Report §9.2 proposes the semantics fix for Phase 3's first package.
- **Not built:** the on-disk log sink carried in from Phase 1 (§0). It is proposed for Phase 3.
- **Evidence:** documentation only. The final tree is CI 42678576228 and phase gate 42676631509 (W7, Step 3).
- **Gate status:**
  - **G9 Docs:** met, subject to the owner's review of the report.

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
