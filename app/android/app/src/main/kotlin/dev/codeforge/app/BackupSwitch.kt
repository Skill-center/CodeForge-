package dev.codeforge.app

import android.content.Context
import java.io.File

/**
 * The backup switch, off unless the user turns it on, and what Android last
 * did with it (ADR-0012).
 *
 * It lives in the host's own preferences file ([BackupPolicy.PREFS]), not
 * in Flutter's: Android runs the backup agent in a restricted mode, without
 * the app's own startup. Dart reads and sets it over the
 * `dev.codeforge/backup` channel (MainActivity), a plain MethodChannel:
 * Phase 3 W2 kept it out of the storage broker's Pigeon API. Every write is
 * a `commit()`: the agent's process may end as soon as it returns.
 */
class BackupSwitch(private val context: Context) {
    private val prefs = context.getSharedPreferences(BackupPolicy.PREFS, Context.MODE_PRIVATE)

    val enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, false)

    /**
     * Whether the agent ever wrote everything (in this install, or in the
     * one a restore came from): a backup with everything may then exist.
     */
    val everWroteEverything: Boolean
        get() = prefs.getBoolean(KEY_EVER_EVERYTHING, false)

    /** The preferences file itself: all a backup holds while the switch is off. */
    val file: File
        get() = File(context.dataDir, "shared_prefs/${BackupPolicy.PREFS}.xml")

    /** Sets the switch; true once it is on disk. */
    fun setEnabled(value: Boolean): Boolean = prefs.edit().putBoolean(KEY_ENABLED, value).commit()

    /** Writes the switch's default if it was never set, so that [file] exists. */
    fun ensureStored() {
        if (!prefs.contains(KEY_ENABLED)) {
            prefs.edit().putBoolean(KEY_ENABLED, false).commit()
        }
    }

    /** The agent ran: when, for which kind of transfer, and what it wrote. */
    fun recordRun(transportFlags: Int, content: BackupPolicy.Content, atMillis: Long) {
        val edit = prefs.edit()
            .putLong(KEY_LAST_RUN_AT, atMillis)
            .putString(KEY_LAST_RUN_KIND, BackupPolicy.kind(transportFlags).id)
            .putBoolean(KEY_LAST_RUN_ENCRYPTED, BackupPolicy.encrypted(transportFlags))
            .putString(KEY_LAST_RUN_CONTENT, content.id)
        if (content == BackupPolicy.Content.EVERYTHING) {
            edit.putBoolean(KEY_EVER_EVERYTHING, true)
        }
        edit.commit()
    }

    /** Android refused a backup as too large (it keeps the previous one). */
    fun recordQuotaExceeded(backupBytes: Long, quotaBytes: Long, atMillis: Long) {
        prefs.edit()
            .putLong(KEY_QUOTA_AT, atMillis)
            .putLong(KEY_QUOTA_BACKUP_BYTES, backupBytes)
            .putLong(KEY_QUOTA_BYTES, quotaBytes)
            .commit()
    }

    /** What the backup channel reports; 0 means never. */
    fun status(): Map<String, Any?> = mapOf(
        "enabled" to enabled,
        "lastRunAt" to prefs.getLong(KEY_LAST_RUN_AT, 0L),
        "lastRunKind" to prefs.getString(KEY_LAST_RUN_KIND, null),
        "lastRunEncrypted" to prefs.getBoolean(KEY_LAST_RUN_ENCRYPTED, false),
        "lastRunContent" to prefs.getString(KEY_LAST_RUN_CONTENT, null),
        "quotaExceededAt" to prefs.getLong(KEY_QUOTA_AT, 0L),
        "quotaBackupBytes" to prefs.getLong(KEY_QUOTA_BACKUP_BYTES, 0L),
        "quotaBytes" to prefs.getLong(KEY_QUOTA_BYTES, 0L),
    )

    private companion object {
        const val KEY_ENABLED = "enabled"
        const val KEY_EVER_EVERYTHING = "everWroteEverything"
        const val KEY_LAST_RUN_AT = "lastRunAt"
        const val KEY_LAST_RUN_KIND = "lastRunKind"
        const val KEY_LAST_RUN_ENCRYPTED = "lastRunEncrypted"
        const val KEY_LAST_RUN_CONTENT = "lastRunContent"
        const val KEY_QUOTA_AT = "quotaExceededAt"
        const val KEY_QUOTA_BACKUP_BYTES = "quotaBackupBytes"
        const val KEY_QUOTA_BYTES = "quotaBytes"
    }
}
