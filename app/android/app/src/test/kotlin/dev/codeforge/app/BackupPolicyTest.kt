package dev.codeforge.app

import android.app.backup.BackupAgent
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * The backup agent's choice (Phase 3 W1, ADR-0012, gate G6): off, nothing,
 * or only the switch once a backup with everything may exist; on, the
 * projects, the database and the settings; logs, caches and the WebView's
 * data never. The rules files Android applies must say
 * exactly what the policy says, for Android 11 and lower and for 12 and
 * later (cloud backup and device-to-device transfer alike).
 */
class BackupPolicyTest {
    @Test
    fun offByDefaultWritesNothing() {
        // Android declines an empty backup and keeps none: a user who never
        // turned the switch on has no backup at all.
        assertEquals(
            BackupPolicy.Content.NOTHING,
            BackupPolicy.content(enabled = false, everWroteEverything = false),
        )
    }

    @Test
    fun offAfterABackupWithEverythingWritesOnlyTheSwitch() {
        assertEquals(
            BackupPolicy.Content.SWITCH_ONLY,
            BackupPolicy.content(enabled = false, everWroteEverything = true),
        )
        assertEquals(BackupPolicy.Location("sharedpref", "codeforge.backup.xml"), BackupPolicy.switchOnly)
        // A restore passes the include rules: the switch's file must pass.
        assertTrue(BackupPolicy.switchOnly in BackupPolicy.included)
    }

    @Test
    fun switchOnBacksUpProjectsDatabaseAndSettings() {
        for (ever in listOf(false, true)) {
            assertEquals(
                BackupPolicy.Content.EVERYTHING,
                BackupPolicy.content(enabled = true, everWroteEverything = ever),
            )
        }
        assertTrue(BackupPolicy.includes("file", "workspaces"))
        assertTrue(BackupPolicy.includes("file", "workspaces/demo/main.js"))
        assertTrue(BackupPolicy.includes("file", "codeforge.sqlite"))
        assertTrue(BackupPolicy.includes("file", "codeforge.sqlite-wal"))
        assertTrue(BackupPolicy.includes("sharedpref", "FlutterSharedPreferences.xml"))
        assertTrue(BackupPolicy.includes("sharedpref", "codeforge.backup.xml"))
    }

    @Test
    fun neverLogsCachesOrTheWebView() {
        assertFalse(BackupPolicy.includes("root", "no_backup/logs/codeforge.log"))
        assertFalse(BackupPolicy.includes("root", "cache/WebView/x"))
        assertFalse(BackupPolicy.includes("root", "app_webview/Default/Cookies"))
        assertFalse(BackupPolicy.includes("file", "codeforge.sqlite-shm"))
        assertFalse(BackupPolicy.includes("file", "largegate/ack.1.ok"))
        assertFalse(BackupPolicy.includes("file", "workspaces-old/x"))
        assertTrue(BackupPolicy.included.none { it.domain == "root" || it.domain == "external" })
    }

    @Test
    fun transportFlagsNameTheKindOfTransfer() {
        assertEquals(BackupAgent.FLAG_CLIENT_SIDE_ENCRYPTION_ENABLED, BackupPolicy.FLAG_ENCRYPTED)
        assertEquals(BackupAgent.FLAG_DEVICE_TO_DEVICE_TRANSFER, BackupPolicy.FLAG_DEVICE_TRANSFER)
        assertEquals(BackupPolicy.Kind.CLOUD, BackupPolicy.kind(0))
        assertEquals(BackupPolicy.Kind.CLOUD, BackupPolicy.kind(BackupPolicy.FLAG_ENCRYPTED))
        assertEquals(BackupPolicy.Kind.DEVICE_TRANSFER, BackupPolicy.kind(BackupPolicy.FLAG_DEVICE_TRANSFER))
        assertEquals(BackupPolicy.Kind.DEVICE_TRANSFER, BackupPolicy.kind(3))
        assertTrue(BackupPolicy.encrypted(3))
        assertFalse(BackupPolicy.encrypted(BackupPolicy.FLAG_DEVICE_TRANSFER))
    }

    @Test
    fun androidElevenRulesListExactlyThePolicy() {
        val root = parse("backup_rules.xml").documentElement
        assertEquals("full-backup-content", root.tagName)
        assertEquals(BackupPolicy.included.toSet(), includes(root))
        assertEquals(0, root.getElementsByTagName("exclude").length)
    }

    @Test
    fun androidTwelveRulesListExactlyThePolicyForCloudAndTransfer() {
        val root = parse("data_extraction_rules.xml").documentElement
        assertEquals("data-extraction-rules", root.tagName)
        for (section in listOf("cloud-backup", "device-transfer")) {
            val sections = root.getElementsByTagName(section)
            assertEquals(section, 1, sections.length)
            val element = sections.item(0) as Element
            assertEquals(section, BackupPolicy.included.toSet(), includes(element))
            // No encryption requirement: the switch is the user's choice,
            // and the Settings text states Android's terms.
            assertEquals(section, "", element.getAttribute("disableIfNoEncryptionCapabilities"))
        }
    }

    // Gradle runs unit tests in the module's folder (android/app).
    private fun parse(name: String) =
        DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(File("src/main/res/xml/$name"))

    private fun includes(element: Element): Set<BackupPolicy.Location> {
        val nodes = element.getElementsByTagName("include")
        return (0 until nodes.length)
            .map { nodes.item(it) as Element }
            .onEach { assertEquals("", it.getAttribute("requireFlags")) }
            .map { BackupPolicy.Location(it.getAttribute("domain"), it.getAttribute("path")) }
            .toSet()
    }
}
