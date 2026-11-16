package dev.codeforge.app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.zip.ZipException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The runtime host's install, warm start and audit (Phase 4 W3, gate G3) on
 * a synthetic payload, through t1's kernel: a verified install is marked
 * installed, a failed one never is, and each failure has its type.
 */
class SealedRuntimeTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var root: File
    private lateinit var libraries: File

    @Before
    fun setUp() {
        root = temp.newFolder("harness")
        libraries = temp.newFolder("lib")
        TestPayload.writeLibraries(libraries)
    }

    private fun runtime(
        payload: TestPayload = TestPayload(),
        source: PayloadSource = payload.source(),
        nativeLibraries: File = libraries,
        free: Long? = null,
    ): SealedRuntime = SealedRuntime(
        source,
        TestPayload.configFor(root, nativeLibraries),
        freeSpace = { directory -> free ?: directory.usableSpace },
    )

    private val prefix: File get() = File(root, "rootfs/data/data/com.termux/files/usr")
    private val marker: File get() = File(root, "codeforge/installed.properties")

    private fun linkTarget(path: String): String =
        Files.readSymbolicLink(File(prefix, path).toPath()).toString()

    @Test
    fun installsVerifiesAndLinksThePayload() {
        val payload = TestPayload()
        val progress = mutableListOf<Pair<Int, Int>>()
        val result = runtime(payload).install { done, total -> progress.add(done to total) }

        assertEquals(payload.files.size, result.files)
        assertEquals(payload.files.size, result.verified)
        assertEquals(payload.bytes, result.bytes)
        assertEquals(2, result.executables)
        assertEquals(1, result.links)
        assertEquals(payload.files.size to payload.files.size, progress.last())
        // Executables are links into the native library directory, data is data.
        assertEquals(File(libraries, "libsh.so").absolutePath, linkTarget("bin/sh"))
        assertEquals(File(libraries, "libtool.so").absolutePath, linkTarget("bin/tool"))
        assertEquals(File(prefix, "lib/libfoo.so.1").absolutePath, linkTarget("lib/libfoo.so"))
        assertTrue(File(prefix, "etc/profile").isFile)
        assertTrue(marker.isFile)
        val installed = runtime(payload).installed()
        assertNotNull(installed)
        assertEquals("0123456789abcdef", installed!!.identity)
        assertEquals("x86_64", installed.abi)
        assertEquals("{\"abi\": \"x86_64\", \"bootstrap\": \"test\"}\n", runtime(payload).payload()!!.info)
    }

    @Test
    fun theAuditOfAFreshInstallIsClean() {
        runtime().install(null)
        val audit = runtime().audit()
        assertEquals(0, audit.outsideApk)
        assertEquals(2, audit.shipped)
        assertFalse(audit.truncated)
        assertTrue(audit.clean)
        assertTrue(File(root, "codeforge/exec-audit.txt").isFile)
    }

    @Test
    fun aWarmStartExtractsNothingAndFollowsMovedLibraries() {
        runtime().install(null)
        // Removed after the install, so an extraction would bring it back.
        File(prefix, "etc/profile").delete()
        // Android gives an updated app a new native library directory.
        val moved = temp.newFolder("lib-after-update")
        TestPayload.writeLibraries(moved)

        val warm = runtime(nativeLibraries = moved)
        assertNotNull(warm.installed())
        assertEquals(2, warm.warmStart().relinked)
        assertEquals(File(moved, "libsh.so").absolutePath, linkTarget("bin/sh"))
        assertEquals(0, runtime(nativeLibraries = moved).warmStart().relinked)
        assertFalse(File(prefix, "etc/profile").exists())
        assertTrue(runtime(nativeLibraries = moved).audit().clean)
    }

    @Test
    fun anotherPayloadIsNotAWarmStart() {
        runtime().install(null)
        assertNull(runtime(TestPayload(identity = "fedcba9876543210")).installed())
        assertNull(runtime(TestPayload(identity = null)).installed())
    }

    @Test
    fun aFlippedByteInTheArchiveFailsTypedAndIsNeverMarkedInstalled() {
        val payload = TestPayload()
        val flipped = payload.source { name, data ->
            if (name.startsWith("userland-")) TestPayload.flip(data, data.size / 2) else data
        }
        val failure = assertThrows(RuntimeFailure::class.java) { runtime(payload, flipped).install(null) }
        assertTrue(
            failure.problem.toString(),
            failure.problem == RuntimeProblem.CORRUPT || failure.problem == RuntimeProblem.INCOMPLETE,
        )
        assertFalse(marker.exists())
        assertNull(runtime(payload, flipped).installed())
        assertNull(runtime(payload).installed())
    }

    @Test
    fun aFileThatDiffersFromItsManifestFailsAsCorrupt() {
        val payload = TestPayload(wrongDigestFor = "etc/profile")
        val failure = assertThrows(RuntimeFailure::class.java) { runtime(payload).install(null) }
        assertEquals(RuntimeProblem.CORRUPT, failure.problem)
        assertTrue(failure.message, failure.message!!.contains("digest differs: etc/profile"))
        assertFalse(marker.exists())
        assertNull(runtime(payload).installed())
    }

    @Test
    fun aFileMissingFromThePayloadFailsAsIncomplete() {
        val payload = TestPayload(manifestExtra = mapOf("share/missing.txt" to "gone".toByteArray()))
        val failure = assertThrows(RuntimeFailure::class.java) { runtime(payload).install(null) }
        assertEquals(RuntimeProblem.INCOMPLETE, failure.problem)
        assertNull(runtime(payload).installed())
    }

    @Test
    fun anExecutableTheApkLacksFails() {
        val payload = TestPayload(executables = TestPayload.DEFAULT_EXECUTABLES + ("bin/gone" to "libgone.so"))
        val failure = assertThrows(RuntimeFailure::class.java) { runtime(payload).install(null) }
        assertEquals(RuntimeProblem.MISSING_EXECUTABLES, failure.problem)
        assertNull(runtime(payload).installed())
    }

    @Test
    fun tooLittleSpaceFailsBeforeAnythingIsWritten() {
        val failure = assertThrows(RuntimeFailure::class.java) { runtime(free = 1024L).install(null) }
        assertEquals(RuntimeProblem.STORAGE, failure.problem)
        assertFalse(File(prefix, "etc/profile").exists())
        assertFalse(marker.exists())
    }

    @Test
    fun anInstallRemovesWhatTheLastOneWroteAndNothingElse() {
        val first = TestPayload(files = TestPayload.DEFAULT_FILES + ("share/old.txt" to "old".toByteArray()))
        runtime(first).install(null)
        val mine = File(prefix, "lib/python3/site-packages/mine.py")
        mine.parentFile!!.mkdirs()
        mine.writeText("print('mine')\n")

        val second = TestPayload(identity = "fedcba9876543210")
        runtime(second).install(null)
        assertFalse(File(prefix, "share/old.txt").exists())
        assertTrue(File(prefix, "etc/profile").isFile)
        assertTrue(mine.isFile)
        assertNotNull(runtime(second).installed())
        assertNull(runtime(first).installed())
    }

    @Test
    fun anExecutableOutsideTheApkFailsTheAudit() {
        runtime().install(null)
        val rogue = File(prefix, "bin/rogue")
        rogue.writeBytes(TestPayload.ELF)
        assertTrue(rogue.setExecutable(true))
        val audit = runtime().audit()
        assertEquals(1, audit.outsideApk)
        assertFalse(audit.clean)
        assertTrue(audit.report, audit.report.contains("bin/rogue"))
    }

    @Test
    fun anApkWithoutAPayloadInstallsNothing() {
        val sealed = runtime(source = TestPayload().source(abi = null))
        assertNull(sealed.payload())
        assertNull(sealed.installed())
        val failure = assertThrows(RuntimeFailure::class.java) { sealed.install(null) }
        assertEquals(RuntimeProblem.NO_PAYLOAD, failure.problem)
    }

    @Test
    fun sizesCountEachFileOnceAndNoLink() {
        val payload = TestPayload()
        runtime(payload).install(null)
        val sizes = runtime(payload).sizes(1234L)
        assertEquals(payload.bytes, sizes.prefixBytes)
        assertEquals(payload.files.size, sizes.prefixFiles)
        assertEquals(1234L, sizes.apkBytes)
        assertTrue(sizes.nativeLibraryBytes > 0)
    }

    @Test
    fun theKernelsProblemsAreTyped() {
        assertEquals(RuntimeProblem.CORRUPT, SealedRuntime.classify(listOf("digest differs: lib/a.py")))
        assertEquals(RuntimeProblem.CORRUPT, SealedRuntime.classify(listOf("size differs: lib/a.py (1 != 2)")))
        assertEquals(RuntimeProblem.CORRUPT, SealedRuntime.classify(listOf("unsafe payload path: ../x")))
        assertEquals(
            RuntimeProblem.INCOMPLETE,
            SealedRuntime.classify(listOf("manifest lists 3 files, payload carried 2")),
        )
        assertEquals(
            RuntimeProblem.MISSING_EXECUTABLES,
            SealedRuntime.classify(listOf("libgit.so (for bin/git)")),
        )
        assertEquals(RuntimeProblem.STORAGE, SealedRuntime.classify(listOf("cannot create lib")))
        assertEquals(RuntimeProblem.CORRUPT, SealedRuntime.classify(ZipException("invalid entry CRC")).problem)
        assertEquals(
            RuntimeProblem.STORAGE,
            SealedRuntime.classify(IOException("write failed: ENOSPC (No space left on device)")).problem,
        )
        assertEquals("a (and 2 more)", SealedRuntime.describe(listOf("a", "b", "c")))
    }
}
