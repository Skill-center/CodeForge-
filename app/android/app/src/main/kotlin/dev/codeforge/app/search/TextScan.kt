package dev.codeforge.app.search

import dev.codeforge.app.storage.DocFlags
import dev.codeforge.app.storage.DocumentOps
import dev.codeforge.app.storage.DocumentRow
import dev.codeforge.app.storage.StorageException
import dev.codeforge.app.storage.StorageProblem
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.Callable
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicInteger

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
 * - **Reads ahead** on [parallelism] threads: through a documents provider
 *   each file is an open the provider answers, about 5 ms on the gate's
 *   emulator, so the files are read and matched several at a time. Their
 *   results are taken back in the walk's order, on the walking thread, so the
 *   order and the counts are the same as one at a time.
 * - **Stops** when [stopped] says so (checked between files), at
 *   [SearchLimits.maxFiles] files, or when the collector is full; reads still
 *   in flight are cancelled.
 */
class TextScan(
    private val tree: ScanTree,
    private val query: SearchQuery,
    private val limits: SearchLimits,
    private val collector: SearchCollector,
    private val parallelism: Int = 1,
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

    /** What reading and matching one file found. */
    private sealed class Outcome {
        class Lines(val lines: List<SearchLine>) : Outcome()
        object Large : Outcome()
        object Binary : Outcome()
        object NotText : Outcome()
        object Unreadable : Outcome()
    }

    /** Walks the tree. Throws IllegalArgumentException for a bad query, and what the top's listing throws. */
    fun run() {
        val matcher = LineMatcher.of(query)
        val filter = GlobFilter(query.includes, query.excludes)
        val threads = parallelism.coerceIn(1, MAX_PARALLELISM)
        val pool = if (threads > 1) {
            val count = AtomicInteger()
            Executors.newFixedThreadPool(threads) { task ->
                Thread(task, "codeforge-scan-${count.incrementAndGet()}").apply { isDaemon = true }
            }
        } else {
            null
        }
        val inFlight = ArrayDeque<Pair<ScanEntry, Future<Outcome>>>()
        try {
            walk(matcher, filter, pool, inFlight)
            while (inFlight.isNotEmpty() && !stopped() && !collector.full) take(inFlight)
        } finally {
            for ((_, future) in inFlight) future.cancel(true)
            pool?.shutdownNow()
        }
    }

    private fun walk(
        matcher: LineMatcher,
        filter: GlobFilter,
        pool: ExecutorService?,
        inFlight: ArrayDeque<Pair<ScanEntry, Future<Outcome>>>,
    ) {
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
                if (pool == null) {
                    record(entry, scanFile(entry, matcher))
                    collector.poll()
                } else {
                    inFlight.add(entry to pool.submit(Callable { scanFile(entry, matcher) }))
                    // Enough read ahead to keep every thread busy, no more.
                    while (inFlight.size >= MAX_IN_FLIGHT) {
                        if (stopped() || collector.full) return
                        take(inFlight)
                    }
                }
            }
        }
    }

    /** The oldest read in flight, waited for and recorded. */
    private fun take(inFlight: ArrayDeque<Pair<ScanEntry, Future<Outcome>>>) {
        val (entry, future) = inFlight.removeFirst()
        val outcome = try {
            future.get()
        } catch (failure: ExecutionException) {
            Outcome.Unreadable
        } catch (failure: CancellationException) {
            Outcome.Unreadable
        }
        record(entry, outcome)
        collector.poll()
    }

    /** Counts one file's outcome; on the walking thread only. */
    private fun record(entry: ScanEntry, outcome: Outcome) {
        when (outcome) {
            is Outcome.Lines -> if (outcome.lines.isNotEmpty()) collector.add(entry.path, outcome.lines)
            Outcome.Large -> large += 1
            Outcome.Binary -> binary += 1
            Outcome.NotText -> notText += 1
            Outcome.Unreadable -> unreadable += 1
        }
    }

    /** Reads and matches one file: on any thread, touching nothing shared. */
    private fun scanFile(entry: ScanEntry, matcher: LineMatcher): Outcome {
        val listed = entry.size
        if (listed != null && listed > limits.maxFileBytes) return Outcome.Large
        val bytes = try {
            tree.read(entry, limits.maxFileBytes)
        } catch (failure: Exception) {
            return Outcome.Unreadable
        } ?: return Outcome.Large
        val text = when (val decoded = TextRule.decode(bytes)) {
            is TextRule.Decoded.Text -> decoded.text
            TextRule.Decoded.Binary -> return Outcome.Binary
            TextRule.Decoded.NotText -> return Outcome.NotText
        }
        val found = ArrayList<SearchLine>()
        var number = 1
        var start = 0
        while (true) {
            var end = start
            while (end < text.length && text[end] != '\n' && text[end] != '\r') end += 1
            val line = text.substring(start, end)
            val matches = matcher.find(line)
            if (matches != null) {
                found.add(SearchCollector.lineOf(number, line, matches.ranges, matches.count))
                // The collector keeps no more than its cap from any one file.
                if (found.size >= limits.maxLines) break
            }
            if (end >= text.length) break
            start = if (text[end] == '\r' && end + 1 < text.length && text[end + 1] == '\n') end + 2 else end + 1
            number += 1
            if (start == text.length) break
        }
        return Outcome.Lines(found)
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
        /** Threads a scan may read with. */
        const val MAX_PARALLELISM = 8

        /** Reads waiting at most, ahead of the one being recorded. */
        const val MAX_IN_FLIGHT = 16

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
