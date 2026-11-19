package dev.codeforge.app.runtime

import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** What a session runs: a one-shot command, or a terminal (Phase 5 W2). */
enum class SessionKind {
    COMMAND,
    TERMINAL,
}

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
    /** The command's pid, once it was started. */
    val child: Int? = null,
    /** "terminal" in terminal mode (Phase 5 W2); null for a command. */
    val mode: String? = null,
    /** The terminal's name (/dev/pts/N), in terminal mode. */
    val tty: String? = null,
    /** Why terminal mode stopped: signal, input_closed, output_closed, protocol or relay_failed. */
    val stopCause: String? = null,
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
                child = number("child"),
                mode = values["mode"],
                tty = values["tty"],
                stopCause = values["stop_cause"],
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
 * docs/SECURITY.md §2): one-shot commands, and since Phase 5 W2 terminal
 * sessions. A session is one launcher process (libcodeforge-spawn.so), which
 * leads a process group of its own and is a subreaper for everything its
 * command starts. Ending a session means:
 *
 *   1. SIGTERM to the launcher (Process.destroy()). It sends SIGTERM and
 *      SIGCONT to its whole group and every descendant (with SIGHUP first
 *      for a terminal), waits [graceMs], then sends SIGKILL to whatever is
 *      left, and exits.
 *   2. Should the launcher itself still be there after that, SIGKILL to its
 *      process group ([killGroup]) and to the launcher; for a terminal, also
 *      to every process group of the shell's session, which /proc lists
 *      ([ProcessTable]): the shell leads a session of its own, apart from
 *      the launcher's group.
 *
 * A command has a deadline: the registry's watchdog thread ends it when the
 * deadline passes ([EndReason.TIMED_OUT]). A terminal has none, and at most
 * [maxTerminals] run at once: a place is reserved before its launcher starts
 * ([reserveTerminal]), so one more is refused without starting anything.
 * [endAll] ends every session, or every one of a kind, and by default
 * refuses new ones until [reopen]: what a reinstall does before it touches
 * the prefix. The user's *End all* does not refuse.
 *
 * No Android type: the JVM tests drive it with real processes.
 */
class SessionRegistry(
    /** SIGKILL to a whole process group (Os.kill(-group) on a device). */
    private val killGroup: (Int) -> Unit,
    /** How long the launcher lets a process end after SIGTERM. */
    val graceMs: Long = DEFAULT_GRACE_MS,
    /** Terminal sessions at once (PHASE_5_PLAN §10 item 6). */
    val maxTerminals: Int = DEFAULT_MAX_TERMINALS,
    /** The processes /proc lists, for the last resort's sweep of a terminal's session. */
    private val processes: () -> List<ProcessTable.Entry> = { ProcessTable.read() },
) {
    /** A place for one terminal session, held from before its launcher starts until it ends. */
    inner class TerminalPlace internal constructor() {
        private val held = AtomicBoolean(true)

        /** Gives the place back; once only, whoever calls it. */
        fun release() {
            if (held.compareAndSet(true, false)) terminals.decrementAndGet()
        }
    }

    inner class Session internal constructor(
        val id: Long,
        val label: String,
        val process: Process,
        val statusFile: File,
        val kind: SessionKind,
        internal val place: TerminalPlace?,
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

    /** Terminal places held: reserved, or taken by a live terminal session. */
    private val terminals = AtomicInteger()

    @Volatile
    private var refusing = false

    /** The sessions whose command has not finished. */
    fun live(): List<Session> = running.values.sortedBy { it.id }

    /** The live sessions of [kind]. */
    fun live(kind: SessionKind): List<Session> = live().filter { it.kind == kind }

    /** Whether new sessions are refused: an install holds the prefix. */
    val isRefusing: Boolean get() = refusing

    /**
     * A place for one more terminal session, or null when [maxTerminals] are
     * held or the registry refuses new sessions. The caller registers its
     * launcher with it, or releases it when the launcher could not start.
     */
    fun reserveTerminal(): TerminalPlace? {
        while (true) {
            if (refusing) return null
            val held = terminals.get()
            if (held >= maxTerminals) return null
            if (terminals.compareAndSet(held, held + 1)) return TerminalPlace()
        }
    }

    /**
     * Takes [process] (a launcher just started) into the registry, to be
     * ended after [timeoutMs] (never when it is 0). A terminal comes with
     * the [place] reserved for it, given back when it ends. A registry that
     * refuses new sessions ends it at once.
     */
    fun register(
        process: Process,
        statusFile: File,
        label: String,
        timeoutMs: Long,
        kind: SessionKind = SessionKind.COMMAND,
        place: TerminalPlace? = null,
    ): Session {
        require((kind == SessionKind.TERMINAL) == (place != null)) { "a terminal session, and only one, holds a place" }
        val session = Session(ids.incrementAndGet(), label, process, statusFile, kind, place)
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

    /** The command and its launcher are gone: no more timers for it, and its place is free. */
    fun finished(session: Session) {
        running.remove(session.id)
        session.timer?.cancel(false)
        session.force?.cancel(false)
        session.place?.release()
    }

    /**
     * Ends every live session, or every one of [kind], and waits for them to
     * exit and to be finished (at most [waitMs] in all), so that a place a
     * terminal held is free when this returns. With [refuse], new sessions
     * are refused until [reopen]. Answers how many are still running.
     */
    fun endAll(
        reason: EndReason,
        waitMs: Long = graceMs + LAUNCHER_KILL_WAIT_MS + FORCE_MARGIN_MS + 1000L,
        kind: SessionKind? = null,
        refuse: Boolean = true,
    ): Int {
        if (refuse) refusing = true
        val sessions = if (kind == null) live() else live(kind)
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
        // Whoever reads a launcher's output (a command's runner, a terminal's
        // reader) finishes its session once the launcher exits, and only then
        // is a terminal's place free. Waited for too: phase gate 44454605348
        // found End all returning before the places were (API 26).
        while (sessions.any { running.containsKey(it.id) } && System.nanoTime() < deadline) {
            try {
                Thread.sleep(FINISH_POLL_MS)
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
        val status = LauncherStatus.read(session.statusFile)
        val groups = linkedSetOf<Int>()
        (status?.group ?: status?.pid)?.let(groups::add)
        val shell = status?.child
        if (session.kind == SessionKind.TERMINAL && shell != null) {
            // The shell leads its own session; its jobs have groups of their own in it.
            groups.addAll(ProcessTable.groupsInSession(processes(), shell))
        }
        for (group in groups) {
            if (group <= 1) continue
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

        /** Terminal sessions at once: the ninth is refused (PHASE_5_PLAN §10 item 6). */
        const val DEFAULT_MAX_TERMINALS = 8

        /** The launcher's own SIGKILL phase (KILL_WAIT_MS in codeforge-spawn.c). */
        const val LAUNCHER_KILL_WAIT_MS = 3000L

        const val FORCE_MARGIN_MS = 1000L

        private const val FINISH_POLL_MS = 5L
    }
}

/**
 * The processes /proc lists, as far as this process may see them: on Android
 * the app's own (/proc is mounted with hidepid). For the last resort of
 * [SessionRegistry]: the process groups of a terminal's session.
 */
object ProcessTable {
    data class Entry(val pid: Int, val parent: Int, val group: Int, val session: Int, val state: Char)

    fun read(proc: File = File("/proc")): List<Entry> =
        proc.listFiles().orEmpty().mapNotNull { directory ->
            val pid = directory.name.toIntOrNull() ?: return@mapNotNull null
            try {
                parse(pid, File(directory, "stat").readText(Charsets.UTF_8))
            } catch (gone: IOException) {
                null
            }
        }

    /** `pid (comm) state ppid pgrp session ...`: the command name may hold spaces and parentheses. */
    fun parse(pid: Int, stat: String): Entry? {
        val close = stat.lastIndexOf(')')
        if (close < 0 || close + 2 > stat.length) return null
        val fields = stat.substring(close + 2).split(' ')
        if (fields.size < 4) return null
        return Entry(
            pid = pid,
            parent = fields[1].toIntOrNull() ?: return null,
            group = fields[2].toIntOrNull() ?: return null,
            session = fields[3].toIntOrNull() ?: return null,
            state = fields[0].firstOrNull() ?: return null,
        )
    }

    /** The process groups with a live process in [session]. */
    fun groupsInSession(entries: List<Entry>, session: Int): Set<Int> =
        entries.filter { it.session == session && it.state != 'Z' && it.state != 'X' }.map { it.group }.toSet()
}
