# Changelog

All notable changes to CodeForge. Format: [Keep a Changelog](https://keepachangelog.com/); versions: SemVer. Phase milestones tag `v0.N.0`; public release starts at `v1.0.0` (Phase 10).

## [Unreleased]

### Added — Phase 2, in progress (plan: [phases/PHASE_2_PLAN.md](phases/PHASE_2_PLAN.md))
- **W1 editor page** (`editor/`): a CodeMirror 6 page in TypeScript speaking protocol v1, validated in both directions, with batched incremental change sets and highlighting for JavaScript/JSX, TypeScript/TSX, Python, JSON, HTML, CSS and Markdown. It builds to one self-contained, reproducible HTML file with a hash-pinned CSP, and comes with a runtime licence gate, a bundle verifier and a CI `editor` job.
- **W2 host and bridge:** the editor runs in the app, in the Android System WebView (`webview_flutter` 4.14.1) behind an `EditorSurface` interface. The page is checked against its manifest SHA-256 before it loads, and the WebView is locked down: no navigation, no file or content access, no dialogs, remote debugging only in debug builds.
- **Protocol and host:** a Dart mirror of protocol v1 is proven against the shared fixtures. The host correlates requests and responses with timeouts and rate-limits the page. It keeps a shadow copy of every open document, applies only exactly fitting changes (anything else triggers a snapshot resync), and reopens every document from the shadows whenever the page restarts.
- **Editor tabs drive the editor:** opening a tab opens its document, and typing marks the tab dirty. Save writes the editor's text: the tab strip's Save button, the palette's Save File, or Ctrl+S while the editor has focus. Typing during a save keeps the tab dirty.
- The editor's appearance follows the app theme, the editor font size and the system text scale. The page's npm licences appear on the app's licences page.
- Tests: the protocol contract on both sides, editor core and host units, page verification, editor widget tests, and an emulator test of the real page in the WebView, now part of the phase gate.
- **W3 engine benchmark:** CodeMirror 6 and Monaco 0.57.0 benchmark pages at identical scope (`editor/bench/`: six-language highlighting, find/replace, a stub completion popup), built with the editor page's kit and verified by hash before they run. The phase gate runs both in the real WebView: 3 fresh runs per engine, then a DevTools driver (`editor/tool/bench_cdp.mjs`) for input → frame latency, 9 composition cases (CJK, Hangul, emoji, autocorrect, cancel) and process memory. The merged results, with every ADR-0004 budget checked, go to `app/ci-results/gate/editor_bench.json`. The first emulator results (phase gate 42206498197) are recorded in ADR-0004.
- **Settings → Developer** (debug and profile builds only): *Editor benchmark* runs the same suite on a device plus a typing check through the real keyboard, and copies the results as JSON. *Frame timing* records frame build and raster times against the 16.7 and 32 ms lines. The phase gate also publishes a profile arm64 APK carrying the benchmark pages (artifact `codeforge-phone-profile-arm64`) for phone runs.

- **W4 real files and tabs:** the editor opens, edits and saves real files in an app-private workspace folder. The first run writes the demo project there. Saves are atomic (temp file, flush, rename), so an interrupted save leaves the old file. A file keeps its byte-order mark and CRLF or LF line endings. Binary files, invalid UTF-8 and UTF-16 are refused with a reason, never converted. A file changed on disk since it was opened is not overwritten without asking. Paths cannot leave the workspace, through `..` or through symbolic links.
- **Documents and tabs:** many open files, each keeping its own cursor, scroll and undo; dirty dots that clear when undo returns to the saved text; Save As (the tab follows, with its history) and New File; closing an unsaved tab asks Save / Don't Save / Cancel; Close others; tabs reopen after a restart. Language detection adds file names (`.babelrc`, `.eslintrc`) and shebangs (`node`, `deno`, `bun`, `python`, `pypy`). The status strip shows line endings and BOM.
- **Shortcuts:** Ctrl+S, Ctrl+Shift+S, Ctrl+N, Ctrl+W, Ctrl+Tab / Ctrl+Shift+Tab and Ctrl+Shift+P work whether the editor or the app has the keyboard.
- W4 verified by CI 42238016497 (`+431: All tests passed!`) and phase gate 42238016973, where the on-device file and tab checks and the restore pair passed on attempt 1 (gates G2 and G3).

- **W5 zero-loss editing:** unsaved text survives the app being killed and a crash of the editor's renderer. A hot-exit journal in the new app database keeps each unsaved document as a snapshot plus the editor's change sets since, written as you type. The next start replays it and reopens the document still unsaved, with its cursor and scroll. A file that changed or was deleted meanwhile keeps both texts and asks: keep my changes, or use the file. A banner says when unsaved changes cannot be backed up.
- **App database** (`codeforge.sqlite`, Drift 2.35.3, schema v1): workspaces, open tabs with each tab's cursor and scroll, and the journal. It opens lazily in a background isolate, and SQLite comes from the `sqlite3` package's prebuilt, hash-checked libraries. A migration test harness starts with v1.
- Tests: journal replay against the live text for randomized edit sequences; the journal's write order, failure recovery and timers; the database on real SQLite, including a v1 fixture through drift_dev's schema verifier; process death, conflicts, deleted files and damaged journals in controller and widget tests. The emulator gate gains an edit pair: type without saving, crash the WebView renderer, force-stop, relaunch, then check the text, the dirty dot and the cursor.

### Fixed — Phase 2
- **Editor commands in the moment after the editor page starts could fail** with "no document is active". The host reports ready when the page announces itself and reopens the documents just after that. A toolbar key, shortcut, save or snapshot sent in between reached a page with no document. Such commands now wait for the reopen. Found by the W5 zero-loss gate (phase gate 42379885027, `edit_a`).
- **Rotating the phone reloaded the editor page**, which cost every open document its undo history. Text, cursor and scroll were restored from the host's copies. Portrait and landscape use different workbench layouts, and the editor pane was rebuilt in each. It now moves between them under one key.
- **Selected text on the cursor's line was invisible**, in the editor and in the benchmark page: the copy menu and handles appeared, but no highlight. The active line's opaque background covered CodeMirror's selection layer. A line is now highlighted only around a plain cursor, as in VS Code (`editor/src/editor/active_line.ts`). The owner found this in the W3 phone run. Verified in CI 42216855073 and phase gate 42216855184.

### Changed — Phase 2
- **Open tabs moved from the shell envelope to the app database**, imported once on the first W5 start; each tab now also gets back its cursor and scroll (ARCHITECTURE.md §2.6 has the migration note).
- **ADR-0008 amended:** buffer journals live in SQLite, not files, because a snapshot must replace the changes it covers in one transaction.
- CI: bootstrap mode generates Drift's code and migration helpers and commits them; every run checks the committed copies are current, and the phase gate generates them before building. Dependency resolution output is kept for the diagnostics commit.
- **ADR-0004 accepted: CodeMirror 6** is the editor engine. It was measured against Monaco on the CI emulator and on the owner's low-end phone (realme C51), where it met the cold-load and typing budgets. Large-file typing and scrolling, memory, and selection handles at line boundaries are carried to W6/W7.
- Phase 1's parked G6 check is complete: 3.4 % of navigation frames over 32 ms on the owner's phone (budget 5 %).
- The benchmark's typing check now says what to do and shows each result (match, or where the text differs and what the editor holds) next to its buttons.
- The workbench's read-only code preview and its banner are replaced by the real editor. The symbol toolbar stays visible but disabled until W6. The workspace goldens change accordingly.
- The palette's save command is now "Save File" (category File). The demo "simulate edit" command is removed.
- SECURITY.md §3 now describes the WebView exactly as configured, including what happens when its renderer crashes. EDITOR_ARCHITECTURE.md §2 lists the real protocol v1 types.
- CI: every test run is time-bounded (2 minutes per widget test; 10 and 15 minutes for the golden and full runs). Golden generation runs only the golden suites and keeps its log, and failing tests leave their last lines as a check-run annotation.
- The editor workspace's page building is shared (`editor/tool/page_kit.mjs`) by the editor page and the benchmark pages; the editor's colour palette moved to `src/editor/palette.ts` so a page can use it without CodeMirror. The editor job's `npm run ci` also builds the benchmark pages. Test builds show the Developer section at the end of Settings.
- EDITOR_ARCHITECTURE.md §4 now describes the WebView as built (inline page, hash-pinned CSP) instead of the Phase 0 asset-loader plan.
- Protocol v1 gains `doc.setLanguage`, and snapshots report the active document's scroll position.
- The editor tabs controller is replaced by `DocumentController`; the in-memory file service fake is gone from the app (tests have their own). The explorer lists the real workspace folder and offers New File. Features reach files only through application controllers, which the import lint now enforces.
- The empty editor offers New File instead of reopening the demo file.

### Added — Phase 1 (2026-11-06) · evidence: [phases/PHASE_1_REPORT.md](phases/PHASE_1_REPORT.md)
- Flutter app (`app/`, `dev.codeforge.app`): pinned toolchain (Flutter 3.47.9; AGP 9.1.0 · Gradle 9.3.1 · Kotlin 2.4.0 from the template; compile/target 36, minSdk 26).
- "Forge" design system: colour/spacing/radius/motion/typography tokens (bundled Inter + JetBrains Mono), dark and light themes, components (buttons and icon buttons, banner, empty state, status chip, file-tree row, settings tiles, and workbench chrome: activity bar, nav rail, tab strip, status strip, symbol toolbar), debug-only gallery.
- Screens: home with a first-run welcome, adaptive workbench (compact, medium, expanded; portrait and landscape) with a demo-workspace explorer and honest Search/Run/Git/Extensions placeholders, a terminal panel (laid out at closed/peek/half/full stops; the top bar toggles closed ↔ half), editor tabs on a demo workspace, command palette (Ctrl+Shift+P), settings (appearance, about).
- Services as interfaces with in-memory fakes; Riverpod controllers; versioned, tolerant `shared_preferences` envelopes for settings and shell layout; restore of the last route, theme and panel state after process death.
- Navigation: deep links resolve; unknown locations land on home; system and predictive back return home from top-level destinations and leave the app only from home.
- Keyboard-safe layouts: with the soft keyboard up the terminal yields (hidden below 60 dp), and the editor pane, nav rail and command palette never overflow. This was found by the emulator phase gate, which caught a real overflow that no widget test covered.
- CI: `ci.yml` (format, analyze, import-boundary lint, license gate, lockfile drift, tests with coverage, debug APK with SHA-256) and `phase-gate.yml` (KVM-accelerated API 36 emulator: smoke, process-death restore pair, release cold-start sampling, `perf.json`), with committed evidence under `app/ci-results/`.
- Tests: unit, widget, accessibility (Android tap-target + labeled-target guidelines, 48 dp ink targets, 1.3× text scale), soft-keyboard insets, WCAG contrast gate, typography tokens, goldens (gallery in both themes; home and workspace at six gate sizes in dark plus two light spot checks; settings), integration.

### Changed — Phase 1
- UI_DESIGN_SYSTEM v1.1: light-theme ember accent `#E85D2A` → `#B93E0C` (2.98:1 → 4.78:1) and AA-compliant semantic colours; chrome bars are 48 dp touch rows plus a 1 px hairline; status chips are display-only.
- TECH_STACK: Android build pins are now the CI-proven template defaults (Phase 0 candidates were AGP 8.13 / Gradle 9.2.1 / NDK 27.2); the emulator gate uses `google_apis` + KVM instead of `aosp_atd` + software emulation.
- Rendering uses Skia in Phase 1 (Impeller disabled pending hardware validation).

### Added — Phase 0 (2026-11-05)
- Complete Phase 0 technical audit of the existing Linux environment (`m-cyber12/t1` @ `0e26d7a`, PR #81): sealed execution model, runtime versions, sizes, CI evidence, license findings — `docs/EXISTING_RUNTIME_AUDIT.md`.
- Phase 0 report with spec corrections, risk register, and acceptance status — `docs/PHASE_0_REPORT.md`.
- Architecture, tech stack (versions verified 2026-11-05), repository structure, runtime integration, editor/terminal/LSP/extension designs, security model, testing strategy, performance budgets, build/release design, UI design system v1.
- 11 Architecture Decision Records (`docs/adr/`).
- Detailed Phase 1 MVP implementation plan — `docs/phases/PHASE_1_PLAN.md`.
- Project process docs: README, AGENTS.md, CONTRIBUTING.md, ROADMAP.

### Decisions locked by owner (2026-11-05)
- minSdk 26 (reconciliation gate ADR-0007 in Phase 4); distribution GitHub-first + Play-compatible; license pending (ADR-0011).

### Notes
- Phase 0 was analysis-only by instruction; CI became the build authority in Phase 1.
- Phase 1 known limitations (details in the report): navigation frame-time profiling (G6) is carried to Phase 2; cold start is measured on a CI emulator, not hardware; the TalkBack spot-check is an owner action on a device.
