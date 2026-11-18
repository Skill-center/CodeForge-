package dev.codeforge.app.runtime

import dev.codeforge.runtime.sealed.SealedInstaller
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption

/**
 * The host's install against the kernel's (Phase 4 W5). [PayloadInstall]
 * makes the calls `SealedInstaller.install` makes, from a manifest read
 * beforehand, because the kernel reads its manifest stream with
 * `InputStream.readAllBytes()`, which Android has only from API 33. On the
 * JVM the kernel's entry point works, so here both install the same payload
 * into roots of their own, and must leave the same prefix (every path, every
 * file's bytes, every link's target) and report the same counts and problems.
 */
class PayloadInstallTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var libraries: File

    @Before
    fun setUp() {
        libraries = temp.newFolder("lib")
    }

    /** One install's result, in the kernel's terms, and what it left. */
    private data class Installed(
        val files: Int,
        val verified: Int,
        val bytes: Long,
        val links: Int,
        val executables: Int,
        val alreadySealed: Int,
        val problems: List<String>,
        val ok: Boolean,
        val tree: Map<String, String>,
    )

    private fun prefixUnder(root: File): File = File(root, "rootfs/data/data/com.termux/files/usr")

    private fun lines(payload: TestPayload, asset: String): List<String> =
        String(payload.assets.getValue("$asset-${payload.abi}.txt"), Charsets.UTF_8).lines()

    private fun throughTheKernel(payload: TestPayload): Installed {
        val root = temp.newFolder("kernel")
        val prefix = prefixUnder(root)
        val request = SealedInstaller.Request()
            .prefix(prefix)
            .nativeLibraryDirectory(libraries)
            .payload(ByteArrayInputStream(payload.assets.getValue("userland-${payload.abi}.zip")))
            .manifest(ByteArrayInputStream(payload.assets.getValue("sealed-manifest-${payload.abi}.txt")))
            .execManifest(lines(payload, "sealed-exec"))
            .linkManifest(lines(payload, "sealed-symlinks"))
        val result = SealedInstaller.install(request)
        return Installed(
            result.files, result.verified, result.bytes, result.links, result.executables,
            result.alreadySealed, result.problems.map { it.replace(root.absolutePath, "<root>") },
            result.ok(), tree(root, prefix),
        )
    }

    private fun throughTheHost(payload: TestPayload): Installed {
        val root = temp.newFolder("host")
        val prefix = prefixUnder(root)
        val result = PayloadInstall.install(
            prefix = prefix,
            nativeLibraryDirectory = libraries,
            payload = ByteArrayInputStream(payload.assets.getValue("userland-${payload.abi}.zip")),
            manifest = payload.assets.getValue("sealed-manifest-${payload.abi}.txt"),
            execManifest = lines(payload, "sealed-exec"),
            linkManifest = lines(payload, "sealed-symlinks"),
            progress = null,
        )
        return Installed(
            result.files, result.verified, result.bytes, result.links, result.executables,
            result.alreadySealed, result.problems.map { it.replace(root.absolutePath, "<root>") },
            result.ok(), tree(root, prefix),
        )
    }

    /** Every path under [prefix]: a link's target, a file's digest, or a folder. */
    private fun tree(root: File, prefix: File): Map<String, String> {
        if (!prefix.exists()) return emptyMap()
        val found = sortedMapOf<String, String>()
        Files.walk(prefix.toPath()).use { paths ->
            for (path in paths) {
                val name = prefix.toPath().relativize(path).toString()
                found[name] = when {
                    Files.isSymbolicLink(path) ->
                        "link " + Files.readSymbolicLink(path).toString().replace(root.absolutePath, "<root>")
                    Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS) -> "folder"
                    else -> "file " + TestPayload.sha256(Files.readAllBytes(path))
                }
            }
        }
        return found
    }

    private fun installedBothWays(payload: TestPayload): Installed {
        val kernel = throughTheKernel(payload)
        val host = throughTheHost(payload)
        assertEquals(kernel, host)
        return host
    }

    @Test
    fun aGoodPayloadLeavesTheSamePrefix() {
        TestPayload.writeLibraries(libraries)
        val payload = TestPayload()
        val installed = installedBothWays(payload)
        assertTrue(installed.ok)
        assertEquals(payload.files.size, installed.files)
        assertEquals(payload.files.size, installed.verified)
        assertEquals(payload.bytes, installed.bytes)
        assertEquals(1, installed.links)
        assertEquals(2, installed.executables)
        assertEquals("link " + File(libraries, "libsh.so").absolutePath, installed.tree["bin/sh"])
        assertEquals("link <root>/rootfs/data/data/com.termux/files/usr/lib/libfoo.so.1", installed.tree["lib/libfoo.so"])
    }

    @Test
    fun badAndUnsafeLinkLinesAreTheSameProblems() {
        TestPayload.writeLibraries(libraries)
        val payload = TestPayload(
            links = linkedMapOf(
                "lib/libfoo.so" to "lib/libfoo.so.1",
                "../outside" to "lib/libfoo.so.1",
                "lib/three" to "fields\there",
                "  lib/padded  " to "lib/libfoo.so.1",
            ),
        )
        val installed = installedBothWays(payload)
        assertEquals(2, installed.links)
        assertEquals(
            listOf(
                "unsafe link line: ../outside\tlib/libfoo.so.1",
                "bad link line: lib/three\tfields\there",
            ),
            installed.problems,
        )
    }

    @Test
    fun aFileThatDiffersFromItsManifestIsTheSameProblem() {
        TestPayload.writeLibraries(libraries)
        val installed = installedBothWays(TestPayload(wrongDigestFor = "etc/profile"))
        assertEquals(listOf("digest differs: etc/profile"), installed.problems)
        assertEquals(installed.files - 1, installed.verified)
    }

    @Test
    fun anExecutableTheApkLacksIsTheSameProblem() {
        TestPayload.writeLibraries(libraries, mapOf("bin/sh" to "libsh.so"))
        val installed = installedBothWays(TestPayload())
        assertEquals(1, installed.executables)
        assertEquals(1, installed.problems.size)
        assertTrue(installed.problems[0], installed.problems[0].contains("libtool.so"))
    }
}
