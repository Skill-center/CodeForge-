# Changelog

All notable changes to CodeForge. Format: [Keep a Changelog](https://keepachangelog.com/); versions: SemVer. Phase milestones tag `v0.N.0`; public release starts at `v1.0.0` (Phase 10).

## [Unreleased]

### Changed — Phase 4 W1, toolchain (plan: [phases/PHASE_4_PLAN.md](phases/PHASE_4_PLAN.md))
- **Flutter 3.50.0**, with the Android pins of its template: Kotlin's Gradle plugin 2.4.20 and Gradle 9.5.0, and Android Gradle Plugin 9.3.3, the latest patch of the template's 9.3 line, because 9.3.1's lint crashes release builds on JDK 17. Upgraded together as the owner decided.
- **The Material widgets come from `package:material_ui`** (1.10.0), because Flutter 3.50 deprecates the framework's copy. All 87 files that imported it moved, by Flutter's own fix, and analysis now flags any new import of the old library. The app looks the same: none of the 26 golden images changed.
- **Screens still change without a transition.** The router builds the same transition-free pages go_router used before; go_router would otherwise have switched to Material's transitions once the app used `material_ui`.
- **Release builds work on Flutter 3.50.0.** Its Dart compiler crashes when building a release or profile app containing one shape of code ([dart-lang/sdk#64917](https://github.com/dart-lang/sdk/issues/64917)), which Home's folder reconnect had; that code is restructured, with the same behaviour.
- **CI builds a release APK on every run**, so a failure that only release builds show is caught there, not first in the phase gate. The phase gate keeps the logs of its builds with its evidence.
- **CI uses the Node 24 versions of GitHub's actions** (checkout, setup-java, cache, upload-artifact, download-artifact, setup-node), each read against its release notes.
- The debug APK is about 1.9 MB smaller: 175,890,252 bytes, from 177,806,969 at Phase 3's exit.
- Verified by CI 43373527631 (`+846: All tests passed!`; analysis clean; 44 Kotlin tests).

### Licence decided (2026-11-12)
- **CodeForge is licensed under the Apache License 2.0** (`LICENSE`; the owner's decision, [ADR-0011](adr/0011-license.md) path B). By ADR-0006's rule the terminal frontend is therefore xterm.js: Termux's GPLv3 terminal modules are never vendored, and Phase 5 writes the PTY. t1 takes the same licence before Phase 4 vendors its code.

### Phase 4 planned (2026-11-12)
- [PHASE_4_PLAN.md](phases/PHASE_4_PLAN.md): runtime integration in seven work packages, starting with the toolchain upgrade (Flutter 3.50.0, AGP 9.3.1, Kotlin 2.4.20, Gradle 9.5.0, and the move to `package:material_ui` that 3.50 requires). The vendoring waits for the licence decision (ADR-0011). Found while planning: t1's code was merged as PR #229; Firebase Test Lab shuts down on 2027-09-30.

### Phase 3 accepted (2026-11-12)
- The owner accepted Phase 3 and decided: the exit phone session runs after the next slice of work; G7's cold start is judged by that session's phone figure, and Impeller stays; FULL against NORMAL (ADR-0008) moves to Phase 4's Firebase Test Lab runs; Flutter 3.50.0, the Android Gradle Plugin and Kotlin's Gradle plugin are upgraded together ([PHASE_3_REPORT.md](phases/PHASE_3_REPORT.md) §1).

### Changed — Phase 3 W7, documentation and phase exit (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md); report: [phases/PHASE_3_REPORT.md](phases/PHASE_3_REPORT.md))
- **What's still to come names the right phase:** Settings no longer lists folders as coming (they open from Home since Phase 3), and gives extensions Phase 8. The workbench's panels say search arrives in Phase 4, source control in Phase 7, extensions in Phase 8, and running in Phase 5 with debugging in Phase 9. The status bar's branch chip says Git arrives in Phase 7. The search panel points to Go to File for finding a file by name.
- **Phase 3's report** ([PHASE_3_REPORT.md](phases/PHASE_3_REPORT.md)): every gate with its evidence, the measurements, what is not reliably met (the release cold start on the emulator with Impeller, over the budget in two of five gates), and four decisions for the owner.
- **One phone checklist for the exit session** ([PHASE_3_PHONE_CHECKLIST.md](phases/PHASE_3_PHONE_CHECKLIST.md)): every check parked since Phase 1, about 75 minutes on the exit gate's profile APK.
- **Docs synced** with Phase 3 as built: architecture (the broker, Pigeon, the data model), editor files, security (the storage review done), runtime storage model, tech stack, performance, design system, roadmap and README.
- W7 verified by CI 43284276980 (`01:38 +846: All tests passed!`) and phase gate 43284276984 (every group on its first try; cold start 1302 ms).

### Added — Phase 3 W6, tests, performance and quality (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Impeller:** the app now draws with Impeller, Flutter's default renderer, instead of Skia, which Flutter 3.47 deprecates as an opt-out. Every phase-gate group passed with it on the CI emulator. There, with software graphics, it starts the app 0.3 to 0.5 s slower than Skia, and in two of four runs over the 1.5 s budget. The phone check before the phase ends decides.
- **No pause when a very large file is first edited or restored:** the fingerprint CodeForge keeps of a file's saved text, to know after a restart whether the file changed, is taken in the background for files of 64 KiB and more. On the emulator, the screen kept drawing while 10 MiB was fingerprinted (13 or 14 frames, at most 96 to 140 ms apart); before, it stopped for 260 to 280 ms.
- **Log viewer** (Settings → Developer, in debug and profile builds): this session's log, newest first, narrowed by level and by tag, following new entries and copying what it shows. Entries are redacted as everywhere else.
- **Failures inside the app's state are logged**, redacted like every other entry, so a problem that shows no message still leaves a trace in the log.
- **Measured on the emulator,** in three runs: a project of 10,000 files opened in about 0.3 s, and Go to File indexed it in 0.21 to 0.24 s. A folder of 1,000 files from shared storage was listed in 0.48 to 0.58 s. Writing or reading 10 MiB took 0.03 to 0.08 s in a project, and 0.08 to 0.16 s in a folder from shared storage.
- **Quality checks:** a CI check fails the build if the app ever declares a storage permission or its backup settings drift from ADR-0012; golden tests that fail commit their images back, so a difference can be seen without downloading anything; the editor benchmark's driver reconnects when its connection to the page drops, no longer waits without limit on a page that stops answering, and talks only to CodeForge's own WebView, never another app's. Between them, these had cost two gates one engine's figures and stalled a third for half an hour.
- **Accessibility:** the automated sweep now covers Home's dialogs, a recent's actions, the explorer's menu, Settings → Privacy and the log viewer, and Home's dialogs are checked beside the keyboard at every screen size; four new goldens show Home's recents, the explorer's menu, the changed-on-disk banner and Privacy.
- W6 verified by CI 43247964184 (`+839: All tests passed!`, goldens `+26: All tests passed!`, Kotlin 44 of 44, the manifest check passed), CI 43256861484 and 43270593998 (the benchmark driver), phase gate 43238952262 (Impeller, every group on its first try), phase gate 43247963954 (every group on its first try, with the measurements; its benchmark driver missed CodeMirror), phase gate 43256861510 (both engines driven; adb stalled, and CodeMirror passed on its second attempt) and phase gate 43270594252 (every group on its first try, both engines driven; cold start 1527 ms, over the budget).

### Added — Phase 3 W5, outside changes (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Files changed by other apps show as it happens:** when a formatter, git, a sync app or another editor changes an open file that has no unsaved changes, the editor shows the new text, keeps the cursor and scroll as close as it can, and says the file was reloaded. On the emulator the new text showed 0.6 to 0.8 s after the write, in a project and in a folder from shared storage.
- **Unsaved text is never overwritten:** if you were typing, or the file had unsaved changes, your text stays. A banner over the editor says the file changed on disk and offers *Keep mine* or *Use the file*, which asks first; typing goes on meanwhile. Saving before you choose asks whether to overwrite the other app's version.
- **Deleted files:** an open file deleted by another app closes its tab, with a notice, when it has no unsaved changes; with unsaved changes the tab stays, marked deleted on disk, until you save it again or close it.
- **The explorer and Go to File follow:** files and folders that other apps create or delete appear and disappear in the folders the explorer shows, and Go to File's list follows. A tool that rewrites many files at once refreshes each folder once.
- **Your own saves** cause no reload and no question.
- **In the background** nothing is checked; coming back catches up (on the emulator, within a second).
- **What is watched:** the workspace's top folder, the folders of open files and the expanded folders, up to 64; open files are also compared with their files every 5 seconds, for storage that does not report changes.
- **Tests:** the watching and every case above, over an in-memory workspace whose changes made "by another app" are reported, and in the workbench; the file services' new checks; the editor page's guarded replace, with protocol fixtures on both sides. A new phase-gate group, `watch`, changes files behind the app's back on the emulator, in a project and in a folder picked in Android's real picker, sends the app to the background and back, and times every reload from the write.
- W5 verified by CI 43228855253 (`+809: All tests passed!`, goldens `+22: All tests passed!`, Kotlin 44 of 44) and phase gate 43228855243, which passed every group on its first try (gate G4; the new `watch` group on a project and on a folder from shared storage). The gate before it, 43222339848, passed every group too, on the code before one fix found in review: coming back from the background now tries again the watches that failed.

### Added — Phase 3 W4, explorer operations and navigation (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Files and folders from the explorer:** New File and New Folder in the selected folder; Rename, also of the case alone; Move to…, with a chooser of the workspace's folders; Duplicate (`x copy.ext`, then `x copy 2.ext`); Copy Path; and Delete, which names the item, counts a folder's files and says that it can't be undone (on shared storage, that Android keeps no bin there). A name that is taken is never overwritten: the dialog asks for another. Items offer only what their storage allows, and a folder granted for reading only offers no changes.
- **Where to find them:** a long-press menu on every row, a ⋯ button on the selected row, and on a hardware keyboard the context-menu key or Shift+F10, with the arrow keys moving through the tree, Enter opening, F2 renaming and Delete deleting.
- **Open files follow every change:** a rename or a move keeps the tab, its unsaved text and its undo history, re-highlights it for a new extension, and moves its tab and unsaved text in the app's database in one transaction, so a crash in between finds the text under the old name or the new one. Deleting a clean open file closes its tab; deleting a file with unsaved text keeps the tab, its name struck through, with a notice that the file was deleted and the text is still there, until Save writes it again.
- **The tree** builds only the rows on screen (fewer than 60 at 10,000 entries), and each file shows a glyph for its kind: 20 kinds, from Dart to lock files, and a plain page for the rest.
- **Icons:** the app's icons are Material Symbols Rounded, as the design system specifies, bundled as a 14 KB font of the 63 the app uses.
- **Go to File** (Ctrl+P, or in the command palette): type a few letters of a file's name or path to find it. It skips `.git` and `node_modules`, searches up to 50,000 files and says when there are more, and follows the explorer's changes.
- **Save logs:** About → Recent logs → *Save* writes the logs, with secrets removed as always, to a file you pick in Android's file picker.
- **Tests:** the operations on a real folder, and through the storage broker for folders from shared storage; the open documents following them, the explorer's menus, dialogs and keys, the fonts against the code that names their glyphs, Go to File's matching and index, and Save logs. A new phase-gate group, `explorer`, runs every file operation on the emulator in a project and in a folder picked in Android's real picker, checks each on disk, and saves a file through Android's create-document picker.
- W4 verified by CI 43166674651 (`+773: All tests passed!`, goldens `+22: All tests passed!`, Kotlin 44 of 44) and phase gate 43183687317, which passed every group on its first try (gate G3; the new `explorer` group on a project and on a folder from shared storage). The two gates before it, 43166674715 and 43171738801, passed every group but the restore pair's part B: its check of the project's restored scroll assumed that the tree builds every row, and then measured a row before the frame that moved it.

### Added — Phase 3 W3, projects, recents and state (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Projects:** *New Project* on Home creates one in the app's own storage, empty or with the demo project's files. From its menu a project is renamed (its tabs and unsaved text follow) or deleted, after a question that says how many files it deletes and, when there are any, how many files' unsaved changes it discards.
- **Home is the launcher:** New Project, Open Folder, the demo project, and the recents. The recents list every project and folder opened, most recent first, each with its kind, its place and whether it is available, missing, or no longer accessible.
- **Reconnect** reopens the folder picker at a folder's old place. A different folder replaces the entry only after you agree. **Remove from recents** gives the folder's access back to Android; its files stay.
- **Each workspace keeps its tabs, unsaved text, expanded folders and explorer scroll** when you switch, and a cold start brings back the last workspace with all of it. A workspace that went missing or lost its access opens Home instead, which says so.
- **Database schema v2,** the first migration: data written by earlier builds opens with nothing lost, and folders opened before find their places again, from the app's grants or the folder that was open ([ADR-0008](adr/0008-persistence.md)).
- **Tests:** project storage on a real folder, the switching and the recents, Home's launcher, the migration from a v1 file, and the explorer's view. The phase gate's restore pair now opens a folder through Android's real picker, leaves unsaved text in it and in a project, and after the process death checks both, switching between them. The keyboard step records which window has focus around each tap.
- W3 verified by CI 43069846481 (`+687: All tests passed!`, Kotlin 44 of 44) and phase gate 43076652650, which passed every group on its first try (gates G2 and G5; the restore pair with a folder workspace). The gate before it, 43069846571, passed every group but the keyboard test. Its new focus record showed Android's *Application Not Responding* dialog for System UI holding the window focus, so the injected tap never reached the app. The gate now hides Android's error dialogs.

### Fixed — CI (2026-11-11)
- **The Flutter pin is enforced.** CI had installed the latest stable Flutter rather than `.flutter-version`'s 3.47.9, because `subosito/flutter-action` does not read that file as a version. The two were the same until Flutter 3.50.0 reached the stable channel. 3.50.0 refuses the app's Android Gradle Plugin, so debug builds failed on the runners that got it. The workflows now pass the pinned version and fail if another is installed ([BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md) §3). Verified by CI 43088413162 and phase gate 43088413208, which passed every group on its first try, both on 3.47.9.
- A failed debug build or Kotlin test run now says why in an annotation, readable without the logs.

### Decisions by the owner on the open items from Phases 0–2 (2026-11-11)
- **Licence (ADR-0011):** decided by Phase 4's start. Until then: no licence file, nothing GPL-derived vendored, no binary release.
- **Terminal (ADR-0006):** the ADR's rule stands: Termux's terminal view if the licence is GPLv3 and it passes Phase 4's arm64 gate, otherwise xterm.js.
- **minSdk (ADR-0007):** stays 26, to be verified on API 26–28 emulators in Phase 4; a raise to 29 needs the owner's sign-off.
- **arm64 hardware (ADR-0009, amended):** Firebase Test Lab's real phones run the tests that need no computer attached, from Phase 4.
- **Play Console (ADR-0010):** prepared at Phase 4, with the closed test that new personal accounts need started well before Phase 10.
- **t1:** the owner merges PR #81 now; t1's licence follows ADR-0011.
- **Added to Phase 3** ([phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md) §0): *Save logs to a file* and Material Symbols Rounded icons (W4); a gate run with Impeller before W6 measures anything; the save digest off the UI isolate, the benchmark driver's reconnect, golden diff images, a debug log viewer and a `ProviderObserver` (W6); one phone session with every parked check at the exit (W7).
- **Placed:** search across files in Phase 4; full support for other text encodings in a later phase.
- **Unchanged:** the emulator gate runs once per work package, with no nightly run; all work stays on the working branch until v1 or later; undo history after a process death stays a known limitation; the keys flake is diagnosed in W3.

### Decisions by the owner at Phase 2's acceptance (2026-11-10)
- Phase 2 accepted, with the phone checks parked ([phases/PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md)).
- Android backup becomes an offer to the user, off by default. Phase 3 W1 builds the switch.
- The on-disk log sink is built in Phase 3.
- The parked large-file checks become phone-only: a Developer action that writes the gate's files, and a plain-text pass in the benchmark, in Phase 3 W1.
- Phase 3 planned: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md).

### Added — Phase 3 W2, folders from shared storage (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Open Folder** on Home: Android's folder picker opens a folder on the device as the workspace, and *Continue in <folder>* reopens it. A cold start reopens it too. The app asks for no storage permission: the picker gives it that folder and nothing else.
- **Files in folders** open, edit and save like the demo project's: UTF-8 text only, byte-order mark and line endings kept, up to 10 MiB. A file changed by another app is not overwritten without asking, also where the folder's storage reports no modification time.
- **Saves in folders are not atomic,** because Android's document storage can't replace a file in one step. A document stays unsaved, with its text kept, until the write is confirmed, and a failed save says the file on disk may be incomplete.
- **Each workspace keeps its own tabs and unsaved text** when you switch between the demo project and a folder.
- **A folder that is gone, or whose access was taken back, says so,** on Home and in the explorer, without a crash.
- **The storage broker,** the Android host's only code that touches shared storage, behind a typed Pigeon API: every path checked again in Kotlin and walked from the folder's root, names Android's storage would change detected and undone, size limits whatever a provider claims, and a time limit on every call. Its security review is SECURITY §4.1.
- **Tests:** 37 Kotlin unit tests against an in-memory provider with the quirks of Android's own; Dart tests of the folder file service, the switching and Home. The phase gate gains a `folders` group: the real picker, driven from the host, and every listing, read, write, create, rename, move, copy and delete checked on disk, then a process death, a deleted folder and a released grant.
- W2 verified by CI 43007795037 (`+631: All tests passed!`, Kotlin 44 of 44) and phase gate 43007795087. Its `folders` group passed on its first try in both attempts (gate G1). Attempt 2 passed every group; attempt 1 failed only the W6 keyboard test at its first step, as W1's first attempt did.

### Added — Phase 3 W1, owner items and carry-overs (plan: [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md))
- **Android backup is now the user's choice, off by default** ([ADR-0012](adr/0012-backup-opt-in.md)):
  - Settings → Privacy → *Back up with Android*, off. It says what Android copies (projects, unsaved text, settings), where (the user's Google Drive) and on what terms, and the row shows the last pass Android ran.
  - A backup agent decides on every pass:
    - **on:** the projects, the database and the settings, never the logs;
    - **off:** nothing, so Android keeps no backup;
    - **off after a backup with everything:** only the switch, which replaces it.
  - A device-to-device transfer follows the same switch.
- **Log file:**
  - The app's log records also go to two rotating files of at most 1 MiB each, in the folder Android never backs up. Errors are written at once, so a crash's last records survive it.
  - Settings → About → Recent logs → *Copy* includes the previous session's records.
  - Document URIs are cut to their authority in every record.
- **Settings → Developer → *Create large test files*** (debug and profile builds) writes the large-file gate's seven files into the workspace, byte for byte, so the large-file policy can be tried on a phone.
- **The engine benchmark** also measures its 1 MiB file as plain text, the path the large-file policy takes.
- **Accessibility:** TalkBack says which tab is selected and which has unsaved changes.
- **Saves keep the file's permission bits:** an executable script stays executable.
- **CI:** the Android host's Kotlin unit tests run on every push.
- **Phase gate:** a `backup` group checks, with Android's local transport, that by default a backup holds nothing; that with the switch on a reinstall restores the project and its unsaved text but not the logs; and that with it off a reinstall gives a fresh app. The restore pair also checks that the log file survives a process kill.
- W1 verified by CI 42862715832 (`+607: All tests passed!`, Kotlin 7 of 7) and phase gate 42862715744. On its second attempt every group passed on its first try. The first attempt failed only the W6 keyboard test, once: a tap that did not focus the editor, cause unknown. In both attempts the default backup was declined, the on and off backups succeeded, and the reinstalls brought back exactly what ADR-0012 says (gate G6).

### Added — Phase 2 (2026-11-10) · evidence: [phases/PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md) (plan: [phases/PHASE_2_PLAN.md](phases/PHASE_2_PLAN.md))
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
- W5 verified by CI 42386742434 and 42388617576 (`+478: All tests passed!`) and phase gate 42386742421. There the edit pair restored 262 unsaved characters, the cursor and the dirty dot after a renderer crash had killed the app, and a rotation to landscape and back kept the page (gate G4).

- **W6 find, replace and go to line:** a find bar over the editor (Ctrl+F, Ctrl+H, or the palette) with match case, whole word and regular expressions. It shows a live match count and steps between matches, and replace all is one undo step. Go to line (Ctrl+G) takes `42` or `42:7`.
- **Symbol toolbar:** a row of 48 dp keys on the soft keyboard: Tab, Shift+Tab, symbols for the file's language, Undo, Redo, the cursor arrows and a hide-keyboard key. Pairs put the cursor between them, and a long press gives the other variant. Settings → Appearance offers Compact, Off or your own keys. Tapping a key never closes the keyboard.
- **Hardware keyboards:** Tab and Shift+Tab indent and outdent. The app's shortcuts work while the editor has the keyboard: save, find, replace, go to line, undo, redo, the palette, and close, next and previous tab. The toolbar steps aside while a hardware keyboard is in use and the soft keyboard is down.
- Tests: the page's search session, Tab and paired inserts (vitest); the toolbar, presets, focus and keys in the workbench (widget tests); and on the emulator, the real find bar over the real page, plus real touches on the toolbar and key chords from the emulator's own keyboard.
- W6 verified by CI 42437560827 (`+512: All tests passed!`) and phase gate 42437560830 for find, replace and go to line (gate G5). The toolbar and keyboards were verified by CI 42517731644 (`+539: All tests passed!`) and phase gate 42517731718, where every touch, key and shortcut passed on attempt 1 (gate G6).

- **W7 large files:** a document over 512 KiB that would be highlighted opens as plain text, so typing stays fast. A banner says what that turns off (highlighting, folding, syntax-aware indentation and comment toggling) and offers *Highlight anyway*, or it can be dismissed; the language chip turns amber. A plain `.txt` loses nothing and gets no banner.
- The phase gate measures large files on the emulator: opening, scrolling, typing, memory and saving at 1, 5 and 10 MiB, as JavaScript and as plain text, with the session store's write costs and a release build's memory with a 1 MiB file restored (EDITOR_ARCHITECTURE.md §10).
- **Dialogs beside the keyboard:** every alert dialog scrolls its title and content above its buttons, with tighter margins when the keyboard leaves little room. On a phone in landscape with the keyboard up, the field and the buttons stay in view.
- Tests: the protocol contract runs on both sides, so a message type that the app and the page do not both know fails CI. Every dialog is checked beside the keyboard at each gate size, at normal and 1.3× text, and the accessibility sweep covers the find bar, the dialogs and the file menu. Goldens show find and replace, the large-file banner, and go to line beside the keyboard.
- W7 verified by CI 42616081306 and phase gate 42616081317 for the measurements, CI 42659207677 (`+552: All tests passed!`) and phase gate 42659207710 for the policy (gate G7), and CI 42678576228 (`+563: All tests passed!`) and phase gate 42676631509 for the quality suite (gate G8).

- **W8 phase exit:** [PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md) records every gate with its run ids, the ADR-0004 tables, the large-file numbers, the artifacts, the parked owner checks and the full gate history. The review found two gaps, both listed in the report: Android Auto Backup (see Changed), and tab state that TalkBack doesn't hear. Phase 2 is built and CI-verified, and awaits the owner's acceptance. The final tree is CI 42678576228 (`+563: All tests passed!`, editor job 187/187) and phase gate 42676631509 (all 11 groups on attempt 1).

### Fixed — Phase 2
- **Text fields with a label were 47 dp tall**, under the 48 dp touch target: the theme made them dense. They are no longer dense, so Material keeps every text field at least 48 dp tall. Found by the W7 accessibility sweep (CI 42665305010).
- **Editor commands in the moment after the editor page starts could fail** with "no document is active". The host reports ready when the page announces itself and reopens the documents just after that. A toolbar key, shortcut, save or snapshot sent in between reached a page with no document. Such commands now wait for the reopen. Found by the W5 zero-loss gate (phase gate 42379885027, `edit_a`).
- **Rotating the phone reloaded the editor page**, which cost every open document its undo history. Text, cursor and scroll were restored from the host's copies. Portrait and landscape use different workbench layouts, and the editor pane was rebuilt in each. It now moves between them under one key.
- **Selected text on the cursor's line was invisible**, in the editor and in the benchmark page: the copy menu and handles appeared, but no highlight. The active line's opaque background covered CodeMirror's selection layer. A line is now highlighted only around a plain cursor, as in VS Code (`editor/src/editor/active_line.ts`). The owner found this in the W3 phone run. Verified in CI 42216855073 and phase gate 42216855184.

### Changed — Phase 2
- **SECURITY.md §4 corrected: Android Auto Backup is on.** The manifest leaves Android's default in place. So when the user has device backup turned on, Android copies the workspace, any unsaved text and the settings to the user's own Google Drive, end-to-end encrypted on Android 9+ with a screen lock. The section had said there was no cloud sync by default. Opting out is an owner decision (PHASE_2_REPORT §1).
- Docs synced at the Phase 2 exit:
  - EDITOR_ARCHITECTURE: its status, and `search.state` in §2's protocol list;
  - ADR-0004: its status;
  - SECURITY §3: the shipped page's hashes, and renderer crashes recovered by the journal;
  - TESTING: totals, CI and the manual checks;
  - BUILD_AND_RELEASE §2.2: the editor job and the gate's groups;
  - ARCHITECTURE §2.7, TECH_STACK, PERFORMANCE §4, ROADMAP and README.
- **Files over 10 MB are refused** (was 16 MB), before they are read: 10 MiB is the largest size the phase gate measured end to end. The message gives the file's size and the limit.
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
