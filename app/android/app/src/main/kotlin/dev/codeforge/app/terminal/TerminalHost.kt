package dev.codeforge.app.terminal

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.codeforge.app.runtime.RuntimeHubs
import dev.codeforge.app.runtime.TerminalFailure
import dev.codeforge.app.runtime.TerminalOutputListener
import dev.codeforge.app.runtime.TerminalSession
import dev.codeforge.app.runtime.TerminalSpec
import dev.codeforge.app.runtime.TerminalState
import dev.codeforge.app.runtime.TerminalTombstone
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
 * Every call but a start, the listing and End all is answered on the main
 * thread at once: input and sizes are queued for each session's writer
 * thread, an end sends a signal. Logs name sessions by id, never a command or
 * a path.
 *
 * Since Phase 5 W5 the listing holds the tombstones the app's last process
 * left (Terminals' ledger) beside the sessions, and the first session asks
 * Android 13 and later for the notification the foreground service shows
 * (SessionService); declined, sessions still run.
 */
class TerminalHost(context: Context, messenger: BinaryMessenger) : TerminalApi {
    private val hub = RuntimeHubs.get(context)
    private val activity = context as? Activity
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
        askForNotifications()
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
        // The command side may not be made yet in a new process, and making it
        // reads the disk: on a command thread, answered on the main thread.
        hub.withTerminals { terminals ->
            val listed = if (terminals == null) {
                emptyList()
            } else {
                terminals.tombstones().map { it.toMessage() } + terminals.list().map { it.toMessage() }
            }
            callback(Result.success(listed.sortedBy { it.id }))
        }
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
        if (session == null && hub.terminals()?.tombstone(sessionId) != null) {
            // A tombstone has nothing to replay: its output ended with the last process.
            callback(Result.success(TerminalReplayMessage(offset = 0L, bytes = ByteArray(0), failure = null)))
            return
        }
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
            terminals == null || (terminals.get(sessionId) == null && terminals.tombstone(sessionId) == null) ->
                TerminalFailure.NO_SUCH_SESSION
            terminals.remove(sessionId) -> null
            else -> TerminalFailure.STILL_RUNNING
        }
        callback(Result.success(failure?.code))
    }

    private fun session(id: Long): TerminalSession? = hub.terminals()?.get(id)

    /**
     * Android 13 and later show the foreground service's notification only
     * with the user's leave: asked once, at the first session. Declined,
     * sessions still run, and Android lists the service in its task manager.
     */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val activity = activity ?: return
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(ASKED, false)) return
        prefs.edit().putBoolean(ASKED, true).apply()
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    private fun dimension(value: Long): Int = value.coerceIn(1L, TerminalSession.MAX_DIMENSION.toLong()).toInt()

    private companion object {
        const val TAG = "CodeForgeTerminal"

        /** The terminal host's own settings: never in a backup (BackupPolicy lists what may be). */
        const val PREFS = "codeforge_terminal"
        const val ASKED = "notifications_asked"
        const val REQUEST_NOTIFICATIONS = 0x5E55
    }
}

/** A tombstone as Pigeon's message: an exited session with nothing left to show. */
internal fun TerminalTombstone.toMessage() = TerminalInfoMessage(
    id = id,
    label = label,
    state = TerminalState.EXITED.code,
    rows = 24L,
    columns = 80L,
    received = 0L,
    leftovers = 0L,
    remaining = 0L,
    exitCode = exitCode?.toLong(),
    signal = signal?.toLong(),
    failure = failure?.code,
    detail = null,
)

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
