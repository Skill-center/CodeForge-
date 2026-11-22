package dev.codeforge.app.lsp

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.codeforge.app.runtime.LanguageServerProcess
import dev.codeforge.app.runtime.LspExit
import dev.codeforge.app.runtime.LspFailure
import dev.codeforge.app.runtime.LspListener
import dev.codeforge.app.runtime.LspWorkspace
import dev.codeforge.app.runtime.RuntimeHubs
import io.flutter.plugin.common.BinaryMessenger
import java.util.concurrent.ConcurrentHashMap

/**
 * The language servers' host (Phase 6 W3; pigeons/lsp_api.dart): Dart's typed
 * API to the runtime's language servers, over the process's one RuntimeHub.
 * Orchestration only: the hub starts a server on a command thread under the
 * prefix's lock (RuntimeHub.startLanguageServer), [dev.codeforge.app.runtime.LspHost]
 * holds the servers and their framing; this class turns them into Pigeon's
 * messages.
 *
 * A server's messages and its exit go to Dart through LspEvents on the main
 * thread, in order, each message with when the host read it whole. The
 * servers belong to this engine, whose Dart side holds their protocol state:
 * when the engine goes ([close]), they are stopped. A stop is answered at
 * once (it sends a signal); a send once its message is written to the
 * server's stdin, with when (W4: Dart times each request's stay in the
 * host's queue), or at once when it is refused. Logs name servers by handle
 * and id, never a message or a path.
 */
class LanguageServerHost(context: Context, messenger: BinaryMessenger) : LspApi {
    private val hub = RuntimeHubs.get(context)
    private val events = LspEvents(messenger)
    private val main = Handler(Looper.getMainLooper())

    /** The servers this engine started and that have not ended. */
    private val mine: MutableSet<Long> = ConcurrentHashMap.newKeySet()

    @Volatile
    private var closed = false

    private val listener = object : LspListener {
        override fun onMessage(handle: Long, message: String, readNs: Long) {
            val readUs = readNs / NANOS_PER_MICRO
            main.post {
                if (!closed) events.received(handle, message, readUs) { }
            }
        }

        override fun onExit(exit: LspExit) {
            mine.remove(exit.handle)
            Log.i(
                TAG,
                "language server ${exit.handle} (${exit.server}) ended: ${exit.end.code}" +
                    (exit.exitCode?.let { " exit $it" } ?: "") + (exit.signal?.let { " signal $it" } ?: ""),
            )
            val message = LspExitMessage(
                handle = exit.handle,
                server = exit.server,
                end = exit.end.code,
                exitCode = exit.exitCode?.toLong(),
                signal = exit.signal?.toLong(),
                detail = exit.detail,
                stderr = exit.stderr,
                leftovers = exit.leftovers.toLong(),
                remaining = exit.remaining.toLong(),
            )
            main.post {
                if (!closed) events.exited(message) { }
            }
        }
    }

    /** The engine is going: its servers stop, and no more events go to it. */
    fun close() {
        closed = true
        val host = hub.languageServers() ?: return
        for (handle in mine) host.stop(handle)
        mine.clear()
    }

    override fun start(server: String, project: String?, copy: String?, callback: (Result<LspStartMessage>) -> Unit) {
        hub.startLanguageServer(server, LspWorkspace(project, copy), listener) { started ->
            val process = started.server
            if (process != null && closed) {
                // The engine went while the server started (an install takes seconds): no one would stop it.
                hub.languageServers()?.stop(process.handle)
                Log.i(TAG, "language server ${process.handle} (${process.server.id}) stopped: its engine is gone")
            } else if (process != null) {
                mine.add(process.handle)
                Log.i(TAG, "language server ${process.handle} (${process.server.id}) started, install ${process.installMs} ms")
            } else {
                Log.w(TAG, "language server $server not started: ${started.failure?.code}")
            }
            val live = process?.takeIf { !closed }
            callback(
                Result.success(
                    LspStartMessage(
                        handle = process?.handle,
                        failure = started.failure?.code,
                        detail = started.detail,
                        running = started.running,
                        root = live?.directory?.absolutePath,
                        bin = live?.bin?.absolutePath,
                        serverDirectory = live?.serverDirectory?.absolutePath,
                    ),
                ),
            )
        }
    }

    override fun send(handle: Long, message: String, callback: (Result<LspSendMessage>) -> Unit) {
        val host = hub.languageServers()
        if (host == null) {
            callback(Result.success(LspSendMessage(failure = LspFailure.NO_SUCH_SERVER.code)))
            return
        }
        // Answered once written, from the writer's thread (or the reader's, when the server ended first).
        val refused = host.send(handle, message) { writtenNs ->
            val answer = if (writtenNs == null) {
                LspSendMessage(failure = LspFailure.NOT_RUNNING.code)
            } else {
                LspSendMessage(writtenUs = writtenNs / NANOS_PER_MICRO)
            }
            main.post { callback(Result.success(answer)) }
        }
        if (refused != null) callback(Result.success(LspSendMessage(failure = refused.code)))
    }

    override fun stop(handle: Long, callback: (Result<String?>) -> Unit) {
        val host = hub.languageServers()
        val failure = if (host == null) LspFailure.NO_SUCH_SERVER else host.stop(handle)
        callback(Result.success(failure?.code))
    }

    override fun servers(callback: (Result<List<LspServerMessage>>) -> Unit) {
        callback(Result.success(hub.languageServers()?.list().orEmpty().map { it.toMessage() }))
    }

    private fun LanguageServerProcess.toMessage(): LspServerMessage {
        val sample = memory
        return LspServerMessage(
            handle = handle,
            server = server.id,
            project = workspace.project,
            copy = workspace.copy,
            startedAtMs = startedAtMs,
            installMs = installMs,
            received = received.get(),
            sent = sent.get(),
            pssKib = sample?.pssKib,
            rssKib = sample?.rssKib,
            processes = sample?.processes?.toLong(),
        )
    }

    private companion object {
        const val TAG = "CodeForgeLsp"
        const val NANOS_PER_MICRO = 1_000L
    }
}
