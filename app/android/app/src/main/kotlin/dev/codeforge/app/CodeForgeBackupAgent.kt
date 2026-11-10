package dev.codeforge.app

import android.app.backup.BackupAgent
import android.app.backup.BackupDataInput
import android.app.backup.BackupDataOutput
import android.app.backup.FullBackupDataOutput
import android.os.Build
import android.os.ParcelFileDescriptor

/**
 * Android's backup, only when the user turned it on (ADR-0012).
 *
 * The manifest names this agent with `android:fullBackupOnly="true"`, so
 * Android keeps file-based Auto Backup and calls [onFullBackup] for a cloud
 * backup and for a device-to-device transfer alike; the transport flags say
 * which, and the same switch covers both. Android runs the agent without
 * the app's own startup, so it reads the switch from the host's preferences
 * file ([BackupSwitch]).
 *
 * - Switch on: Android's default full backup, which the rules files limit
 *   to the projects, the database and the settings ([BackupPolicy.included]).
 * - Switch off, and it never wrote everything: nothing. Android declines an
 *   empty backup, so a user who never turned it on has no backup at all.
 * - Switch off after it wrote everything: only the switch's own file
 *   ([BackupPolicy.switchOnly]), so that the backup Android keeps holds no
 *   projects, text or settings (an empty backup would be declined, and the
 *   one with everything kept).
 */
class CodeForgeBackupAgent : BackupAgent() {
    // Key-value backup is not used (android:fullBackupOnly="true"); Android
    // requires the two methods all the same.
    override fun onBackup(
        oldState: ParcelFileDescriptor?,
        data: BackupDataOutput?,
        newState: ParcelFileDescriptor?,
    ) = Unit

    override fun onRestore(
        data: BackupDataInput?,
        appVersionCode: Int,
        newState: ParcelFileDescriptor?,
    ) = Unit

    override fun onFullBackup(data: FullBackupDataOutput) {
        val backup = BackupSwitch(this)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) data.transportFlags else 0
        val content = BackupPolicy.content(backup.enabled, backup.everWroteEverything)
        when (content) {
            BackupPolicy.Content.EVERYTHING -> super.onFullBackup(data)
            BackupPolicy.Content.SWITCH_ONLY -> {
                backup.ensureStored()
                fullBackupFile(backup.file, data)
            }
            BackupPolicy.Content.NOTHING -> Unit
        }
        // After the files: the record never changes what this pass wrote.
        backup.recordRun(flags, content, System.currentTimeMillis())
    }

    override fun onQuotaExceeded(backupDataBytes: Long, quotaBytes: Long) {
        BackupSwitch(this).recordQuotaExceeded(backupDataBytes, quotaBytes, System.currentTimeMillis())
    }
}
