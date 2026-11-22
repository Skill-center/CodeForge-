package dev.codeforge.app.runtime

import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** Why a language server did not start, or a call to one was refused. Each code travels to Dart. */
enum class LspFailure(val code: String) {
    /** The runtime is not ready, or is being installed. */
    NOT_READY("not_ready"),

    /** No workspace, a workspace that is not one, or a server id that is not a name. */
    BAD_REQUEST("bad_request"),

    /** This APK carries no such server (LanguageServers). */
    NOT_IN_APK("not_in_apk"),

    /** The server's files in the APK are damaged (LanguageServers). */
    DAMAGED("damaged"),

    /** The device could not store the server (LanguageServers). */
    STORAGE("storage"),

    /** [LspHost.maxServers] servers run already. */
    TOO_MANY("too_many"),

    /** This server runs already: one per language. */
    ALREADY_RUNNING("already_running"),

    LAUNCH_FAILED("launch_failed"),

    /** No server has this handle. */
    NO_SUCH_SERVER("no_such_server"),

    /** The server is ending or has ended. */
    NOT_RUNNING("not_running"),

    /** The messages waiting for the server's stdin would pass [LanguageServerProcess.MAX_QUEUED_BYTES]. */
    QUEUE_FULL("queue_full"),
}

/** How a language server's process ended. Each code travels to Dart. */
enum class LspEnd(val code: String) {
    /** It exited by itself, with [LspExit.exitCode]. */
    EXITED("exited"),

    /** A signal it did not ask for ended it: a crash, or the kernel's OOM killer. */
    SIGNALED("signaled"),

    /** The host stopped it: on request, when the engine went, or before a reinstall. */
    STOPPED("stopped"),

    /** The host stopped it to free memory, when Android warned of low memory. */
    MEMORY("memory"),

    /** It wrote something that is not LSP's base protocol, so the host ended it. */
    BROKEN("broken"),

    /** Its launcher wrote no outcome, or could not start node. */
    LOST("lost"),
}

/** Where a server works: a project's folder by its name, or a folder's run copy by its id (ADR-0013). */
data class LspWorkspace(val project: String? = null, val copy: String? = null)

/** A language server's end, as Dart hears it. */
data class LspExit(
    val handle: Long,
    val server: String,
    val end: LspEnd,
    val exitCode: Int?,
    val signal: Int?,
    val detail: String?,
    /** The last [LanguageServerProcess.STDERR_KEPT] bytes it wrote to stderr. */
    val stderr: String,
    /** Processes of its tree the launcher ended after it. */
    val leftovers: Int,
    /** Processes that could not be ended. */
    val remaining: Int,
)

/** A server's process tree's memory, from /proc: PSS and RSS in KiB. */
data class LspMemory(val pssKib: Long, val rssKib: Long, val processes: Int, val sampledAtMs: Long)

/** What a language server tells whoever started it: its messages, then its exit, in order, on the host's delivery thread. */
interface LspListener {
    fun onMessage(handle: Long, message: String)

    fun onExit(exit: LspExit)
}

/** A started server, or why none started; [running] names the server already running for ALREADY_RUNNING. */
data class LspStart(val server: LanguageServerProcess?, val failure: LspFailure?, val detail: String?, val running: Long? = null) {
    companion object {
        fun failed(failure: LspFailure, detail: String?, running: Long? = null) = LspStart(null, failure, detail, running)
    }
}

/**
 * The language servers' processes (Phase 6 W3; docs/LSP_ARCHITECTURE.md §1,
 * docs/adr/0015-language-servers.md). CodeForge's own. Kotlin is a supervised
 * pipe: it starts a server, carries whole messages both ways, stops it, and
 * says how it ended; Dart owns the protocol (W4).
 *
 *   * A server starts as a command does, through the launcher
 *     (libcodeforge-spawn.so): in a session and process group of its own,
 *     under the sessions' limits (SessionLimits.SESSION), ended with its whole
 *     tree. Unlike a command it has no deadline, and its stdin stays open.
 *     W1 showed the launcher's command mode hands a server its stdin
 *     unchanged on every target, so no new mode was needed.
 *   * Its program is the runtime's node running the server's entry, from its
 *     install by [LanguageServers] (W2), which happens here the first time.
 *     Its environment is the runtime's (E2), with NODE_OPTIONS capping V8's
 *     heap at [heapMb]: a backstop against a runaway server, not its budget.
 *     It gets no credentials, and needs no network.
 *   * Its folder is a project's or a folder's copy, named by Dart and
 *     resolved by [resolve], never a path from Dart (SECURITY T3).
 *   * At most [maxServers] run at once, one per server: a server already
 *     running is refused with its handle, and one more with TOO_MANY.
 *   * Every [sampleEveryMs] each server's process tree's memory is read from
 *     /proc (PHASE_6_PLAN §10 item 3: a budget of its own, 300 MB of PSS).
 *   * [stopAll] with [LspEnd.MEMORY] is what Android's low-memory warning
 *     calls: servers are the first thing the app gives up.
 *
 * Servers do not hold the foreground service: when Android ends the app,
 * they end with it.
 */
class LspHost(
    private val environment: RuntimeEnvironment,
    private val launcher: File,
    private val sessions: SessionRegistry,
    private val servers: LanguageServers,
    /** Where the launchers' status files go: the runtime's state folder. */
    private val stateDirectory: File,
    /** A workspace's folder; IllegalArgumentException for one that is not a project's or a copy's. */
    private val resolve: (LspWorkspace) -> File,
    /** Where listeners are told, in order: one thread. */
    private val delivery: Executor,
    private val limits: SessionLimits = SessionLimits.SESSION,
    val heapMb: Int = HEAP_MB,
    val maxServers: Int = MAX_SERVERS,
    private val sampleEveryMs: Long = SAMPLE_EVERY_MS,
    private val memory: (Int) -> LspMemory? = { group -> ProcessMemory.ofGroup(group) },
) {
    private val running = ConcurrentHashMap<Long, LanguageServerProcess>()
    private val samplerLock = Any()
    private var sampler: ScheduledThreadPoolExecutor? = null
    private var sampling: ScheduledFuture<*>? = null

    /** The servers that run, oldest first. */
    fun list(): List<LanguageServerProcess> = running.values.sortedBy { it.handle }

    fun get(handle: Long): LanguageServerProcess? = running[handle]

    /**
     * Starts server [serverId] in [workspace], with [listener] told of its
     * messages and its exit. Installs the server first if it is not yet
     * (that may take seconds: never on the main thread).
     */
    @Synchronized
    fun start(serverId: String, workspace: LspWorkspace, listener: LspListener): LspStart {
        if (!SERVER_ID.matches(serverId)) return LspStart.failed(LspFailure.BAD_REQUEST, "a server is named by its id, not \"$serverId\"")
        val directory = try {
            if ((workspace.project == null) == (workspace.copy == null)) {
                throw IllegalArgumentException("a server works in a project or in a copy, one of them")
            }
            resolve(workspace)
        } catch (refused: IllegalArgumentException) {
            return LspStart.failed(LspFailure.BAD_REQUEST, refused.message)
        }
        running.values.firstOrNull { it.server.id == serverId }?.let { other ->
            return LspStart.failed(LspFailure.ALREADY_RUNNING, "the $serverId server runs already", other.handle)
        }
        if (running.size >= maxServers) {
            return LspStart.failed(LspFailure.TOO_MANY, "$maxServers language servers run already")
        }
        if (sessions.isRefusing) return LspStart.failed(LspFailure.NOT_READY, "the runtime is being installed")
        val installed = try {
            servers.ensure(serverId)
        } catch (failure: LanguageServerFailure) {
            val code = when (failure.problem) {
                LanguageServerProblem.NOT_IN_APK -> LspFailure.NOT_IN_APK
                LanguageServerProblem.DAMAGED -> LspFailure.DAMAGED
                LanguageServerProblem.STORAGE -> LspFailure.STORAGE
            }
            return LspStart.failed(code, failure.message)
        }
        val node = File(environment.bin, NODE)
        if (!node.exists()) return LspStart.failed(LspFailure.LAUNCH_FAILED, "the runtime has no $NODE")
        if (!launcher.isFile) return LspStart.failed(LspFailure.LAUNCH_FAILED, "the launcher is missing: $launcher")
        var statusFile: File? = null
        val process = try {
            environment.prepare()
            if (!stateDirectory.isDirectory && !stateDirectory.mkdirs() && !stateDirectory.isDirectory) {
                throw IOException("could not create $stateDirectory")
            }
            val status = File.createTempFile("lsp-", ".status", stateDirectory)
            statusFile = status
            val command = listOf(
                launcher.absolutePath,
                "--status", status.absolutePath,
                "--grace", sessions.graceMs.toString(),
            ) + limits.arguments() + listOf("--", node.absolutePath, installed.entry.absolutePath) + installed.server.arguments
            val builder = ProcessBuilder(command).directory(directory)
            builder.environment().clear()
            builder.environment().putAll(environment.variables(directory))
            builder.environment()[NODE_OPTIONS] = "--max-old-space-size=$heapMb"
            builder.start()
        } catch (failure: IOException) {
            statusFile?.delete()
            return LspStart.failed(LspFailure.LAUNCH_FAILED, "could not start the launcher: ${failure.message}")
        }
        val registered = sessions.register(process, statusFile!!, serverId, 0L, SessionKind.LANGUAGE_SERVER)
        val server = LanguageServerProcess(
            handle = registered.id,
            server = installed.server,
            workspace = workspace,
            directory = directory,
            installMs = if (installed.reused) 0L else installed.millis,
            registered = registered,
            registry = sessions,
            listener = listener,
            delivery = delivery,
            finished = { done ->
                running.remove(done.handle)
                stopSamplingIfIdle()
            },
        )
        running[server.handle] = server
        server.start()
        startSampling()
        return LspStart(server, null, null)
    }

    /**
     * Queues [message] for server [handle]'s stdin. Null, or why not. (Not
     * `running[handle]?.send(message) ?: NO_SUCH_SERVER`: the elvis would
     * also take a successful send's null for a missing server.)
     */
    fun send(handle: Long, message: String): LspFailure? {
        val server = running[handle] ?: return LspFailure.NO_SUCH_SERVER
        return server.send(message)
    }

    /** Stops server [handle] with its tree. Null, or why not (as [send]). */
    fun stop(handle: Long, end: LspEnd = LspEnd.STOPPED): LspFailure? {
        val server = running[handle] ?: return LspFailure.NO_SUCH_SERVER
        return server.stop(end)
    }

    /** Stops every server; answers how many were running. */
    fun stopAll(end: LspEnd = LspEnd.STOPPED): Int {
        val all = list()
        for (server in all) server.stop(end)
        return all.size
    }

    /** Reads every running server's memory now (the sampler does it every [sampleEveryMs]). */
    fun sample() {
        for (server in list()) {
            val group = server.group() ?: continue
            memory(group)?.let { server.memory = it }
        }
    }

    private fun startSampling() {
        synchronized(samplerLock) {
            if (sampling != null) return
            val executor = sampler ?: ScheduledThreadPoolExecutor(1) { task ->
                Thread(task, "codeforge-lsp-memory").apply { isDaemon = true }
            }.apply { removeOnCancelPolicy = true }.also { sampler = it }
            sampling = executor.scheduleWithFixedDelay(
                {
                    try {
                        sample()
                    } catch (failure: Exception) {
                        // A process that went away between the listing and the read: the next round reads again.
                    }
                },
                0L,
                sampleEveryMs,
                TimeUnit.MILLISECONDS,
            )
        }
    }

    private fun stopSamplingIfIdle() {
        synchronized(samplerLock) {
            if (running.isNotEmpty()) return
            sampling?.cancel(false)
            sampling = null
        }
    }

    companion object {
        /** The runtime's node, which runs every server. */
        const val NODE = "node"

        const val NODE_OPTIONS = "NODE_OPTIONS"

        /**
         * V8's old space per node process, in MB: a backstop. W1 measured the
         * servers' whole process trees at 167 to 255 MB of PSS on the Pixel 8a
         * (ADR-0015); a server past this cap fails, and Dart says so.
         */
        const val HEAP_MB = 256

        /** Servers at once: one per language, two languages (PHASE_6_PLAN W3). */
        const val MAX_SERVERS = 2

        /** How often each server's memory is read. */
        const val SAMPLE_EVERY_MS = 10_000L

        private val SERVER_ID = Regex("^[a-z][a-z0-9-]*$")
    }
}

/**
 * One running language server (Phase 6 W3): its launcher's process, a thread
 * that reads its stdout into whole messages, one that keeps the last
 * [STDERR_KEPT] bytes of its stderr, and one that writes the messages queued
 * for its stdin, so a busy server never holds up whoever sends to it.
 * Messages and then the exit go to the listener on the host's delivery
 * thread, in order.
 */
class LanguageServerProcess internal constructor(
    val handle: Long,
    val server: LanguageServers.Server,
    val workspace: LspWorkspace,
    val directory: File,
    /** How long its install took before it started; 0 when it was installed already. */
    val installMs: Long,
    private val registered: SessionRegistry.Session,
    private val registry: SessionRegistry,
    private val listener: LspListener,
    private val delivery: Executor,
    private val finished: (LanguageServerProcess) -> Unit,
) {
    val startedAtMs: Long = System.currentTimeMillis()

    /** Its process tree's memory, as last read; null before the first reading. */
    @Volatile
    var memory: LspMemory? = null
        internal set

    /** Messages it has written, and messages written to it. */
    val received = AtomicLong()
    val sent = AtomicLong()

    /** False once its launcher has exited. */
    @Volatile
    var alive: Boolean = true
        private set

    @Volatile
    private var requested: LspEnd? = null

    @Volatile
    private var broken: String? = null

    private val outbox = LinkedBlockingQueue<ByteArray>()
    private val queued = AtomicLong()
    private val stderr = ByteTail(STDERR_KEPT)
    private var errors: Thread? = null

    internal fun start() {
        errors = Thread({ readErrors() }, "codeforge-lsp-$handle-err").apply {
            isDaemon = true
            start()
        }
        Thread({ writeMessages() }, "codeforge-lsp-$handle-in").apply {
            isDaemon = true
            start()
        }
        Thread({ readMessages() }, "codeforge-lsp-$handle-out").apply {
            isDaemon = true
            start()
        }
    }

    /** The launcher's process group (its pid): the server's whole tree. */
    fun group(): Int? = registered.group()

    /** The node process the launcher started, once it has. */
    fun child(): Int? = LauncherStatus.read(registered.statusFile)?.child

    /** What its stderr ends with. */
    fun stderrTail(): String = stderr.text()

    /** Queues [message] for its stdin. Null, or why not. */
    fun send(message: String): LspFailure? {
        if (!alive || requested != null) return LspFailure.NOT_RUNNING
        val frame = LspFrames.frame(message)
        if (frame.size - HEADER_ALLOWANCE > LspFrames.MAX_MESSAGE_BYTES) return LspFailure.BAD_REQUEST
        if (queued.get() + frame.size > MAX_QUEUED_BYTES) return LspFailure.QUEUE_FULL
        queued.addAndGet(frame.size.toLong())
        outbox.offer(frame)
        return null
    }

    /** Ends it with its tree, saying why. Null, or why not. */
    fun stop(end: LspEnd): LspFailure? {
        if (!alive) return LspFailure.NOT_RUNNING
        synchronized(this) {
            if (requested == null) requested = end
        }
        registry.end(registered, EndReason.ENDED)
        return null
    }

    private fun readMessages() {
        val reader = LspFrameReader(registered.process.inputStream)
        try {
            while (true) {
                val message = reader.read() ?: break
                received.incrementAndGet()
                delivery.execute { listener.onMessage(handle, message) }
            }
        } catch (bad: LspFramingException) {
            broken = "${bad.reason}: ${bad.message}"
            synchronized(this) {
                if (requested == null) requested = LspEnd.BROKEN
            }
            registry.end(registered, EndReason.ENDED)
        } catch (closed: IOException) {
            // The pipe closed under the reader: the process is ending.
        }
        val process = registered.process
        try {
            process.waitFor()
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        errors?.join(STDERR_JOIN_MS)
        alive = false
        outbox.clear()
        outbox.offer(STOP)
        registry.finished(registered)
        val exit = describe(LauncherStatus.read(registered.statusFile))
        registered.statusFile.delete()
        finished(this)
        delivery.execute { listener.onExit(exit) }
    }

    private fun describe(status: LauncherStatus?): LspExit {
        val asked = requested
        val leftovers = status?.ended ?: 0
        val remaining = status?.remaining ?: 0
        fun exit(end: LspEnd, detail: String?) =
            LspExit(handle, server.id, end, status?.exit, status?.signal, detail, stderr.text(), leftovers, remaining)
        return when {
            asked == LspEnd.BROKEN -> exit(LspEnd.BROKEN, broken)
            asked != null -> exit(asked, null)
            registered.endReason != null -> exit(LspEnd.STOPPED, "the runtime ended it")
            status?.reason == "exited" -> exit(LspEnd.EXITED, null)
            status?.reason == "signaled" -> exit(LspEnd.SIGNALED, "ended by signal ${status?.signal}")
            status?.reason == "stopped" -> exit(LspEnd.STOPPED, "its launcher was asked to stop")
            status?.reason == "exec_failed" || status?.reason == "spawn_failed" ->
                exit(LspEnd.LOST, "node could not be started (${status?.reason}, errno ${status?.execErrno})")
            else -> exit(LspEnd.LOST, "its launcher wrote no outcome")
        }
    }

    private fun readErrors() {
        val buffer = ByteArray(ERROR_CHUNK)
        val input = registered.process.errorStream
        try {
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                stderr.append(buffer, count)
            }
        } catch (closed: IOException) {
            // The process has ended.
        }
    }

    private fun writeMessages() {
        val output = registered.process.outputStream
        try {
            while (true) {
                val frame = outbox.take()
                if (frame === STOP) break
                output.write(frame)
                output.flush()
                queued.addAndGet(-frame.size.toLong())
                sent.incrementAndGet()
            }
        } catch (closed: IOException) {
            // The server has gone: its exit says how.
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
        } finally {
            try {
                output.close()
            } catch (ignored: IOException) {
                // Closed already.
            }
        }
    }

    companion object {
        /** The stderr kept for the exit (PHASE_6_PLAN W3). */
        const val STDERR_KEPT = 64 * 1024

        /** Bytes that may wait for a server's stdin. */
        const val MAX_QUEUED_BYTES = 32L * 1024 * 1024

        private const val HEADER_ALLOWANCE = 64
        private const val ERROR_CHUNK = 4096
        private const val STDERR_JOIN_MS = 500L
        private val STOP = ByteArray(0)
    }
}

/** The last [capacity] bytes written to it, for a server's stderr. */
internal class ByteTail(private val capacity: Int) {
    private val buffer = ByteArray(capacity)
    private var start = 0
    private var size = 0

    @Synchronized
    fun append(bytes: ByteArray, count: Int) {
        for (index in 0 until count) {
            val at = (start + size) % capacity
            buffer[at] = bytes[index]
            if (size < capacity) size += 1 else start = (start + 1) % capacity
        }
    }

    @Synchronized
    fun text(): String {
        val out = ByteArray(size)
        for (index in 0 until size) out[index] = buffer[(start + index) % capacity]
        return String(out, Charsets.UTF_8)
    }
}

/** A process group's memory, from /proc (Phase 6 W3): the server's whole tree. */
object ProcessMemory {
    fun ofGroup(group: Int, proc: File = File("/proc")): LspMemory? {
        val members = ProcessTable.read(proc).filter { it.group == group && it.state != 'Z' && it.state != 'X' }
        if (members.isEmpty()) return null
        var pss = 0L
        var rss = 0L
        for (member in members) {
            pss += pssKib(File(proc, member.pid.toString()))
            rss += statusKib(File(proc, member.pid.toString()), "VmRSS:")
        }
        return LspMemory(pss, rss, members.size, System.currentTimeMillis())
    }

    private fun pssKib(directory: File): Long {
        val rollup = File(directory, "smaps_rollup")
        val rows = try {
            if (rollup.isFile) rollup.readLines() else File(directory, "smaps").readLines()
        } catch (gone: IOException) {
            return 0L
        }
        return rows.filter { it.startsWith("Pss:") }.sumOf { kib(it) }
    }

    private fun statusKib(directory: File, key: String): Long =
        try {
            File(directory, "status").readLines().firstOrNull { it.startsWith(key) }?.let { kib(it) } ?: 0L
        } catch (gone: IOException) {
            0L
        }

    private fun kib(line: String): Long = line.substringAfter(':').trim().removeSuffix("kB").trim().toLongOrNull() ?: 0L
}
