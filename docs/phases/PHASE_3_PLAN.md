# Phase 3 Implementation Plan — Workspace & Files

**Status:** **In progress** (2026-11-10): W1 built, see *As built (W1)*; the owner's "next" starts W2 · Prerequisite: Phase 2 accepted on 2026-11-10 ([report](PHASE_2_REPORT.md)), with the phone checks parked · Blocks: nothing external (no runtime, licence decision or phone is needed to start)
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

**The phone checks stay parked** (ROADMAP, "Parked owner checks"). Phase 3 adds its own: the folder picker and a folder workspace on the owner's phone, and backup with a real Google account. None of them blocks acceptance unless the owner decides otherwise.

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
- **Evidence:** CI and phase-gate run ids are added after the runs.

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

### W3 — Projects, recents and state (1–2 sessions) → G2, G5

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

**Go to File** (Ctrl+P, and in the palette):
- fuzzy matching over the workspace's file names, from an index built in the background and kept current by W5;
- `.git` and `node_modules` are skipped by default, and the index stops at 50,000 entries and says so.

This is the plan's one addition to ROADMAP's list: with real projects, finding a file by name is basic navigation. The owner can drop it.

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
- **New parked phone checks:** the folder picker and a folder workspace on the owner's phone, whose picker may differ from the emulator's, and backup with a real Google account.

### W7 — Documentation and phase exit (0.5 session) → G9

PHASE_3_REPORT.md with run ids, and the documents in §7.

## 4. Deliverables

- **Kotlin:** `StorageBroker.kt`, the Pigeon `StorageApi`, the backup agent, and JVM unit tests.
- **Flutter:**
  - `SafFileService` and the larger `FileService` contract;
  - projects and recents (schema v2), with Home as the launcher;
  - the explorer's operations, file glyphs and Go to File;
  - the watcher;
  - the log sink, Settings → Privacy, the Developer action and tab semantics.
- **Editor:** the benchmark's plain-text pass.
- **CI:**
  - Pigeon codegen and its check;
  - the Kotlin unit tests and the manifest check;
  - the gate's `folders` and `watch` groups, with the picker driver.
- **Docs:** see §7.

## 5. Acceptance criteria (measurable gates)

| Gate | Criterion | Evidence |
|---|---|---|
| **G1 Folders** | a device folder opens through Android's picker on the emulator, and its grant survives a process death<br>list, read, write, create, rename, move, copy and delete work through the real provider, each checked on disk<br>nothing outside the tree is reachable<br>a missing folder or a lost grant shows its status, without a crash | gate `folders` group + JVM tests |
| **G2 Projects & recents** | projects are created, renamed and deleted<br>recents show each entry's kind, location and status<br>switching keeps each workspace's tabs and unsaved text<br>the v1 → v2 migration passes from a fixture | unit + widget tests, migration test, gate |
| **G3 Explorer** | on both kinds of workspace: new file and folder, rename (case-only too), move, copy, duplicate and delete<br>open tabs and the journal follow every change<br>a name collision never overwrites<br>the tree builds only visible rows at 10,000 entries | service tests on a real folder + widget tests + gate |
| **G4 Outside changes** | an outside edit reaches a clean open document exactly, within 2 s on the emulator<br>unsaved text is never overwritten<br>new and deleted files reach the explorer<br>the app's own saves cause no reload<br>changes made in the background are caught on resume | gate `watch` group + unit tests |
| **G5 Restart** | after a process death, everything comes back: the last workspace (project or folder), its tabs with their unsaved text, its expanded folders and explorer scroll, and the recents | the restore pair, extended |
| **G6 Owner items** | backup is off by default<br>with it on, a backup and reinstall restore a project and its unsaved text, never the logs; with it off, they restore a fresh app<br>the log sink rotates, redacts and survives a crash<br>the Developer action writes byte-identical gate files, and the benchmark's plain-text pass runs<br>TalkBack hears the active tab and unsaved changes<br>project saves keep permission bits | JVM, unit and widget tests; gate (`bmgr`) |
| **G7 Performance** | the W6 measurements are recorded<br>release cold start ≤ 1500 ms | gate JSON |
| **G8 Quality & security** | CI green (Flutter, editor and Kotlin)<br>no storage permission in the manifest<br>SECURITY §4's storage review done, each threat with its test<br>the accessibility suite covers the new chrome<br>no overflow with the keyboard up | run ids + review |
| **G9 Docs** | docs synced; PHASE_3_REPORT with run ids | review |

**Definition of done:** every gate is green with cited evidence, no critical issue is open, and the owner accepts the report. The phone checks (§0) stay parked and don't block acceptance unless the owner decides otherwise.

## 6. Tests

| Layer | Tool | Phase 3 additions |
|---|---|---|
| Kotlin/JVM unit | Gradle `testDebugUnitTest` (new in CI) | name validation, path resolution and scoping in the broker; the backup agent's choice |
| Dart unit | flutter_test | the larger `FileService` on a real temporary folder: create, rename (case-only too), move, copy, delete, collisions, permission bits<br>`SafFileService` against a fake broker<br>the v1 → v2 migration from a fixture<br>journal re-keying on rename<br>the watcher's coalescing and own-write filter<br>log rotation and redaction<br>Go to File's matching<br>the large-file generator's hashes |
| Widget | flutter_test + fakes | Home's recents and their statuses; the explorer's menus, dialogs and keyboard navigation; tab semantics; Settings → Privacy; the virtualised tree at 10,000 entries |
| Integration (emulator) | integration_test + gate scripts | the `folders` group, through the real picker and provider; the `watch` group; the restore pair with a folder workspace and a switch; backup and restore with `bmgr`; the W6 measurements |

## 7. Documentation

Updated in W7:
- ARCHITECTURE §2–§4 (the broker, Pigeon and the data model, as built);
- EDITOR_ARCHITECTURE §6 (file watching and renames);
- SECURITY §1 and §4 (the storage review and backup);
- ADR-0008 (schema v2) and the new ADR-0012 (backup);
- RUNTIME_INTEGRATION §4 (the storage model, as built);
- TESTING, BUILD_AND_RELEASE (Pigeon codegen, the Kotlin tests, the new gate groups), TECH_STACK and PERFORMANCE §4;
- UI_DESIGN_SYSTEM (the explorer's menus and file glyphs);
- CHANGELOG, ROADMAP and README;
- the new PHASE_3_REPORT.

## 8. Known limitations (planned) and out of scope

**Out of scope:**
- running code, the terminal, and running from a folder (Phases 4–5);
- Git, including how it works on SAF folders (Phase 7, which ROADMAP gives a spike);
- search across files (not yet placed in ROADMAP);
- a side-by-side view for conflicts (Phase 7's diff view);
- copying between projects and folders, as import and export (decided with the runtime in Phase 4);
- workspaces with several roots;
- encodings other than UTF-8, and viewers for binary files.

**Planned limitations:**
- Saves to SAF folders are not atomic; the journal keeps the text until a save is confirmed (W2).
- Providers other than the device's shared storage are best effort.
- Watching covers what the user can see (up to 64 folders), plus stamp checks of open documents. A change deep inside a collapsed folder shows when that folder is opened.
- Frame-timed numbers come from an emulator until the parked phone runs.

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
