package dev.codeforge.app.runtime

import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** Why a session was ended before its command exited by itself. */
enum class EndReason(val code: String) {
    /** It ran past its time limit. */
    TIMED_OUT("timed_out"),

    /** The app ended it: a reinstall, or a request. */
    ENDED("ended"),
}

/**
 * What the launcher (native/runtime-core/src/main/jni/codeforge-spawn.c)
 * wrote to its status file: who it is first, then how the command ended.
 */
data class LauncherStatus(
    val pid: Int?,
    val group: Int?,
    val subreaper: Boolean,
    /** exited, signaled, stopped, exec_failed or spawn_failed; null while it runs. */
    val reason: String?,
    val exit: Int?,
    val signal: Int?,
    val execErrno: Int?,
    val stopSignal: Int?,
    /** Processes it ended: what the command left behind, or the whole tree when stopped. */
    val ended: Int?,
    /** Processes it could not end. */
    val remaining: Int?,
) {
    companion object {
        fun parse(text: String): LauncherStatus {
            val values = text.lineSequence()
                .mapNotNull { line ->
                    val equals = line.indexOf('=')
                    if (equals <= 0) null else line.substring(0, equals) to line.substring(equals + 1).trim()
                }
                .toMap()
            fun number(key: String): Int? = values[key]?.toIntOrNull()
            return LauncherStatus(
                pid = number("pid"),
                group = number("group"),
                subreaper = values["subreaper"] == "1",
                reason = values["reason"],
                exit = number("exit"),
                signal = number("signal"),
                execErrno = number("exec_errno"),
                stopSignal = number("stop_signal"),
                ended = number("ended"),
                remaining = number("remaining"),
            )
        }

        /** The status file's content, or null when there is none yet. */
        fun read(file: File): LauncherStatus? =
            try {
                if (file.isFile) parse(file.readText(Charsets.UTF_8)) else null
            } catch (unreadable: IOException) {
                null
            }
    }
}

/**
 * Every child process of the runtime, in one place (Phase 4 W4;
 * docs/SECURITY.md §2): one-shot commands now, Phase 5's terminal sessions
 * later. A session is one launcher process (libcodeforge-spawn.so), which
 * leads a process group of its own and is a subreaper for everything its
 * command starts. Ending a session means:
 *
 *   1. SIGTERM to the launcher (Process.destroy()). It sends SIGTERM and
 *      SIGCONT to its whole group and every descendant, waits [graceMs], then
 *      sends SIGKILL to whatever is left, and exits.
 *   2. Should the launcher itself still be there after that, SIGKILL to its
 *      process group ([killGroup]) and to the launcher.
 *
 * Each session has a deadline: the registry's watchdog thread ends it when
 * the deadline passes ([EndReason.TIMED_OUT]). [endAll] ends every session
 * and refuses new ones until [reopen]: what a reinstall does before it
 * touches the prefix.
 *
 * No Android type: the JVM tests drive it with real processes.
 */
class SessionRegistry(
    /** SIGKILL to a whole process group (Os.kill(-group) on a device). */
    private val killGroup: (Int) -> Unit,
    /** How long the launcher lets a process end after SIGTERM. */
    val graceMs: Long = DEFAULT_GRACE_MS,
) {
    inner class Session internal constructor(
        val id: Long,
        val label: String,
        val process: Process,
        val statusFile: File,
    ) {
        /** Why it was ended, or null while it runs or when its command exited by itself. */
        @Volatile
        var endReason: EndReason? = null
            internal set

        @Volatile
        internal var timer: ScheduledFuture<*>? = null

        @Volatile
        internal var force: ScheduledFuture<*>? = null

        /** The launcher's process group, as it wrote it; null before it did. */
        fun group(): Int? = LauncherStatus.read(statusFile)?.let { it.group ?: it.pid }

        fun end(reason: EndReason): Boolean = this@SessionRegistry.end(this, reason)
    }

    private val watchdog = ScheduledThreadPoolExecutor(1) { task ->
        Thread(task, "codeforge-sessions").apply { isDaemon = true }
    }.apply { removeOnCancelPolicy = true }

    private val running = ConcurrentHashMap<Long, Session>()
    private val ids = AtomicLong()

    @Volatile
    private var refusing = false

    /** The sessions whose command has not finished. */
    fun live(): List<Session> = running.values.sortedBy { it.id }

    /**
     * Takes [process] (a launcher just started) into the registry, to be
     * ended after [timeoutMs]. A registry that refuses new sessions ends it
     * at once.
     */
    fun register(process: Process, statusFile: File, label: String, timeoutMs: Long): Session {
        val session = Session(ids.incrementAndGet(), label, process, statusFile)
        running[session.id] = session
        if (refusing) {
            end(session, EndReason.ENDED)
        } else if (timeoutMs > 0) {
            session.timer = watchdog.schedule(Runnable { end(session, EndReason.TIMED_OUT) }, timeoutMs, TimeUnit.MILLISECONDS)
        }
        return session
    }

    /**
     * Ends [session]: SIGTERM to its launcher now, which ends the whole tree;
     * SIGKILL to the group if the launcher is still there after [graceMs] and
     * its own kill phase. False when it was already ending or had exited.
     */
    fun end(session: Session, reason: EndReason): Boolean {
        synchronized(session) {
            if (session.endReason != null || !session.process.isAlive) return false
            session.endReason = reason
        }
        session.timer?.cancel(false)
        session.process.destroy()
        session.force = watchdog.schedule(
            Runnable { force(session) },
            graceMs + LAUNCHER_KILL_WAIT_MS + FORCE_MARGIN_MS,
            TimeUnit.MILLISECONDS,
        )
        return true
    }

    /** The command and its launcher are gone: no more timers for it. */
    fun finished(session: Session) {
        running.remove(session.id)
        session.timer?.cancel(false)
        session.force?.cancel(false)
    }

    /**
     * Ends every live session, waits for them to exit (at most [waitMs]) and
     * refuses new ones until [reopen]. Answers how many are still running.
     */
    fun endAll(reason: EndReason, waitMs: Long = graceMs + LAUNCHER_KILL_WAIT_MS + FORCE_MARGIN_MS + 1000L): Int {
        refusing = true
        val sessions = live()
        for (session in sessions) end(session, reason)
        val deadline = System.nanoTime() + waitMs * 1_000_000L
        for (session in sessions) {
            val left = (deadline - System.nanoTime()) / 1_000_000L
            if (left <= 0) break
            try {
                session.process.waitFor(left, TimeUnit.MILLISECONDS)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                break
            }
        }
        return sessions.count { it.process.isAlive }
    }

    /** Takes new sessions again. */
    fun reopen() {
        refusing = false
    }

    private fun force(session: Session) {
        if (!session.process.isAlive) return
        val group = session.group()
        if (group != null && group > 1) {
            try {
                killGroup(group)
            } catch (refused: Exception) {
                // The launcher below still gets SIGKILL.
            }
        }
        session.process.destroyForcibly()
    }

    companion object {
        /** How long a process gets between SIGTERM and SIGKILL. */
        const val DEFAULT_GRACE_MS = 1000L

        /** The launcher's own SIGKILL phase (KILL_WAIT_MS in codeforge-spawn.c). */
        const val LAUNCHER_KILL_WAIT_MS = 3000L

        const val FORCE_MARGIN_MS = 1000L
    }
}
