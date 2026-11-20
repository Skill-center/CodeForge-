package dev.codeforge.app.terminal

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.codeforge.app.runtime.RuntimeHubs
import dev.codeforge.app.runtime.TerminalFailure
import dev.codeforge.app.runtime.TerminalOutputListener
import dev.codeforge.app.runtime.TerminalSession
import dev.codeforge.app.runtime.TerminalSpec
import dev.codeforge.app.runtime.TerminalState
import io.flutter.plugin.common.BinaryMessenger

/**
 * The terminal host (Phase 5 W2; pigeons/terminal_api.dart): Dart's typed
 * API to the runtime's terminal sessions, over the process's one RuntimeHub.
 * Orchestration only: the hub starts a session on a command thread under the
 * prefix's lock (RuntimeHub.startTerminal), [dev.codeforge.app.runtime.Terminals]
 * checks and holds the sessions, each [TerminalSession] its process and its
 * buffer; this class turns them into Pigeon's messages.
 *
 * This engine is the view of the sessions it starts or attaches: their
 * output goes to Dart through TerminalEvents on the main thread, in order,
 * and Dart acknowledges what it has drawn (credit flow control). When the
 * engine goes ([close]), every session is detached and reads into its
 * buffer; the sessions outlive the engine.
 *
 * Every call but a start and End all is answered on the main thread at once:
 * input and sizes are queued for each session's writer thread, an end sends
 * a signal. Logs name sessions by id, never a command or a path.
 */
class TerminalHost(context: Context, messenger: BinaryMessenger) : TerminalApi {
    private val hub = RuntimeHubs.get(context)
    private val events = TerminalEvents(messenger)
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var closed = false

    /** The view: every batch, to Dart, on the main thread. */
    private val view = TerminalOutputListener { session, offset, bytes ->
        val id = session.id
        main.post {
            if (!closed) events.output(id, offset, bytes) { }
        }
    }

    /** Every start and exit, to Dart, on the main thread. */
    private val changed: (TerminalSession) -> Unit = { session ->
        val info = session.toMessage()
        if (session.state == TerminalState.EXITED) {
            Log.i(TAG, "terminal ${session.id} exited: ${info.failure ?: "exit ${info.exitCode}"} leftovers=${info.leftovers}")
        }
        main.post {
            if (!closed) events.changed(info) { }
        }
    }

    init {
        hub.addTerminalListener(changed)
    }

    /** The engine is going: no more events to it, and its sessions read into their buffers. */
    fun close() {
        closed = true
        hub.removeTerminalListener(changed)
        hub.terminals()?.list()?.forEach { it.detach() }
    }

    override fun start(spec: TerminalSpecMessage, callback: (Result<TerminalStartMessage>) -> Unit) {
        val request = TerminalSpec(
            project = spec.project,
            copy = spec.copy,
            program = spec.program,
            arguments = spec.arguments,
            environment = spec.environment,
            rows = dimension(spec.rows),
            columns = dimension(spec.columns),
            bufferBytes = spec.bufferBytes?.coerceIn(0L, Int.MAX_VALUE.toLong())?.toInt(),
            label = spec.label,
        )
        hub.startTerminal(request, view) { started ->
            val session = started.session
            if (session != null) {
                Log.i(TAG, "terminal ${session.id} started")
            } else {
                Log.w(TAG, "terminal not started: ${started.failure?.code}")
            }
            callback(
                Result.success(
                    TerminalStartMessage(
                        session = session?.toMessage(),
                        failure = started.failure?.code,
                        detail = started.detail,
                    ),
                ),
            )
        }
    }

    override fun sessions(callback: (Result<List<TerminalInfoMessage>>) -> Unit) {
        callback(Result.success(hub.terminals()?.list()?.map { it.toMessage() } ?: emptyList()))
    }

    override fun write(sessionId: Long, bytes: ByteArray, callback: (Result<String?>) -> Unit) {
        val session = session(sessionId)
        val failure = if (session == null) TerminalFailure.NO_SUCH_SESSION else session.write(bytes)
        callback(Result.success(failure?.code))
    }

    override fun resize(sessionId: Long, rows: Long, columns: Long, callback: (Result<String?>) -> Unit) {
        val session = session(sessionId)
        val failure = if (session == null) TerminalFailure.NO_SUCH_SESSION else session.resize(dimension(rows), dimension(columns))
        callback(Result.success(failure?.code))
    }

    override fun acknowledge(sessionId: Long, offset: Long, callback: (Result<Unit>) -> Unit) {
        session(sessionId)?.acknowledge(offset)
        callback(Result.success(Unit))
    }

    override fun attach(sessionId: Long, callback: (Result<TerminalReplayMessage>) -> Unit) {
        val session = session(sessionId)
        if (session == null) {
            callback(Result.success(TerminalReplayMessage(offset = 0L, bytes = ByteArray(0), failure = TerminalFailure.NO_SUCH_SESSION.code)))
            return
        }
        // The replay answers before any batch that follows it: both leave from this thread, in order.
        val replay = session.attach(view)
        callback(Result.success(TerminalReplayMessage(offset = replay.offset, bytes = replay.bytes, failure = null)))
    }

    override fun detach(sessionId: Long, callback: (Result<Unit>) -> Unit) {
        session(sessionId)?.detach()
        callback(Result.success(Unit))
    }

    override fun end(sessionId: Long, callback: (Result<String?>) -> Unit) {
        val session = session(sessionId)
        val failure = when {
            session == null -> TerminalFailure.NO_SUCH_SESSION
            session.end() -> null
            else -> TerminalFailure.NOT_RUNNING
        }
        callback(Result.success(failure?.code))
    }

    override fun endAll(callback: (Result<Long>) -> Unit) {
        hub.endAllTerminals { left ->
            Log.i(TAG, "terminals: End all, $left still running")
            callback(Result.success(left.toLong()))
        }
    }

    override fun remove(sessionId: Long, callback: (Result<String?>) -> Unit) {
        val terminals = hub.terminals()
        val failure = when {
            terminals == null || terminals.get(sessionId) == null -> TerminalFailure.NO_SUCH_SESSION
            terminals.remove(sessionId) -> null
            else -> TerminalFailure.STILL_RUNNING
        }
        callback(Result.success(failure?.code))
    }

    private fun session(id: Long): TerminalSession? = hub.terminals()?.get(id)

    private fun dimension(value: Long): Int = value.coerceIn(1L, TerminalSession.MAX_DIMENSION.toLong()).toInt()

    private companion object {
        const val TAG = "CodeForgeTerminal"
    }
}

/** A session as Pigeon's message. */
internal fun TerminalSession.toMessage(): TerminalInfoMessage {
    val ended = exit
    return TerminalInfoMessage(
        id = id,
        label = label,
        state = state.code,
        rows = rows.toLong(),
        columns = columns.toLong(),
        received = received,
        leftovers = (ended?.leftovers ?: 0).toLong(),
        remaining = (ended?.remaining ?: 0).toLong(),
        exitCode = ended?.exitCode?.toLong(),
        signal = ended?.signal?.toLong(),
        failure = ended?.failure?.code,
        detail = ended?.detail,
    )
}
