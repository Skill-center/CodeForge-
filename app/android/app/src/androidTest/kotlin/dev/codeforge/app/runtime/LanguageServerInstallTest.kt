package dev.codeforge.app.runtime

import android.content.Context
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FilterInputStream
import java.io.InputStream
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters

/**
 * Phase 6 W2, gate G2 on a device: the language servers the APK carries
 * (lsp/servers.json, each server's archive and manifest, built by
 * runtime/language_servers.py) install through LanguageServers as the app
 * installs them.
 *
 *   * a: each server installs from the APK's assets, every file verified
 *     against its manifest, and its folder holds exactly those files and the
 *     marker;
 *   * b: a later start (a new LanguageServers) reuses each one without
 *     extracting it again;
 *   * c: an archive with one byte changed is refused as damaged, leaving
 *     nothing at the server's place, and the APK's own archive then installs.
 *
 * The installer needs no runtime: only a folder (its root) and the assets.
 * Every figure goes to the device log (RUNTIME_GATE lsp_install_...) and to
 * files/runtime-gate/lsp-install-report.txt, which the gate copies out.
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class LanguageServerInstallTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val gate = File(context.filesDir, "runtime-gate")

    private fun record(key: String, value: Any?) {
        val line = "lsp_install_$key=$value"
        Log.i(TAG, "RUNTIME_GATE $line")
        gate.mkdirs()
        File(gate, REPORT).appendText(line + "\n")
    }

    private fun servers(root: File, source: PayloadSource = AssetPayloadSource(context)): LanguageServers =
        LanguageServers(source, root)

    @Test
    fun a_eachServerInstallsFromTheApkVerified() {
        File(gate, REPORT).delete()
        root(FIRST).deleteRecursively()
        val described = servers(root(FIRST)).available()
        record("servers", described.joinToString(",") { "${it.id}:${it.files}" })
        assertEquals("the APK's servers", listOf("pyright", "typescript"), described.map { it.id })
        for (server in described) {
            val installed = servers(root(FIRST)).ensure(server.id)
            val onDisk = installed.directory.walkTopDown().count { it.isFile }
            record(server.id, "reused=${installed.reused} files=${installed.files} on_disk=$onDisk bytes=${server.bytes} ms=${installed.millis}")
            assertFalse("${server.id}: an install was found before the first", installed.reused)
            assertEquals("${server.id}: the files verified", server.files, installed.files)
            assertEquals("${server.id}: the files in its folder (its own and the marker)", server.files + 1, onDisk)
            assertTrue("${server.id}: its entry ${server.entry}", installed.entry.isFile)
        }
    }

    @Test
    fun b_aLaterStartReusesEachServer() {
        for (server in servers(root(FIRST)).available()) {
            val installed = servers(root(FIRST)).ensure(server.id)
            record("${server.id}_again", "reused=${installed.reused} ms=${installed.millis}")
            assertTrue("${server.id}: extracted again", installed.reused)
        }
    }

    @Test
    fun c_aDamagedArchiveIsRefusedAndTheApksOwnThenInstalls() {
        val root = root(DAMAGED)
        root.deleteRecursively()
        val real = AssetPayloadSource(context)
        val server = servers(root, real).available().first { it.id == "pyright" }
        val damaged = object : PayloadSource {
            override fun abi(): String? = real.abi()

            override fun identity(abi: String): String? = real.identity(abi)

            override fun open(name: String): InputStream =
                if (name == server.archive) FlippedByte(real.open(name), FLIP_AT) else real.open(name)
        }
        try {
            servers(root, damaged).ensure(server.id)
            fail("an archive with a changed byte was installed")
        } catch (refused: LanguageServerFailure) {
            record("damaged", refused.problem.code)
            record("damaged_detail", refused.message?.take(200))
            assertEquals(LanguageServerProblem.DAMAGED, refused.problem)
        }
        val place = File(root, "codeforge/lsp/${server.id}")
        assertFalse("a refused server is at its place", place.exists())
        val installed = servers(root, real).ensure(server.id)
        record("after_damaged", "reused=${installed.reused} files=${installed.files}")
        assertFalse(installed.reused)
        assertEquals(server.files, installed.files)
    }

    private fun root(name: String): File = File(context.filesDir, "runtime-gate/lsp-install/$name")

    /** A stream whose byte at [at] is inverted. */
    private class FlippedByte(input: InputStream, private val at: Long) : FilterInputStream(input) {
        private var position = 0L

        override fun read(): Int {
            val value = super.read()
            if (value < 0) return value
            val flipped = if (position == at) value xor 0xff else value
            position += 1
            return flipped
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            val count = super.read(buffer, offset, length)
            if (count > 0) {
                if (at >= position && at < position + count) {
                    val index = offset + (at - position).toInt()
                    buffer[index] = (buffer[index].toInt() xor 0xff).toByte()
                }
                position += count
            }
            return count
        }
    }

    companion object {
        private const val TAG = "CodeForgeRuntimeGate"
        private const val REPORT = "lsp-install-report.txt"
        private const val FIRST = "first"
        private const val DAMAGED = "damaged"

        /** Inside Pyright's archive (about 6 MB), well past its first entries. */
        private const val FLIP_AT = 3_000_000L

        @JvmStatic
        @AfterClass
        fun removeTheServers() {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            File(context.filesDir, "runtime-gate/lsp-install").deleteRecursively()
        }
    }
}
