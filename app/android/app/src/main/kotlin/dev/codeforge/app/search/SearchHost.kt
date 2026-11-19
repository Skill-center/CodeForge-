package dev.codeforge.app.search

import android.content.Context
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import dev.codeforge.app.runtime.CommandRequest
import dev.codeforge.app.runtime.CommandRunner
import dev.codeforge.app.runtime.EndReason
import dev.codeforge.app.runtime.RuntimeHubs
import dev.codeforge.app.runtime.RuntimeState
import dev.codeforge.app.runtime.SessionRegistry
import dev.codeforge.app.storage.Cancellation
import dev.codeforge.app.storage.DocumentOps
import dev.codeforge.app.storage.StorageException
import dev.codeforge.app.storage.StorageProblem
import io.flutter.plugin.common.BinaryMessenger
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * The search host (Phase 4 W6; pigeons/search_api.dart): searching across
 * the open workspace's files.
 *
 * - **A project** (`<filesDir>/workspaces/<name>`) is searched by the
 *   runtime's ripgrep ([RipgrepSearch]) while the runtime is READY or
 *   DEGRADED, through the runtime's command path (RuntimeHub.stream: the
 *   launcher, the session, the prefix's read lock). Otherwise, while the
 *   runtime installs or in a build without one, [TextScan] searches it, and
 *   the summary says so.
 * - **A folder from shared storage** is searched by [TextScan] through the
 *   storage broker's operations on its grant ([folders]): ripgrep can't read
 *   a documents provider.
 * - **One search at a time:** a new one cancels the one before. Each ends
 *   with one summary; results reach Dart in batches before it
 *   ([SearchCollector]). Cancelling ends ripgrep with everything it started,
 *   and stops a scan between files and in its provider calls.
 *
 * Logs give the engine, the outcome, the counts and the times: never a
 * query or a path.
 */
class SearchHost(
    context: Context,
    messenger: BinaryMessenger,
    private val folders: (treeUri: String, signal: CancellationSignal, cancel: Cancellation) -> DocumentOps,
) : SearchApi {
    private val app = context.applicationContext
    private val events = SearchEvents(messenger)
    private val main = Handler(Looper.getMainLooper())
    private val threads = AtomicInteger()
    private val pool = Executors.newCachedThreadPool { task ->
        Thread(task, "codeforge-search-${threads.incrementAndGet()}").apply { isDaemon = true }
    }
    private val lock = Any()
    private var running: Running? = null

    @Volatile
    private var closed = false

    /** One search's way to stop: its flag, ripgrep's session, and the provider calls' signal. */
    private class Running(val id: Long, private val timeoutMs: Long) {
        private val startedAt = SystemClock.elapsedRealtime()
        private var session: SessionRegistry.Session? = null
        val signal = CancellationSignal()

        @Volatile
        var cancelled = false
            private set

        fun timedOut(): Boolean = SystemClock.elapsedRealtime() - startedAt > timeoutMs

        fun stopped(): Boolean = cancelled || timedOut()

        fun cancel() {
            val current = synchronized(this) {
                cancelled = true
                session
            }
            current?.end(EndReason.ENDED)
            signal.cancel()
        }

        /** ripgrep runs: a cancel that came first ends it now. */
        fun attach(started: SessionRegistry.Session) {
            val late = synchronized(this) {
                session = started
                cancelled
            }
            if (late) started.end(EndReason.ENDED)
        }
    }

    override fun start(request: SearchRequestMessage, callback: (Result<Unit>) -> Unit) {
        val wanted = request.maxResults?.toInt() ?: SearchLimits.DEFAULT_MAX_LINES
        val limits = SearchLimits(maxLines = wanted.coerceIn(1, SearchLimits.DEFAULT_MAX_LINES))
        val run = Running(request.searchId, limits.timeoutMs)
        val previous = synchronized(lock) {
            val before = running
            running = run
            before
        }
        callback(Result.success(Unit))
        pool.execute {
            previous?.cancel()
            val summary = try {
                search(run, request, limits)
            } catch (error: Exception) {
                SearchSummary(SearchOutcome.FAILED, SearchEngine.SCAN, SearchFailure.FAILED, error.toString())
            }
            Log.i(
                TAG,
                "search ${summary.engine.code} ${summary.outcome.code}${summary.failure?.let { "/${it.code}" } ?: ""} " +
                    "files=${summary.filesSearched} matched=${summary.filesMatched} lines=${summary.lines} " +
                    "matches=${summary.matches} firstMs=${summary.firstResultMs} ms=${summary.elapsedMs}",
            )
            synchronized(lock) {
                if (running === run) running = null
            }
            val message = summary.toMessage(run.id)
            deliver { events.finished(message) {} }
        }
    }

    override fun cancel(searchId: Long, callback: (Result<Unit>) -> Unit) {
        val target = synchronized(lock) { running?.takeIf { it.id == searchId } }
        if (target != null) pool.execute { target.cancel() }
        callback(Result.success(Unit))
    }

    /** The engine is going: the running search stops, and nothing more is sent. */
    fun close() {
        closed = true
        val current = synchronized(lock) {
            val before = running
            running = null
            before
        }
        if (current != null) pool.execute { current.cancel() }
        pool.shutdown()
    }

    private fun search(run: Running, request: SearchRequestMessage, limits: SearchLimits): SearchSummary {
        val query = SearchQuery(
            text = request.query,
            caseSensitive = request.caseSensitive,
            regex = request.regex,
            wholeWord = request.wholeWord,
            includes = GlobFilter.expand(request.includes),
            excludes = GlobFilter.expand(request.excludes),
        )
        if (query.text.isEmpty()) return failed(SearchFailure.BAD_QUERY, "Type something to search for.")
        try {
            GlobFilter(query.includes, query.excludes)
        } catch (bad: IllegalArgumentException) {
            return failed(SearchFailure.BAD_QUERY, bad.message)
        }
        val collector = SearchCollector(limits, emit = { batch ->
            val messages = batch.map { it.toMessage() }
            deliver { events.found(run.id, messages) {} }
        })
        val project = request.projectRoot
        val tree = request.treeUri
        return when {
            project != null -> searchProject(run, project, query, limits, collector)
            tree != null -> searchFolder(run, tree, query, limits, collector)
            else -> failed(SearchFailure.BAD_QUERY, "Nothing to search in.")
        }
    }

    private fun searchProject(
        run: Running,
        path: String,
        query: SearchQuery,
        limits: SearchLimits,
        collector: SearchCollector,
    ): SearchSummary {
        val projects = File(app.filesDir, PROJECTS).canonicalFile
        val root = try {
            File(path).canonicalFile
        } catch (unreadable: IOException) {
            null
        }
        if (root == null || !root.path.startsWith(projects.path + File.separator)) {
            return failed(SearchFailure.FAILED, "Only a project's folder can be searched this way.")
        }
        if (!root.isDirectory) return failed(SearchFailure.NOT_FOUND, "The project's folder is gone.")
        val hub = RuntimeHubs.get(app)
        val state = hub.snapshot().state
        if (state == RuntimeState.READY || state == RuntimeState.DEGRADED) {
            val ripgrep = RipgrepSearch(root, query, limits, collector, run::stopped)
            // In the project's folder: ripgrep reads its globs from where it runs.
            val command = CommandRequest(
                program = "rg",
                arguments = ripgrep.arguments(),
                directory = root,
                timeoutMs = limits.timeoutMs.coerceAtMost(CommandRunner.MAX_TIMEOUT_MS),
                outputLimit = STDERR_LIMIT,
            )
            val result = hub.stream(command, ripgrep, run::attach, extraRoots = listOf(projects))
            if (result != null) return ripgrep.summary(result, run.cancelled)
            // An install took the prefix meanwhile: the scan instead.
        }
        return scan(TextScan(LocalTree(root), query, limits, collector, stopped = run::stopped), run)
    }

    private fun searchFolder(
        run: Running,
        treeUri: String,
        query: SearchQuery,
        limits: SearchLimits,
        collector: SearchCollector,
    ): SearchSummary {
        val ops = try {
            folders(treeUri, run.signal, Cancellation {
                if (run.stopped()) throw StorageException(StorageProblem.TIMEOUT, "The search stopped.")
            })
        } catch (error: Exception) {
            val (failure, detail) = TextScan.failureOf(error)
            return failed(failure, detail)
        }
        // Each file is an open the provider answers: read several at a time.
        val walk = TextScan(SafTree(ops), query, limits, collector, parallelism = SAF_READERS, stopped = run::stopped)
        return scan(walk, run)
    }

    private fun scan(walk: TextScan, run: Running): SearchSummary = try {
        walk.run()
        walk.summary(null, null, run.cancelled, run.timedOut())
    } catch (bad: IllegalArgumentException) {
        walk.summary(SearchFailure.BAD_QUERY, bad.message, cancelled = false, timedOut = false)
    } catch (error: Exception) {
        if (run.stopped()) {
            walk.summary(null, null, run.cancelled, run.timedOut())
        } else {
            val (failure, detail) = TextScan.failureOf(error)
            walk.summary(failure, detail, cancelled = false, timedOut = false)
        }
    }

    private fun failed(failure: SearchFailure, detail: String?) =
        SearchSummary(SearchOutcome.FAILED, SearchEngine.SCAN, failure, detail)

    private fun deliver(task: () -> Unit) {
        if (closed) return
        main.post { if (!closed) task() }
    }

    private companion object {
        const val TAG = "CodeForgeSearch"

        /** Where projects live: `<filesDir>/workspaces` (lib/services/platform/app_directories.dart). */
        const val PROJECTS = RuntimeHubs.PROJECTS

        /** ripgrep's stderr kept: its complaints about files it could not read. */
        const val STDERR_LIMIT = 64 * 1024

        /** Files a folder's scan reads at once through its provider. */
        const val SAF_READERS = 4
    }
}

internal fun SearchLine.toMessage() = SearchLineMessage(
    line = line.toLong(),
    column = column.toLong(),
    preview = preview,
    previewStart = previewStart.toLong(),
    cutEnd = cutEnd,
    ranges = ranges.map { it.toLong() },
    matches = matches.toLong(),
)

internal fun SearchFile.toMessage() = SearchFileMessage(path = path, lines = lines.map { it.toMessage() })

internal fun SearchSummary.toMessage(searchId: Long) = SearchSummaryMessage(
    searchId = searchId,
    outcome = outcome.code,
    engine = engine.code,
    failure = failure?.code,
    detail = detail,
    filesSearched = filesSearched?.toLong(),
    filesMatched = filesMatched.toLong(),
    lines = lines.toLong(),
    matches = matches.toLong(),
    skippedBinary = skippedBinary.toLong(),
    skippedLarge = skippedLarge.toLong(),
    skippedNotText = skippedNotText.toLong(),
    skippedLongLines = skippedLongLines.toLong(),
    unreadable = unreadable.toLong(),
    firstResultMs = firstResultMs,
    elapsedMs = elapsedMs,
)
