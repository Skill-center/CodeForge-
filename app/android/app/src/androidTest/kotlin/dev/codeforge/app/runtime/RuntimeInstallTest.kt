package dev.codeforge.app.runtime

import android.content.Context
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.codeforge.runtime.core.HarnessConfig
import dev.codeforge.runtime.core.exec.SealedPayloadInstaller
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FilterInputStream
import java.io.InputStream
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters

/**
 * Gate G3 on a device (Phase 4 W3): the APK's own payload installed, audited,
 * started warm, and broken on purpose. The emulator gate's runtime group runs
 * it on x86_64 (app/tool/ci/emulator_gate.sh); Phase 4 W5 runs it on an arm64
 * phone in Firebase Test Lab.
 *
 * Every figure goes to the device log (RUNTIME_GATE key=value) and to
 * files/runtime-gate/report.txt, which the gate copies out. The installs go
 * to their own roots under files/runtime-gate, never the app's runtime.
 */
@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class RuntimeInstallTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val gate = File(context.filesDir, "runtime-gate")
    private val nativeLibraries = File(context.applicationInfo.nativeLibraryDir)
    private val apkBytes: Long get() = File(context.applicationInfo.sourceDir).length()

    /** t1's HarnessPaths layout, under a root of the gate's own. */
    private fun config(name: String): HarnessConfig {
        val root = File(gate, name)
        val rootfs = File(root, "rootfs")
        val prefix = File(rootfs, "data/data/com.termux/files/usr")
        return HarnessConfig.Builder()
            .workspace(File(root, "workspace"))
            .home(File(root, "home"))
            .prefix(prefix)
            .rootfs(rootfs)
            .toolDirectory(File(prefix, "bin"))
            .libraryDirectory(File(prefix, "lib"))
            .nativeLibraryDirectory(nativeLibraries)
            .build()
    }

    private fun runtime(name: String, source: PayloadSource = AssetPayloadSource(context)) =
        SealedRuntime(source, config(name))

    private fun record(key: String, value: Any?) {
        val line = "$key=$value"
        Log.i(TAG, "RUNTIME_GATE $line")
        gate.mkdirs()
        File(gate, "report.txt").appendText(line + "\n")
    }

    private fun failureOf(block: () -> Unit): RuntimeFailure? =
        try {
            block()
            null
        } catch (failure: RuntimeFailure) {
            failure
        }

    @Test
    fun a_theApkCarriesThePayloadAndThePreload() {
        File(gate, "report.txt").delete()
        val source = AssetPayloadSource(context)
        val abi = source.abi()
        record("abi", abi)
        assertNotNull("this APK carries no runtime payload for this device", abi)
        record("payload", source.identity(abi!!))
        record("apk_bytes", apkBytes)
        // Extracted at install (legacy packaging): real files in nativeLibraryDir.
        assertTrue(File(nativeLibraries, "libharness-exec.so").isFile)
        assertTrue(File(nativeLibraries, "libharnessprobe.so").isFile)
        val executables = SealedPayloadInstaller.readManifestLines(context, abi, "", "exec")
            .count { it.isNotBlank() && !it.startsWith("#") }
        record("exec_manifest_entries", executables)
        assertTrue(executables > 100)
    }

    @Test
    fun b_aFirstInstallVerifiesEveryFileAndAuditsClean() {
        File(gate, "main").deleteRecursively()
        val sealed = runtime("main")
        var notices = 0
        var lastDone = 0
        var lastTotal = 0
        val result = sealed.install { done, total ->
            notices++
            lastDone = done
            lastTotal = total
        }
        record("first_install_ms", result.millis)
        record("first_install_files", result.files)
        record("first_install_verified", result.verified)
        record("first_install_bytes", result.bytes)
        record("first_install_executables", result.executables)
        record("first_install_links", result.links)
        assertEquals(result.files, result.verified)
        assertEquals(lastTotal, result.files)
        assertEquals(lastTotal, lastDone)
        assertTrue(notices > 0)
        assertTrue(result.executables > 100)
        assertNotNull(runtime("main").installed())

        val audit = sealed.audit()
        record("audit_outside_apk", audit.outsideApk)
        record("audit_outside_scripts", audit.outsideScripts)
        record("audit_shipped", audit.shipped)
        record("audit_scanned", audit.scanned)
        record("audit_truncated", audit.truncated)
        record("audit_ms", audit.millis)
        assertNull(audit.failure)
        assertFalse(audit.truncated)
        assertEquals(audit.report, 0, audit.outsideApk)
        assertTrue(audit.shipped > 100)

        val sizes = sealed.sizes(apkBytes)
        record("prefix_bytes", sizes.prefixBytes)
        record("prefix_files", sizes.prefixFiles)
        record("native_library_bytes", sizes.nativeLibraryBytes)
        record("installed_total_bytes", sizes.prefixBytes + sizes.nativeLibraryBytes + sizes.apkBytes)
    }

    @Test
    fun c_aWarmStartSkipsTheExtraction() {
        val samples = (1..5).map {
            val started = System.nanoTime()
            val sealed = runtime("main")
            assertNotNull(sealed.installed())
            val warm = sealed.warmStart()
            assertEquals(0, warm.relinked)
            (System.nanoTime() - started) / 1_000_000L
        }
        val median = samples.sorted()[samples.size / 2]
        record("warm_start_ms_samples", samples.joinToString(","))
        record("warm_start_ms_median", median)
        record("warm_start_budget_ms", 100)
        assertTrue("the warm start took $median ms; the budget is 100 ms", median <= 100)
        val audit = runtime("main").audit()
        record("warm_audit_outside_apk", audit.outsideApk)
        record("warm_audit_ms", audit.millis)
        assertEquals(audit.report, 0, audit.outsideApk)
    }

    @Test
    fun d_aLinkThatPointsElsewhereIsRepointed() {
        // An updated app gets a new native library directory, so every link
        // the last install made points at a path that is gone: the warm start
        // finds them and points them at this APK's libraries again.
        val exec = SealedPayloadInstaller.readManifestLines(context, AssetPayloadSource(context).abi()!!, "", "exec")
            .first { it.isNotBlank() && !it.startsWith("#") }
        val (path, library) = exec.split('\t')
        val link = File(config("main").prefix, path)
        Files.delete(link.toPath())
        Files.createSymbolicLink(link.toPath(), File("/data/app/gone/lib/$library").toPath())
        val warm = runtime("main").warmStart()
        record("relinked_after_move", warm.relinked)
        assertEquals(1, warm.relinked)
        assertEquals(File(nativeLibraries, library).absolutePath, Files.readSymbolicLink(link.toPath()).toString())
    }

    @Test
    fun e_aFlippedByteFailsTypedAndIsNeverMarkedInstalled() {
        File(gate, "flipped").deleteRecursively()
        val source = FlippingSource(AssetPayloadSource(context), FLIP_OFFSET)
        val failure = failureOf { runtime("flipped", source).install(null) }
        record("flipped_byte_offset", FLIP_OFFSET)
        record("flipped_byte_problem", failure?.problem?.code)
        record("flipped_byte_detail", failure?.message)
        assertTrue("the byte was never read", source.flipped)
        assertNotNull("an install with a flipped byte succeeded", failure)
        assertTrue(
            failure!!.problem.code,
            failure.problem == RuntimeProblem.CORRUPT || failure.problem == RuntimeProblem.INCOMPLETE,
        )
        assertFalse(File(gate, "flipped/codeforge/installed.properties").exists())
        assertNull(runtime("flipped").installed())
        File(gate, "flipped").deleteRecursively()
    }

    @Test
    fun f_aFileThatDiffersFromItsManifestFailsTyped() {
        // One digit of the manifest's first digest changed: every file is
        // verified as it is written, so the install fails, and nothing is
        // marked installed.
        File(gate, "digest").deleteRecursively()
        val source = DigestFlippingSource(AssetPayloadSource(context))
        val failure = failureOf { runtime("digest", source).install(null) }
        record("digest_problem", failure?.problem?.code)
        record("digest_detail", failure?.message)
        assertNotNull("an install with a wrong digest succeeded", failure)
        assertEquals(RuntimeProblem.CORRUPT, failure!!.problem)
        assertTrue(failure.message, failure.message!!.contains("digest differs"))
        assertFalse(File(gate, "digest/codeforge/installed.properties").exists())
        assertNull(runtime("digest").installed())
        File(gate, "digest").deleteRecursively()
    }

    /** The payload, with one byte of the userland zip inverted. */
    private class FlippingSource(private val inner: PayloadSource, private val offset: Long) : PayloadSource by inner {
        @Volatile
        var flipped = false

        override fun open(name: String): InputStream {
            val stream = inner.open(name)
            if (!name.startsWith("userland-")) return stream
            return object : FilterInputStream(stream) {
                private var position = 0L

                override fun read(): Int {
                    val value = super.read()
                    if (value < 0) return value
                    val result = if (position == offset) flip(value) else value
                    position++
                    return result
                }

                override fun read(buffer: ByteArray, start: Int, length: Int): Int {
                    val count = super.read(buffer, start, length)
                    if (count > 0 && offset >= position && offset < position + count) {
                        val index = start + (offset - position).toInt()
                        buffer[index] = flip(buffer[index].toInt()).toByte()
                    }
                    if (count > 0) position += count
                    return count
                }

                private fun flip(value: Int): Int {
                    flipped = true
                    return value xor 0xff
                }
            }
        }
    }

    /** The payload, with one digit of the manifest's first digest changed. */
    private class DigestFlippingSource(private val inner: PayloadSource) : PayloadSource by inner {
        override fun open(name: String): InputStream {
            if (!name.startsWith("sealed-manifest-")) return inner.open(name)
            val lines = inner.open(name).bufferedReader(Charsets.UTF_8).use { it.readLines() }.toMutableList()
            val index = lines.indexOfFirst { it.isNotBlank() && !it.startsWith("#") }
            val digest = lines[index].substringBefore('\t')
            val changed = (if (digest[0] == '0') '1' else '0') + digest.substring(1)
            lines[index] = changed + lines[index].substring(digest.length)
            return ByteArrayInputStream((lines.joinToString("\n") + "\n").toByteArray(Charsets.UTF_8))
        }
    }

    private companion object {
        const val TAG = "CodeForgeRuntimeGate"

        /** 32 MiB into the userland zip (about 98 MB): inside an entry, far from the end. */
        const val FLIP_OFFSET = 32L * 1024L * 1024L
    }
}
