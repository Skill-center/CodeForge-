# ADR-0012: Android backup — the user's choice, off by default

**Status:** Accepted · 2026-11-10 · Owner decision at Phase 2's acceptance ("keep it as a offer to user, by default it's false") · Built in Phase 3 W1 ([PHASE_3_PLAN.md](../phases/PHASE_3_PLAN.md))

## Context
- **Until Phase 3, Android's Auto Backup was on by Android's default.** The manifest set neither `android:allowBackup` nor any rules (PHASE_2_REPORT §1, SECURITY §4). On a phone with device backup on, Android copied all the app's files to the user's Google Drive: the workspace, `codeforge.sqlite` with any unsaved text, and the settings.
- **Android's terms** ([Auto Backup](https://developer.android.com/identity/data/autobackup)):
  - Apps targeting API 23 and later take part unless they opt out.
  - Each app gets at most 25 MB in a private folder of the user's Drive, and only the latest backup is kept.
  - Backups run about once a day while the phone is idle and on Wi-Fi, and they are restored when the app is installed again.
  - The copy is end-to-end encrypted on Android 9 and later when the phone has a screen lock.
  - On Android 12 and later, a device-to-device transfer uses the same mechanism and its own rules section.
  - `getNoBackupFilesDir()` and the cache are never backed up.
- **The manifest decides for everyone.** `android:allowBackup` is all or nothing, so a per-user choice needs a `BackupAgent` that decides at backup time. Android runs that agent in a restricted mode, without the app's own startup, so Flutter is not running. The agent must therefore read the choice in Kotlin alone.
- **A transport declines an empty backup.** AOSP's `LocalTransport.checkFullBackupSize` rejects a size of 0 or less ("Decline zero-size backups"). `PerformFullTransportBackupTask` then reports `ERROR_TRANSPORT_PACKAGE_REJECTED` and skips the package, so the backup the transport already holds stays.
- **Android runs the agent twice per backup.** First comes a measuring pass (`doMeasureFullBackup`), then the real one; both call `onFullBackup`.

## Decision
1. **A switch, off by default.**
   - It sits in Settings → Privacy as *Back up with Android*.
   - It is stored in the host's own preferences file, `shared_prefs/codeforge.backup.xml` (`BackupSwitch.kt`), which the agent can read without Flutter.
   - Dart reads and sets it over the `dev.codeforge/backup` channel; W2 folds this into the Pigeon API.
   - A change is committed to disk before the switch shows it, and it calls `BackupManager.dataChanged()`.
2. **The agent decides.**
   - `CodeForgeBackupAgent` is declared in the manifest with `android:backupAgent` and `android:fullBackupOnly="true"`, so Android keeps file-based Auto Backup.
   - The rules files are `android:fullBackupContent` for Android 11 and lower, and `android:dataExtractionRules` for Android 12 and later.
   - On each pass, `BackupPolicy.content` picks one of three cases:
     - **On:** Android's own full backup, limited by the rules files to three things:
       - the projects: `files/workspaces`;
       - the database: `files/codeforge.sqlite` and its write-ahead log (SQLite rebuilds the `-shm` index);
       - the settings: `FlutterSharedPreferences.xml` and `codeforge.backup.xml`.
     - **Off, and the agent never wrote everything:** nothing. Android declines the empty backup, so a user who never turned the switch on has no backup of CodeForge at all.
     - **Off, after a pass that wrote everything:** only `codeforge.backup.xml`. An empty backup would be declined, and the one with everything would stay. This small file replaces it instead, so the backup Android keeps holds no project, text or settings.
   - *Ever wrote everything* is a flag in the same file. The measuring pass of a backup with everything sets it, so the backup carries it and a restore of that backup brings it back.
3. **Never in a backup:**
   - the logs (`no_backup/logs`, a folder Android never backs up);
   - caches and the WebView's data;
   - anything outside the app's own storage. Folders the user opens from shared storage (W2) belong to the user, not the app, so they are never part of a backup.
4. **One switch covers both kinds of transfer.**
   - A cloud backup and a device-to-device transfer take the same files: `<cloud-backup>` and `<device-transfer>` list the same includes.
   - There is no encryption requirement (`disableIfNoEncryptionCapabilities` is unset). The user decides, and the Privacy text states Android's terms.
5. **Settings shows what Android did.**
   - The agent records each pass: its time, cloud backup or device transfer, whether it was end-to-end encrypted, and what it wrote.
   - It also records each refusal as too large (`onQuotaExceeded`). Settings → Privacy shows both.
   - The agent sees its own pass, not the transport's verdict, so the row says "last backup run", not "backed up".
6. **Restores pass the same rules.** Everything a backup can hold is in the include list, the switch's own file included. `BackupPolicyTest` checks that both rules files list exactly `BackupPolicy.included`.

## Deviation from the plan
PHASE_3_PLAN W1 said that turning the switch off "makes the next backup empty". As built, that holds only while no backup with everything can exist. After one, an empty backup would be declined and the full one kept, the opposite of what turning the switch off means. So the agent writes the switch's file alone instead.

## Consequences
- **By default, Android keeps nothing of CodeForge.**
- **Switched on,** a backup and a reinstall bring back the projects, the unsaved text, the settings and the switch, but never the logs.
- **Switched off again,** the next backup holds only the switch, and a reinstall then brings back a fresh app.
- **Turning it off takes effect at Android's next backup** (about daily, when idle), not at once. An app cannot start a backup itself, because `BackupManager.requestBackup` is a system API. Until that backup runs, the one with everything stays, and it also stays if the app is uninstalled first.
- **Cases where an old backup with everything can stay:**
  - The app's data is cleared before the switch-only backup runs. The flag goes with the data, so the agent goes back to writing nothing.
  - A backup with everything from an earlier install is never restored, for example when the user turned off automatic restore. The new install does not know it exists.
  - In both cases, that backup stays until Android replaces or expires it. Both need the user to have turned backup on before.
- **A device-to-device transfer with the switch off** carries nothing, or only the switch.
- **Phase 10's export (ADR-0008) is separate,** an explicit user action. This ADR covers only Android's backup.
- **A restore stamps files with January 1970.**
  - AOSP's `FullBackup.restoreFile` passes the tar header's seconds to `File.setLastModified`, which takes milliseconds. The gate's restored files read 1970-01-21.
  - It also keeps only the owner's permission bits (`mode & 0700`).
  - The app compares file stamps only for equality and journals by digest, so nothing breaks. Code that shows modification times or orders files by them must not trust a restored file's.
- **Evidence:**
  - `BackupPolicyTest` (JVM);
  - the controller and Settings tests (Dart);
  - the phase gate's `backup` group, which runs `bmgr` against Android's local transport on the emulator (TESTING.md §1.3). First run: phase gate 42862715744 (PHASE_3_PLAN, *As built (W1)*).
  - A real Google account is a parked phone check.
