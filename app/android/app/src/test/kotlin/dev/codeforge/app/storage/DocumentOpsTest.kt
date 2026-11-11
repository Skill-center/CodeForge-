package dev.codeforge.app.storage

import android.provider.DocumentsContract.Document
import java.io.FileNotFoundException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The broker's operations (Phase 3 W2, gate G1; docs/SECURITY.md §4.1)
 * against an in-memory provider with the quirks of Android's own
 * ([FakeProvider]): scoping and resolution, names a provider changes,
 * in-place writes with their stamp check, moves, copies, deletes, and the
 * limits.
 */
class DocumentOpsTest {
    private val provider = FakeProvider()
    private val cache = DocumentIdCache()
    private val ops = DocumentOps(provider, cache, Cancellation.NONE)

    private fun problem(block: () -> Unit): StorageProblem {
        try {
            block()
        } catch (error: StorageException) {
            return error.problem
        }
        fail("expected a StorageException")
        throw IllegalStateException()
    }

    @Test
    fun flagsAreAndroids() {
        assertEquals(Document.FLAG_SUPPORTS_WRITE, DocFlags.SUPPORTS_WRITE)
        assertEquals(Document.FLAG_SUPPORTS_DELETE, DocFlags.SUPPORTS_DELETE)
        assertEquals(Document.FLAG_DIR_SUPPORTS_CREATE, DocFlags.DIR_SUPPORTS_CREATE)
        assertEquals(Document.FLAG_SUPPORTS_RENAME, DocFlags.SUPPORTS_RENAME)
        assertEquals(Document.FLAG_SUPPORTS_COPY, DocFlags.SUPPORTS_COPY)
        assertEquals(Document.FLAG_SUPPORTS_MOVE, DocFlags.SUPPORTS_MOVE)
        assertEquals(Document.FLAG_VIRTUAL_DOCUMENT, DocFlags.VIRTUAL_DOCUMENT)
    }

    @Test
    fun listsAFolderInOneQueryAndRemembersItsIds() {
        provider.file("hello.txt", "Hello\n")
        provider.file("src/main.js", "main();\n")
        provider.calls.clear()
        val rows = ops.list("")
        assertEquals(setOf("hello.txt", "src"), rows.map { it.name }.toSet())
        assertEquals(listOf("query", "children"), provider.calls)
        val src = rows.single { it.name == "src" }
        assertTrue(src.isDirectory)
        assertEquals(1L or 2L or 4L or 8L, DocFlags.forDart(src))
        assertEquals(1L or 2L or 4L or 8L, DocFlags.forDart(rows.single { it.name == "hello.txt" }))
        // A remembered id costs one query, not a walk from the root.
        provider.calls.clear()
        assertEquals(listOf("main.js"), ops.list("src").map { it.name })
        assertEquals(listOf("query", "children"), provider.calls)
    }

    @Test
    fun resolvesNameByNameAndNeverFromText() {
        provider.file("src/main.js", "main();\n")
        // The provider would find "SRC/MAIN.JS" (its ids are looked up without
        // case), but the broker walks the listings, where no entry has that name.
        assertEquals(StorageProblem.NOT_FOUND, problem { ops.stat("SRC/MAIN.JS") })
        assertEquals("main.js", ops.stat("src/main.js").name)
    }

    @Test
    fun refusesEscapingPathsBeforeAskingTheProvider() {
        provider.file("hello.txt", "Hello\n")
        provider.calls.clear()
        for (path in listOf("..", "../outside.txt", "src/../../x", "/sdcard/x", "a//b")) {
            assertEquals(path, StorageProblem.INVALID_PATH, problem { ops.read(path, 1024) })
            assertEquals(path, StorageProblem.INVALID_PATH, problem { ops.write(path, ByteArray(1), false, null) })
            assertEquals(path, StorageProblem.INVALID_PATH, problem { ops.delete(path) })
        }
        assertEquals(StorageProblem.INVALID_PATH, problem { ops.rename("hello.txt", "../x") })
        assertEquals(StorageProblem.INVALID_PATH, problem { ops.create("", "a/b", directory = false) })
        assertEquals(StorageProblem.INVALID_PATH, problem { ops.copy("hello.txt", "", "..") })
        assertEquals(emptyList<String>(), provider.calls)
    }

    @Test
    fun theGrantedFolderItselfIsNeverDeletedRenamedOrMoved() {
        assertEquals(StorageProblem.INVALID_PATH, problem { ops.delete("") })
        assertEquals(StorageProblem.INVALID_PATH, problem { ops.rename("", "x") })
        assertEquals(StorageProblem.INVALID_PATH, problem { ops.move("", "x") })
        assertEquals(StorageProblem.WRONG_TYPE, problem { ops.read("", 1024) })
    }

    @Test
    fun aRememberedIdThatWentStaleIsWalkedAgain() {
        val node = provider.file("notes/a.txt", "A\n")
        ops.list("notes")
        assertNotNull(cache.get("notes/a.txt"))
        node.name = "b.txt" // renamed by another app
        assertEquals(StorageProblem.NOT_FOUND, problem { ops.stat("notes/a.txt") })
        assertNull(cache.get("notes/a.txt"))
        assertEquals("b.txt", ops.stat("notes/b.txt").name)
    }

    @Test
    fun aMissingFolderIsMissingAndAMissingFileIsNotFound() {
        provider.file("src/main.js", "main();\n")
        ops.list("src")
        assertEquals(StorageProblem.NOT_FOUND, problem { ops.stat("src/gone.js") })
        provider.deleteRoot()
        assertEquals(StorageProblem.MISSING, problem { ops.root() })
        assertEquals(StorageProblem.MISSING, problem { ops.list("") })
        assertEquals(StorageProblem.MISSING, problem { ops.list("src") })
        assertEquals(StorageProblem.MISSING, problem { ops.read("src/main.js", 1024) })
    }

    @Test
    fun readsBytesAndTheFileAsItIsAfterwards() {
        provider.file("hello.txt", "Hello\n")
        val (row, bytes) = ops.read("hello.txt", 1024)
        assertEquals("Hello\n", bytes.toString(Charsets.UTF_8))
        assertEquals(6L, row.size)
        assertNotNull(row.modifiedMs)
    }

    @Test
    fun readRefusesAListedSizeAboveTheCapWithoutOpeningTheFile() {
        provider.file("big.txt", ByteArray(2048))
        provider.calls.clear()
        assertEquals(StorageProblem.TOO_LARGE, problem { ops.read("big.txt", 1024) })
        assertFalse(provider.calls.contains("read"))
    }

    @Test
    fun writesInPlaceAndReadsTheStampBack() {
        provider.file("notes.md", "a much longer first version\n")
        val short = "short\n".toByteArray()
        val row = ops.write("notes.md", short, createNew = false, expect = null)
        assertEquals("short\n", provider.text("notes.md"))
        assertEquals(short.size.toLong(), row.size)
    }

    @Test
    fun aWriteThatLeavesOldBytesBehindIsAnError() {
        provider.file("notes.md", "a much longer first version\n")
        provider.truncates = false
        assertEquals(StorageProblem.IO, problem { ops.write("notes.md", "short\n".toByteArray(), false, null) })
    }

    @Test
    fun aWriteRefusesAFileThatChangedSinceItWasRead() {
        provider.file("notes.md", "v1\n")
        val (read, _) = ops.read("notes.md", 1024)
        val expect = DocumentOps.Expectation(read.size, read.modifiedMs, null)
        provider.at("notes.md")!!.modifiedMs += 5_000 // another app saved it
        assertEquals(StorageProblem.CHANGED, problem { ops.write("notes.md", "v2\n".toByteArray(), false, expect) })
        assertEquals("v1\n", provider.text("notes.md"))
    }

    @Test
    fun withoutAModifiedTimeTheBytesAreCompared() {
        // Restored from a backup: dated 1970, so Android lists no time.
        provider.file("restored.txt", "same\n", modifiedMs = 0)
        val (read, bytes) = ops.read("restored.txt", 1024)
        assertNull(read.modifiedMs)
        val expect = DocumentOps.Expectation(read.size, null, Streams.sha256Hex(bytes))
        val written = ops.write("restored.txt", "new\n".toByteArray(), false, expect)
        assertEquals("new\n", provider.text("restored.txt"))
        assertNotNull(written.modifiedMs)
        // Changed meanwhile (same size, still no time): refused.
        provider.file("other.txt", "aaaa\n", modifiedMs = 0)
        val (before, original) = ops.read("other.txt", 1024)
        provider.at("other.txt")!!.bytes = "bbbb\n".toByteArray()
        val stale = DocumentOps.Expectation(before.size, null, Streams.sha256Hex(original))
        assertEquals(StorageProblem.CHANGED, problem { ops.write("other.txt", "c\n".toByteArray(), false, stale) })
        assertEquals("bbbb\n", provider.text("other.txt"))
    }

    @Test
    fun writeCreatesTheFileAndMissingFolders() {
        val row = ops.write("a/b/c.txt", "c\n".toByteArray(), createNew = true, expect = null)
        assertEquals("c.txt", row.name)
        assertEquals("c\n", provider.text("a/b/c.txt"))
        assertTrue(provider.at("a/b")!!.isDirectory)
        assertEquals(StorageProblem.EXISTS, problem { ops.write("a/b/c.txt", ByteArray(0), true, null) })
        assertEquals(StorageProblem.WRONG_TYPE, problem { ops.write("a/b", ByteArray(0), false, null) })
    }

    @Test
    fun newNamesAreCheckedWithoutCaseFirst() {
        provider.file("main.js", "main();\n")
        provider.calls.clear()
        assertEquals(StorageProblem.EXISTS, problem { ops.create("", "Main.js", directory = false) })
        assertEquals(StorageProblem.EXISTS, problem { ops.write("MAIN.JS", ByteArray(0), true, null) })
        assertFalse(provider.calls.contains("create"))
    }

    @Test
    fun aNameTheProviderChangesIsReportedAndTheNewItemRemoved() {
        // FAT-unsafe characters become '_' on Android's own provider.
        assertEquals(StorageProblem.NAME_CHANGED, problem { ops.create("", "a:b.txt", directory = false) })
        assertNull(provider.at("a_b.txt"))
        assertEquals(emptyList<String>(), provider.root.children.map { it.name })
    }

    @Test
    fun renameRefusesATakenNameAndChangesNothing() {
        provider.file("a.txt", "A\n")
        provider.file("b.txt", "B\n")
        assertEquals(StorageProblem.EXISTS, problem { ops.rename("a.txt", "B.TXT") })
        assertEquals("A\n", provider.text("a.txt"))
        val renamed = ops.rename("a.txt", "c.txt")
        assertEquals("c.txt", renamed.name)
        assertNull(provider.at("a.txt"))
        assertEquals("A\n", provider.text("c.txt"))
    }

    @Test
    fun aCaseOnlyRenameGoesThroughATemporaryName() {
        val node = provider.file("readme.md", "# hi\n")
        // Directly, Android's provider takes the file for its own clash.
        val direct = provider.rename(provider.idOf(node), "README.md")
        assertTrue(direct.endsWith("README (1).md"))
        node.name = "readme.md"
        provider.calls.clear()
        val renamed = ops.rename("readme.md", "README.md")
        assertEquals("README.md", renamed.name)
        assertEquals(listOf("README.md"), provider.root.children.map { it.name })
        assertEquals(2, provider.calls.count { it == "rename" })
    }

    @Test
    fun moveKeepsTheNameAndRefusesClashesAndItsOwnInside() {
        provider.file("a.txt", "A\n")
        provider.folder("dest")
        provider.file("other/a.txt", "other\n")
        val moved = ops.move("a.txt", "dest")
        assertEquals("a.txt", moved.name)
        assertEquals("A\n", provider.text("dest/a.txt"))
        assertNull(provider.at("a.txt"))
        assertEquals(StorageProblem.EXISTS, problem { ops.move("dest/a.txt", "other") })
        provider.folder("dest/inner")
        assertEquals(StorageProblem.INVALID_PATH, problem { ops.move("dest", "dest/inner") })
    }

    @Test
    fun aProviderThatCantMoveGetsACopyAndADelete() {
        provider.supportsMove = false
        provider.file("src/x/y.txt", "Y\n")
        provider.folder("dest")
        ops.move("src", "dest")
        assertEquals("Y\n", provider.text("dest/src/x/y.txt"))
        assertNull(provider.at("src"))
        assertFalse(provider.calls.contains("move"))
    }

    @Test
    fun copiesFilesAndFoldersByteForByte() {
        val bytes = ByteArray(200_000) { (it % 251).toByte() }
        provider.file("tree/bin.dat", bytes)
        provider.file("tree/deep/er/t.txt", "t\n")
        ops.copy("tree", "", "tree-copy")
        assertArrayEquals(bytes, provider.at("tree-copy/bin.dat")!!.bytes)
        assertEquals("t\n", provider.text("tree-copy/deep/er/t.txt"))
        assertArrayEquals(bytes, provider.at("tree/bin.dat")!!.bytes)
        assertEquals(StorageProblem.EXISTS, problem { ops.copy("tree", "", "TREE-COPY") })
        assertEquals(StorageProblem.INVALID_PATH, problem { ops.copy("tree", "tree/deep", "again") })
    }

    @Test
    fun aCopyDeeperThanTheLimitStopsAndLeavesNothing() {
        provider.file(List(DocumentOps.MAX_COPY_DEPTH + 2) { "d" }.joinToString("/") + "/f.txt", "f\n")
        assertEquals(StorageProblem.UNSUPPORTED, problem { ops.copy("d", "", "e") })
        assertNull(provider.at("e"))
    }

    @Test
    fun deletesFilesAndFoldersWithEverythingInThem() {
        provider.file("gone/a/b.txt", "b\n")
        provider.file("keep.txt", "k\n")
        ops.list("gone")
        ops.delete("gone")
        assertNull(provider.at("gone"))
        assertNull(cache.get("gone/a"))
        assertEquals("k\n", provider.text("keep.txt"))
        assertEquals(StorageProblem.NOT_FOUND, problem { ops.delete("gone") })
    }

    @Test
    fun listingsSkipBadAndRepeatedNamesAndStopAtTheLimit() {
        provider.raw(provider.root, "ok.txt")
        provider.raw(provider.root, "bad\u0001name")
        provider.raw(provider.root, "dup.txt")
        provider.raw(provider.root, "dup.txt")
        assertEquals(listOf("ok.txt", "dup.txt"), ops.list("").map { it.name })
        assertEquals(StorageProblem.AMBIGUOUS, problem { ops.read("dup.txt", 1024) })
        val many = provider.folder("many")
        repeat(DocumentOps.MAX_LIST + 5) { provider.raw(many, "f$it") }
        assertEquals(DocumentOps.MAX_LIST, ops.list("many").size)
    }

    @Test
    fun readOnlyDocumentsAreNotChanged() {
        provider.file("ro.txt", "r\n").writable = false
        assertEquals(StorageProblem.UNSUPPORTED, problem { ops.write("ro.txt", ByteArray(1), false, null) })
        assertEquals(StorageProblem.UNSUPPORTED, problem { ops.delete("ro.txt") })
        assertEquals(StorageProblem.UNSUPPORTED, problem { ops.rename("ro.txt", "rw.txt") })
        assertEquals("r\n", provider.text("ro.txt"))
    }

    @Test
    fun timeRunningOutStopsTheCall() {
        provider.file("hello.txt", "Hello\n")
        var checks = 0
        val impatient = DocumentOps(provider, cache) {
            checks += 1
            if (checks > 2) throw StorageException(StorageProblem.TIMEOUT, "time is up")
        }
        assertEquals(StorageProblem.TIMEOUT, problem { impatient.read("hello.txt", 1024) })
    }

    @Test
    fun providerExceptionsMeanWhatTheySay() {
        fun code(error: Throwable) = StorageErrors.classify(error).problem
        assertEquals(StorageProblem.OUTSIDE, code(SecurityException("Document x is not a descendant of y")))
        assertEquals(StorageProblem.ACCESS_LOST, code(SecurityException("Permission Denial")))
        assertEquals(StorageProblem.NOT_FOUND, code(FileNotFoundException("gone")))
        assertEquals(StorageProblem.UNSUPPORTED, code(UnsupportedOperationException("no")))
        assertEquals(StorageProblem.IO, code(IllegalStateException("Failed to rename")))
        val own = StorageException(StorageProblem.EXISTS, "taken")
        assertTrue(StorageErrors.classify(own) === own)
        // Messages never carry what the provider said: it can name files.
        assertFalse(StorageErrors.classify(IllegalStateException("/storage/emulated/0/secret")).message!!.contains("secret"))
    }
}
