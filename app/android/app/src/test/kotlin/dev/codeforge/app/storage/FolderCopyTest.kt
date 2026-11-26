package dev.codeforge.app.storage

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * A folder's run copy (Phase 5 W4, ADR-0013): one way and incremental, over
 * the in-memory provider the storage tests use and real files; what it
 * leaves out; links in the copy; what runs created or changed, and export.
 */
class FolderCopyTest {
    @get:Rule
    val temp = TemporaryFolder()

    private val provider = FakeProvider()
    private val ops = DocumentOps(provider, DocumentIdCache(), Cancellation.NONE)

    private lateinit var copies: File

    private fun copy(
        limits: CopyLimits = CopyLimits(),
        parallelism: Int = 1,
        skipped: Set<String> = FolderCopy.RUN_SKIPPED,
        source: CopySource = SafCopySource(ops),
        stopped: () -> Boolean = { false },
    ): FolderCopy {
        if (!::copies.isInitialized) copies = temp.newFolder("copies")
        return FolderCopy(
            source = source,
            target = File(copies, "folder-1"),
            manifestFile = File(copies, ".manifests/folder-1.tsv"),
            staging = File(copies, ".staging/folder-1"),
            limits = limits,
            skipped = skipped,
            parallelism = parallelism,
            stopped = stopped,
        )
    }

    private fun copied(path: String): File = File(copies, "folder-1/$path")

    private fun reads(): Int = provider.calls.count { it == "read" }

    private fun touch(path: String, text: String) {
        val node = provider.at(path)!!
        node.bytes = text.toByteArray()
        node.modifiedMs += 5_000
    }

    /** A run writes [text] to the copy's [path], later than the copy did. */
    private fun runWrites(path: String, text: String) {
        val file = copied(path)
        file.parentFile!!.mkdirs()
        val before = if (file.exists()) file.lastModified() else 0L
        file.writeText(text)
        file.setLastModified(maxOf(before, System.currentTimeMillis()) + 10_000)
    }

    @Test
    fun theFirstCopyTakesEverythingButGit() {
        provider.file("main.js", "console.log('hi')\n")
        provider.file("src/util.js", "export const x = 1\n")
        provider.file(".git/config", "[core]\n")
        provider.file("lib/.git", "gitdir: ../.git/modules/lib\n")
        provider.folder("data/empty")
        val summary = copy().sync()
        assertEquals(2, summary.copied)
        assertEquals(2, summary.files)
        assertEquals(2, summary.skipped)
        assertEquals(0, summary.unchanged)
        assertEquals("console.log('hi')\n", copied("main.js").readText())
        assertEquals("export const x = 1\n", copied("src/util.js").readText())
        assertFalse(copied(".git").exists())
        assertFalse(copied("lib/.git").exists())
        assertTrue("an empty folder is copied as one", copied("data/empty").isDirectory)
        assertEquals(37L, summary.bytes)
        assertFalse(summary.capped)
        assertTrue(File(copies, ".manifests/folder-1.tsv").readText().startsWith(CopyManifest.HEADER))
        assertTrue("nothing is left in the staging folder", File(copies, ".staging/folder-1").list()!!.isEmpty())
    }

    @Test
    fun theSecondCopyReadsOnlyWhatChanged() {
        provider.file("main.js", "one\n")
        provider.file("src/util.js", "two\n")
        provider.file("src/deep/three.py", "three\n")
        copy().sync()
        val before = reads()
        val again = copy().sync()
        assertEquals(0, again.copied)
        assertEquals(3, again.unchanged)
        assertEquals(3, again.files)
        assertEquals("nothing is read again", before, reads())

        touch("src/util.js", "two, changed\n")
        val third = copy().sync()
        assertEquals(1, third.copied)
        assertEquals(2, third.unchanged)
        assertEquals(before + 1, reads())
        assertEquals("two, changed\n", copied("src/util.js").readText())
    }

    @Test
    fun aFileWithoutATimeIsCopiedEveryTime() {
        provider.file("old.txt", "from 1970\n", modifiedMs = 1_000L)
        copy().sync()
        assertEquals(1, copy().sync().copied)
    }

    @Test
    fun whatTheFolderLostTheCopyLosesButARunsOutputStays() {
        provider.file("main.js", "main\n")
        provider.file("src/util.js", "util\n")
        provider.file("gone/a.txt", "a\n")
        provider.file("gone/deeper/b.txt", "b\n")
        copy().sync()
        runWrites("out.txt", "written by a run\n")
        runWrites("node_modules/left-pad/index.js", "module.exports = 1\n")
        provider.delete(provider.idOf(provider.at("src/util.js")!!))
        provider.delete(provider.idOf(provider.at("gone")!!))
        val summary = copy().sync()
        assertEquals(3, summary.removed)
        assertEquals(1, summary.unchanged)
        assertFalse(copied("src/util.js").exists())
        assertTrue("the folder still has src", copied("src").isDirectory)
        assertFalse("a folder the folder lost goes once it is empty", copied("gone").exists())
        assertEquals("written by a run\n", copied("out.txt").readText())
        assertTrue(copied("node_modules/left-pad/index.js").isFile)
    }

    @Test
    fun aFileARunChangedIsCopiedAgainSoARunStartsFromTheFolder() {
        provider.file("data.json", "{\"n\": 1}\n")
        copy().sync()
        runWrites("data.json", "{\"n\": 2}\n")
        val changes = copy().changes()
        assertEquals(listOf(CopyChange("data.json", created = false, size = 9)), changes.changes)
        val summary = copy().sync()
        assertEquals(1, summary.copied)
        assertEquals("{\"n\": 1}\n", copied("data.json").readText())
        assertTrue(copy().changes().changes.isEmpty())
    }

    @Test
    fun changesListWhatRunsCreatedOrChangedButNotDependencies() {
        provider.file("main.js", "main\n")
        provider.file("README.md", "readme\n")
        copy().sync()
        runWrites("main.js", "main, edited by a run\n")
        runWrites("dist/out.js", "out\n")
        runWrites("node_modules/x/index.js", "x\n")
        runWrites("__pycache__/m.pyc", "pyc\n")
        val link = copied("link.txt").toPath()
        Files.createSymbolicLink(link, copied("README.md").toPath())
        val changes = copy().changes()
        assertEquals(
            listOf(CopyChange("dist/out.js", created = true, size = 4), CopyChange("main.js", created = false, size = 22)),
            changes.changes,
        )
        assertEquals(2, changes.skippedFolders)
        assertEquals(0, changes.more)
        val capped = copy().changes(limit = 1)
        assertEquals(1, capped.changes.size)
        assertEquals(1, capped.more)
    }

    @Test
    fun exportWritesBackAndTheFileIsNoLongerAChange() {
        provider.file("main.js", "main\n")
        copy().sync()
        runWrites("main.js", "main v2\n")
        runWrites("out/report.txt", "report\n")
        val result = copy().export(listOf("main.js", "out/report.txt", "missing.txt", "../escape", ".git/config")) { path, bytes ->
            ops.write(path, bytes, createNew = false, expect = null)
        }
        assertEquals(2, result.exported)
        assertEquals(listOf("missing.txt", "../escape", ".git/config"), result.failures.map { it.path })
        assertEquals(StorageProblem.NOT_FOUND, result.failures[0].problem)
        assertEquals(StorageProblem.INVALID_PATH, result.failures[1].problem)
        assertEquals("main v2\n", provider.text("main.js"))
        assertEquals("report\n", provider.text("out/report.txt"))
        assertTrue(copy().changes().changes.isEmpty())
        // The folder now has them as the copy does: nothing to copy again.
        val before = reads()
        val summary = copy().sync()
        assertEquals(0, summary.copied)
        assertEquals(2, summary.unchanged)
        assertEquals(before, reads())
    }

    @Test
    fun linksARunMadeAreReplacedNeverFollowed() {
        provider.file("src/util.js", "util\n")
        provider.file("top.txt", "top\n")
        copy().sync()
        val outside = temp.newFolder("outside")
        File(outside, "keep.txt").writeText("keep\n")
        copied("src").deleteRecursively()
        Files.createSymbolicLink(copied("src").toPath(), outside.toPath())
        Files.delete(copied("top.txt").toPath())
        Files.createSymbolicLink(copied("top.txt").toPath(), File(outside, "keep.txt").toPath())
        copy().sync()
        assertFalse(Files.isSymbolicLink(copied("src").toPath()))
        assertEquals("util\n", copied("src/util.js").readText())
        assertFalse(Files.isSymbolicLink(copied("top.txt").toPath()))
        assertEquals("top\n", copied("top.txt").readText())
        assertEquals(listOf("keep.txt"), outside.list()!!.toList())
        assertEquals("keep\n", File(outside, "keep.txt").readText())
        // Export never reads through a link either.
        Files.delete(copied("top.txt").toPath())
        Files.createSymbolicLink(copied("top.txt").toPath(), File(outside, "keep.txt").toPath())
        val result = copy().export(listOf("top.txt")) { path, bytes -> ops.write(path, bytes, createNew = false, expect = null) }
        assertEquals(0, result.exported)
        assertEquals("top\n", provider.text("top.txt"))
    }

    @Test
    fun aFolderWhereAFileWasAndAFileWhereAFolderWas() {
        provider.file("thing", "a file\n")
        copy().sync()
        provider.delete(provider.idOf(provider.at("thing")!!))
        provider.file("thing/inside.txt", "now a folder\n")
        copy().sync()
        assertEquals("now a folder\n", copied("thing/inside.txt").readText())
        provider.delete(provider.idOf(provider.at("thing")!!))
        provider.file("thing", "a file again\n")
        copy().sync()
        assertEquals("a file again\n", copied("thing").readText())
    }

    @Test
    fun theCapsLeaveFilesOutAndSaySo() {
        provider.file("a.txt", "aaaa\n")
        provider.file("b.txt", "bbbb\n")
        provider.file("big.bin", ByteArray(100))
        provider.file("c.txt", "cccc\n")
        provider.file("d/e/f/deep.txt", "deep\n")
        val summary = copy(CopyLimits(maxFiles = 2, maxFileBytes = 50, maxDepth = 3)).sync()
        assertEquals(2, summary.files)
        assertEquals(1, summary.leftOutLarge)
        assertEquals(1, summary.leftOutFull)
        assertTrue(summary.capped)
        assertTrue(copied("a.txt").isFile)
        assertTrue(copied("b.txt").isFile)
        assertFalse(copied("big.bin").exists())
        assertFalse(copied("c.txt").exists())

        // Folders too deep, then the bytes cap.
        val deep = copy(CopyLimits(maxDepth = 3)).sync()
        assertEquals(1, deep.leftOutDeep)
        assertFalse(deep.capped)
        assertTrue(copied("d/e").isDirectory)
        assertFalse(copied("d/e/f").exists())
        val bytes = copy(CopyLimits(maxBytes = 12)).sync()
        assertEquals(10L, bytes.bytes)
        assertEquals(2, bytes.leftOutFull)
        assertTrue(bytes.capped)
        assertFalse(copied("c.txt").exists())
        assertTrue("what was not walked keeps what it has", copied("d/e").isDirectory)
    }

    @Test
    fun aFileLeftOutLosesItsEarlierCopy() {
        provider.file("grows.txt", "small\n")
        copy().sync()
        touch("grows.txt", "x".repeat(200))
        val summary = copy(CopyLimits(maxFileBytes = 100)).sync()
        assertEquals(1, summary.leftOutLarge)
        assertEquals("left out is not removed", 0, summary.removed)
        assertFalse(copied("grows.txt").exists())
    }

    @Test
    fun aFileThatCannotBeReadKeepsItsEarlierCopy() {
        provider.file("flaky.txt", "v1\n")
        provider.file("fine.txt", "fine\n")
        copy().sync()
        touch("flaky.txt", "v2\n")
        val flaky = object : CopySource {
            val inner = SafCopySource(ops)

            override fun entries(folder: CopyEntry?) = inner.entries(folder)

            override fun open(file: CopyEntry): InputStream {
                if (file.path == "flaky.txt") throw IOException("the provider failed")
                return inner.open(file)
            }
        }
        val summary = copy(source = flaky).sync()
        assertEquals(1, summary.unreadable)
        assertEquals(0, summary.removed)
        assertEquals("v1\n", copied("flaky.txt").readText())
        assertEquals("the next copy takes it", 1, copy().sync().copied)
        assertEquals("v2\n", copied("flaky.txt").readText())
    }

    @Test
    fun aFolderThatCannotBeListedKeepsItsFiles() {
        provider.file("sub/a.txt", "a\n")
        provider.file("top.txt", "top\n")
        copy().sync()
        val failing = object : CopySource {
            val inner = SafCopySource(ops)

            override fun entries(folder: CopyEntry?): List<CopyEntry> {
                if (folder?.path == "sub") throw IOException("not listed")
                return inner.entries(folder)
            }

            override fun open(file: CopyEntry) = inner.open(file)
        }
        val summary = copy(source = failing).sync()
        assertEquals(1, summary.unreadable)
        assertEquals(0, summary.removed)
        assertTrue(copied("sub/a.txt").isFile)
    }

    @Test
    fun virtualDocumentsAreLeftOut() {
        val source = object : CopySource {
            override fun entries(folder: CopyEntry?) = listOf(
                CopyEntry("doc", "doc", isDirectory = false, size = null, modifiedMs = 2_000_000_000_000L, virtual = true),
                CopyEntry("a.txt", "a.txt", isDirectory = false, size = 2, modifiedMs = 2_000_000_000_000L),
            )

            override fun open(file: CopyEntry): InputStream = ByteArrayInputStream("a\n".toByteArray())
        }
        val summary = copy(source = source).sync()
        assertEquals(1, summary.leftOutVirtual)
        assertEquals(1, summary.copied)
    }

    @Test
    fun readsAheadGiveTheSameCopy() {
        for (i in 1..60) provider.file("many/f%02d.txt".format(i), "file $i\n")
        val summary = copy(parallelism = 4).sync()
        assertEquals(60, summary.copied)
        for (i in 1..60) assertEquals("file $i\n", copied("many/f%02d.txt".format(i)).readText())
        assertEquals(0, copy(parallelism = 4).sync().copied)
    }

    @Test
    fun aStoppedCopyKeepsWhatItCopiedAndTheNextOneGoesOn() {
        for (i in 1..10) provider.file("f%02d.txt".format(i), "$i\n")
        var opened = 0
        val counting = object : CopySource {
            val inner = SafCopySource(ops)

            override fun entries(folder: CopyEntry?) = inner.entries(folder)

            override fun open(file: CopyEntry): InputStream {
                opened += 1
                return inner.open(file)
            }
        }
        val summary = copy(source = counting, stopped = { opened >= 4 }).sync()
        assertTrue(summary.stopped)
        assertTrue(summary.copied in 3..4)
        assertEquals("nothing is removed after a stop", 0, summary.removed)
        val next = copy().sync()
        assertEquals(10 - summary.copied, next.copied)
        assertEquals(summary.copied, next.unchanged)
    }

    @Test
    fun aManifestThatCannotBeReadCopiesEverythingAgain() {
        provider.file("a.txt", "a\n")
        copy().sync()
        File(copies, ".manifests/folder-1.tsv").writeText("garbage\n")
        assertEquals(1, copy().sync().copied)
        File(copies, ".manifests/folder-1.tsv").writeText("${CopyManifest.HEADER}\n../x\t1\t2\t3\t4\n")
        assertEquals(1, copy().sync().copied)
        assertNull(CopyManifest.read(File(copies, "none.tsv"))["a.txt"])
    }

    @Test
    fun anImportTakesGitToo() {
        provider.file(".git/HEAD", "ref: refs/heads/main\n")
        provider.file("main.js", "main\n")
        val target = temp.newFolder("import-target")
        val summary = FolderCopy(
            source = SafCopySource(ops),
            target = target,
            manifestFile = null,
            staging = temp.newFolder("import-staging"),
            limits = CopyLimits.IMPORT,
            skipped = emptySet(),
        ).sync()
        assertEquals(2, summary.copied)
        assertEquals("ref: refs/heads/main\n", File(target, ".git/HEAD").readText())
    }

    @Test
    fun anImportTakesAPackFileOverTheUsualCap() {
        // A repository's pack is one large file (PHASE_7_PLAN §9): an import's
        // per-file cap is the whole copy's, so `.git` comes along entire or the
        // copy fills up and says so. A run's copy keeps the 64 MB cap, and skips
        // `.git` altogether.
        assertEquals(CopyLimits.IMPORT.maxBytes, CopyLimits.IMPORT.maxFileBytes)
        assertEquals(64L * 1024 * 1024, CopyLimits().maxFileBytes)

        provider.file(".git/objects/pack/pack-1.pack", ByteArray(150))
        provider.file("main.js", "main\n")
        val target = temp.newFolder("import-pack-target")
        // The import's shape at a size this test can hold: one file may be as
        // large as the whole copy.
        val summary = FolderCopy(
            source = SafCopySource(ops),
            target = target,
            manifestFile = null,
            staging = temp.newFolder("import-pack-staging"),
            limits = CopyLimits(maxFiles = 100, maxBytes = 200, maxFileBytes = 200),
            skipped = emptySet(),
        ).sync()
        assertEquals(0, summary.leftOutLarge)
        assertEquals(2, summary.copied)
        assertEquals(150L, File(target, ".git/objects/pack/pack-1.pack").length())

        // A run's copy leaves the same file out and takes no .git at all.
        val run = copy(CopyLimits(maxFileBytes = 100)).sync()
        assertEquals(0, run.leftOutLarge)
        assertEquals(1, run.skipped)
        assertEquals(1, run.copied)
        assertFalse(copied(".git").exists())
    }

    @Test
    fun deleteTreeLeavesWhatALinkPointsAt() {
        val outside = temp.newFolder("keep")
        File(outside, "precious.txt").writeText("precious\n")
        val doomed = temp.newFolder("doomed")
        File(doomed, "a.txt").writeText("a\n")
        Files.createSymbolicLink(File(doomed, "link").toPath(), outside.toPath())
        FolderCopy.deleteTree(doomed.toPath())
        assertFalse(doomed.exists())
        assertEquals("precious\n", File(outside, "precious.txt").readText())
    }

    @Test
    fun copyIdsAreNamesNeverPaths() {
        assertTrue(FolderCopy.isCopyId("folder-0123456789abcdef0123456789abcdef"))
        for (bad in listOf("", ".manifests", "../x", "a/b", "Folder", "-x", "x".repeat(65))) {
            assertFalse(bad, FolderCopy.isCopyId(bad))
        }
    }
}
