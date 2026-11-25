package dev.codeforge.app.git

import dev.codeforge.app.runtime.CommandFailure
import dev.codeforge.app.runtime.CommandRequest
import dev.codeforge.app.runtime.CommandResult
import dev.codeforge.app.runtime.EndReason
import dev.codeforge.app.runtime.LineSink
import dev.codeforge.app.runtime.ProgressSink
import dev.codeforge.app.runtime.SessionRegistry
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor

/** How a run ended: git's exit, or the host's failure, with what came out. */
data class GitExit(
    val runId: Long,
    val operation: String,
    val access: GitAccess,
    /** git's exit code when it exited by itself; null when it was ended, or never ran. */
    val exitCode: Int?,
    val failure: GitFailure?,
    val detail: String?,
    /** What git wrote to stderr, up to [GitRunner.STDERR_LIMIT] bytes. */
    val stderr: String,
    /** Records passed on, and their characters. */
    val records: Int,
    val chars: Long,
    /** Ended at the run's record cap or the host's character cap: what came is a beginning. */
    val truncated: Boolean,
    val elapsedMs: Long,
)

/** A run's records, in batches as they come, and its progress, then its exit, once; on the run's threads. */
interface GitListener {
    fun output(runId: Long, records: List<String>)

    /** A line of git's progress from stderr (`Updating files:  45% (450/1000)`); [closing] ends a run of them. */
    fun progress(runId: Long, text: String, closing: Boolean)

    fun exited(exit: GitExit)
}

/** The runtime's command side as the Git runner uses it: RuntimeHub.stream on a device, CommandRunner in a JVM test. */
fun interface GitProcesses {
    /**
     * Runs [request] with its stdout cut at [separator] into [sink], and its
     * stderr's progress into [progress]; null when the runtime cannot run
     * commands now.
     */
    fun stream(
        request: CommandRequest,
        sink: LineSink,
        maxRecordBytes: Int,
        separator: Int,
        started: (SessionRegistry.Session) -> Unit,
        extraRoots: List<File>,
        progress: ProgressSink,
    ): CommandResult?
}

/**
 * One remote run's credentials (Phase 7 W3; ADR-0016): CodeForge's
 * credential helper on that command's line ([settings]), ssh's askpass and
 * how git runs ssh in its variables ([variables]); [close] once it ends.
 * A secret never passes through either: CredentialChannel's FIFOs carry it.
 */
interface GitRunCredentials {
    val settings: List<String>
    val variables: Map<String, String>

    /** A stored credential was refused and erased during the run. */
    val erased: Boolean

    fun close()
}

/** Opens [GitRunCredentials] for a run that reaches a remote. */
fun interface GitCredentialsFactory {
    fun open(runId: Long): GitRunCredentials
}

/**
 * Runs the runtime's git for Dart (Phase 7 W2, PHASE_7_PLAN W2; ADR-0016):
 * the operations [GitCommands] allows, in a project named by its folder's
 * name and resolved here, never a path from Dart (docs/SECURITY.md §2.1,
 * E3), or in the runtime's home for the identity.
 *
 * A run starts at once on [executor], or is refused at once. Its stdout
 * reaches the listener as records in batches, and its exit follows, once,
 * after the last batch. One change at a time runs per repository: a second
 * is refused as BUSY, and Dart's controller queues its own. Reads run
 * alongside, without the index's optional lock. Nothing here logs:
 * GitHost logs an operation's kind, its time and its exit, never its
 * arguments, a path or a URL.
 */
class GitRunner(
    private val processes: GitProcesses,
    /** Where projects live (`<filesDir>/workspaces`). */
    projects: File,
    private val executor: Executor,
    private val clock: () -> Long = System::nanoTime,
    /** The most characters of records one run passes on; it is ended there, truncated. */
    private val maxChars: Long = MAX_CHARS,
    private val batchRecords: Int = BATCH_RECORDS,
    private val batchChars: Int = BATCH_CHARS,
    /** Runs at once; another is refused as BUSY (Dart's controller runs a few). */
    private val maxRunning: Int = MAX_RUNNING,
    /** A remote run's helper and askpass (Phase 7 W3); without it, a remote run fails to launch. */
    private val credentials: GitCredentialsFactory? = null,
) {
    private val projectsRoot: File = projects.absoluteFile
    private val running = ConcurrentHashMap<Long, Run>()

    /** Each repository's running change, by its folder (or [HOME_KEY]): the run's id. */
    private val writers = ConcurrentHashMap<String, Long>()

    /** Admits runs one at a time, so the cap and the locks hold exactly. */
    private val admission = Any()

    /** One run's way to stop: its flag, and its git's session once it runs. */
    private class Run(val id: Long, val command: GitCommand) {
        private var session: SessionRegistry.Session? = null

        @Volatile
        var stopped = false
            private set

        fun stop() {
            val current = synchronized(this) {
                stopped = true
                session
            }
            current?.end(EndReason.ENDED)
        }

        /** git runs: a stop that came first ends it now. */
        fun attach(started: SessionRegistry.Session) {
            val late = synchronized(this) {
                session = started
                stopped
            }
            if (late) started.end(EndReason.ENDED)
        }
    }

    /**
     * Starts [operation] with [arguments] as run [runId], in [project] (a
     * project's folder name) or, for the identity, the runtime's home.
     * Answers null when it runs, its records and exit following through
     * [listener]; otherwise why not, at once, and nothing follows.
     * [maxRecords] ends it there, truncated: a status of a tree with a
     * million new files shows its first ones.
     */
    fun start(
        runId: Long,
        project: String?,
        operation: String,
        arguments: List<String>,
        maxRecords: Int?,
        listener: GitListener,
    ): GitRefused? {
        val command = try {
            GitCommands.build(operation, arguments)
        } catch (refused: GitRefused) {
            return refused
        }
        val directory: File? = when (command.place) {
            GitPlace.PROJECT -> {
                if (project == null) return GitRefused(GitFailure.BAD_REQUEST, "git $operation runs in a project")
                try {
                    projectFolder(project)
                } catch (refused: GitRefused) {
                    return refused
                }
            }
            GitPlace.HOME -> {
                if (project != null) return GitRefused(GitFailure.BAD_REQUEST, "git $operation runs in the runtime's home")
                null
            }
            GitPlace.EITHER -> if (project == null) {
                null
            } else {
                try {
                    projectFolder(project)
                } catch (refused: GitRefused) {
                    return refused
                }
            }
            GitPlace.NEW_PROJECT -> {
                if (project == null) return GitRefused(GitFailure.BAD_REQUEST, "git $operation names the new project")
                try {
                    newProjectFolder(project)
                } catch (refused: GitRefused) {
                    return refused
                }
            }
        }
        val run = Run(runId, command)
        val lock = when {
            command.place == GitPlace.NEW_PROJECT -> NEW_KEY + directory!!.name.lowercase()
            command.access == GitAccess.WRITE -> directory?.path ?: HOME_KEY
            else -> null
        }
        synchronized(admission) {
            if (running.containsKey(runId)) return GitRefused(GitFailure.BAD_REQUEST, "run $runId is running")
            if (running.size >= maxRunning) return GitRefused(GitFailure.BUSY, "$maxRunning git commands are running")
            if (lock != null && writers.putIfAbsent(lock, runId) != null) {
                return GitRefused(GitFailure.BUSY, "another change to this repository is running")
            }
            running[runId] = run
        }
        val limit = (maxRecords ?: MAX_RECORDS).coerceIn(1, MAX_RECORDS)
        try {
            executor.execute { execute(run, directory, limit, lock, listener) }
        } catch (rejected: RuntimeException) {
            running.remove(runId, run)
            if (lock != null) writers.remove(lock, runId)
            return GitRefused(GitFailure.LAUNCH_FAILED, "the git host is closing")
        }
        return null
    }

    /** Stops run [runId] with everything it started; its exit follows. False when no such run runs. */
    fun stop(runId: Long): Boolean {
        val run = running[runId] ?: return false
        run.stop()
        return true
    }

    /** Stops every run; their exits follow. */
    fun stopAll() {
        for (run in running.values) run.stop()
    }

    /** The runs that have not exited. */
    fun runningCount(): Int = running.size

    private fun execute(run: Run, directory: File?, maxRecords: Int, lock: String?, listener: GitListener) {
        val startedAt = clock()
        val command = run.command
        val sink = Batcher(run.id, listener, maxRecords, maxChars, batchRecords, batchChars)
        var result: CommandResult? = null
        var thrown: String? = null
        var refused: GitExit? = null
        var opened: GitRunCredentials? = null
        // A clone runs in the projects' folder, into a hidden folder renamed into place when git succeeds.
        val target = if (command.place == GitPlace.NEW_PROJECT) directory else null
        val staging = target?.let { File(it.parentFile, "$STAGING_PREFIX${run.id}") }
        try {
            if (command.network) {
                opened = (credentials ?: throw IOException("no credential helper here")).open(run.id)
            }
            var arguments = GitCommands.withSettings(command, opened?.settings.orEmpty())
            if (staging != null) {
                staging.deleteRecursively()
                arguments = arguments + staging.path
            }
            val request = CommandRequest(
                program = "git",
                arguments = arguments,
                directory = if (target != null) target.parentFile else directory,
                timeoutMs = command.timeoutMs,
                outputLimit = STDERR_LIMIT,
                variables = GitCommands.variables(if (directory != null) canonicalProjects() else null) +
                    opened?.variables.orEmpty(),
            )
            result = processes.stream(
                request,
                sink,
                command.output.maxRecordBytes,
                command.output.separator,
                run::attach,
                listOf(projectsRoot),
                Throttle(run.id, listener, clock),
            )
            if (target != null && staging != null) {
                val cloned = result != null && result.failure == null && result.exitCode == 0
                if (cloned && !run.stopped) {
                    refused = moveIntoPlace(run, staging, target, sink)
                }
            }
        } catch (failure: Exception) {
            thrown = failure.toString()
        } finally {
            try {
                sink.flush()
            } finally {
                try {
                    opened?.close()
                } finally {
                    if (staging != null && staging.exists()) staging.deleteRecursively()
                    running.remove(run.id, run)
                    if (lock != null) writers.remove(lock, run.id)
                }
            }
        }
        val elapsedMs = (clock() - startedAt) / 1_000_000L
        listener.exited(refused?.copy(elapsedMs = elapsedMs) ?: exitOf(run, result, thrown, sink, elapsedMs))
    }

    /** A clone's staging folder renamed to its project's name; an exit when that cannot be done. */
    private fun moveIntoPlace(run: Run, staging: File, target: File, sink: Batcher): GitExit? {
        val taken = target.exists() || taken(target.name)
        if (!taken && staging.renameTo(target)) return null
        return GitExit(
            runId = run.id,
            operation = run.command.operation,
            access = run.command.access,
            exitCode = null,
            failure = if (taken) GitFailure.EXISTS else GitFailure.LAUNCH_FAILED,
            detail = if (taken) "a project of that name appeared meanwhile" else "the clone could not be moved into place",
            stderr = "",
            records = sink.records,
            chars = sink.chars,
            truncated = sink.truncated,
            elapsedMs = 0L,
        )
    }

    private fun exitOf(run: Run, result: CommandResult?, thrown: String?, sink: Batcher, elapsedMs: Long): GitExit {
        fun exit(exitCode: Int?, failure: GitFailure?, detail: String?, stderr: String = result?.stderr?.text.orEmpty()) =
            GitExit(
                runId = run.id,
                operation = run.command.operation,
                access = run.command.access,
                exitCode = exitCode,
                failure = failure,
                detail = detail,
                stderr = stderr,
                records = sink.records,
                chars = sink.chars,
                truncated = sink.truncated,
                elapsedMs = elapsedMs,
            )
        if (thrown != null) return exit(null, GitFailure.LAUNCH_FAILED, thrown, "")
        if (result == null) return exit(null, GitFailure.NOT_READY, "the runtime is not ready", "")
        if (run.command.output == GitOutput.WHOLE && sink.overlong) {
            return exit(null, GitFailure.TOO_LARGE, "more than ${run.command.output.maxRecordBytes / (1024 * 1024)} MiB")
        }
        return when (result.failure) {
            null -> exit(result.exitCode, null, null)
            // The cap ended it: what came is a beginning, not a failure. Otherwise Dart's stop, or the host closing.
            CommandFailure.ENDED ->
                if (sink.truncated) exit(null, null, "ended at the cap") else exit(null, GitFailure.STOPPED, result.detail)
            CommandFailure.TIMED_OUT -> exit(null, GitFailure.TIMED_OUT, result.detail)
            CommandFailure.SIGNALED -> exit(null, GitFailure.SIGNALED, result.detail)
            CommandFailure.NOT_READY -> exit(null, GitFailure.NOT_READY, result.detail)
            CommandFailure.BAD_REQUEST -> exit(null, GitFailure.BAD_REQUEST, result.detail)
            CommandFailure.NOT_FOUND, CommandFailure.CANNOT_EXECUTE, CommandFailure.LAUNCH_FAILED ->
                exit(null, GitFailure.LAUNCH_FAILED, result.detail)
        }
    }

    /** [name]'s folder directly in the projects' folder, links resolved (E3). */
    fun projectFolder(name: String): File {
        if (name.isEmpty() || name == "." || name == ".." || name.contains('/') || name.contains('\u0000') || name.length > 255) {
            throw GitRefused(GitFailure.BAD_REQUEST, "a project is named by its folder's name")
        }
        val root = canonicalProjects()
        val folder = try {
            File(root, name).canonicalFile
        } catch (unreadable: IOException) {
            throw GitRefused(GitFailure.NO_SUCH_PROJECT, "no such project")
        }
        if (folder.parentFile != root) {
            throw GitRefused(GitFailure.BAD_REQUEST, "a project's folder lies in the projects' folder, links resolved")
        }
        if (!folder.isDirectory) throw GitRefused(GitFailure.NO_SUCH_PROJECT, "no such project")
        return folder
    }

    /**
     * Where a new project named [name] will be: directly in the projects'
     * folder, and nothing there named so in any case (Dart's projects compare
     * names so). Its folder does not exist yet.
     */
    fun newProjectFolder(name: String): File {
        if (name.isEmpty() || name == "." || name == ".." || name.startsWith(".") || name.contains('/') ||
            name.contains('\u0000') || name.length > 255
        ) {
            throw GitRefused(GitFailure.BAD_REQUEST, "a project is named by its folder's name")
        }
        val root = canonicalProjects()
        root.mkdirs()
        val folder = File(root, name)
        if (folder.exists() || taken(name)) throw GitRefused(GitFailure.EXISTS, "a project of that name exists")
        return folder
    }

    /** Whether anything in the projects' folder is named [name], in any case. */
    private fun taken(name: String): Boolean {
        val lower = name.lowercase()
        return canonicalProjects().list()?.any { it.lowercase() == lower } ?: false
    }

    private fun canonicalProjects(): File = try {
        projectsRoot.canonicalFile
    } catch (unreadable: IOException) {
        throw GitRefused(GitFailure.NO_SUCH_PROJECT, "the projects' folder cannot be read")
    }

    /**
     * Passes progress on, on the stderr reader's thread: at most one redrawn
     * line per [PROGRESS_INTERVAL_MS], as git redraws as often as a
     * percentage moves; every closing line.
     */
    private class Throttle(
        private val runId: Long,
        private val listener: GitListener,
        private val clock: () -> Long,
    ) : ProgressSink {
        private var last = Long.MIN_VALUE

        override fun progress(text: String, closing: Boolean) {
            val now = clock()
            if (!closing && last != Long.MIN_VALUE && now - last < PROGRESS_INTERVAL_MS * 1_000_000L) return
            last = now
            listener.progress(runId, text, closing)
        }
    }

    /**
     * Hands records on in batches, on the stdout reader's thread, and ends
     * the command at the run's record cap or the host's character cap. Read
     * again only after the command, whose readers have joined.
     */
    private class Batcher(
        private val runId: Long,
        private val listener: GitListener,
        private val maxRecords: Int,
        private val maxChars: Long,
        private val batchRecords: Int,
        private val batchChars: Int,
    ) : LineSink {
        private var batch = ArrayList<String>()
        private var batchSize = 0
        var records = 0
            private set
        var chars = 0L
            private set
        var truncated = false
            private set
        var overlong = false
            private set

        override fun line(text: String): Boolean {
            if (records >= maxRecords || chars + text.length > maxChars) {
                truncated = true
                return false
            }
            batch.add(text)
            records += 1
            chars += text.length
            batchSize += text.length
            if (batch.size >= batchRecords || batchSize >= batchChars) flush()
            return true
        }

        override fun overlong() {
            overlong = true
        }

        fun flush() {
            if (batch.isEmpty()) return
            val full = batch
            batch = ArrayList()
            batchSize = 0
            listener.output(runId, full)
        }
    }

    companion object {
        /** The lock's key for a change outside any project: the identity, in the runtime's home. */
        const val HOME_KEY = "<home>"

        /** The lock's key for a project being cloned, before its name: one clone per name at once. */
        const val NEW_KEY = "<new>"

        /** A clone's hidden staging folder in the projects' folder, before its run id: Dart lists no dot folder. */
        const val STAGING_PREFIX = ".clone-"

        /** Runs at once. */
        const val MAX_RUNNING = 8

        /** A run's most records, and its default: a status of a million new files shows the first ones. */
        const val MAX_RECORDS = 1_000_000

        /** A run's most characters of records (PHASE_7_PLAN W2: 64 MiB). */
        const val MAX_CHARS = 64L * 1024 * 1024

        /** A batch goes to Dart at this many records, or this many characters. */
        const val BATCH_RECORDS = 2_000
        const val BATCH_CHARS = 256 * 1024

        /** stderr kept: git's messages, which Dart reads to say what went wrong. */
        const val STDERR_LIMIT = 64 * 1024

        /** The shortest time between two redrawn progress lines passed on. */
        const val PROGRESS_INTERVAL_MS = 100L
    }
}
