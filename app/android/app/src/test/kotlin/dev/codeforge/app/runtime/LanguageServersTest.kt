package dev.codeforge.app.runtime

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The language servers' install (Phase 6 W2, gate G2) on servers built in
 * memory as runtime/language_servers.py builds them: a server verified file
 * by file is put in place whole, an installed one is reused, and every damage
 * is refused with its type, leaving nothing at the server's place.
 */
class LanguageServersTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var root: File

    @Before
    fun setUp() {
        root = temp.newFolder("runtime")
    }

    private fun servers(source: PayloadSource, free: Long? = null): LanguageServers =
        LanguageServers(source, root, freeSpace = { directory -> free ?: directory.usableSpace })

    private val place: File get() = File(root, "codeforge/lsp/demo")

    private fun assertNothingInPlace() {
        assertFalse("a refused server is at its place", place.exists())
        val left = File(root, "codeforge/lsp").list().orEmpty().filter { it.startsWith(".") }
        assertEquals("staging or old folders left", emptyList<String>(), left)
    }

    private fun refusal(source: PayloadSource, free: Long? = null): LanguageServerFailure =
        assertThrows(LanguageServerFailure::class.java) { servers(source, free).ensure("demo") }

    @Test
    fun describesTheServersTheApkCarries() {
        val fixture = ServerFixture()
        val servers = servers(fixture.source())
        val server = servers.available().single()
        assertEquals("demo", server.id)
        assertEquals("node_modules/demo/server.js", server.entry)
        assertEquals(listOf("--stdio"), server.arguments)
        assertEquals(listOf(LanguageServers.Package("demo", "1.0.0", "MIT")), server.packages)
        assertEquals(fixture.identity, server.identity)
        assertEquals(3, server.files)
        assertEquals("demo", servers.forLanguage("demo-lang")?.id)
        assertNull(servers.forLanguage("cobol"))
        assertNull("nothing is installed before it is asked for", servers.installed("demo"))
    }

    @Test
    fun installsVerifiesAndPutsTheServerInPlace() {
        val fixture = ServerFixture()
        val progress = mutableListOf<Int>()
        val installed = servers(fixture.source()).ensure("demo") { done, total ->
            assertEquals(3, total)
            progress.add(done)
        }
        assertFalse(installed.reused)
        assertEquals(3, installed.files)
        assertEquals(place, installed.directory)
        assertEquals(File(place, "node_modules/demo/server.js"), installed.entry)
        assertEquals("console.log('demo')\n", installed.entry.readText())
        assertEquals(listOf(1, 2, 3), progress)
        assertEquals(fixture.identity, LanguageServers.readMarker(File(place, LanguageServers.MARKER))?.get("identity"))
        assertEquals(listOf("demo"), File(root, "codeforge/lsp").list().orEmpty().sorted())
    }

    @Test
    fun reusesAnInstalledServerWithoutExtractingAgain() {
        val fixture = ServerFixture()
        servers(fixture.source()).ensure("demo")
        val source = fixture.source()
        val again = servers(source).ensure("demo")
        assertTrue(again.reused)
        assertEquals(place, again.directory)
        assertFalse("the archive was opened again", source.opened.contains("lsp/demo.zip"))
        assertEquals(place, servers(source).installed("demo")?.directory)
    }

    @Test
    fun aChangedByteIsRefusedAndLeavesNothing() {
        val files = ServerFixture().files
        val tampered = files + ("node_modules/demo/lib/util.js" to "module.exports = 2\n".toByteArray())
        val failure = refusal(ServerFixture(archived = tampered).source())
        assertEquals(LanguageServerProblem.DAMAGED, failure.problem)
        assertTrue(failure.message, failure.message!!.contains("differs from its manifest"))
        assertNothingInPlace()
    }

    @Test
    fun aTruncatedArchiveIsRefused() {
        val source = ServerFixture().source { name, data -> if (name.endsWith(".zip")) data.copyOf(data.size / 2) else data }
        assertEquals(LanguageServerProblem.DAMAGED, refusal(source).problem)
        assertNothingInPlace()
    }

    @Test
    fun aFileTheManifestDoesNotListIsRefused() {
        val files = ServerFixture().files
        val failure = refusal(ServerFixture(archived = files + ("node_modules/demo/extra.js" to "1\n".toByteArray())).source())
        assertEquals(LanguageServerProblem.DAMAGED, failure.problem)
        assertTrue(failure.message, failure.message!!.contains("does not list"))
        assertNothingInPlace()
    }

    @Test
    fun aFileTheArchiveLacksIsRefused() {
        val files = ServerFixture().files
        val failure = refusal(ServerFixture(archived = files - "node_modules/demo/lib/util.js").source())
        assertEquals(LanguageServerProblem.DAMAGED, failure.problem)
        assertNothingInPlace()
    }

    @Test
    fun aPathOutsideTheServerIsRefused() {
        val files = ServerFixture().files
        val failure = refusal(ServerFixture(archived = files + ("../escape.js" to "1\n".toByteArray())).source())
        assertEquals(LanguageServerProblem.DAMAGED, failure.problem)
        assertFalse("a file escaped the server's folder", File(root, "codeforge/lsp/escape.js").exists())
        assertNothingInPlace()
    }

    @Test
    fun aManifestThatDiffersFromItsIdentityIsRefused() {
        val failure = refusal(ServerFixture(identityOverride = "0".repeat(64)).source())
        assertEquals(LanguageServerProblem.DAMAGED, failure.problem)
        assertTrue(failure.message, failure.message!!.contains("identity"))
        assertNothingInPlace()
    }

    @Test
    fun aMissingArchiveIsDamaged() {
        val source = ServerFixture().source()
        val without = CountingSource(source.files - "lsp/demo.zip")
        val failure = refusal(without)
        assertEquals(LanguageServerProblem.DAMAGED, failure.problem)
        assertTrue(failure.message, failure.message!!.contains("lacks lsp/demo.zip"))
        assertNothingInPlace()
    }

    @Test
    fun aNewIdentityReplacesTheOldCopy() {
        val first = ServerFixture().files + ("node_modules/demo/old.js" to "old\n".toByteArray())
        servers(ServerFixture(files = first).source()).ensure("demo")
        assertTrue(File(place, "node_modules/demo/old.js").isFile)

        val second = ServerFixture().files + ("node_modules/demo/server.js" to "console.log('two')\n".toByteArray())
        val installed = servers(ServerFixture(files = second).source()).ensure("demo")
        assertFalse(installed.reused)
        assertEquals("console.log('two')\n", installed.entry.readText())
        assertFalse("the old copy's file is left", File(place, "node_modules/demo/old.js").exists())
        assertEquals(listOf("demo"), File(root, "codeforge/lsp").list().orEmpty().sorted())
    }

    @Test
    fun anApkWithoutServersHasNone() {
        val servers = servers(CountingSource(emptyMap()))
        assertEquals(emptyList<LanguageServers.Server>(), servers.available())
        val failure = assertThrows(LanguageServerFailure::class.java) { servers.ensure("demo") }
        assertEquals(LanguageServerProblem.NOT_IN_APK, failure.problem)
    }

    @Test
    fun notEnoughSpaceIsAStorageFailureBeforeAnythingIsWritten() {
        val source = ServerFixture().source()
        val failure = refusal(source, free = 10L)
        assertEquals(LanguageServerProblem.STORAGE, failure.problem)
        assertFalse("the archive was read without the space for it", source.opened.contains("lsp/demo.zip"))
        assertNothingInPlace()
    }

    @Test
    fun aMalformedDescriptionIsDamaged() {
        val source = CountingSource(mapOf(LanguageServers.SERVERS to "{\"schema\": 2, \"servers\": []}".toByteArray()))
        val failure = assertThrows(LanguageServerFailure::class.java) { servers(source).available() }
        assertEquals(LanguageServerProblem.DAMAGED, failure.problem)
    }
}

/** A server's three assets, built in memory as runtime/language_servers.py builds them. */
private class ServerFixture(
    val files: Map<String, ByteArray> = mapOf(
        "node_modules/demo/package.json" to "{\"name\": \"demo\"}\n".toByteArray(),
        "node_modules/demo/server.js" to "console.log('demo')\n".toByteArray(),
        "node_modules/demo/lib/util.js" to "module.exports = 1\n".toByteArray(),
    ),
    /** What the archive holds, when it differs from what the manifest lists. */
    archived: Map<String, ByteArray> = files,
    identityOverride: String? = null,
) {
    val manifest: String = "# sha256\tsize\tpath within the server's folder\n" +
        files.keys.sorted().joinToString("") { path ->
            val data = files.getValue(path)
            "${LanguageServers.sha256(data)}\t${data.size}\t$path\n"
        }
    val identity: String = identityOverride ?: LanguageServers.sha256(manifest.toByteArray())
    private val archive: ByteArray = zip(archived)
    private val description: String =
        "{\"schema\": 1, \"pins\": \"test\", \"servers\": [{\"id\": \"demo\", \"languages\": [\"demo-lang\"], " +
            "\"entry\": \"node_modules/demo/server.js\", \"arguments\": [\"--stdio\"], " +
            "\"packages\": [{\"name\": \"demo\", \"version\": \"1.0.0\", \"license\": \"MIT\"}], " +
            "\"archive\": \"lsp/demo.zip\", \"manifest\": \"lsp/demo-manifest.txt\", \"identity\": \"$identity\", " +
            "\"files\": ${files.size}, \"bytes\": ${files.values.sumOf { it.size.toLong() }}}]}"

    fun source(transform: (String, ByteArray) -> ByteArray = { _, data -> data }): CountingSource =
        CountingSource(
            mapOf(
                LanguageServers.SERVERS to description.toByteArray(),
                "lsp/demo.zip" to archive,
                "lsp/demo-manifest.txt" to manifest.toByteArray(),
            ).mapValues { (name, data) -> transform(name, data) },
        )

    private fun zip(entries: Map<String, ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((path, data) in entries) {
                zip.putNextEntry(ZipEntry(path))
                zip.write(data)
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }
}

/** Assets held in memory, with the names opened recorded. */
private class CountingSource(val files: Map<String, ByteArray>) : PayloadSource {
    val opened = mutableListOf<String>()

    override fun abi(): String? = null

    override fun identity(abi: String): String? = null

    override fun open(name: String): InputStream {
        opened.add(name)
        return ByteArrayInputStream(files[name] ?: throw FileNotFoundException(name))
    }
}
