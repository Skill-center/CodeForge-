# Editor Architecture

**Status:** Phase 2 in progress: the CodeMirror 6 page (W1) and its WebView host (W2) are built. **The engine is decided: CodeMirror 6** (ADR-0004 Accepted 2026-11-06, after the W3 benchmark on the emulator and the owner's low-end phone)

---

## 1. Engine decision: CodeMirror 6 (decided in W3; Monaco challenged and measured)

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

### As built in W3: how the gate measures

Both benchmark pages come from `editor/bench/` (`npm run build:bench`). They are built with the same page kit as the editor page (`editor/tool/page_kit.mjs`: one self-contained document, a hash-pinned CSP, the licence gate and the notices) into `app/assets/editor_bench/`. That directory is gitignored and is built only for the phase gate and the phone APK. Monaco 0.57.0 is a dev dependency, never part of the shipped editor page. It runs without web workers, through its own in-process fallback, and with a small hand-written JSON Monarch grammar, because 0.57 ships none.

| Metric | How it is measured | By |
|---|---|---|
| Cold load | navigation start → the first frame painted after the editor is mounted | the page (`bench/harness.ts`) |
| Typing (engine path) | 60 characters through the engine's own typing path, each timed to the end of the next frame | the page |
| Input → frame | 60 keys sent as DevTools `Input.insertText`, each timed from its first input event to the end of the next frame (`bench/input_recorder.ts`) | DevTools driver |
| Composition | 9 cases sent with `Input.imeSetComposition` / `Input.insertText`, each document compared with the expected text: Latin predictive, autocorrect replacement, pinyin, Japanese, Hangul, emoji, cancelled composition, mid-line and backspace inside a composition | DevTools driver |
| 1 MiB file | open time, typing p95 in the middle of the file, and the share of frames over 32 ms during 3 s of scripted scrolling | the page |
| Memory | total PSS of the app process plus its WebView renderer processes (`dumpsys meminfo`) after the scripted session, which takes minutes rather than the ADR's 10 | DevTools driver |
| Size | gzip size of the self-contained page | the build manifest |

- **In the phase gate:** `app/integration_test/editor_bench_test.dart` drives Settings → Developer → Editor benchmark on the debug APK. It runs 3 fresh WebViews per engine in ABBA order and reports medians. It then hands each engine's page to `editor/tool/bench_cdp.mjs`, which reaches the WebView's DevTools socket over adb. `editor/tool/bench_report.mjs` merges both into `app/ci-results/gate/editor_bench.json` and `.txt`, with every value checked against its budget. A budget miss is evidence for the decision, not a gate failure; the gate fails only when a run cannot complete.
- **What the emulator can show:** the CI emulator composites the WebView in software (swiftshader) and runs a debug APK. Its first gate run (42206498197) reached about 7 fps for both engines while scrolling. Its frame-timed numbers (typing, input, scrolling) and its memory therefore compare the engines but don't test the absolute budgets; those need hardware. Cold load, composition correctness and size are meaningful on the emulator as they are.
- **On a phone:** the same screen runs the in-page suite and an on-screen typing check per engine through the real keyboard: the document is compared with the expected phrase, and keyboard input → frame latency is recorded. The profile arm64 APK from the phase gate carries the pages; steps are in `docs/phases/PHASE_2_PHONE_CHECKLIST.md`. A profile build has no DevTools socket, so the phone provides no driver numbers (DevTools input latency, composition cases, memory).

## 2. Integration topology

```
Flutter (Dart)                      WebView (bundled assets only)
┌──────────────────────┐   JS bridge ┌─────────────────────────────┐
│ DocumentController   │◄───────────►│ protocol.ts (validated)     │
│  tabs, dirty, saves  │  messages   │ CM6 EditorState per doc     │
│ EditorHost: shadows  │             │ one EditorView, swapped     │
│  journal (W5)        │             │ mobile extensions:          │
│  LSP routing (Ph. 6) │             │  symbol toolbar hooks,      │
└──────────┬───────────┘             │  indent/fold/brackets,      │
           │ Dart calls              │  search panel, completions  │
┌──────────▼───────────┐             └─────────────────────────────┘
│ FileService (dart:io)│  one app-private workspace (W4);
│  SAF broker: Phase 3 │  canonical root, atomic writes
└──────────────────────┘
```

- **One WebView, many documents.** CM6 `EditorState` per open tab; switching tabs swaps state into the single `EditorView` (cheap, keeps scroll/undo per state). Avoids N WebViews (memory, R6).
- **Dart owns truth for persistence; CM6 owns truth for live editing.** On open: Dart reads the file through `FileService` (strict UTF-8; the byte-order mark and line-ending style are noted and stripped) → `doc.open(id, text, language)`. While editing: CM6 applies changes locally at 60 fps and emits **change sets** (CM6 `ChangeDesc` JSON: retain/insert/delete spans), debounced ~150 ms and flushed on blur, save and tab switch. Dart applies them to its shadow buffer, which the W5 journal will make crash-safe. On save: Dart takes a snapshot (which flushes pending changes), encodes it in the file's own format and writes it atomically (temp file, flush, rename). A file changed outside the app since it was read is caught at save time by its stamp, and the user decides whether to overwrite. Reloading a file when it changes on disk needs file watching (Phase 3), which will use `doc.replace`. Details: §6.
- **No full-document sync per keystroke** (spec §6.3). Full text moves only on open, save-conflict resolution, and recovery.
- **Protocol v1** (`editor/src/protocol/` ↔ `app/lib/core/editor/protocol.dart`): envelope `{v: 1, id, type, payload}`, strict on both sides (unknown type, version or field → rejected and logged). Host → editor: `editor.configure`, `doc.open/activate/close/replace/flush/snapshot/setLanguage`, `cmd.insert/exec/gotoLine`, `search.set`. A snapshot answers with the text, version and main selection, plus `scrollTop` for the active document (the only one with a laid-out view). Editor → host: `editor.ready`, `doc.changed`, `doc.viewState`, `editor.history`, `editor.focus`, `ime.composition`, `app.shortcut`, `editor.log`, and `response` (correlated by id, with timeouts). Contract tests: the same JSON fixtures (`editor/test/fixtures/`) run in vitest and in `app/test/core/editor_protocol_test.dart`. Later work adds types, each with fixtures on both sides: W4 added `doc.setLanguage` (Save As to a new extension re-highlights the same document); external changes come with file watching (Phase 3) and LSP passthrough with Phase 6.
- **Host and recovery** (`app/lib/application/editor/editor_host.dart`): the host keeps a shadow copy of every open document and applies each `doc.changed` to it only if it follows on exactly (base version, lengths); anything else is refused and the shadow is rebuilt from a snapshot. Whenever the page announces `editor.ready` (first start, reload, restart), the host replays the configuration and reopens every document from its shadow, selection and scroll included. The host reports ready as soon as the page announces itself, before that replay finishes. Commands that need the page to hold the document therefore wait for a replay in flight: `doc.activate`, `doc.snapshot`, `doc.flush` (and so `doc.replace`), `doc.setLanguage`, `cmd.insert` and `cmd.exec`. With no replay in flight they go out at once, in call order. A delayed `doc.activate` is dropped when another document was activated meanwhile. `doc.open` and `editor.configure` never wait, because the replay is built to run alongside them. Until W5's gate caught it (run 42379885027), a command in that window reached a page with no active document. A WebView renderer crash cannot be caught (the plugin exposes no `onRenderProcessGone`), so it ends the app process, and unsaved text comes back from the hot-exit journal (§7).

## 3. Mobile editing experience (spec §4.4)

- **Symbol toolbar** (Flutter widget above IME): customizable row — `Tab ⇥ {} [] () ; : = > < " ' | & $ # ~ \` _ /` + undo/redo + cursor arrows + dismiss-keyboard. Long-press for paired variants. Config per language; hardware keyboard attached → toolbar collapses to a slim strip.
- **Selection visibility:** the active line is highlighted only around a plain cursor, never while text on it is selected (`editor/src/editor/active_line.ts`). The host sends the active-line colour as an opaque, contrast-tested token, and CodeMirror draws selections beneath the lines, so a highlighted line would hide its own selection. The phone run in W3 found exactly that.
- **IME integration:** CM6 runs in contentEditable mode; Flutter side uses `SystemChannels.textInput` awareness only for toolbar insets — the WebView owns its IME session (no double-IME). Tested matrix: Gboard swipe, voice, CJK, RTL, emoji, physical keyboard.
- **Shortcuts (hardware):** editing keys (Ctrl+F/H/Z/Y/Shift+Z, Ctrl+G, Ctrl+/, Ctrl+D, Alt+↑/↓) are CM6 keymap. App-level shortcuts work wherever the keyboard focus is: §6 "Shortcuts".
- **Tabs & dirty state:** Flutter tab strip (scrollable, close buttons, dirty dot), with state in `DocumentController` (§6 "Documents and tabs"). Tabs reopen after a restart from W4. Unsaved text survives process death from W5's journal (Phase 2 acceptance: kill mid-edit → reopen → zero loss).

## 4. WebView hardening (summary; full: SECURITY.md)

As built in W1–W2: one self-contained page, loaded with `loadHtmlString` under `https://appassets.androidplatform.net/`. `WebViewAssetLoader` is unreachable, because the plugin exposes no request interception. The CSP is `default-src 'none'; script-src 'sha256-<build hash>'; style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'`. File and content access are off, geolocation is off, and every navigation is refused. The bridge is one JavaScript channel taking a JSON string, which is schema-validated, size-capped and rate-limited. Nothing remote is evaluated, and the page's SHA-256 is checked against its manifest before it loads. The W3 benchmark pages follow the same rules: they are verified the same way and hardened the same way.

## 5. Fallback posture

If WebView editing proves unreliable on target devices after the gate, the documented fallback is a **native Flutter editor surface** (custom render of a rope/text-buffer with CM6-like keymaps) — a major investment, deliberately out of scope unless the gate forces it. We do not silently degrade to a plain TextField and call it an IDE.

## 6. Files, documents and tabs (as built in W4)

### Files

- **One app-private workspace in Phase 2.** `LocalFileService` (`app/lib/services/files/local_file_service.dart`) works in `<filesDir>/workspaces/demo`. MainActivity answers a single method, `filesDir`, on the `dev.codeforge/paths` channel; path_provider is not used (TECH_STACK.md §4). The first open writes the demo project into `<root>.seeding` and renames it into place, so a half-written demo never looks like a workspace. Picking a folder through the system (SAF) is Phase 3.
- **Paths are checked twice.** They are workspace-relative and `/`-separated. First as text (`app/lib/core/files/workspace_path.dart`): absolute paths, `.` and `..`, empty segments, control characters, the characters `\ : * ? " < > |` (other systems' separators, and what FAT-formatted storage cannot hold), over-long names and paths, and the save temp suffix are refused with a sentence the UI shows. Then on disk: the deepest existing ancestor, with symbolic links resolved, must lie inside the canonical (symlink-free) root. A link that stays inside works; a link that points out is refused (`outsideWorkspace`). Listings skip links and save temp files.
- **Reading.** Files up to 16 MiB; larger ones are refused (`tooLarge`; W7 measures large files). The file is stat'ed before and after reading, and read again if it changed meanwhile, so the stamp always matches the bytes. The codec (`app/lib/core/files/text_codec.dart`) decodes strict UTF-8. A byte-order mark is removed and remembered. Line breaks become `\n` for the editor and the file's style is remembered: CRLF when CRLF and lone CR breaks are the majority. Files that mix styles are flagged, and their line-ending chip turns amber; saving writes one style throughout. UTF-16/32 byte-order marks, NUL bytes and malformed UTF-8 are refused as `notText` with a reason; nothing is converted.
- **Writing is atomic.** The text is encoded in the remembered format and written to `.<name>.cf-tmp` beside the target, then flushed, closed and renamed over the target. A failure at any step deletes the temp file and leaves the target as it was; `test/services/local_file_service_test.dart` interrupts a save just before the rename to prove it. The data reaches the device before the rename, and the rename replaces the file in one step, so after a crash the file is the old version or the new one, never a mix of the two.
- **Conflicts are caught at save time.** Each document keeps the stamp (modified time and size) it was read or last saved with. A save passes it on, and if the file changed since, the save stops with `changedOnDisk`; the workbench asks before overwriting. Without file watching (Phase 3), an outside change is noticed when saving, not when it happens.
- **Failures are typed.** Every operation returns a `FileFailure` with a `FileProblem` (`notFound`, `exists`, `wrongType`, `invalidPath`, `outsideWorkspace`, `notText`, `tooLarge`, `changedOnDisk`, `inUse`, `io`) and a message written for the user.

### Documents and tabs

- **`DocumentController`** (`app/lib/application/documents/document_controller.dart`) holds one `OpenDocument` per tab, keyed by path: its editor document id, language, file format, last saved text and stamp. The live text is the editor host's shadow, kept current from the page's change sets. *Dirty* means the shadow differs from the saved text, recomputed on every change (lengths first), so undoing back to the saved text clears the dot.
- **Save** takes a snapshot, which flushes pending edits, writes it, and records it as the saved text. Typing that lands while the file is being written is not on disk, so the tab stays dirty. Saves of one file run one at a time, in the order they were asked for.
- **Save As** writes the snapshot to the new path, creating the file unless the user confirmed replacing it, and then moves the tab. The editor document id stays the same, so the page keeps its cursor, scroll and undo history. The language is detected again from the new name and sent with `doc.setLanguage`. The original file stays as it was. A path that is open in another tab is refused (`inUse`).
- **New File** creates an empty file, refusing an existing path, and opens it.
- **Close** never asks by itself: the workbench (`app/lib/features/workbench/file_actions.dart`) first offers Save / Don't Save / Cancel for a tab with unsaved changes. The active tab falls back to the most recently used other tab. *Close others* asks about each unsaved tab, showing it while it asks, and Cancel stops there.
- **Language detection** goes by extension, then by whole file name (`.babelrc`, `.eslintrc`, `*.webmanifest`), then by the shebang of a file without a known extension (`node`, `deno`, `bun`, `ts-node`, `python3.x`, `pypy`; `env -S` and `NAME=value` are skipped). An explicit `.txt` stays plain text.
- **Restore.** The tab order and the active tab are part of the shell state (`codeforge.shell.v1`, debounced and flushed on pause). On start, the workbench opens the workspace and reopens those tabs, once per app run. Files that have gone are skipped, and with nothing to reopen, `main.js` opens. *Since W5, tabs (with their cursor and scroll) and unsaved text live in the app database; see §7.*
- **The tab strip** builds every tab and scrolls the active one into view, moving only as far as needed. The status strip shows the active document's language, its line endings (amber when mixed) and BOM.

### Shortcuts

App shortcuts work wherever the keyboard focus is. While Flutter has focus, the workbench binds them with `CallbackShortcuts`. While the editor page has focus, hardware keys never reach Flutter, so the page's keymap forwards them as `app.shortcut`, after flushing pending edits. Both paths, and the palette's commands, become one `WorkbenchIntent` (`app/lib/application/workbench_intents.dart`), which the workbench carries out because only it can show dialogs.

| Keys | Intent |
|---|---|
| Ctrl+S | Save |
| Ctrl+Shift+S | Save As |
| Ctrl+N | New File |
| Ctrl+W | Close tab (asks if unsaved) |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab, wrapping |
| Ctrl+Shift+P (F1 in the page) | Command palette |

## 7. Zero-loss editing: the hot-exit journal (as built in W5)

Spec §4.4: never lose text, never corrupt a file, never jump the cursor. Saving stays the user's decision. The journal keeps the unsaved text safe in the meantime, so that killing the app or a crash of the editor's renderer loses nothing typed (gate G4). The storage side is in ARCHITECTURE.md §2.6 and the ADR-0008 amendment.

### What is written, and when

- **Change sets, as they arrive.** The page reports every edit as a CodeMirror change set with its base version, new version and the text length before and after (§2). The host applies it to its shadow and passes it on as `DocumentEdited(docId, version, change: JournalChange)`. If the edit makes the document dirty, `DocumentJournal` appends the change to its journal.
- **A snapshot, from which the changes continue.** A snapshot is the document's full text at a known version. One is taken:
  - at the first unsaved edit;
  - when the user switches tabs (for the tab being left);
  - on pause, and on `checkpoint()`;
  - every 5 s while new changes arrive (documents over 512 KiB at most once a minute);
  - after 200 changes, so a replay stays short;
  - whenever a change does not continue the last one written: a version gap, or a whole-text replacement such as a resync after a refused change or "Use the file".

  Each snapshot replaces the document's stored changes in one transaction.
- **Gone when clean.** A document that becomes clean again loses its journal: saved, closed with "Don't save", or typed or undone back to its saved text. A save while typing continues rebases the journal onto the new saved text. Save As moves it to the new path.
- **Cursor and scroll.** The page reports `doc.viewState` after the cursor or scroll settles (`ViewStateChanged`). The controller saves the tabs at most once a second after such reports, and also when tabs open, close or switch, and on pause.
- **Failures.** Writes go through one queue, in order. A failed write marks every journal as needing a fresh snapshot, so later changes are never appended to a journal that is missing its base. The timer then retries without waiting for new edits. While writes fail, the editor shows a banner saying unsaved changes are not being backed up. It disappears after the next successful write.

### What a cold start does

`DocumentController.restoreTabs` loads the saved tabs. On the first W5 start it imports the shell envelope's tabs instead (ARCHITECTURE.md §2.6). It then adds any document that has a journal but no tab, and for each journal:

1. **Replays** the snapshot and its changes in order (`replayJournal` in `app/lib/core/editor/journal.dart`). Changes at or below the snapshot's version are skipped. Replay stops, keeping the text so far, at a version gap, a length that does not match, or a change set that does not apply. Damage after that point is dropped, never guessed at.
2. **Reads the file** and compares it with the replayed text and with the journal's `baseDigest`, the SHA-256 of the saved text the edits were made against:
   - The replayed text equals the file: the journal goes and the document opens clean.
   - The file is the one the edits were made against: the document opens **dirty**, with the replayed text, cursor and scroll.
   - **The file changed meanwhile:** the document opens dirty with the user's text. The saved text is now the file's, and the conflict is `changedOnDisk`. The workbench shows the tab and asks: **Keep my changes** (they become unsaved changes to the file as it now is) or **Use the file** (the editor text becomes the file's and the journal goes). Closing the dialog keeps the user's text and asks again on the next start, so nothing is decided for the user.
   - **The file was deleted:** the same question, with "Discard changes" instead of "Use the file". Keeping the changes and saving creates the file again.
   - **The file cannot be read:** the document opens dirty, as `unreadable`.
3. **Rewrites the journal** as one snapshot of the replayed text, so the next start replays from there. Until the user answers, that snapshot keeps the old `baseDigest`, so an unanswered conflict is still a conflict after another restart.

The editor document is opened at the replayed version, with the saved selection and scroll. The page therefore continues the version sequence, and the next change appends to the journal without starting over.

### Renderer crashes and rotation

webview_flutter_android 4.14.1 does not expose `onRenderProcessGone`, so when the WebView renderer dies, Android ends the app too. The journal does not need a separate recovery path for that case: a renderer crash is a process death, and the next start restores as above. The emulator gate's edit pair checks exactly that (TESTING.md §1.2). It crashes the renderer of a running app that has unsaved text, then checks the text, the dirty dot and the cursor after relaunch. Rotation keeps the process: the manifest handles orientation and size changes, so Android does not recreate the activity. It also keeps the page. Rotating swaps the workbench's portrait layout for the docked one, and the editor pane moves across under one `GlobalKey` instead of being rebuilt. The page therefore keeps every document's undo history and does not reload. The edit pair checks that on the emulator: `edit_b` rotates to landscape and back, and the page must not restart. Until W5 the page reloaded on rotation, and the host restored text, cursor and scroll from its shadows. The journal is not involved.
