# Phase 3 Implementation Plan — Workspace & Files

**Status:** **In progress** (2026-11-12): W1 done (CI 42862715832, phase gate 42862715744), W2 done (CI 43007795037, phase gate 43007795087), W3 done (CI 43069846481, phase gate 43076652650) and W4 done (CI 43166674651, phase gate 43183687317), see *As built (W1)* to *(W4)*; the owner's "next" starts W5; the owner decided the open items from Phases 0–2 on 2026-11-11 (§0) · Prerequisite: Phase 2 accepted on 2026-11-10 ([report](PHASE_2_REPORT.md)), with the phone checks parked · Blocks: nothing external (no runtime, licence decision or phone is needed to start)
**Spec reference:** §8 Phase 3 (Workspace & File Management), §7 (security claims), §12.19 (stored data survives upgrades) · **Architecture:** [ARCHITECTURE.md](../ARCHITECTURE.md) §2.5, §3 and §4, [ADR-0001](../adr/0001-flutter-kotlin-hybrid.md) (SAF belongs to the Kotlin host), [ADR-0008](../adr/0008-persistence.md) (Drift), [RUNTIME_INTEGRATION.md](../RUNTIME_INTEGRATION.md) §4 (storage model) · **Security:** [SECURITY.md](../SECURITY.md) §1 and §4 · **CI:** [BUILD_AND_RELEASE.md](../BUILD_AND_RELEASE.md)

---

## 0. Carried in from Phase 2 and the owner

**Owner decisions at Phase 2's acceptance (2026-11-10):**
1. **Android backup becomes an offer, off by default** ("keep it as a offer to user, by default it's false"). Today Android's Auto Backup is on, because the manifest never opts out (PHASE_2_REPORT §1). W1 turns it off by default and adds a switch for users who want it.
2. **The on-disk log sink is built in Phase 3.** It is a Phase 1 carry-over that Phase 2 did not build.
3. **The parked large-file checks become phone-only:** a Developer action that writes the gate's large files, and a plain-text pass in the benchmark, both in the first package.

**Phase 2 carry-overs** (PHASE_2_REPORT §9.2 and §10):
- TalkBack does not hear which tab is active or which has unsaved changes.
- A save in a project should keep the file's permission bits before user folders arrive (SECURITY §4).
- File watching, with protocol v1's `doc.replace` (EDITOR_ARCHITECTURE §6).
- File-type glyphs for the explorer (a Phase 1 item, UI_DESIGN_SYSTEM).
- Pigeon arrives with the first real Kotlin surface, the storage broker (TECH_STACK).

**The phone checks stay parked** (ROADMAP, "Parked owner checks"). Phase 3 adds its own: the folder picker and a folder workspace on the owner's phone, and backup with a real Google account. None of them blocks acceptance unless the owner decides otherwise. On 2026-11-11 the owner chose to run them all in one session at Phase 3's exit (W7).

**Owner decisions on the open items from Phases 0–2 (2026-11-11).** The owner was asked about each of the 18 items still open, and chose:
- **For later phases** (ROADMAP's decision queue and the ADRs):
  - **Licence** ([ADR-0011](../adr/0011-license.md)): decided by Phase 4's start. The interim rules stay: no licence file, nothing GPL-derived vendored, no binary release.
  - **Terminal frontend** ([ADR-0006](../adr/0006-terminal-frontend.md)): the ADR's rule. Termux's terminal view if the licence is GPLv3 and it passes Phase 4's arm64 gate; otherwise xterm.js.
  - **minSdk** ([ADR-0007](../adr/0007-min-sdk.md)): stays 26, to be verified on API 26–28 emulators in Phase 4. A raise to 29 still needs the owner's sign-off.
  - **arm64 hardware** ([ADR-0009](../adr/0009-ci-github-actions.md), amended): Firebase Test Lab's real phones, for the tests that need no computer attached. Owner action by Phase 4: a free Firebase project and one CI credential.
  - **Play Console and upload key** ([ADR-0010](../adr/0010-distribution.md)): prepared at Phase 4. A personal account created after 13 November 2023 must run a closed test with at least 12 testers for 14 days before production, so that test starts well before Phase 10.
  - **t1:** the owner merges PR #81 (the commit CodeForge pins, `0e26d7a`) now; t1's LICENSE follows ADR-0011.
  - **Search across files:** Phase 4, with the runtime: ripgrep for projects, and a scan by the app for SAF folders, which ripgrep can't read.
  - **Text encodings other than UTF-8:** full support (open, edit and save in the original encoding) in a later phase, not chosen yet. Until then they are refused, never converted.
- **Built in Phase 3:**
  - **W3:** the keys flake is diagnosed first: the injector records which window has focus after each tap. Until then a flake still fails the gate and is rerun by hand.
  - **W4:** *Save logs to a file* (W1 waited for the broker), and Material Symbols Rounded in place of Flutter's Material Icons, as UI_DESIGN_SYSTEM specifies, together with the file glyphs so that the goldens change once.
  - **W6:** a gate run with Impeller before anything is measured; the save digest off the UI isolate; the benchmark driver reconnecting when its CodeMirror session drops; golden diff images on CI failures; a debug log viewer with filters; a `ProviderObserver` that logs provider failures.
  - **W7:** one phone session at the exit, with every parked check from Phases 1–3 on one checklist, and fresh APKs.
- **Unchanged:**
  - the emulator gate runs once per work package, with no nightly run;
  - all work stays on this working branch until v1 or later, and `main` keeps its initial commit (GitHub runs scheduled workflows only from `main`, so none is scheduled);
  - undo history still doesn't survive a process death (the unsaved text does), a known limitation to revisit if it becomes a problem.

## 1. Objectives

1. Open folders on the device through the Storage Access Framework (SAF). The user picks a folder in Android's own picker. The app keeps a persistable, revocable grant to that folder only, and edits its files behind the same `FileService` contract as the app's own projects.
2. Make projects first-class: several app-private projects (create, rename, delete) beside opened folders, a recents list on Home that shows whether each one can still be reached, and switching between them without losing unsaved text.
3. Explorer file operations on both kinds of workspace: new file and folder, rename, move, duplicate and delete. Open tabs and the hot-exit journal follow every change.
4. Notice outside changes: files changed, added or removed by other apps reach the explorer and the open documents.
5. Bring the whole workbench back after a restart or a process death: the last workspace, its tabs, the explorer's expanded folders and scroll, and the recents.
6. Pass ROADMAP's Phase 3 gate, the storage-scoping security review, and carry out the owner's decisions in §0.

## 2. MVP 3 definition (ROADMAP)

"Project-based IDE", with the exit "SAF open-folder, explorer CRUD, file watch, state survives restart, recents".

**Scope decisions:**
- **Two kinds of workspace** (RUNTIME_INTEGRATION §4):
  - *Projects* live in app-private storage, `<filesDir>/workspaces/<name>`: no permission prompt, full POSIX semantics and atomic saves. The demo workspace becomes the first project.
  - *Folders* are SAF trees the user picks. Supported and tested: the device's shared storage (Android's external-storage provider), on the emulator and, parked, on the owner's phone. Other providers, such as cloud drives, are best effort: the explorer offers only the operations a provider declares (`Document.COLUMN_FLAGS`).
- **No broad storage permission.** The manifest declares none (`READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`, `MANAGE_EXTERNAL_STORAGE`). The app reaches only what the user picks (SECURITY §1), and a CI check keeps it that way.
- **Android's limits are explained, not hidden.** From Android 11 the picker refuses the root of the internal storage, the roots of SD cards and the `Download` folder. Home says so before opening the picker, and suggests a folder such as `Documents/Projects`.
- **Running code from a folder** (through a workspace copy, RUNTIME_INTEGRATION §4) belongs to Phase 4, with the runtime.

## 3. Technical implementation (work packages)

### W1 — Owner decisions and Phase 2 carry-overs (1–2 sessions)

**Backup as an offer, off by default:**
- Settings gets a Privacy section with one switch, *Back up with Android*, off by default. Its text says what Android copies (projects, unsaved text and settings) and where (the user's Google Drive). It also gives Android's terms: end-to-end encrypted on Android 9 and later when the phone has a screen lock, and at most 25 MB. Folders in shared storage are not the app's data and are never part of it; after a restore, their recents entries ask to reconnect.
- **Mechanism:** a Kotlin `BackupAgent` (`android:backupAgent`, with `android:fullBackupOnly="true"` so that Android keeps file-based Auto Backup).
  - Its `onFullBackup` writes nothing while the switch is off. When it is on, it backs up the projects, the database and the settings, never logs or caches.
  - The same switch covers device-to-device transfer: the agent sees the transfer type in the transport flags.
  - Android runs the agent in a restricted mode, without the app's own startup. So the agent reads the switch from a small preferences file the host owns, which the app sets through a small channel (folded into W2's Pigeon API).
- **Turning it off** makes the next backup empty. W1 checks on the emulator what that does to an earlier backup, and the switch's text says it.
- **Quota:** when Android reports a backup as too large (`onQuotaExceeded`), the switch shows it.
- **Evidence:**
  - A JVM unit test of the agent's choice: off, nothing; on, the three locations, never logs.
  - On the emulator, `bmgr` with Android's local transport, which is Android's documented test path. With the switch off, a backup and a reinstall bring back a fresh app. With it on, they bring back a project and its unsaved text.
  - If the emulator image lacks the local transport, the unit test and a parked phone check stand in, and the report says so.
- **Records:** ADR-0012 (backup is the user's choice) and SECURITY §4.

**On-disk log sink:**
- The logger also writes to `getNoBackupFilesDir()/logs`, a folder Android never backs up. It keeps two rotating files of at most 1 MiB each, with the memory buffer's redaction rules, and never logs a SAF URI whole.
- Errors from Flutter, the platform dispatcher and uncaught zone errors are flushed at once, so a crash's last records survive it. Other records are buffered and flushed when the app pauses.
- Settings → About copies the logs, including the previous session's. Once W2's broker exists, it can also save them to a file through Android's create-document picker.
- **Tests:**
  - rotation at the cap, redaction, and the flush on error;
  - the restore pair reads the previous session's records after a force-stop.

**Phone-only large-file checks:**
- **Settings → Developer → *Create large test files*,** in debug and profile builds only:
  - It writes the gate's files (512 KiB, 1, 5 and 10 MiB, as `.js` and as `.txt`) into the open project.
  - They come from the generator the gate uses (`largeJavaScript`, moved from `integration_test/large_files_test.dart` into `lib/`). A unit test pins each file's SHA-256, so the phone types into the same bytes as the gate.
- **A plain-text pass in the engine benchmark** over its 1 MiB file, so that a phone also measures the large-file policy's path. The harness already has a plain-text mode.
- **Docs:** PHASE_2_PHONE_CHECKLIST gets the steps, and ROADMAP's parked rows change from "needs a computer" to "phone only".

**Carry-overs:**
- **Tab semantics:** the active tab is announced as selected, and a tab with unsaved changes says so. A widget test reads both from the semantics tree.
- **Permission bits:**
  - A save in a project keeps the file's mode. The temporary file takes the original's mode before the rename, through libc's `chmod` over `dart:ffi`; Dart has no chmod.
  - A test saves an executable file and checks its mode.
  - SAF saves write in place (W2), so they keep the file's mode anyway.

**As built (W1):**
- **Backup, the user's choice, off by default** ([ADR-0012](../adr/0012-backup-opt-in.md)):
  - **Settings → Privacy:**
    - *Back up with Android*, off. The explanation under the switch states what Android copies, where it goes and on what terms. Folders from shared storage and the logs are never included, and turning the switch off replaces the copy with one that holds only the setting.
    - The row shows the last pass the agent ran: when, whether it was a cloud backup or a device transfer, and whether it was end-to-end encrypted. A backup refused as too large shows its size against the quota.
  - **Host:**
    - `BackupPolicy.kt` holds what a backup may contain, as plain data.
    - `BackupSwitch.kt` keeps the switch, the run records and the quota records in `codeforge.backup.xml`, and writes each with `commit()`.
    - `CodeForgeBackupAgent.kt` makes the choice on each pass.
    - The manifest declares `allowBackup`, `backupAgent`, `fullBackupOnly` and both rules files. `backup_rules.xml` covers Android 11 and lower; `data_extraction_rules.xml` covers 12 and later, with the same list for cloud backup and device transfer.
  - **Dart:**
    - `BackupService` over `dev.codeforge/backup` (`status`, `setEnabled`); W2 folds the channel into the Pigeon API.
    - `BackupController` shows the host's answer, never only the request, and a change the host did not save leaves the switch as it was.
  - **Deviation from this plan:** "off" writes nothing only while no backup with everything can exist. After one, it writes the switch's file alone. An empty backup is declined (AOSP's `LocalTransport.checkFullBackupSize`), and the one with everything would stay.
- **Log file** (`services/logging/file_log_sink.dart`):
  - **Files:** `no_backup/logs/codeforge.log` and the previous `codeforge.1.log`, at most 1 MiB each.
  - **Lines:** each session starts with a marker line, `=== session <utc> · CodeForge <version> · pid <pid> ===`, followed by one line per record, cut at 8 KiB.
  - **Writes:**
    - Errors go to disk and are synced before `add` returns.
    - Other records are batched and written at 16 KiB, after 5 s, or when the app is hidden, paused or detached.
    - A write that fails turns the file off for the session.
  - **Logger:** it gained `addSink`/`removeSink`, and it cuts `content://` URIs to their authority for every sink.
  - **Startup and copying:**
    - Bootstrap starts the file after the first frame and replays the records already in memory.
    - Settings → About → Recent logs → *Copy* takes the newest 256 KiB across both files.
    - Saving the logs to a file through Android's picker waits for W2's broker.
- **Create large test files** (Settings → Developer; debug and profile builds):
  - It writes the gate's seven files into `large-files/` in the workspace, replacing earlier copies, and lists the folder in the explorer. The row shows progress and the result.
  - The generator moved to `lib/core/editor/large_samples.dart`, which the gate uses too.
  - Each file's SHA-256 is pinned twice: in `test/core/large_samples_test.dart`, and in `editor/test/bench.test.ts`, computed from `samples.ts`.
- **Plain-text benchmark pass:**
  - After the 1 MiB file's highlighted pass, the harness opens the same text as plain text, types the same 30 keys in the middle and scrolls for 3 s.
  - The results go in an additive `largePlain` field (the schema stays 1), and they are record-only.
  - The medians `plainOpenMs`, `plainTypingP95Ms` and `plainScrollSlowFramePct` appear in the runner's summary, on the Developer screen and in `editor_bench.txt`.
- **Tab semantics:** each tab is one node that a screen reader announces as selected or not. A tab with the dirty dot is labelled "<name>, unsaved changes". The close button stays a separate node.
- **Permission bits:**
  - `services/files/file_mode.dart` calls libc's `chmod` through `dart:ffi`.
  - `LocalFileService` gives the temporary file the old file's mode before the rename. If `chmod` fails, the save goes on and logs a warning.
- **CI:** a *Kotlin unit tests* step runs `:app:testDebugUnitTest` (JUnit 4.13.2) after the APK build. Its counts go to `ci-results/kotlin-tests.txt` and the run summary, and the quality gate fails on a failure or on no tests.
- **Phase gate:**
  - The restore pair also checks the log file: part A logs an error just before the kill, and part B finds it on disk ahead of its own session marker (`logs_after_a.txt`).
  - The new `backup` group (TESTING.md §1.3) runs `bmgr` with Android's local transport. First the default: a backup of the app as installed is declined, so nothing is kept. Then three tests:
    - `backup_a` turns the switch on in Settings, saves a file and leaves an unsaved edit. The app is then backed up and reinstalled, and Android restores it at install.
    - `backup_b` finds the file, the unsaved edit, the settings and the switch, and a log file holding only its own session. It then turns the switch off. After a second backup and reinstall:
    - `backup_c` finds a fresh app, with the switch off as the only thing restored.
  - The group wipes the transport and restores the device's backup settings afterwards. It is record-only on an image without a local transport.
- **Evidence** (commit a558bd3):
  - **CI 42862715832:**
    - `01:30 +607: All tests passed!` (563 at Phase 2's exit), and the analyzer found no issues.
    - Kotlin: `kotlin_tests=7 failures=0 errors=0`. Goldens: `+22: All tests passed!`. The bootstrap regenerated `settings_412x915_dark.png` for the Privacy section.
    - Coverage of hand-written code: 5052/5721 lines (88.3 %, 88.0 % at Phase 2's exit).
    - vitest: 188 tests in 15 files.
  - **Phase gate 42862715744, attempt 2:** every group passed on its first try (`gate_result=pass`). Cold start was 837 ms. The job took 33 minutes of its 75.
  - **Backup group (`backup.txt`), the same in both attempts:**
    - The default backup: `Transport rejected`. The agent recorded `lastRunContent nothing`, so Android kept nothing.
    - Switch on: `Success`, writing `everything`.
    - `backup_b` after the reinstall: "restored backup-gate.md, 255 unsaved chars in main.js, the settings and the switch; log sessions 1".
    - Switch off: `Success`, writing `switch`.
    - `backup_c` after the reinstall: "fresh app, switch off, last pass switch; no backup-gate.md, main.js clean".
    - `backup_after_restore.txt` lists the restored files. The log folder held only `backup_b`'s own 76-byte session.
  - **Restore pair:** "log file 872 chars, part A record at 613, this session from 655". Part A's error was on disk after the kill.
  - **Plain-text pass** (`editor_bench.txt`, record-only; software rendering bounds the frame numbers):
    - CodeMirror 6 opened the 1 MiB file as plain text in 87.8 ms, with typing p95 85.8 ms.
    - Monaco: 164.4 ms and 80 ms.
  - **Attempt 1:**
    - Everything passed except `keys` (Phase 2 W6), at its first step: the injected tap (`tap 540 1256`, exit 0, the same point as in W7's runs) never focused the editor within 30 s. The gate retries a test only for infrastructure errors, so attempt 1 failed.
    - The same commit passed `keys` on attempt 2, and `keys` had passed in the seven gate runs before this one.
    - W1 changes nothing on that path: the tab strip gained semantics only, and the test's files are new, so no `chmod` runs.
    - **The cause is unknown.** The injector's `adb root` answered nothing in attempt 1, but it did the same in three earlier runs that passed. If it recurs, the step needs evidence it does not record today: which window had focus when the tap landed.
- **Found on the emulator: Android's restore stamps files with January 1970.**
  - The restored files' modification times read 1970-01-21. AOSP's `FullBackup.restoreFile` passes the tar header's seconds to `File.setLastModified`, which takes milliseconds.
  - A restore also keeps only the owner's permission bits (`mode & 0700`).
  - Nothing breaks today: the app compares file stamps only for equality and journals by digest. W4's explorer and W5's watch must not show these times or order files by them as if they were real.

### W2 — Storage broker and folders (2 sessions) 🔑 critical path → G1

**Pigeon:** one typed `StorageApi` between Dart and Kotlin (TECH_STACK: Pigeon arrives with the broker).
- The version is pinned exactly in W2. TECH_STACK lists 29.1.0, and the flutter/packages repository is at 29.2.0 today.
- As with Drift, CI's bootstrap generates the code and commits it, and every run checks that it is current.
- The two small Phase 2 channels stay as they are.

**`StorageBroker.kt`** (ARCHITECTURE §3) is the only code that touches `content://`:
- **Grants:**
  - the picker (`ACTION_OPEN_DOCUMENT_TREE`, with `EXTRA_INITIAL_URI` to reconnect a known folder);
  - then `takePersistableUriPermission` for reading and writing;
  - listing the kept grants, and releasing one.
- **Operations:**
  - list a folder in one `DocumentsContract` query (id, name, MIME type, size, modified time, flags);
  - read bytes;
  - write bytes in place with mode `"wt"`, because plain `"w"` can leave old bytes behind a shorter write on some Android versions;
  - create a file or folder, rename, copy and delete;
  - move, or copy and then delete where a provider can't move.
- **Scoping:**
  - Every document is reached from the granted tree's root, name by name, through tree-based document URIs, which Android checks against the grant.
  - Names pass one validator shared with projects: no `/`, no NUL or control characters, and never `.` or `..`.
  - A provider that changes a name on create ("main (1).js") is detected and reported.
  - A rename that only changes case goes through a temporary name, since shared storage may ignore case.
- **Threads:** every call runs off Android's main thread. Paths map to document ids through a cache that listings fill and W5's watch events clear.

**`SafFileService`** implements `FileService` with the same strict codec as `LocalFileService`: UTF-8 only, BOM and CRLF kept, binary refused. The 10 MiB cap is checked from the listed size before anything is read.
- **Stamps** are the modified time and the size. A provider that reports no modified time gets a SHA-256 stamp instead, so a save still notices that the file changed.
- **Saves are not atomic on SAF:** DocumentsContract cannot replace a file by renaming over it.
  - A document therefore stays unsaved, with its text in the journal, until the write completes and the file's new stamp has been read back.
  - A failed or interrupted save never marks a document saved.
  - The report states this difference from projects.

**Security review first** (ROADMAP's gate for Phase 3). SECURITY §4 gets its storage section before the broker's code lands. It lists each threat with its mitigation and the test that proves it:
- a path escaping the tree;
- a hostile or slow provider (wrong or huge sizes, endless streams, slow calls), met with size caps and time limits;
- a grant that went stale;
- a URI reaching the WebView or the logs;
- another app writing during our write.

**Emulator gate, a new `folders` group:**
- The host script creates `/sdcard/Documents/cf-gate` with known files (`adb push`).
- The test taps Open Folder. A host-side picker driver uses `uiautomator dump` and `input tap` to choose the folder and confirm Android's prompt. It works like Phase 2's key injector (W6): the test logs a request and the host acts on it.
- The test then lists, reads, writes, creates, renames, moves, copies and deletes through the real provider. The host checks every result on disk with `sha256sum`.
- After a force-stop and a relaunch, the grant still works.
- When the host deletes the folder, the workspace shows it as missing, with no crash.

**As built (W2):**
- **Security review first:** SECURITY §4.1 (commit 2b85904) landed before the broker's code, with seven threats (S1–S7), each with its mitigation and the tests that prove it. The tests it names are the ones built below.
- **Pigeon 29.2.0** (a dev dependency; TECH_STACK listed 29.1.0):
  - `pigeons/storage_api.dart` defines `StorageApi`. CI generates `lib/services/files/native/storage_api.g.dart` and `android/…/storage/StorageApi.g.kt`; `[bootstrap]` commits them.
  - *Generated code check* regenerates them with Drift's output. It now fails when a generator exits non-zero, not only when a committed copy is stale. The phase gate generates them too, because it builds the pushed commit.
  - Every method answers through a callback (`@asyncCallback`). The broker runs the work on its own threads, and the generated Kotlin needs no coroutines library.
  - `tool/lint_imports.dart`: generated Pigeon code is imported only from its own `native/` folder (ARCHITECTURE §2, rule 3).
  - **Deviation:** the backup channel stays a plain MethodChannel, with the paths and keyboard channels. This plan's W1 text said W2 would fold it into the Pigeon API. Folding two working methods into it would add generated code without making either safer. ADR-0012 is amended, and `MainActivity`'s KDoc no longer promises it.
- **The broker** (`android/…/storage/`):
  - **`StorageBroker.kt`** implements the generated interface. MainActivity registers it and passes it the picker's answer (`onActivityResult`: FlutterActivity is not an androidx ComponentActivity).
  - **Grants:** the picker (`ACTION_OPEN_DOCUMENT_TREE`, starting at `EXTRA_INITIAL_URI` when Dart names a place), then `takePersistableUriPermission` for reading and writing (reading only, when the picker granted no more); listing the grants; releasing one. Every call checks that its tree URI is among the persisted grants (`access_lost` otherwise), and changes need the write grant.
  - **`StoragePaths`:** every path is parsed again in Kotlin. A name is not empty, `.` or `..`, holds no `/`, NUL or control character, and takes at most 255 bytes in UTF-8. A path has at most 4,096 characters and 128 names.
  - **`DocumentOps`** (pure Kotlin) does the work over a `DocumentBackend`; `ResolverBackend` is the real one, over ContentResolver and tree-based document URIs.
    - A path is walked from the grant's root, name by name, through the provider's listings. A `DocumentIdCache` remembers the ids of up to 20,000 paths (the least recently used go first), and an id is used only after a query finds the same name there.
    - **Writes** go in place with mode `"wt"`, are synced where the provider gives a real file, and the new stamp is read back: its size must be the number of bytes written. A write with an expected stamp is refused when the file changed: size and time, or a SHA-256 of the bytes when the provider gave no time. Missing folders above the file are created.
    - **Names:** a new name is checked against its folder first, case ignored. A created item that the provider named otherwise is deleted, and a rename named otherwise is undone; both are reported (`name_changed`). A rename that changes only the case goes through a temporary name (`.cf-rename-<hex>`).
    - **Moves** use the provider's move when the document offers it, and otherwise a copy and a delete. **Copies** stream bytes (Android's file-system provider offers no copy), stop at 64 levels or 10,000 items, and remove a partial copy.
    - **Limits:** a listing keeps at most 50,000 entries and skips names `StoragePaths` refuses, and repeats (a repeated name can't be reached: `ambiguous`). A read stops one buffer past its cap, whatever size was listed, and no read takes more than 64 MiB.
  - **Threads:** four background threads and a queue of 64 (`busy` when it is full). Each call has a time limit: 10 s for checks, stats and grants; 20 s for listings and changes; 30 s for reads and writes; 120 s for moves and copies. When it passes, the call's `CancellationSignal` is cancelled and Dart gets `timeout`. Answers go back on the main thread. The log names the call, its outcome, the entry count and the duration; never a URI, a path or a file name.
- **Dart:**
  - `services/files/storage_broker.dart` is the broker as the app sees it. `native/pigeon_storage_broker.dart` is the only code that sees the generated types: it waits 5 s longer than Kotlin (the picker has no limit), maps the error codes to `FileProblem`s, and without a host reports folders as unsupported.
  - `FileProblem` gains `folderMissing`, `accessLost`, `timeout`, `unsupported` and `nameChanged`. `FileStamp` gains `digest`, the SHA-256 that stands in for a time the provider did not give.
  - **`SafFileService`** implements `FileService` with the strict codec, the 10 MiB cap checked from the listed size, and those stamps. A failed save says the file on disk may be incomplete and that the text is still in the editor, unsaved. `FileService.writeText`'s documentation no longer promises atomic writes in folders.
- **Workspaces** (W3's recents and database rows are still to come):
  - `core/files/workspace_location.dart`: a workspace is the demo project or a folder (its tree URI and name). A folder's id in the session store is `folder-` and 32 hex digits of the URI's SHA-256, so the database never holds the URI.
  - The shell envelope remembers the open folder (`folder`), written at once rather than after the usual delay. Envelopes without it open the demo project.
  - `fileServiceProvider` follows the open workspace: `LocalFileService` for the project, `SafFileService` for a folder.
  - `WorkspaceSwitcher` opens a workspace, or the picker and then the folder picked. First `DocumentController.leaveWorkspace()` waits for saves and opens in progress, stores every document's unsaved text and the tabs as a checkpoint does, and closes the documents in the editor while keeping their journals. Then the shell changes, and the new workspace opens.
  - `WorkspaceController` starts over when the file service changes, and work the previous one still had in flight lands nowhere (`ref.mounted`). The explorer opens and lists the workspace again when that happens under it.
  - The workbench reopens `main.js` as the first-time fallback in the demo project only. Phase 2's envelope tabs are imported for the demo project only.
- **Home:** *Open Folder…* (the picker); *Continue in <folder>* for the folder opened last. A folder that is missing, or whose grant is gone, says so in a snack bar, and the demo project still opens.
- **Limit:** if Android stops the app's process while the picker is open (it can, when memory is short), the folder picked is not kept and the user picks it again: the Dart side that asked is gone, so the broker drops the answer rather than take a grant nothing will use.
- **W1 carry-over:** bootstrap opened the log file right after `runApp`, although its comment and *As built (W1)* said "after the first frame". It now opens it in a post-frame callback.
- **Tests:**
  - **JVM** (37 new): `StoragePathsTest`, `DocumentOpsTest` and `CappedReadTest`, against `FakeProvider`, an in-memory provider with the quirks of Android's own (path-based ids, FAT-safe and unique names compared without case, a move refused onto a taken name, recursive delete, no copy flag, no time before 1971).
  - **Dart:** `saf_file_service_test` (over `test/support/fake_storage_broker.dart`, and the Pigeon client against a mocked channel), `workspace_switch_test`, `open_folder_test`, and the envelope's folder in `shell_state_test`. `TestHarness` takes a fake broker, and without one gives the app an empty fake.
  - **Emulator, the `folders` group** (TESTING §1.3):
    - The fixture (`integration_test/folder_fixture.dart`) is written by `tool/ci/write_folder_fixture.dart` and pushed to `/sdcard/Documents`: `cf-gate` with five files, and `cf-gate-outside` beside it.
    - `folders_a` taps Open Folder. The host drives DocumentsUI with `uiautomator dump` (`tool/ci/ui_node.py` finds the nodes) and `input tap`, then answers the test's checks the way the keys group's injector answers its requests (`integration_test/folder_gate.dart`): the test logs a request and waits, and the answer comes back through `run-as` into the app's files folder.
    - The app is force-stopped, then `folders_b` runs.
    - Each part runs once per attempt, since a retry would meet the folder as the failed attempt left it; the whole pair runs again, from a fresh fixture, after an infrastructure failure.
- **Evidence** (commit b72da16):
  - **CI 43007795037:**
    - `01:37 +631: All tests passed!` (607 at W1), and the analyzer found no issues.
    - Kotlin: `kotlin_tests=44 failures=0 errors=0` (7 at W1). Goldens: `+22: All tests passed!`. The first commit's bootstrap regenerated Home's eight baselines for Open Folder.
    - *Generated code check*: the generators exited with status 0, and no committed copy differed.
    - Coverage of hand-written code: 5360/6095 lines (87.9 %; 88.3 % at W1). The Pigeon client's methods that only pass calls on are covered on the emulator.
  - CI 43006166469 (the first commit, 1fd095e) failed one test: `workbench_layout_test` replaces the app's providers between sizes, and the explorer waited forever on a workspace nobody reopened. b72da16 makes the explorer reopen it.
  - **Phase gate 43007795087, attempt 1** (job 130479518569, 37 of 75 minutes): the `folders` group passed on its first try (`folders_group=pass`):
    - **The picker:** DocumentsUI (`com.google.android.documentsui`) opened inside `cf-gate`. The driver tapped *Use this folder*, then *ALLOW* under "Allow CodeForge to access files in cf-gate?".
    - **Part A** (26 s after the build): 20 disk checks and 3 listings, each as the test expected. The shorter text over the longer one left exactly `short\n` (`c962fa1b…`), and the editor's save left exactly its text. `Readme.md` became `README.md`, with no " (1)" and no temporary name left. The `..` paths were refused by the broker itself, the folder beside it and the Documents folder above both were refused as never granted, and a document URI was refused as no grant.
    - The force-stop: "no dev.codeforge.app process after am force-stop — process death confirmed".
    - **Part B** (7 s, 3 disk checks): the folder reopened by itself, so the grant survived. The file part A saved was there, and a new one landed. After the host deleted the folder, the explorer said it was missing. After an empty folder came back and the grant was released, the explorer said access was lost.
    - The folder beside it still held the fixture's bytes (`secret.txt`, `015e8529…`).
    - Every other group passed except `keys`, at its first step, as in W1's attempt 1: the injected tap (`tap 540 1256`, exit 0) did not focus the editor within 30 s. Cold start was 1168 ms (W1: 837 ms), and the release build's memory with the 1 MiB file open was 221.6 MB.
  - **Attempt 2** (job 130497405290, 35 minutes): every group passed on its first try (`gate_result=pass`), `keys` included. The `folders` group passed again with the same 23 disk checks and 3 listings (part A 25 s, part B 6 s), and the backup group gave the same three results as in W1. Cold start was 1083 ms, and the release build's memory was 226.2 MB.
  - **The `keys` step** has now failed at its first step in two of the last four attempts, the first attempt of W1's gate and of W2's, and passed on each rerun. W2 changes nothing on its path: the test reaches the demo project through Home's button, which now goes through the workspace switcher, and the failure comes later, at the tap. The cause is still unknown. W3's first code commit makes the injector record which window has focus after each tap, the evidence W1 named as missing.

### W3 — Projects, recents and state (1–2 sessions) → G2, G5

**First, the keys flake** (*As built (W2)*; owner decision 2026-11-11): the keys injector records which window has focus after each tap, the evidence W1 named as missing. Until the cause is found, a flake still fails the gate and is rerun by hand.

**Drift schema v2, the first real migration** (ADR-0008):
- `workspaces` gains its kind (project or folder), its location (the project's folder name, or the tree URI) and a display path.
- A new `workspace_views` table keeps each workspace's expanded folders and explorer scroll.
- The migration turns v1's demo row into a project. drift_dev's verifier and a fixture test from v1 (the harness from Phase 2 W5) prove it: data written by v1 opens in v2 (spec §12.19).

**Projects:**
- New Project creates `<filesDir>/workspaces/<name>`, either empty or from the demo template.
- Rename moves the folder and updates its row in one step, and open tabs follow.
- Delete asks first, giving the number of files. It then closes the project's tabs and discards its journal.
- One name validator serves projects, files and folders.

**Home becomes the launcher:**
- Recents list projects and folders, most recent first. Each shows its name, kind, location and status: *available*, *folder missing*, or *access lost* (the grant is gone).
- *Reconnect* reopens the picker at the old location. If the user picks a different folder, the app asks before replacing the entry.
- *Remove from recents* also releases the folder's grant, since Android limits how many grants an app can keep.

**Switching and restarting:**
- Opening another workspace keeps the current one's tabs and unsaved text in the database, and reopens the other's. The database rows have been per workspace since schema v1.
- The shell records the open workspace. A cold start reopens it with:
  - its tabs, with their cursor and scroll, as since Phase 2;
  - its expanded folders and the explorer's scroll.
- A workspace that went missing or lost its grant lands on Home with that status, never a crash.

**Emulator:** the restore pair grows a folder workspace.
- `restore_a` opens a SAF folder through the picker driver, edits without saving and expands folders. It also leaves unsaved text in a project. Then the app is force-stopped.
- `restore_b` checks the workspace, the tabs, the unsaved text and the expanded folders. It then switches to the project and back, and both unsaved texts must survive.

**As built (W3):**
- **The keys flake, found.** The first W3 commit (a3ad26e) makes the keys injector record, before and after each tap, which window has the focus, where the keyboard goes and which window the input dispatcher holds focused (`dumpsys window`, `dumpsys input`). It also keeps the screen after each run's first tap.
  - In gate 43069846571 (below) the step failed again at its first tap, and the record says why. Before and after the tap, the focused window was Android's *Application Not Responding* dialog for System UI (`com.android.systemui`), so the tap and every key went to the dialog, never to the app.
  - The other groups drive the app from inside: Flutter's integration tests put their input straight into the app, so a dialog over it does not stop them. By the time the restore pair and the `folders` group drove Android's picker, the dialog had gone: both picks went through. That run's screenshot of the first tap came out black. The two gates since, with no dialog, took the same screenshot, and it shows the app with `keys.js` open and the keyboard up, so the emulator can take screenshots; why that one is black is not known.
  - **The fix** (commit 0c4337f): after boot the gate sets `hide_error_dialogs`, so Android ends a process that stops responding instead of asking. System UI starts again, and an ANR of the app itself ends the app, which its test then sees. The injector also closes system dialogs if an error dialog still has the focus before a tap, and `keys_events.txt` lists every ANR and crash since boot.
  - **With the fix,** gate 43076652650 passed `keys` on its first try, and all 5 of its taps found the app's window focused, before and after. The event log held 2 ANRs since boot and no crash. Both ANRs were Google Play services processes that failed to complete startup, 5 minutes before the first tap. The record can't tell whether either would have put a dialog over the app without the fix.
  - Whether the failed attempts of W1's and W2's gates had the same cause is not known, since they had no focus record. The symptom was the same: a tap that exited 0 and focused nothing.
- **Drift schema v2** (ADR-0008), the first migration:
  - `workspaces` gains `kind`, `location` (a project's folder name, or a folder's tree URI) and `display_path`. A new `workspace_views` table keeps each workspace's expanded folders and explorer scroll.
  - The step adds them, marks W2's `folder-…` rows as folders, and gives each project its id as its folder (v1's only project was the demo).
  - v1 never recorded where a folder is. Home's recents find the place among the app's grants, whose URIs hash to the same ids, or in the shell's open folder, and store it. A folder found in neither shows *access lost* and can be reconnected.
  - CI's bootstrap generated the v2 dump, `schema_v2.dart` and `app_database.steps.dart`. `migration_test.dart` is written by hand, so drift_dev's `make-migrations` leaves it alone: the verifier checks 1 → 2, and a v1 file with a row in every table, written with v1's own SQL, opens in v2 with nothing lost.
  - **The database now holds folders' tree URIs** (`workspaces.location`), which W2's *As built* said it never did: Home needs them to check and reopen each folder. They stay in the app's private storage, like the shell envelope's open folder (SECURITY §4.1, S5).
- **Projects** (`services/files/project_storage.dart`):
  - A project is `<filesDir>/workspaces/<name>`, its folder named after it. Its id is random (`project-` and 16 hex digits), so it never changes with the name; a project folder found without a record gets an id made from its folder name.
  - A new project is written under a hidden name (`.staging-…`) and renamed into place. A deleted one is renamed away (`.deleting-…`) before it is emptied, and a rename that changes only the case goes through `.rename-…`. Hidden and half-written folders are not projects, and names are compared without case.
  - `projectNameProblem` adds the project rules to `nameProblem`, the name rule files and folders share (`core/files/workspace_path.dart`): no leading `.`, no leading or trailing space, `demo` and the staging suffix reserved, and no name that differs from another project's only in case.
  - `WorkspaceSwitcher`: `createProject`, empty or with the demo project's files; `renameProject`, the folder and then the record, where a record that can't be written puts the folder back; `deleteProject`, whose open documents close first, then the folder goes, then everything kept for it (tabs, journal, view, record). When the deleted project was open, the demo project opens in its place.
  - Another project's missing folder is reported as missing and never recreated. The demo project is written again when its folder is gone, and it can be deleted but not renamed.
- **Home is the launcher** (`features/home/`): New Project (a name dialog, with a switch for the demo project's files), Open Folder…, the demo project's card, and the recents (`application/recents_controller.dart`).
  - Each entry shows its name, *Project* or *Folder* with its place (`CodeForge projects/<name>`, or the folder's place read from its URI, such as `Internal storage/Documents/cf-gate`), and a status: *available*, *missing* (a project), *folder missing* or *access lost*. There is no status while the check runs, or when the check itself fails. Folders are checked through the broker.
  - The menu: Open; Rename… (not for the demo project) and Delete… for projects; Reconnect… and Remove from recents… for folders. Delete's question gives the number of files, and the number of documents with unsaved changes when there are any.
  - Reconnect opens the picker at the folder's old place, the folder itself as its provider's document (`folderPickerStart`). The same folder reconnects at once. Another one asks *Replace …?* first; the entry then keeps its id, so its tabs, unsaved text and view follow, and the old place's grant is given back. Turned down, the folder picked is given back. A folder already in the recents under another entry is refused.
  - Remove from recents gives the grant back and forgets the folder; its files stay. A folder that fails to open says why in a snack bar with a *Reconnect* action.
  - W2's *Continue in <folder>* is gone: the recents replace it.
- **Switching and restarting:**
  - The shell envelope's `workspace`, a project or a folder, replaces W2's `folder`, which still reads.
  - The explorer's view (`application/explorer_view_controller.dart`): each workspace's expanded folders and scroll, stored 400 ms after a change, and at once when the app goes to the background or another workspace opens. The explorer scrolls back once the tree is long enough, or once every expanded folder is listed: at most 50 tries, 100 ms apart, counted rather than timed, so a test's fake clock behaves the same.
  - A cold start into a missing or inaccessible workspace lands on Home, with a snack bar that says why.
- **Found by CI, fixed before the gate counted:**
  - **cef5155** (CI 43064976154, `+492 -20`): one analyzer error, a missing import in `explorer_view_controller.dart`, kept 20 suites from compiling.
  - **1e721a8** (CI 43067325867, `+684 -3`): `explorer_view_test` caught the explorer's view carrying one workspace's expanded folders into the next. Riverpod keeps a notifier object across rebuilds, and with it its fields. 3bdb685 resets them in each build, after the old view is stored, and drops a stored view that arrives after another workspace opened. The gate run started with 1e721a8 (43067325895) was cancelled after its first three groups, since its restore pair would have met the same bug.
  - In the same run, two accessibility tests of Home with recents (no overflow at text scale 1.3 across the gate sizes; labels and targets at 800×360) found no recents: Home is a lazy list that had not built them, and the tests now scroll to them first.
- **The Flutter pin was not enforced** (BUILD_AND_RELEASE §3). After W3's gates, three CI runs of commits that changed only docs or CI failed at the debug build (CI 43082992891 attempt 1, 43084317447, 43086757260); a rerun of the first passed.
  - A new step, *Build digest*, now puts the build's error in an annotation, which the API can read. It showed Flutter 3.50.0 refusing the Android Gradle Plugin 9.1.0.
  - The workflows handed `subosito/flutter-action` the `.flutter-version` file, which the action reads only as a pubspec or an FVM file. It found no version there and installed the latest stable release: the pinned 3.47.9 until 3.50.0 reached the stable channel.
  - Both workflows now read the file and pass its version, and a step fails if another Flutter was installed. CI 43088413162 and phase gate 43088413208 (below) ran on the pin; each noted `3.47.9 (pinned: 3.47.9)`.
  - Moving to 3.50.0 needs the Android Gradle Plugin 9.1.1 and Kotlin's Gradle plugin 2.4.10 (the app has 9.1.0 and 2.4.0). 3.50.0's engine source still has the Skia path that the app's opt-out selects (`flutter_main.cc`, the same lines as in 3.47.9), so the opt-out alone does not block the move; a gate run would show whether it still works. That is the owner's decision, so W4 stays on 3.47.9 unless the owner says otherwise.
- **Emulator: the restore pair grows a folder workspace** (TESTING §1.3):
  - Part A starts from a clean slate, so its retries stand. It leaves unsaved text in the demo project's `app.py`, writes 40 files into its `docs` folder, expands `src` and `docs` and scrolls the explorer. Then it opens the gate folder through Android's real picker, driven by the host as in the `folders` group, and leaves unsaved text in `src/app.js` with `src` and `src/lib` expanded.
  - Part B finds the folder open after the kill, with its unsaved tab and expanded folders, and Home's recents with both workspaces. It switches to the project, whose tabs, unsaved text, expanded folders and scroll come back, and then back to the folder. Last, the host confirms that `src/app.js` on disk is still the fixture's.
  - Part B runs once per pair, because it switches workspaces. The pair pushes the `folders` group's fixture and runs its own picker driver, and the device log is cleared after it.
- **Evidence:**
  - **CI 43069846481** (commit 3bdb685):
    - `01:37 +687: All tests passed!` (631 at W2), and the analyzer found no issues. Kotlin: `kotlin_tests=44 failures=0 errors=0`.
    - Goldens: `+22: All tests passed!`. 1e721a8's bootstrap regenerated Home's eight baselines for the launcher, and 3bdb685's reproduced them unchanged.
    - *Generated code check*: the generators exited with status 0, and no committed copy differed, the v2 dump and helpers included.
    - Coverage of hand-written code: 6297/7068 lines (89.1 %; 87.9 % at W2).
  - **Phase gate 43069846571** (commit 3bdb685, job 130694447406, 39 of 75 minutes): every group passed on its first try except `keys` (above).
    - **The restore pair:** part A took 28 s after the build. It asked for the picker once, and the driver answered `picked`; part A then left the folder open with 1 tab, unsaved text in both workspaces and 2 recents. The force-stop: "no dev.codeforge.app process after am force-stop — process death confirmed".
    - Part B took 14 s: the folder, its unsaved text and expanded folders came back; the project kept its tabs, unsaved text and explorer scroll; and the host found `src/app.js` with the fixture's SHA-256 (`3c58a542…`). The log file held part A's last record ahead of part B's session marker.
    - `folders` passed on its first try (23 disk checks, 3 listings), the backup group gave the same three results as in W1 and W2, and the edit pair passed. Cold start was 1372 ms (W2: 1168 and 1083 ms; budget 1500 ms), and the release build's memory with the 1 MiB file open was 226.4 MB.
  - **Phase gate 43076652650** (commit 0c4337f, which changes only the gate script; job 130718108467, 38 of 75 minutes): every group passed on its first try (`gate_result=pass`), `keys` included (above).
    - The restore pair passed again with the same checks: part A in 25 s, part B in 13 s, one pick, and the fixture's SHA-256 on disk after both parts.
    - `folders` passed again with 23 disk checks and 3 listings, and the backup group gave the same three results. Cold start was 1177 ms, and the release build's memory with the 1 MiB file open was 225.6 MB.
  - **CI 43076652940** (commit 0c4337f) passed.
  - **After the Flutter pin's fix** (commit d69bd61, which changes only the workflows and docs): CI 43088413162 passed, and phase gate 43088413208 (job 130758738766, 33 of 75 minutes) passed every group on its first try, both on Flutter 3.47.9.
    - `keys_events.txt`: no ANR and no crash since boot. All 5 taps found the app's window focused, before and after.
    - The restore pair passed with the same checks: part A in 23 s, part B in 10 s, one pick, and the fixture's SHA-256 on disk after both parts.
    - `folders` passed with 23 disk checks and 3 listings, the backup group gave the same three results, and the edit pair passed. Cold start was 1005 ms, and the release build's memory with the 1 MiB file open was 223.1 MB.

### W4 — Explorer operations and navigation (2 sessions) → G3

**Contract:**
- `FileService` gains `createFolder`, `rename`, `move`, `copy` and `delete`.
- It also reports each workspace's capabilities; a provider that cannot rename hides Rename.
- Both backends implement them, and the widget tests' `memory_file_service.dart` mirrors them.

**Actions:**
- New File and New Folder, in the selected folder.
- Rename, including case-only renames.
- Move to…, with a folder chooser inside the workspace.
- Duplicate, and Copy Path.
- Delete, with a confirmation that names the item and counts a folder's files. SAF deletes are permanent, and the dialog says so.
- A name that already exists is never overwritten: the dialog asks for another.

**Where to find them:**
- a long-press menu on every row;
- a ⋯ button on the selected row, so the menu can be found without long-pressing;
- the context-menu key and Shift+F10 on a hardware keyboard, where the arrow keys also move through the tree.

**Open documents follow every change:**
- A rename or a move re-keys the document's tab and journal rows in one transaction, and its language follows the new name. The editor page's document ids are opaque (`d1`, `d2`, …), so the page keeps the document, undo history included.
- Deleting a clean open file closes its tab.
- Deleting a file with unsaved changes keeps the tab, marked deleted on disk, so that Save or Save As can bring it back. Documents have had that state since Phase 2.
- Deleting a folder does the same for everything inside it.

**The tree:**
- It is virtualised: only visible rows are built, and a widget test over 10,000 entries counts the rows built.
- Folders are listed when expanded, and hidden files follow the existing setting.
- File-type glyphs for the 20 most common extensions, with a generic fallback, following UI_DESIGN_SYSTEM's icon rules (a Phase 1 item). Goldens cover them.

**Owner decisions (2026-11-11):**
- **Icons:** the app's icons move from Flutter's Material Icons to a bundled Material Symbols Rounded subset, as UI_DESIGN_SYSTEM specifies, in the same change as the file glyphs, so that the goldens change once. TECH_STACK records the font's source, version and licence.
- **Save logs to a file:** About → Recent logs gains *Save*, which writes the log files' redacted text to a file the user picks through Android's create-document picker. The broker gains that picker.

**Go to File** (Ctrl+P, and in the palette):
- fuzzy matching over the workspace's file names, from an index built in the background and kept current by W5;
- `.git` and `node_modules` are skipped by default, and the index stops at 50,000 entries and says so.

This is the plan's one addition to ROADMAP's list: with real projects, finding a file by name is basic navigation. The owner can drop it.

**As built (W4):**
- **The contract** (`services/contracts.dart`): `FileService` gains `createFolder`, `rename`, `move`, `copy` and `delete`, and each entry it lists carries its `FileCapabilities`: write (for a folder, taking new items), rename, move and delete.
  - A project's items allow everything. In a folder from shared storage each item allows what its provider declares in DocumentsContract's flags; Move is offered where the provider can move or delete the item, since the broker copies and deletes where it cannot move. A folder granted for reading only allows nothing that changes it.
  - Nothing is ever replaced: an operation onto a taken name fails with `exists`, on both services. A rename that changes only the case works on both.
  - `LocalFileService` (a project): one `rename(2)` per rename or move, never following a link for the item itself. Copies keep permission bits, skip links, stop at 10,000 items or 64 levels like the broker's, and leave no partial copy behind.
  - `SafFileService` (a folder) runs on the broker's operations, which W2 built and covered with Kotlin tests, and creates the missing folders above a new one.
- **The explorer** (`features/workbench/panels/explorer_panel.dart`, `explorer_actions.dart`, `explorer_dialogs.dart`):
  - Each row's menu: New File… and New Folder… (in the row's folder), Rename…, Move to…, Duplicate, Copy Path and Delete…, leaving out what the item does not allow. It opens with a long-press, the selected row's ⋯ button, the context-menu key or Shift+F10.
  - Keys: the arrows, Home and End move through the tree; → expands a folder or steps into it, ← collapses it or steps out to its parent; Enter or Space opens; F2 renames and Delete deletes. The selected file follows the active document.
  - A taken name keeps its dialog open: '“<name>” is taken in this folder. Choose another name.' Move to… shows the workspace's folders as a tree. Delete names the item, counts a folder's files, says that tabs with unsaved text stay open, and says that it can't be undone; on shared storage, that Android keeps no bin there.
  - Duplicate names the copy `x copy.ext`, then `x copy 2.ext`.
- **Open documents follow** (`application/file_operations.dart`, `application/documents/`):
  - A rename or a move (`pathMoved`): the tabs of the item and of everything in it follow, with their unsaved text, cursor and place in the tab strip. They keep their editor documents, whose ids say nothing of paths, so the undo history survives, and a file whose name changed is highlighted for its new name.
  - `SessionStore.movePaths` gives their tab and journal rows the new paths in one transaction, after every write queued before it, and the journals continue there instead of being written again: a process death finds the unsaved text under the old path or the new one.
  - A delete (`pathDeleted`): clean tabs close. Tabs with unsaved text stay, marked deleted on disk, with a banner ('<name> was deleted. Your text is still here: save it to write the file again, or close the tab to discard it.'), the tab's name struck through, and TalkBack's "deleted on disk". Save writes the file again.
  - Before an operation `settle()` waits for saves in progress, and `occupant()` refuses a place held by a tab kept for a deleted file.
- **The tree** is one flat list of visible rows (`visibleRows`) under `ListView.builder` with a fixed 48 dp row, so only the rows on screen are built: a widget test over 10,000 entries finds fewer than 60 built. Folders are listed when expanded, and hidden entries follow the existing setting.
- **Icons and glyphs** (owner decision; TECH_STACK §1, UI_DESIGN_SYSTEM §6):
  - The app's icons are Material Symbols Rounded 2.978 from Google's repository (Apache 2.0): a static instance (FILL 0, GRAD 0, optical size 20, weight 400) cut to the 63 icons the app uses, 14,064 bytes (`tool/fonts/subset_symbols.py`). `CfIcons` names them, and `icons_test` fails when the font and `CfIcons` disagree. Directional icons mirror in right-to-left text, and About lists the font and its licence.
  - `CfFileGlyphs.ttf` is drawn for the app on a 16-unit grid with a 1.5-unit stroke (`tool/fonts/build_file_glyphs.py`): 20 kinds and a generic page, 5,560 bytes. `CfFileGlyphs.forName` tries whole names first (`.gitignore`, shell rc files, `LICENSE`, `README`, …), then `.env` files, then the last extension in any case.
  - All 22 goldens changed once, in 01e6129's bootstrap, and the gallery's two grew a *File glyphs* section.
- **Save logs** (owner decision): About → Recent logs → *Save* writes all the log text, redacted as the screen shows it (4 MiB at most), to a file picked in Android's create-document picker, suggested as `codeforge-logs-YYYYMMDD-HHMM.txt`. The broker's new `saveDocument` keeps no grant (SECURITY §4.1). Backing out says nothing, and each failure says what to do next. `saveDocument` has no Kotlin unit test, since it starts an activity: the gate drives it (below).
- **Go to File** (Ctrl+P, and `file.goTo` in the palette; the editor page passes Ctrl+P to the app):
  - The index (`application/file_index.dart`) is built the first time Go to File opens in a workspace, top folders first, without blocking the UI. It skips `.git` and `node_modules`, stops at 50,000 files and says so, and goes 64 folders deep. The explorer's operations, New File and Save As keep it current, and switching workspaces drops it. W5 makes it follow outside changes.
  - The matching (`core/files/fuzzy_match.dart`) is fzf's first method: the query's characters in order, ignoring case, in the shortest window of the path. Matches at word starts, in runs and in the file name score higher; ties go to the shorter name, then the shorter path.
  - Each result shows its name over its folder, and TalkBack reads '<name>, in <folder>'. The status line gives the number of files, the progress of the index, the 50,000-file limit, or why the files could not be listed.
  - The owner did not drop it.
- **Found by CI and the gate, fixed before the gate counted:**
  - **11645fc** (CI 43101965611, `+715 -1`): a new test expected `greeting.dart` to open as Dart, but the test harness opens it as plain text. 72c8b95 fixed the test.
  - **Phase gate 43166674715** (a722f1a): every group passed on its first try, the new `explorer` group included, except W3's `restore_b`. To check the project's restored scroll, it expected `docs/note_39.md` to be built: W3's tree built every row, W4's builds only those on screen. c9ae96f checks instead that `docs/note_09.md`, the eleventh row, is at the top of the tree.
  - **Phase gate 43171738801** (c9ae96f): the same result. `restore_b` found that row 480 dp below the top of the tree, where it sits at offset 0. The explorer jumps to the stored offset in a frame callback, and the test measured before the next frame laid the rows out; a0fd31e waits one frame first.
  - In gate 43166674715 the `explorer` group's test log was overwritten by its verdict, both named `explorer.txt`. Since c9ae96f the log is `explorer_itest.txt`.
- **Emulator: the `explorer` group** (TESTING §1.3), one integration test on both kinds of workspace: the demo project, then the gate folder picked in Android's real picker.
  - Each operation runs through `FileOperations`, as the menu runs it, and is checked on disk: new folder and new file, rename, a case-only rename, move, duplicate (of a folder, so copying too) and delete.
  - A taken name is refused, with both files as they were. An open document with unsaved text follows its renamed folder and its move, its journal row included. Deleting a clean open file closes its tab, and deleting the folder of a file with unsaved text keeps the tab, which Save writes again.
  - Then one rename through the explorer's real menu and dialog, and a file saved through the create-document picker, driven by the host (`FOLDERGATE save`).
- **Evidence:**
  - **CI 43166674651** (commit a722f1a): `02:03 +773: All tests passed!` (687 at W3), and the analyzer found no issues. Goldens: `+22: All tests passed!`. Kotlin: `kotlin_tests=44 failures=0 errors=0`. Coverage of hand-written code: 7615/8484 lines (89.8 %; 89.1 % at W3).
  - CI 43171738808 (c9ae96f) and 43183687656 (a0fd31e) passed every quality gate. Those commits change only an integration test, the gate script and docs; without `[bootstrap]` in their messages, CI committed no results for them.
  - **Phase gate 43183687317** (commit a0fd31e, job 131065555316, 36 of 75 minutes): every group passed on its first try (`gate_result=pass`).
    - **`explorer`:** `00:29 +1: All tests passed!` after the build. The driver answered one pick (`picked`) and one save (`saved`), made 19 disk checks and 3 listings, and the test logged `project done`, `folder done` and `saved through the picker`.
    - **The restore pair**, with W4's tree: part A in 18 s and part B in 7 s, one pick. Part B found the project's explorer scrolled back to 480 with `docs/note_09.md` at the top, and the host found `src/app.js` with the fixture's SHA-256 (`3c58a542…`). The log file held part A's last record ahead of part B's session marker.
    - `keys_events.txt`: no ANR and no crash since boot, and all 5 taps found the app's window focused, before and after.
    - `folders` passed with 23 disk checks and 3 listings, the backup group gave the same three results as since W1, and the edit pair passed. Cold start was 755 ms (median of 10; budget 1500 ms; W3's gates: 1005 to 1372 ms), and the release build's memory with the 1 MiB file open was 225.0 MB.

### W5 — Outside changes (1–2 sessions) → G4

**What is watched:** neither backend can watch a tree recursively, so the app watches what the user can see. That means the root, the expanded folders and the folders of open documents, up to 64 folders.
- **In projects:** one `Directory.watch` per folder. It uses inotify, and Dart doesn't support recursive watches on Linux, which includes Android.
- **In SAF folders:** a content observer on each folder's children, kept alive by an open query. Android's file-system provider sends change notices while such a query is open. W5 verifies this on the emulator; providers that send nothing rely on the next point.
- **On both:** open documents' stamps are re-checked when the app resumes, when a tab is activated, and every 5 seconds in the foreground.

**What happens** (EDITOR_ARCHITECTURE §6):
- A clean open document whose file changed reloads through protocol v1's `doc.replace`, with a short notice. It keeps the cursor and scroll as close as it can.
- A document with unsaved changes keeps them and shows the conflict choice: keep mine, or use the file. Nothing is overwritten.
- When a file is deleted, a clean tab closes with a notice, and a tab with unsaved changes is marked deleted on disk.
- The explorer refreshes the folders it shows, and Go to File's index follows.
- **Own writes are ignored:** a save records the stamp it wrote, and an event that matches it is dropped.
- **Bursts are coalesced** over 300 ms, so a tool rewriting many files refreshes each folder once.

**Emulator gate, a new `watch` group:** the host changes files behind the app's back, with `adb shell` in the SAF folder and `run-as` in a project. The test checks that:
- a clean document shows the new text exactly, within 2 seconds;
- a document with unsaved changes keeps them and shows the conflict;
- a new file appears in the explorer;
- the app's own save triggers no reload;
- a change made while the app was in the background is caught on resume.

### W6 — Tests, performance and quality (continuous + 1 session) → G6, G7, G8

- **Renderer, before anything is measured** (owner decision 2026-11-11):
  - The app has run on Skia since Phase 1, because Impeller's OpenGLES backend never sized its surface on the CI emulator. Flutter 3.47.9 now warns in the gate's log that the opt-out "is going to go away in an upcoming Flutter release".
  - One gate run removes the opt-out. If every group passes, Impeller stays and W6 measures it. If a group fails because of the renderer, Skia stays, the failure is recorded, the owner is asked again, and Flutter stays at 3.47.9 until Phase 4's device testing.
  - Impeller on the owner's phone joins the exit session's checklist.
- **Kotlin tests in CI:** a new step runs Gradle's unit tests (`testDebugUnitTest`) for the broker's pure logic (names, path resolution, scoping) and the backup agent's choice.
- **Manifest check:** a CI test fails if the merged manifest declares any storage permission, or if its backup attributes drift from ADR-0012.
- **Measurements in the gate,** recorded as evidence. As in Phase 2, frame-timed numbers are judged on a phone.
  - listing a 1,000-entry SAF folder;
  - reading and writing 1 and 10 MiB through the broker, against `dart:io` in a project;
  - opening a project of 10,000 files, and building Go to File's index;
  - the release cold start, which must stay within 1500 ms (median of 10).
- **Accessibility and layout:**
  - The sweep covers Home's recents, the explorer's menu, the new dialogs and Settings → Privacy.
  - `keyboard_insets_test` opens the new dialogs beside the keyboard.
  - Goldens cover the new chrome.
- **Coverage per layer,** as in Phase 2. The gate runs the platform glue that host tests can't.
- **The save digest leaves the UI isolate** (owner decision 2026-11-11): the SHA-256 of the saved text took up to 28 ms at 1 MiB and 80–184 ms at 10 MiB in a debug build (PHASE_2_REPORT §9.2). It moves to a background isolate, and a test shows that frames keep coming while a 10 MiB digest runs.
- **The benchmark's DevTools driver reconnects** (owner decision) when its CodeMirror session drops ("DevTools connection closed", "Runtime.evaluate timed out"), so that every gate has complete figures. In Phase 2, 7 of the last 11 gates had no CM6 debug-memory figure.
- **Developer tooling** (owner decision; Phase 1 items):
  - **golden diff images:** when a golden test fails, CI commits the failure images back with its diagnostics;
  - **a debug log viewer:** Settings → Developer (debug and profile builds), with level and tag filters;
  - **a `ProviderObserver`** that logs provider failures through the logger, with its redaction.
- **New parked phone checks:** the folder picker and a folder workspace on the owner's phone, whose picker may differ from the emulator's, and backup with a real Google account. By the owner's decision (2026-11-11), they run with the older ones in one session at the exit (W7).

### W7 — Documentation and phase exit (0.5 session) → G9

PHASE_3_REPORT.md with run ids, and the documents in §7.

**The phone session** (owner decision 2026-11-11): W7 writes one checklist with every parked check from Phases 1–3 (ROADMAP's table, including the folder picker and a folder workspace, backup with a Google account, and Impeller if W6 switched to it), and builds fresh debug and profile APKs. The owner runs it in one session, and the results go into PHASE_3_REPORT. Memory and FULL against NORMAL need a computer with adb.

## 4. Deliverables

- **Kotlin:** `StorageBroker.kt`, the Pigeon `StorageApi`, the backup agent, and JVM unit tests.
- **Flutter:**
  - `SafFileService` and the larger `FileService` contract;
  - projects and recents (schema v2), with Home as the launcher;
  - the explorer's operations, file glyphs and Go to File;
  - the watcher;
  - the log sink, Settings → Privacy, the Developer action and tab semantics;
  - Save logs, Material Symbols Rounded icons, the debug log viewer and the `ProviderObserver`.
- **Editor:** the benchmark's plain-text pass.
- **CI:**
  - Pigeon codegen and its check;
  - the Kotlin unit tests and the manifest check;
  - the gate's `folders` and `watch` groups, with the picker driver;
  - one gate run with Impeller, the benchmark driver's reconnect, and golden diff images on failure.
- **Docs:** see §7, and the phone checklist (W7).

## 5. Acceptance criteria (measurable gates)

| Gate | Criterion | Evidence |
|---|---|---|
| **G1 Folders** | a device folder opens through Android's picker on the emulator, and its grant survives a process death<br>list, read, write, create, rename, move, copy and delete work through the real provider, each checked on disk<br>nothing outside the tree is reachable<br>a missing folder or a lost grant shows its status, without a crash | gate `folders` group + JVM tests |
| **G2 Projects & recents** | projects are created, renamed and deleted<br>recents show each entry's kind, location and status<br>switching keeps each workspace's tabs and unsaved text<br>the v1 → v2 migration passes from a fixture | unit + widget tests, migration test, gate |
| **G3 Explorer** | on both kinds of workspace: new file and folder, rename (case-only too), move, copy, duplicate and delete<br>open tabs and the journal follow every change<br>a name collision never overwrites<br>the tree builds only visible rows at 10,000 entries | service tests on a real folder + widget tests + gate |
| **G4 Outside changes** | an outside edit reaches a clean open document exactly, within 2 s on the emulator<br>unsaved text is never overwritten<br>new and deleted files reach the explorer<br>the app's own saves cause no reload<br>changes made in the background are caught on resume | gate `watch` group + unit tests |
| **G5 Restart** | after a process death, everything comes back: the last workspace (project or folder), its tabs with their unsaved text, its expanded folders and explorer scroll, and the recents | the restore pair, extended |
| **G6 Owner items** | backup is off by default<br>with it on, a backup and reinstall restore a project and its unsaved text, never the logs; with it off, they restore a fresh app<br>the log sink rotates, redacts and survives a crash<br>the Developer action writes byte-identical gate files, and the benchmark's plain-text pass runs<br>TalkBack hears the active tab and unsaved changes<br>project saves keep permission bits<br>the owner's items of 2026-11-11 (§0): Save logs, Material Symbols icons, the save digest off the UI isolate, the benchmark driver's reconnect, golden diff images, the debug log viewer and the `ProviderObserver` | JVM, unit and widget tests; gate (`bmgr`); W4 and W6 tests and gate runs |
| **G7 Performance** | the W6 measurements are recorded, on the renderer the app ships (after W6's Impeller run)<br>release cold start ≤ 1500 ms | gate JSON |
| **G8 Quality & security** | CI green (Flutter, editor and Kotlin)<br>no storage permission in the manifest<br>SECURITY §4's storage review done, each threat with its test<br>the accessibility suite covers the new chrome<br>no overflow with the keyboard up | run ids + review |
| **G9 Docs** | docs synced; PHASE_3_REPORT with run ids | review |

**Definition of done:** every gate is green with cited evidence, no critical issue is open, and the owner accepts the report. The phone checks (§0) are run in one session at the exit, by the owner's decision of 2026-11-11 (W7); they don't block acceptance unless the owner decides otherwise.

## 6. Tests

| Layer | Tool | Phase 3 additions |
|---|---|---|
| Kotlin/JVM unit | Gradle `testDebugUnitTest` (new in CI) | name validation, path resolution and scoping in the broker; the backup agent's choice |
| Dart unit | flutter_test | the larger `FileService` on a real temporary folder: create, rename (case-only too), move, copy, delete, collisions, permission bits<br>`SafFileService` against a fake broker<br>the v1 → v2 migration from a fixture<br>journal re-keying on rename<br>the watcher's coalescing and own-write filter<br>log rotation and redaction<br>Go to File's matching<br>the large-file generator's hashes<br>the save digest in a background isolate |
| Widget | flutter_test + fakes | Home's recents and their statuses; the explorer's menus, dialogs and keyboard navigation; tab semantics; Settings → Privacy; the virtualised tree at 10,000 entries; the debug log viewer's filters; Save logs |
| Integration (emulator) | integration_test + gate scripts | the `folders` group, through the real picker and provider; the `watch` group; the restore pair with a folder workspace and a switch; backup and restore with `bmgr`; the W6 measurements; the gate run with Impeller |

## 7. Documentation

Updated in W7:
- ARCHITECTURE §2–§4 (the broker, Pigeon and the data model, as built);
- EDITOR_ARCHITECTURE §6 (file watching and renames);
- SECURITY §1 and §4 (the storage review and backup);
- ADR-0008 (schema v2) and the new ADR-0012 (backup);
- RUNTIME_INTEGRATION §4 (the storage model, as built);
- TESTING, BUILD_AND_RELEASE (Pigeon codegen, the Kotlin tests, the new gate groups), TECH_STACK and PERFORMANCE §4;
- UI_DESIGN_SYSTEM (the explorer's menus, the file glyphs and the Material Symbols icons, as built);
- CHANGELOG, ROADMAP and README;
- the phone checklist for the exit session;
- the new PHASE_3_REPORT.

## 8. Known limitations (planned) and out of scope

**Out of scope:**
- running code, the terminal, and running from a folder (Phases 4–5);
- Git, including how it works on SAF folders (Phase 7, which ROADMAP gives a spike);
- search across files (Phase 4, by the owner's decision of 2026-11-11);
- a side-by-side view for conflicts (Phase 7's diff view);
- copying between projects and folders, as import and export (decided with the runtime in Phase 4);
- workspaces with several roots;
- encodings other than UTF-8 (full support in a later phase, by the owner's decision of 2026-11-11), and viewers for binary files.

**Planned limitations:**
- Saves to SAF folders are not atomic; the journal keeps the text until a save is confirmed (W2).
- Providers other than the device's shared storage are best effort.
- Watching covers what the user can see (up to 64 folders), plus stamp checks of open documents. A change deep inside a collapsed folder shows when that folder is opened.
- Frame-timed numbers come from an emulator until the parked phone runs.
- Undo history doesn't survive a process death; the unsaved text does (Phase 2; accepted by the owner on 2026-11-11).

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Android's folder picker is hard to automate in CI, and it differs between Android versions and makers | a host-side driver built like Phase 2's key injector, with retries, on the pinned API 36 image; the owner's picker is a parked phone check |
| SAF calls are slow, because each operation calls another process | folders listed only when expanded, one query per listing, a cache of document ids, and the timings measured in W6 |
| SAF saves are not atomic | write with mode `"wt"` and read the stamp back; a document stays unsaved, with its text in the journal, until the save is confirmed; a test writes shorter text over longer |
| Providers differ: names changed on create, case ignored, repeated names, no modified time | capabilities from the provider's flags; case-only renames through a temporary name; a SHA-256 stamp when there is no modified time; the device's shared storage tested, others best effort |
| Data lost on a rename, move or delete with unsaved changes | the journal is re-keyed in the same transaction; a delete keeps unsaved text in its tab; a test for each case |
| The first real schema migration | drift_dev's verifier and a fixture test from v1, with the harness built in Phase 2 W5 |
| Pigeon codegen without a local Flutter toolchain | CI's bootstrap generates and commits the code, and plain runs check it, as with Drift |
| Testing backup on the emulator, where the local transport may be missing | the agent's choice is unit-tested; `bmgr` where the image allows it; otherwise a parked phone check, stated in the report |
| Bursts of changes from other tools | 300 ms coalescing, only visible folders refreshed, at most 64 watched folders |
| Android's limit on how many grants an app keeps | removing a recent folder releases its grant, and the number of grants is logged |
| Impeller fails on the CI emulator, or a later Flutter removes the Skia opt-out | W6 tries Impeller in one gate run before measuring; if it fails, Skia stays, the owner is asked again, and Flutter stays at 3.47.9 until Phase 4's device testing |
