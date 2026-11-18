package dev.codeforge.app.search

import dev.codeforge.app.storage.DocFlags
import dev.codeforge.app.storage.DocumentOps
import dev.codeforge.app.storage.DocumentRow
import dev.codeforge.app.storage.StorageException
import dev.codeforge.app.storage.StorageProblem
import java.io.File
import java.io.IOException
import java.nio.file.Files

/** One entry of a [ScanTree]: [path] is relative to the tree's top, '/'-separated. */
class ScanEntry(
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    /** Bytes, when the tree says. */
    val size: Long?,
    internal val handle: Any?,
)

/** A tree [TextScan] walks: a project's folder, or a folder from shared storage. */
interface ScanTree {
    /** The entries of [folder], or of the top when it is null. Throws when they can't be listed. */
    fun entries(folder: ScanEntry?): List<ScanEntry>

    /** [file]'s bytes; null when it holds more than [cap]. Throws when it can't be read. */
    fun read(file: ScanEntry, cap: Int): ByteArray?
}

/** A project's folder in the app's storage. Links are never followed, as ripgrep does not. */
class LocalTree(private val root: File) : ScanTree {
    override fun entries(folder: ScanEntry?): List<ScanEntry> {
        val dir = (folder?.handle as? File) ?: root
        val children = dir.listFiles() ?: throw IOException("not listed")
        val out = ArrayList<ScanEntry>(children.size)
        for (child in children) {
            if (Files.isSymbolicLink(child.toPath())) continue
            val path = if (folder == null) child.name else "${folder.path}/${child.name}"
            val directory = child.isDirectory
            out.add(ScanEntry(child.name, path, directory, if (directory) null else child.length(), child))
        }
        return out
    }

    override fun read(file: ScanEntry, cap: Int): ByteArray? {
        val handle = file.handle as File
        if (handle.length() > cap) return null
        return handle.readBytes().takeIf { it.size <= cap }
    }
}

/**
 * A folder from shared storage, through the storage broker's operations on
 * its grant (DocumentOps): the same listings the explorer gets, so a name the
 * explorer can't reach is never a result. Virtual documents have no bytes.
 */
class SafTree(private val ops: DocumentOps) : ScanTree {
    override fun entries(folder: ScanEntry?): List<ScanEntry> {
        val row = (folder?.handle as? DocumentRow) ?: ops.root()
        val out = ArrayList<ScanEntry>()
        for (child in ops.entries(row, folder?.path ?: "")) {
            if (!child.isDirectory && child.has(DocFlags.VIRTUAL_DOCUMENT)) continue
            val path = if (folder == null) child.name else "${folder.path}/${child.name}"
            out.add(ScanEntry(child.name, path, child.isDirectory, child.size, child))
        }
        return out
    }

    override fun read(file: ScanEntry, cap: Int): ByteArray? = try {
        ops.bytes(file.handle as DocumentRow, cap)
    } catch (large: StorageException) {
        if (large.problem == StorageProblem.TOO_LARGE) null else throw large
    }
}

/**
 * The search CodeForge runs itself (Phase 4 W6): a folder from shared
 * storage, which ripgrep can't read, and a project while the runtime is not
 * ready. It walks [tree] top folders first, in name order, and reads each
 * file the editor could open, line by line through [LineMatcher].
 *
 * - **Left out:** [SearchLimits.SKIPPED_FOLDERS] (files of that name too, as
 *   ripgrep's glob does), whatever [GlobFilter] leaves out, folders deeper
 *   than [SearchLimits.maxDepth], files over [SearchLimits.maxFileBytes], and
 *   files that are not text by the editor's rule ([TextRule]).
 * - **Lines** break at \n, \r\n and a lone \r, as the editor's do, so a
 *   result opens at its line.
 * - **Stops** when [stopped] says so (checked between files), at
 *   [SearchLimits.maxFiles] files, or when the collector is full.
 */
class TextScan(
    private val tree: ScanTree,
    private val query: SearchQuery,
    private val limits: SearchLimits,
    private val collector: SearchCollector,
    private val stopped: () -> Boolean,
) {
    var searched = 0
        private set
    var binary = 0
        private set
    var large = 0
        private set
    var notText = 0
        private set
    var unreadable = 0
        private set

    /** Whether it stopped at [SearchLimits.maxFiles]. */
    var filesCapped = false
        private set

    /** Walks the tree. Throws IllegalArgumentException for a bad query, and what the top's listing throws. */
    fun run() {
        val matcher = LineMatcher.of(query)
        val filter = GlobFilter(query.includes, query.excludes)
        val pending = ArrayDeque<Pair<ScanEntry?, Int>>()
        pending.add(null to 0)
        while (pending.isNotEmpty()) {
            if (stopped() || collector.full) return
            val (folder, depth) = pending.removeFirst()
            val entries = try {
                tree.entries(folder)
            } catch (failure: Exception) {
                if (folder == null) throw failure
                unreadable += 1
                continue
            }
            for (entry in entries.sortedBy { it.name }) {
                if (stopped() || collector.full) return
                if (entry.name in SearchLimits.SKIPPED_FOLDERS) continue
                if (!filter.accepts(entry.path, entry.name, entry.isDirectory)) continue
                if (entry.isDirectory) {
                    if (depth + 1 < limits.maxDepth) pending.add(entry to depth + 1)
                    continue
                }
                if (searched >= limits.maxFiles) {
                    filesCapped = true
                    return
                }
                searched += 1
                scanFile(entry, matcher)
                collector.poll()
            }
        }
    }

    private fun scanFile(entry: ScanEntry, matcher: LineMatcher) {
        val listed = entry.size
        if (listed != null && listed > limits.maxFileBytes) {
            large += 1
            return
        }
        val bytes = try {
            tree.read(entry, limits.maxFileBytes)
        } catch (failure: Exception) {
            unreadable += 1
            return
        }
        if (bytes == null) {
            large += 1
            return
        }
        val text = when (val decoded = TextRule.decode(bytes)) {
            is TextRule.Decoded.Text -> decoded.text
            TextRule.Decoded.Binary -> {
                binary += 1
                return
            }
            TextRule.Decoded.NotText -> {
                notText += 1
                return
            }
        }
        val found = ArrayList<SearchLine>()
        var number = 1
        var start = 0
        while (true) {
            var end = start
            while (end < text.length && text[end] != '\n' && text[end] != '\r') end += 1
            val matches = matcher.find(text.substring(start, end))
            if (matches != null) {
                found.add(SearchCollector.lineOf(number, text.substring(start, end), matches.ranges, matches.count))
                if (collector.lines + found.size >= limits.maxLines) break
            }
            if (end >= text.length) break
            start = if (text[end] == '\r' && end + 1 < text.length && text[end + 1] == '\n') end + 2 else end + 1
            number += 1
            if (start == text.length) break
        }
        if (found.isNotEmpty()) collector.add(entry.path, found)
    }

    /** The summary once the walk has ended. */
    fun summary(engineFailure: SearchFailure?, detail: String?, cancelled: Boolean, timedOut: Boolean): SearchSummary {
        collector.flush()
        val base = SearchSummary(
            outcome = SearchOutcome.DONE,
            engine = SearchEngine.SCAN,
            filesSearched = searched,
            filesMatched = collector.filesMatched,
            lines = collector.lines,
            matches = collector.matches,
            skippedBinary = binary,
            skippedLarge = large,
            skippedNotText = notText,
            unreadable = unreadable,
            firstResultMs = collector.firstResultMs,
            elapsedMs = collector.elapsedMs(),
        )
        return when {
            engineFailure != null -> base.copy(outcome = SearchOutcome.FAILED, failure = engineFailure, detail = detail)
            cancelled -> base.copy(outcome = SearchOutcome.CANCELLED)
            timedOut -> base.copy(
                outcome = SearchOutcome.FAILED,
                failure = SearchFailure.TIMED_OUT,
                detail = "The search ran past its time limit.",
            )
            collector.full || filesCapped -> base.copy(outcome = SearchOutcome.LIMIT)
            else -> base
        }
    }

    companion object {
        /** A failure the top folder's listing threw, as the search's. */
        fun failureOf(error: Throwable): Pair<SearchFailure, String> = when (error) {
            is StorageException -> when (error.problem) {
                StorageProblem.ACCESS_LOST -> SearchFailure.ACCESS_LOST to (error.message ?: "The app lost access to the folder.")
                StorageProblem.MISSING, StorageProblem.NOT_FOUND -> SearchFailure.NOT_FOUND to (error.message ?: "The folder is gone.")
                StorageProblem.TIMEOUT -> SearchFailure.TIMED_OUT to "The folder took too long to answer."
                else -> SearchFailure.FAILED to (error.message ?: error.problem.code)
            }
            is IOException -> SearchFailure.NOT_FOUND to "The folder could not be listed."
            else -> SearchFailure.FAILED to error.toString()
        }
    }
}
