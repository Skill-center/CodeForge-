package dev.codeforge.app.git

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.codeforge.app.runtime.RuntimeHubs
import io.flutter.plugin.common.BinaryMessenger
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * The Git host (Phase 7 W2; pigeons/git_api.dart; docs/adr/0016-git.md):
 * Dart's typed API to the runtime's own git, over the process's one
 * RuntimeHub. Orchestration only: [GitCommands] decides what may run and
 * how, [GitRunner] runs it in a project resolved from its folder's name,
 * and this class turns runs into Pigeon's messages.
 *
 * A run's records, progress and exit go to Dart through GitEvents on the
 * main thread, in order. Runs belong to this engine: when it goes
 * ([close]), they are stopped. Logs name an operation, its run, its exit
 * and its time, never an argument, a path or a URL (PHASE_7_PLAN §4).
 */
class GitHost(context: Context, messenger: BinaryMessenger) : GitApi {
    private val app = context.applicationContext
    private val hub = RuntimeHubs.get(app)
    private val events = GitEvents(messenger)
    private val main = Handler(Looper.getMainLooper())
    private val threads = AtomicInteger()
    private val pool: ExecutorService = Executors.newCachedThreadPool { task ->
        Thread(task, "codeforge-git-${threads.incrementAndGet()}").apply { isDaemon = true }
    }

    @Volatile
    private var closed = false

    private val runner = GitRunner(
        processes = { request, sink, maxRecordBytes, separator, started, extraRoots, progress ->
            hub.stream(request, sink, started, extraRoots, maxRecordBytes, separator, progress)
        },
        projects = File(app.filesDir, RuntimeHubs.PROJECTS),
        executor = pool,
    )

    private val listener = object : GitListener {
        override fun output(runId: Long, records: List<String>) {
            main.post {
                if (!closed) events.output(runId, records) { }
            }
        }

        override fun progress(runId: Long, text: String, closing: Boolean) {
            main.post {
                if (!closed) events.progress(runId, text, closing) { }
            }
        }

        override fun exited(exit: GitExit) {
            Log.i(
                TAG,
                "git ${exit.operation} (run ${exit.runId}): " + (exit.failure?.code ?: exit.exitCode?.let { "exit $it" } ?: "ended") +
                    ", ${exit.records} records, ${exit.elapsedMs} ms" + (if (exit.truncated) ", truncated" else ""),
            )
            val message = GitExitMessage(
                runId = exit.runId,
                operation = exit.operation,
                exitCode = exit.exitCode?.toLong(),
                failure = exit.failure?.code,
                detail = exit.detail,
                stderr = exit.stderr,
                records = exit.records.toLong(),
                chars = exit.chars,
                truncated = exit.truncated,
                elapsedMs = exit.elapsedMs,
            )
            main.post {
                if (!closed) events.exited(message) { }
            }
        }
    }

    /** The engine is going: its runs stop, and no more events go to it. */
    fun close() {
        closed = true
        runner.stopAll()
        pool.shutdown()
    }

    override fun run(request: GitRunMessage, callback: (Result<GitStartMessage>) -> Unit) {
        if (closed) {
            callback(Result.success(GitStartMessage(failure = GitFailure.LAUNCH_FAILED.code, detail = "the git host is closed")))
            return
        }
        val maxRecords = request.maxRecords?.coerceIn(1L, GitRunner.MAX_RECORDS.toLong())?.toInt()
        val refused = runner.start(request.runId, request.project, request.operation, request.arguments, maxRecords, listener)
        if (refused != null) {
            // The operation only when it is one of ours: anything else Dart sent could be anything.
            val operation = request.operation.takeIf { it in GitCommands.OPERATIONS } ?: "(unknown operation)"
            Log.w(TAG, "git $operation (run ${request.runId}) refused: ${refused.failure.code}")
        }
        callback(Result.success(GitStartMessage(failure = refused?.failure?.code, detail = refused?.message)))
    }

    override fun stop(runId: Long, callback: (Result<Boolean>) -> Unit) {
        callback(Result.success(runner.stop(runId)))
    }

    private companion object {
        const val TAG = "CodeForgeGit"
    }
}
