package dev.codeforge.app

/**
 * What Android's backup may take from CodeForge (ADR-0012), as plain data
 * that a JVM test can check (src/test, BackupPolicyTest).
 *
 * [CodeForgeBackupAgent] asks [content]. With the switch on, Android's own
 * full backup runs, filtered by the rules files, which must list exactly
 * [included]: res/xml/backup_rules.xml for Android 11 and lower,
 * res/xml/data_extraction_rules.xml (cloud backup and device-to-device
 * transfer) for Android 12 and later. Restores pass the same rules, so
 * whatever a backup holds must be in [included], the switch's own file
 * too. Logs live in `no_backup/`, which Android never backs up.
 */
object BackupPolicy {
    /** The host's preferences file that holds the switch ([BackupSwitch]). */
    const val PREFS = "codeforge.backup"

    /** Android's `BackupAgent.FLAG_CLIENT_SIDE_ENCRYPTION_ENABLED` (API 28). */
    const val FLAG_ENCRYPTED = 1

    /** Android's `BackupAgent.FLAG_DEVICE_TO_DEVICE_TRANSFER` (API 28). */
    const val FLAG_DEVICE_TRANSFER = 2

    /** One include rule: a domain of the rules files and a path inside it. */
    data class Location(val domain: String, val path: String)

    /**
     * What a backup holds with the switch on: the projects, the app
     * database (with its write-ahead log; the `-shm` index is rebuilt on
     * open) and the settings, Flutter's and the host's.
     */
    val included: List<Location> = listOf(
        Location("file", "workspaces"),
        Location("file", "codeforge.sqlite"),
        Location("file", "codeforge.sqlite-wal"),
        Location("sharedpref", "FlutterSharedPreferences.xml"),
        Location("sharedpref", "$PREFS.xml"),
    )

    /**
     * All a backup holds with the switch off once a backup with everything
     * may exist: the switch itself. Android keeps only the latest backup,
     * and a transport declines an empty one (Android's local transport
     * declines size 0) and keeps the earlier one. So after a backup with
     * everything, "off" writes this one small file, and the backup Android
     * keeps then holds no projects, text or settings.
     */
    val switchOnly: Location = Location("sharedpref", "$PREFS.xml")

    enum class Content(val id: String) {
        EVERYTHING("everything"),
        SWITCH_ONLY("switch"),
        NOTHING("nothing"),
    }

    /**
     * What the agent writes: everything only when the user said yes. With
     * the switch off, nothing at all until a backup with everything was
     * written (Android declines the empty backup and keeps none, so a user
     * who never said yes has no backup); after one, only the switch, which
     * replaces it.
     */
    fun content(enabled: Boolean, everWroteEverything: Boolean): Content = when {
        enabled -> Content.EVERYTHING
        everWroteEverything -> Content.SWITCH_ONLY
        else -> Content.NOTHING
    }

    enum class Kind(val id: String) { CLOUD("cloud"), DEVICE_TRANSFER("device") }

    /** A cloud backup or a device-to-device transfer, from the transport flags. */
    fun kind(transportFlags: Int): Kind =
        if ((transportFlags and FLAG_DEVICE_TRANSFER) != 0) Kind.DEVICE_TRANSFER else Kind.CLOUD

    /** Whether the transport encrypts end to end (Android 9+ with a screen lock). */
    fun encrypted(transportFlags: Int): Boolean = (transportFlags and FLAG_ENCRYPTED) != 0

    /** Whether [path] in [domain] is part of a backup with the switch on. */
    fun includes(domain: String, path: String): Boolean =
        included.any { it.domain == domain && (path == it.path || path.startsWith(it.path + "/")) }
}
