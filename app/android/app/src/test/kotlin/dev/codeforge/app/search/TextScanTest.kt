package dev.codeforge.app.search

import dev.codeforge.app.storage.Cancellation
import dev.codeforge.app.storage.DocumentIdCache
import dev.codeforge.app.storage.DocumentOps
import dev.codeforge.app.storage.FakeProvider
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * CodeForge's own search (Phase 4 W6): a project's folder on real files, and
 * a folder from shared storage over the in-memory provider the storage tests
 * use, with the editor's rules for what is text and where lines break.
 */
class TextScanTest {
    @get:Rule
    val temp = TemporaryFolder()

    private val batches = mutableListOf<List<SearchFile>>()
    private var stop = false

    private fun write(root: File, path: String, bytes: ByteArray) {
        val file = File(root, path)
        file.parentFile!!.mkdirs()
        file.writeBytes(bytes)
    }

    private fun write(root: File, path: String, text: String) = write(root, path, text.toByteArray())

    private fun scan(tree: ScanTree, query: SearchQuery, limits: SearchLimits = SearchLimits()): Pair<TextScan, SearchSummary> {
        val collector = SearchCollector(limits, emit = { batches.add(it) })
        val scan = TextScan(tree, query, limits, collector) { stop }
        scan.run()
        return scan to scan.summary(null, null, cancelled = stop, timedOut = false)
    }

    private fun found(): Map<String, List<Int>> = batches.flatten().associate { file -> file.path to file.lines.map { it.line } }

    @Test
    fun linesBreakAsTheEditorBreaksThem() {
        val root = temp.newFolder("p")
        write(root, "lf.txt", "a\nneedle\nb\n")
        write(root, "crlf.txt", "a\r\nb\r\nneedle\r\n")
        write(root, "cr.txt", "a\rneedle")
        write(root, "bom.txt", "\uFEFFneedle at the start")
        val (_, summary) = scan(LocalTree(root), SearchQuery("needle"))
        assertEquals(mapOf("bom.txt" to listOf(1), "cr.txt" to listOf(2), "crlf.txt" to listOf(3), "lf.txt" to listOf(2)), found())
        val bom = batches.flatten().first { it.path == "bom.txt" }.lines.single()
        assertEquals("the byte-order mark is not a column", 1, bom.column)
        assertEquals(SearchOutcome.DONE, summary.outcome)
        assertEquals(SearchEngine.SCAN, summary.engine)
        assertEquals(4, summary.filesSearched)
    }

    @Test
    fun whatTheEditorWouldNotOpenIsLeftOutAndCounted() {
        val root = temp.newFolder("p")
        write(root, "text.txt", "needle")
        write(root, "binary.bin", byteArrayOf(0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x00))
        write(root, "latin1.txt", byteArrayOf(0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0xE9.toByte()))
        write(root, "utf16.txt", byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x6E, 0x00))
        write(root, "big.txt", "needle\n" + "x".repeat(2000))
        val (_, summary) = scan(LocalTree(root), SearchQuery("needle"), SearchLimits(maxFileBytes = 1000))
        assertEquals(setOf("text.txt"), found().keys)
        assertEquals(1, summary.skippedBinary)
        assertEquals(2, summary.skippedNotText)
        assertEquals(1, summary.skippedLarge)
    }

    @Test
    fun skippedFoldersAndGlobsAreLeftAsRipgrepLeavesThem() {
        val root = temp.newFolder("p")
        for (path in listOf("src/a.js", "src/b.ts", "node_modules/x.js", ".git/config", "web/node_modules/y.js", "dist/a.js", ".hidden.js")) {
            write(root, path, "needle")
        }
        scan(LocalTree(root), SearchQuery("needle", includes = listOf("*.js"), excludes = GlobFilter.expand(listOf("dist"))))
        assertEquals(setOf("src/a.js", ".hidden.js"), found().keys)
    }

    @Test
    fun caseWholeWordsAndRegularExpressions() {
        val root = temp.newFolder("p")
        write(root, "a.txt", "Needle\nneedles\nneedle_x\nthe needle.\nneedleneedle\n")
        scan(LocalTree(root), SearchQuery("needle"))
        assertEquals(listOf(1, 2, 3, 4, 5), found()["a.txt"])
        batches.clear()
        scan(LocalTree(root), SearchQuery("needle", caseSensitive = true, wholeWord = true))
        assertEquals("_ is a word character; . is not", listOf(4), found()["a.txt"])
        batches.clear()
        scan(LocalTree(root), SearchQuery("^n\\w+s$", regex = true))
        assertEquals(listOf(2), found()["a.txt"])
        val twice = batches.flatten().single().lines.single()
        assertEquals(1, twice.matches)
        batches.clear()
        scan(LocalTree(root), SearchQuery("needle", caseSensitive = true))
        assertEquals(2, batches.flatten().single().lines.last().matches)
    }

    @Test
    fun aPatternThatDoesNotCompileIsRefusedBeforeTheWalk() {
        val root = temp.newFolder("p")
        try {
            TextScan(LocalTree(root), SearchQuery("(", regex = true), SearchLimits(), SearchCollector(SearchLimits(), emit = {})) { false }.run()
            fail("an unclosed group was accepted")
        } catch (bad: IllegalArgumentException) {
            assertTrue(bad.message!!.startsWith("Not a valid regular expression"))
        }
    }

    @Test
    fun theFileCapAndAStopEndTheWalk() {
        val root = temp.newFolder("p")
        for (i in 1..30) write(root, "f%02d.txt".format(i), "needle")
        val (scan, summary) = scan(LocalTree(root), SearchQuery("needle"), SearchLimits(maxFiles = 10))
        assertEquals(10, scan.searched)
        assertEquals(SearchOutcome.LIMIT, summary.outcome)
        batches.clear()
        stop = true
        val (_, stopped) = scan(LocalTree(root), SearchQuery("needle"))
        assertEquals(SearchOutcome.CANCELLED, stopped.outcome)
        assertEquals(0, stopped.filesSearched)
    }

    @Test
    fun aFolderFromSharedStorageIsWalkedThroughItsProvider() {
        val provider = FakeProvider()
        provider.file("notes/todo.md", "buy milk\nfind the needle\n")
        provider.file("notes/deep/x.txt", "needle")
        provider.file("photo.jpg", byteArrayOf(0x00, 0x01))
        provider.file("node_modules/skip.js", "needle")
        val ops = DocumentOps(provider, DocumentIdCache(), Cancellation.NONE)
        val (_, summary) = scan(SafTree(ops), SearchQuery("needle"))
        assertEquals(mapOf("notes/todo.md" to listOf(2), "notes/deep/x.txt" to listOf(1)), found())
        assertEquals(3, summary.filesSearched)
        assertEquals(1, summary.skippedBinary)
    }

    @Test
    fun aGoneFolderFailsTheSearchWithAReason() {
        val missing = File(temp.root, "gone")
        try {
            TextScan(LocalTree(missing), SearchQuery("x"), SearchLimits(), SearchCollector(SearchLimits(), emit = {})) { false }.run()
            fail("a missing folder was searched")
        } catch (gone: Exception) {
            assertEquals(SearchFailure.NOT_FOUND, TextScan.failureOf(gone).first)
        }
    }
}
