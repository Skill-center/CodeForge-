package dev.codeforge.app.runtime

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Where a terminal session is in its life. Each code travels to Dart. */
enum class TerminalState(val code: String) {
    /** Its launcher is being started. */
    STARTING("starting"),

    /** Its launcher runs, and its shell with it. */
    RUNNING("running"),

    /** Its shell and everything it started are gone. */
    EXITED("exited"),
}

/**
 * Why a terminal session did not start, why a call about one was refused,
 * or how it ended other than by its shell's own exit. Each code travels to
 * Dart.
 */
enum class TerminalFailure(val code: String) {
    /** The runtime is not installed and started, or is being installed. */
    NOT_READY("not_ready"),

    /** Kotlin refused the request: a path for a program, a NUL byte, a protected variable, a folder outside. */
    BAD_REQUEST("bad_request"),

    /** No such program in the runtime: bash itself, or the one asked for. */
    NOT_FOUND("not_found"),

    /** Every place for a terminal is taken (SessionRegistry.maxTerminals). */
    TOO_MANY("too_many"),

    /** The shell is there and could not be executed. */
    CANNOT_START("cannot_start"),

    /** No pseudo-terminal could be opened. */
    TERMINAL_FAILED("terminal_failed"),

    /** The launcher could not run: missing, or no process could be made. */
    LAUNCH_FAILED("launch_failed"),

    /** The app ended it (a request, End all, a reinstall), with everything it started. */
    ENDED("ended"),

    /** A signal ended the shell by itself (a crash). */
    SIGNALED("signaled"),

    /** The relay between the app and the terminal stopped: a frame out of step, a broken pipe. */
    LOST("lost"),

    /** No session has that id. */
    NO_SUCH_SESSION("no_such_session"),

    /** The session has ended, so it takes no more input. */
    NOT_RUNNING("not_running"),

    /** More input waits than a session queues (TerminalSession.INPUT_QUEUE_BYTES). */
    INPUT_FULL("input_full"),

    /** The session still runs, so it cannot be forgotten. */
    STILL_RUNNING("still_running"),
}

/** How a terminal session ended. [failure] is null when its shell exited by itself, whatever its code. */
data class TerminalExit(
    val exitCode: Int?,
    val signal: Int?,
    val failure: TerminalFailure?,
    val detail: String?,
    /** Processes the launcher ended: what the shell left behind, or its whole tree when it was ended. */
    val leftovers: Int,
    /** Processes that could not be ended: 0 unless the kernel refused. */
    val remaining: Int,
)

/** Takes a session's output while a view is attached: in order, each byte once. */
fun interface TerminalOutputListener {
    /** [bytes] from [offset] on. Called on the delivery thread, never two at once. */
    fun output(session: TerminalSession, offset: Long, bytes: ByteArray)
}

/** What a view gets when it attaches: the buffer's content, from [offset] on. */
class TerminalReplay(val offset: Long, val bytes: ByteArray)

/**
 * One terminal session (Phase 5 W2; docs/TERMINAL_ARCHITECTURE.md §1): a
 * launcher in terminal mode (codeforge-spawn.c), whose shell runs on a
 * pseudo-terminal, and everything the app keeps of it. CodeForge's own, in
 * place of Termux's TerminalSession, which CodeForge may not use (AGENTS §4).
 *
 *   * **Output.** A reader thread takes the launcher's stdout into a ring
 *     buffer that keeps the last [bufferBytes] (1 MiB by default), so a view
 *     that attaches later finds the screen ([attach]). While a view is
 *     attached, its output goes to it in batches: at most one every
 *     [BATCH_NS] (60 a second), and the first bytes after a quiet moment at
 *     once, so an echo never waits for a batch.
 *   * **Flow control by credit.** The view acknowledges what it has drawn
 *     ([acknowledge]); the reader reads no further than [window] bytes past
 *     that. A program flooding the terminal then blocks in the kernel,
 *     behind the launcher and the pipe: nothing is lost, and memory stays
 *     bounded. Without a view, or once the session is ending, the reader
 *     reads freely into the ring.
 *   * **Input.** [write] and [resize] queue frames (the launcher's: input,
 *     window size) for a writer thread, so no caller ever blocks on a full
 *     pipe, and the two keep their order; at most [INPUT_QUEUE_BYTES] wait.
 *   * **The end.** [end] ends the launcher through the registry, which hangs
 *     the terminal up and ends the whole tree. When the launcher exits, the
 *     session reads its status file: the shell's exit code or signal, or why
 *     it could not start.
 *
 * No Android type: the JVM tests drive it with real processes.
 */
class TerminalSession internal constructor(
    val id: Long,
    val label: String,
    rows: Int,
    columns: Int,
    private val registered: SessionRegistry.Session,
    private val registry: SessionRegistry,
    /** The launcher's own error output, kept for the exit's detail. */
    private val errorFile: File,
    val bufferBytes: Int,
    window: Int,
    /** The one thread that delivers every session's batches and changes, in order. */
    private val delivery: ScheduledExecutorService,
    private val clock: () -> Long,
    private val changed: (TerminalSession) -> Unit,
) {
    /** Bytes a view may have unacknowledged; never more than the buffer keeps. */
    val window: Int = window.coerceIn(1, bufferBytes)

    private val lock = ReentrantLock()
    private val credit = lock.newCondition()
    private val ring = OutputRing(bufferBytes)

    // All guarded by lock.
    private var output: TerminalOutputListener? = null
    private var delivered = 0L
    private var acknowledged = 0L
    private var flushScheduled = false
    private var flushedOnce = false
    private var lastFlush = 0L
    private var ending = false
    private var highWater = 0L
    private var currentState = TerminalState.STARTING
    private var currentExit: TerminalExit? = null
    private var currentRows = rows
    private var currentColumns = columns

    private val input = LinkedBlockingQueue<ByteArray>()
    private val queued = AtomicLong()

    val state: TerminalState get() = lock.withLock { currentState }

    /** How it ended; null until it has. */
    val exit: TerminalExit? get() = lock.withLock { currentExit }

    val rows: Int get() = lock.withLock { currentRows }

    val columns: Int get() = lock.withLock { currentColumns }

    /** Every byte the shell has written so far. */
    val received: Long get() = lock.withLock { ring.end }

    /**
     * The most output ever held for a view at once: read and not yet
     * acknowledged. Never above [window] while the view keeps up its
     * acknowledgements (TerminalSessionTest's bound).
     */
    val unacknowledgedHighWater: Long get() = lock.withLock { highWater }

    /** The launcher's status file while it runs (the tests read its pids). */
    val launcherStatusFile: File get() = registered.statusFile

    /** Starts the threads: called once, after a view (if any) is attached. */
    internal fun start() {
        lock.withLock { currentState = TerminalState.RUNNING }
        Thread({ readOutput() }, "codeforge-terminal-$id-out").apply { isDaemon = true }.start()
        Thread({ writeInput() }, "codeforge-terminal-$id-in").apply { isDaemon = true }.start()
        delivery.execute { changed(this) }
    }

    /**
     * Attaches [listener] as the session's view, after any other; answers
     * what the buffer holds, which the view draws first. Its credit starts at
     * the replay's start: the reader waits until the view has drawn it.
     */
    fun attach(listener: TerminalOutputListener): TerminalReplay = lock.withLock {
        var start = ring.start
        var bytes = ring.copy(start, ring.end)
        if (start > 0) {
            // The buffer has wrapped: the replay starts at a line, not inside a character or a sequence.
            val newline = bytes.indexOf(NEWLINE)
            if (newline in 0 until REPLAY_ALIGN_LIMIT) {
                bytes = bytes.copyOfRange(newline + 1, bytes.size)
                start += newline + 1
            }
        }
        output = listener
        delivered = ring.end
        acknowledged = start
        credit.signalAll()
        TerminalReplay(start, bytes)
    }

    /** The view is gone: the reader reads freely into the buffer from now on. */
    fun detach() {
        lock.withLock {
            output = null
            delivered = ring.end
            credit.signalAll()
        }
    }

    /** The view has drawn everything before [offset]. */
    fun acknowledge(offset: Long) {
        lock.withLock {
            val upTo = minOf(offset, delivered)
            if (upTo > acknowledged) {
                acknowledged = upTo
                credit.signalAll()
            }
        }
    }

    /** Queues [bytes] as input, as typed; null when queued, or why not. */
    fun write(bytes: ByteArray): TerminalFailure? {
        if (bytes.isEmpty()) return null
        val frames = ArrayList<ByteArray>()
        var at = 0
        while (at < bytes.size) {
            val length = minOf(MAX_FRAME_PAYLOAD, bytes.size - at)
            frames.add(frame(FRAME_INPUT, bytes, at, length))
            at += length
        }
        return enqueue(frames)
    }

    /** Queues a new window size (brought into 1..[MAX_DIMENSION]); null when queued, or why not. */
    fun resize(rows: Int, columns: Int): TerminalFailure? {
        val r = rows.coerceIn(1, MAX_DIMENSION)
        val c = columns.coerceIn(1, MAX_DIMENSION)
        val payload = byteArrayOf((r shr 8).toByte(), r.toByte(), (c shr 8).toByte(), c.toByte())
        val failure = enqueue(listOf(frame(FRAME_SIZE, payload, 0, payload.size)))
        if (failure == null) {
            lock.withLock {
                currentRows = r
                currentColumns = c
            }
        }
        return failure
    }

    /** Ends the session with everything it started. False when it was already ending or gone. */
    fun end(): Boolean {
        lock.withLock {
            ending = true
            credit.signalAll()
        }
        return registry.end(registered, EndReason.ENDED)
    }

    private fun enqueue(frames: List<ByteArray>): TerminalFailure? {
        val size = frames.sumOf { it.size.toLong() }
        lock.withLock {
            if (currentState == TerminalState.EXITED || ending) return TerminalFailure.NOT_RUNNING
        }
        if (queued.addAndGet(size) > INPUT_QUEUE_BYTES) {
            queued.addAndGet(-size)
            return TerminalFailure.INPUT_FULL
        }
        input.addAll(frames)
        return null
    }

    // ── The writer thread ────────────────────────────────────────────

    private fun writeInput() {
        val stdin = registered.process.outputStream
        try {
            while (true) {
                val frame = input.take()
                if (frame === CLOSE) break
                queued.addAndGet(-frame.size.toLong())
                stdin.write(frame)
                if (input.isEmpty()) stdin.flush()
            }
        } catch (gone: IOException) {
            // The launcher has exited; the reader finds its end.
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
        } finally {
            try {
                stdin.close()
            } catch (ignored: IOException) {
                // Closed either way.
            }
        }
    }

    // ── The reader thread ────────────────────────────────────────────

    private fun readOutput() {
        val stdout: InputStream = registered.process.inputStream
        val buffer = ByteArray(READ_CHUNK)
        try {
            while (true) {
                val room = room()
                val count = stdout.read(buffer, 0, room)
                if (count < 0) break
                if (count > 0) took(buffer, count)
            }
        } catch (closed: IOException) {
            // Cut off: the launcher is gone.
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
        } finally {
            try {
                stdout.close()
            } catch (ignored: IOException) {
                // Closed either way.
            }
        }
        finish()
    }

    /**
     * How much the reader may read now: it waits while a view has no credit
     * left. Once the session is ending (by [end], or by the registry: End
     * all, a reinstall) it reads freely. Once its launcher has exited, it
     * still waits for credit while the view acknowledges, but no longer
     * than [EXITED_CREDIT_WAIT_MS] at a time: what is left in the pipe never
     * waits for a view that has stopped acknowledging, and the session
     * always reaches its end.
     */
    private fun room(): Int {
        lock.lock()
        try {
            var waitedSinceExit = 0L
            while (true) {
                if (output == null || ending || registered.endReason != null) return READ_CHUNK
                val left = window - (ring.end - acknowledged)
                if (left > 0) return minOf(left, READ_CHUNK.toLong()).toInt()
                if (!registered.process.isAlive) {
                    if (waitedSinceExit >= EXITED_CREDIT_WAIT_MS) return READ_CHUNK
                    waitedSinceExit += CREDIT_WAIT_MS
                }
                credit.await(CREDIT_WAIT_MS, TimeUnit.MILLISECONDS)
            }
        } finally {
            lock.unlock()
        }
    }

    private fun took(buffer: ByteArray, count: Int) {
        lock.withLock {
            ring.write(buffer, 0, count)
            if (output == null) {
                delivered = ring.end
                return
            }
            // Only a session that is ending, or one whose view stopped
            // acknowledging after its launcher exited, outruns the buffer.
            if (delivered < ring.start) delivered = ring.start
            val unacknowledged = ring.end - acknowledged
            if (unacknowledged > highWater) highWater = unacknowledged
            if (!flushScheduled) {
                flushScheduled = true
                val wait = if (flushedOnce) maxOf(0L, lastFlush + BATCH_NS - clock()) else 0L
                delivery.schedule(Runnable { flush() }, wait, TimeUnit.NANOSECONDS)
            }
        }
    }

    /** Hands what was read since the last batch to the view, if one is attached. */
    private fun flush() {
        val batch = lock.withLock {
            flushScheduled = false
            val view = output
            if (view == null) {
                delivered = ring.end
                null
            } else if (delivered >= ring.end) {
                null
            } else {
                val offset = delivered
                val bytes = ring.copy(delivered, ring.end)
                delivered = ring.end
                lastFlush = clock()
                flushedOnce = true
                Batch(view, offset, bytes)
            }
        } ?: return
        batch.listener.output(this, batch.offset, batch.bytes)
    }

    private class Batch(val listener: TerminalOutputListener, val offset: Long, val bytes: ByteArray)

    /** The launcher closed its stdout: it exits. Reads how, then tells the view and the host. */
    private fun finish() {
        input.offer(CLOSE)
        val process = registered.process
        val exited = try {
            process.waitFor(FINISH_WAIT_MS, TimeUnit.MILLISECONDS)
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!exited) process.destroyForcibly()
        val launcherExit = if (process.isAlive) null else process.exitValue()
        val result = interpret(
            LauncherStatus.read(registered.statusFile),
            launcherExit,
            registered.endReason,
            readError(),
        )
        registry.finished(registered)
        registered.statusFile.delete()
        File(registered.statusFile.path + ".part").delete()
        errorFile.delete()
        // The last batch, then the exit, in that order, on the delivery thread.
        delivery.execute {
            flush()
            lock.withLock {
                currentExit = result
                currentState = TerminalState.EXITED
                credit.signalAll()
            }
            changed(this)
        }
    }

    private fun readError(): String =
        try {
            if (errorFile.isFile) {
                errorFile.inputStream().use { stream ->
                    String(stream.readNBytesCompat(ERROR_LIMIT), Charsets.UTF_8).trim()
                }
            } else {
                ""
            }
        } catch (unreadable: IOException) {
            ""
        }

    companion object {
        /** The buffer kept while no view is attached (PHASE_5_PLAN §3, W2). */
        const val DEFAULT_BUFFER_BYTES = 1024 * 1024
        const val MIN_BUFFER_BYTES = 64 * 1024
        const val MAX_BUFFER_BYTES = 8 * 1024 * 1024

        /** Output a view may have unacknowledged: about 10 to 50 ms of xterm.js's work. */
        const val DEFAULT_WINDOW = 256 * 1024

        /** At most one batch in this long: 60 a second. */
        const val BATCH_NS = 16_000_000L

        /** Input waiting for the writer thread, past which [write] answers INPUT_FULL. */
        const val INPUT_QUEUE_BYTES = 1024L * 1024L

        /** A window's side, in rows or columns. */
        const val MAX_DIMENSION = 999

        // The launcher's frames (codeforge-spawn.c, terminal mode).
        const val FRAME_INPUT: Byte = 1
        const val FRAME_SIZE: Byte = 2
        const val MAX_FRAME_PAYLOAD = 65535

        private const val READ_CHUNK = 64 * 1024
        private const val CREDIT_WAIT_MS = 250L
        private const val EXITED_CREDIT_WAIT_MS = 2000L
        private const val FINISH_WAIT_MS = 10_000L
        private const val ERROR_LIMIT = 4096
        private const val REPLAY_ALIGN_LIMIT = 4096
        private const val NEWLINE: Byte = 10
        private val CLOSE = ByteArray(0)

        /** A frame: its type, the payload's length in two bytes (big-endian), the payload. */
        fun frame(type: Byte, payload: ByteArray, offset: Int, length: Int): ByteArray {
            require(length in 0..MAX_FRAME_PAYLOAD)
            val frame = ByteArray(3 + length)
            frame[0] = type
            frame[1] = (length shr 8).toByte()
            frame[2] = length.toByte()
            System.arraycopy(payload, offset, frame, 3, length)
            return frame
        }

        /** What the launcher's status file says of a terminal session's end. */
        fun interpret(status: LauncherStatus?, launcherExit: Int?, endReason: EndReason?, error: String): TerminalExit {
            val leftovers = status?.ended ?: 0
            val remaining = status?.remaining ?: 0
            fun result(exitCode: Int?, signal: Int?, failure: TerminalFailure?, detail: String?) =
                TerminalExit(exitCode, signal, failure, detail, leftovers, remaining)
            val said = if (error.isEmpty()) "" else ": $error"
            if (status == null || status.reason == null) {
                // The launcher wrote no outcome: it was killed (the last resort) or never ran.
                val failure = if (endReason != null) TerminalFailure.ENDED else TerminalFailure.LAUNCH_FAILED
                return result(null, null, failure, "the launcher ended without a status (exit $launcherExit)$said")
            }
            return when (status.reason) {
                "exited" -> result(status.exit, null, null, null)
                "signaled" -> result(null, status.signal, TerminalFailure.SIGNALED, "ended by ${CommandRunner.signalName(status.signal)}")
                "stopped" -> {
                    val how = if (status.exit != null) "it exited with ${status.exit}" else "ended by ${CommandRunner.signalName(status.signal)}"
                    val processes = "with ${status.ended ?: 0} processes in all"
                    when {
                        endReason != null -> result(status.exit, status.signal, TerminalFailure.ENDED, "it was ended; $how, $processes")
                        else -> result(
                            status.exit,
                            status.signal,
                            TerminalFailure.LOST,
                            "the terminal's relay stopped (${status.stopCause ?: "signal ${status.stopSignal}"}); $how, $processes",
                        )
                    }
                }
                "exec_failed" -> result(null, null, TerminalFailure.CANNOT_START, "could not start: ${CommandRunner.errnoName(status.execErrno)}")
                "terminal_failed" ->
                    result(null, null, TerminalFailure.TERMINAL_FAILED, "no terminal could be opened: ${CommandRunner.errnoName(status.execErrno)}")
                "spawn_failed" ->
                    result(null, null, TerminalFailure.LAUNCH_FAILED, "no process could be made: ${CommandRunner.errnoName(status.execErrno)}")
                else -> result(null, null, TerminalFailure.LAUNCH_FAILED, "the launcher said ${status.reason}$said")
            }
        }
    }
}

/** InputStream.readNBytes needs API 33; this reads up to [limit] bytes on every level. */
internal fun InputStream.readNBytesCompat(limit: Int): ByteArray {
    val buffer = ByteArray(limit)
    var total = 0
    while (total < limit) {
        val count = read(buffer, total, limit - total)
        if (count < 0) break
        total += count
    }
    return buffer.copyOf(total)
}

/**
 * The last [capacity] bytes of a stream, by their offset in it. Not
 * thread-safe: its owner holds a lock.
 */
internal class OutputRing(val capacity: Int) {
    private val data = ByteArray(capacity)

    /** The offset after the last byte written: every byte the stream has had. */
    var end = 0L
        private set

    /** The oldest offset still kept. */
    val start: Long get() = maxOf(0L, end - capacity)

    fun write(bytes: ByteArray, offset: Int, length: Int) {
        var from = offset
        var left = length
        if (left > capacity) {
            // Only the last capacity bytes can be kept.
            from += left - capacity
            end += (left - capacity).toLong()
            left = capacity
        }
        while (left > 0) {
            val at = (end % capacity).toInt()
            val chunk = minOf(left, capacity - at)
            System.arraycopy(bytes, from, data, at, chunk)
            from += chunk
            left -= chunk
            end += chunk.toLong()
        }
    }

    /** The bytes from [from] to [to], both between [start] and [end]. */
    fun copy(from: Long, to: Long): ByteArray {
        require(from in start..to && to <= end) { "not kept: $from..$to of $start..$end" }
        val copied = ByteArray((to - from).toInt())
        var position = from
        var written = 0
        while (position < to) {
            val at = (position % capacity).toInt()
            val chunk = minOf((to - position).toInt(), capacity - at)
            System.arraycopy(data, at, copied, written, chunk)
            position += chunk.toLong()
            written += chunk
        }
        return copied
    }
}
