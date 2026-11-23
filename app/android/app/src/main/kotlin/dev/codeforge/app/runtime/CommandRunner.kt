package dev.codeforge.app.runtime

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.TimeUnit

/** One command for the runtime: a program in its bin, run once. */
data class CommandRequest(
    /** A name in the runtime's bin (`node`, `git`); never a path. */
    val program: String,
    val arguments: List<String> = emptyList(),
    /** The runtime's home when null; otherwise a folder inside its home or workspace. */
    val directory: File? = null,
    val timeoutMs: Long = CommandRunner.DEFAULT_TIMEOUT_MS,
    /** Bytes kept of each of stdout and stderr; the rest is counted and dropped. */
    val outputLimit: Int = CommandRunner.DEFAULT_OUTPUT_LIMIT,
    /**
     * Variables a host in Kotlin adds for this command (Phase 7 W2: git's
     * settings, never Dart's): names of letters, digits and underscores that
     * the runtime's own environment does not set, since they may only add to
     * it, never replace it.
     */
    val variables: Map<String, String> = emptyMap(),
)

/** Why a command has no ordinary result. Each code travels to Dart. */
enum class CommandFailure(val code: String) {
    /** The runtime is not installed and started, or is being installed. */
    NOT_READY("not_ready"),

    /** Not a program name, a folder outside the runtime, a NUL byte. */
    BAD_REQUEST("bad_request"),

    /** No such program in the runtime (or no interpreter for its `#!` line). */
    NOT_FOUND("not_found"),

    /** The program is there and could not be executed. */
    CANNOT_EXECUTE("cannot_execute"),

    /** It ran past its time limit, and was ended with everything it started. */
    TIMED_OUT("timed_out"),

    /** The app ended it (a reinstall, a request), with everything it started. */
    ENDED("ended"),

    /** A signal ended it by itself (a crash). */
    SIGNALED("signaled"),

    /** The launcher could not run: missing, or no process could be made. */
    LAUNCH_FAILED("launch_failed"),
}

/** One output stream, as much of it as was kept. */
data class CommandOutput(
    val text: String,
    /** Every byte the command wrote, kept or not. */
    val bytes: Long,
    val truncated: Boolean,
) {
    companion object {
        val EMPTY = CommandOutput("", 0L, false)
    }
}

/**
 * Takes a command's stdout line by line as it comes (Phase 4 W6: a
 * project's search reads ripgrep's `--json` lines), instead of keeping it.
 */
interface LineSink {
    /** One line, without its \n. False stops the command, with everything it started. */
    fun line(text: String): Boolean

    /** A line longer than the limit was dropped unread. */
    fun overlong() {}
}

/**
 * Receives a streamed command's progress from its stderr (Phase 7 W2: git's
 * `--progress`), on the stderr reader's thread: each line git redraws with
 * a carriage return, then the line that closes them ([closing]: `..., done.`).
 */
fun interface ProgressSink {
    fun progress(text: String, closing: Boolean)
}

/** What became of a command. [failure] is null when it ran and exited, whatever its exit code. */
data class CommandResult(
    val exitCode: Int?,
    /** The signal that ended it, when one did. */
    val signal: Int?,
    val stdout: CommandOutput,
    val stderr: CommandOutput,
    val durationMs: Long,
    val failure: CommandFailure?,
    val detail: String?,
    /** Processes the launcher ended: what the command left behind, or its whole tree when stopped. */
    val leftovers: Int,
    /** Processes that could not be ended: 0 unless the kernel refused. */
    val remaining: Int,
) {
    val succeeded: Boolean get() = failure == null && exitCode == 0

    companion object {
        fun failed(failure: CommandFailure, detail: String?, durationMs: Long = 0L) =
            CommandResult(null, null, CommandOutput.EMPTY, CommandOutput.EMPTY, durationMs, failure, detail, 0, 0)
    }
}

/**
 * Runs one-shot commands in the sealed runtime (Phase 4 W4;
 * docs/SECURITY.md §2). CodeForge's own, in place of t1's
 * HarnessCommandRunner, which merges stderr into stdout through one shared
 * log file, prepares apt at every call and ends only its direct child.
 *
 * A command is a program in the runtime's bin, never a path, run in the
 * runtime's home or in a folder inside its home or workspace, with
 * [RuntimeEnvironment]'s variables and no others, stdin closed, and stdout
 * and stderr read apart, each up to its limit.
 *
 * It starts through the launcher (libcodeforge-spawn.so), which Android
 * extracted into nativeLibraryDir: ProcessBuilder can execute it, and the
 * launcher then executes the program with the preload loaded, so the
 * preload's own execve translates a script's official `#!` line (t1's
 * runner translated it in Java, because ProcessBuilder's exec bypasses the
 * preload). The launcher leads a process group of its own and ends it
 * whole; [SessionRegistry] owns the session and its deadline.
 */
class CommandRunner(
    private val environment: RuntimeEnvironment,
    private val launcher: File,
    private val sessions: SessionRegistry,
    /** Where the launchers' status files go (the runtime's state folder). */
    private val statusDirectory: File,
    private val clock: () -> Long = System::nanoTime,
) {
    fun run(request: CommandRequest): CommandResult = execute(request, null, null, emptyList())

    /**
     * Runs [request] like [run], with its stdout going to [lines] line by line
     * as it comes (lines over [maxLineBytes] dropped), so the result's stdout is
     * empty but counted. [started] gets the session once the command runs, so
     * another thread can end it. A sink that answers false ends it the same way.
     * [extraRoots] are folders the command may also run in, besides the
     * runtime's home and workspace: a project's search runs in the project, as
     * ripgrep reads its globs from the folder it runs in (Phase 4 W6).
     * [separator] ends a line: a newline by default; [NUL_SEPARATOR] for
     * git's `-z` output, whose records may hold newlines (Phase 7 W2); and
     * [NO_SEPARATOR] for the whole output as one line, up to [maxLineBytes].
     * With [progress], stderr's progress goes there instead of into the
     * result's stderr, which keeps the other lines ([ProgressReader]).
     */
    fun stream(
        request: CommandRequest,
        lines: LineSink,
        maxLineBytes: Int = DEFAULT_MAX_LINE_BYTES,
        started: (SessionRegistry.Session) -> Unit = {},
        extraRoots: List<File> = emptyList(),
        separator: Int = NEWLINE_SEPARATOR,
        progress: ProgressSink? = null,
    ): CommandResult = execute(request, LineStream(lines, maxLineBytes, separator, progress), started, extraRoots)

    private class LineStream(val sink: LineSink, val maxLineBytes: Int, val separator: Int, val progress: ProgressSink?)

    private fun execute(
        request: CommandRequest,
        streaming: LineStream?,
        started: ((SessionRegistry.Session) -> Unit)?,
        extraRoots: List<File>,
    ): CommandResult {
        val startedAt = clock()
        fun elapsed(): Long = (clock() - startedAt) / 1_000_000L

        val program = request.program
        if (program.isEmpty() || program == "." || program == ".." || program.contains('/') || program.contains('\u0000')) {
            return CommandResult.failed(CommandFailure.BAD_REQUEST, "a program is a name in the runtime's bin, not \"$program\"")
        }
        if (request.arguments.any { it.contains('\u0000') }) {
            return CommandResult.failed(CommandFailure.BAD_REQUEST, "an argument holds a NUL byte")
        }
        for ((name, value) in request.variables) {
            if (!VARIABLE_NAME.matches(name) || value.contains('\u0000')) {
                return CommandResult.failed(CommandFailure.BAD_REQUEST, "not a variable a command can be given: \"$name\"")
            }
        }
        val executable = File(environment.bin, program)
        if (!executable.exists()) {
            return CommandResult.failed(CommandFailure.NOT_FOUND, "the runtime has no $program")
        }
        val directory = try {
            directoryFor(request.directory, extraRoots)
        } catch (refused: IllegalArgumentException) {
            return CommandResult.failed(CommandFailure.BAD_REQUEST, refused.message)
        }
        if (!launcher.isFile) {
            return CommandResult.failed(CommandFailure.LAUNCH_FAILED, "the launcher is missing: $launcher")
        }

        val statusFile = try {
            environment.prepare()
            if (!statusDirectory.isDirectory && !statusDirectory.mkdirs() && !statusDirectory.isDirectory) {
                throw IOException("could not create $statusDirectory")
            }
            File.createTempFile("command-", ".status", statusDirectory)
        } catch (failure: IOException) {
            return CommandResult.failed(CommandFailure.LAUNCH_FAILED, "the runtime's folders: ${failure.message}", elapsed())
        }
        val timeout = request.timeoutMs.coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        val limit = request.outputLimit.coerceIn(MIN_OUTPUT_LIMIT, MAX_OUTPUT_LIMIT)
        val command = listOf(
            launcher.absolutePath,
            "--status", statusFile.absolutePath,
            "--grace", sessions.graceMs.toString(),
            "--", executable.absolutePath,
        ) + request.arguments
        val variables = environment.variables(directory)
        val replaced = request.variables.keys.firstOrNull { it in variables }
        if (replaced != null) {
            statusFile.delete()
            return CommandResult.failed(CommandFailure.BAD_REQUEST, "$replaced is the runtime's own variable")
        }
        val builder = ProcessBuilder(command).directory(directory)
        builder.environment().clear()
        builder.environment().putAll(variables)
        builder.environment().putAll(request.variables)

        val process = try {
            builder.start()
        } catch (failure: IOException) {
            statusFile.delete()
            return CommandResult.failed(CommandFailure.LAUNCH_FAILED, "could not start the launcher: ${failure.message}", elapsed())
        }
        val session = sessions.register(process, statusFile, program, timeout)
        try {
            try {
                process.outputStream.close()
            } catch (ignored: IOException) {
                // Its stdin is closed either way.
            }
            val stdout: OutputReader = if (streaming == null) {
                CappedReader(process.inputStream, limit)
            } else {
                LineReader(process.inputStream, streaming.maxLineBytes, streaming.sink, streaming.separator) {
                    sessions.end(session, EndReason.ENDED)
                }
            }
            val progress = streaming?.progress
            val stderr: OutputReader = if (progress == null) {
                CappedReader(process.errorStream, limit)
            } else {
                ProgressReader(process.errorStream, limit, progress)
            }
            started?.invoke(session)
            val readers = listOf(
                Thread(stdout, "codeforge-stdout-${session.id}"),
                Thread(stderr, "codeforge-stderr-${session.id}"),
            )
            for (reader in readers) {
                reader.isDaemon = true
                reader.start()
            }
            try {
                process.waitFor()
            } catch (interrupted: InterruptedException) {
                // The caller gave up: the command ends with everything it started.
                sessions.end(session, EndReason.ENDED)
                process.waitFor(sessions.graceMs + SessionRegistry.LAUNCHER_KILL_WAIT_MS + SessionRegistry.FORCE_MARGIN_MS, TimeUnit.MILLISECONDS)
                Thread.currentThread().interrupt()
            }
            // The launcher ended everything that held the pipes before it
            // exited, so the readers are at their end; should anything have
            // escaped it, they are cut off.
            for (reader in readers) reader.join(READER_JOIN_MS)
            if (readers.any { it.isAlive }) {
                closeQuietly(process.inputStream)
                closeQuietly(process.errorStream)
                for (reader in readers) reader.join(READER_JOIN_MS)
            }
            val launcherExit = if (process.isAlive) null else process.exitValue()
            return interpret(LauncherStatus.read(statusFile), launcherExit, session.endReason, stdout.output(), stderr.output(), elapsed())
        } finally {
            sessions.finished(session)
            statusFile.delete()
            File(statusFile.path + ".part").delete()
        }
    }

    /** The folder a command runs in: the home, or one inside the home, the workspace or [extraRoots]. */
    fun directoryFor(requested: File?, extraRoots: List<File> = emptyList()): File {
        if (requested == null) return environment.home
        val canonical = try {
            requested.canonicalFile
        } catch (unreadable: IOException) {
            throw IllegalArgumentException("not a folder the runtime can use: $requested")
        }
        val allowed = (listOf(environment.home, environment.workspace) + extraRoots).map { it.canonicalFile }
        val inside = allowed.any { root -> canonical == root || canonical.path.startsWith(root.path + File.separator) }
        if (!inside) {
            throw IllegalArgumentException("commands run in the runtime's home or workspace, not $requested")
        }
        if (!canonical.isDirectory) {
            throw IllegalArgumentException("not a folder: $requested")
        }
        return canonical
    }

    private fun interpret(
        status: LauncherStatus?,
        launcherExit: Int?,
        endReason: EndReason?,
        stdout: CommandOutput,
        stderr: CommandOutput,
        durationMs: Long,
    ): CommandResult {
        val leftovers = status?.ended ?: 0
        val remaining = status?.remaining ?: 0
        fun result(exitCode: Int?, signal: Int?, failure: CommandFailure?, detail: String?) =
            CommandResult(exitCode, signal, stdout, stderr, durationMs, failure, detail, leftovers, remaining)

        if (status == null || status.reason == null) {
            // The launcher wrote no outcome: it was killed (the forced end) or never ran.
            val failure = endReason?.let(::failureFor) ?: CommandFailure.LAUNCH_FAILED
            return result(null, null, failure, "the launcher ended without a status (exit $launcherExit)")
        }
        return when (status.reason) {
            "exited" -> result(status.exit, null, null, null)
            "signaled" -> result(null, status.signal, CommandFailure.SIGNALED, "ended by ${signalName(status.signal)}")
            "stopped" -> {
                val failure = endReason?.let(::failureFor) ?: CommandFailure.ENDED
                val how = if (status.exit != null) "it exited with ${status.exit}" else "ended by ${signalName(status.signal)}"
                val why = if (failure == CommandFailure.TIMED_OUT) "ran past its time limit" else "was ended"
                result(status.exit, status.signal, failure, "it $why; $how, with ${status.ended ?: 0} processes in all")
            }
            "exec_failed" -> if (status.execErrno == ENOENT) {
                result(null, null, CommandFailure.NOT_FOUND, "no such program, or no interpreter for its #! line")
            } else {
                result(null, null, CommandFailure.CANNOT_EXECUTE, "could not execute it: ${errnoName(status.execErrno)}")
            }
            "spawn_failed" ->
                result(null, null, CommandFailure.LAUNCH_FAILED, "no process could be made: ${errnoName(status.execErrno)}")
            else -> result(null, null, CommandFailure.LAUNCH_FAILED, "the launcher said ${status.reason}")
        }
    }

    private fun failureFor(reason: EndReason): CommandFailure = when (reason) {
        EndReason.TIMED_OUT -> CommandFailure.TIMED_OUT
        EndReason.ENDED -> CommandFailure.ENDED
    }

    private fun closeQuietly(stream: InputStream) {
        try {
            stream.close()
        } catch (ignored: IOException) {
            // Closing is all that is wanted.
        }
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 60_000L
        const val MIN_TIMEOUT_MS = 100L
        const val MAX_TIMEOUT_MS = 10L * 60_000L
        const val DEFAULT_OUTPUT_LIMIT = 256 * 1024
        const val MIN_OUTPUT_LIMIT = 1024
        const val MAX_OUTPUT_LIMIT = 1024 * 1024
        const val READER_JOIN_MS = 2000L

        /** The longest stdout line [stream] passes on. */
        const val DEFAULT_MAX_LINE_BYTES = 8 * 1024 * 1024

        /** [stream]'s separators: a newline, a NUL byte (git's `-z`), or none, the whole output as one line. */
        const val NEWLINE_SEPARATOR = 10
        const val NUL_SEPARATOR = 0
        const val NO_SEPARATOR = -1

        /** A variable's name that [CommandRequest.variables] may add. */
        private val VARIABLE_NAME = Regex("[A-Za-z_][A-Za-z0-9_]*")

        private const val ENOENT = 2

        /** Linux's numbers, the same on arm64 and x86_64. */
        fun signalName(signal: Int?): String = when (signal) {
            null -> "a signal"
            1 -> "SIGHUP"
            2 -> "SIGINT"
            3 -> "SIGQUIT"
            4 -> "SIGILL"
            5 -> "SIGTRAP"
            6 -> "SIGABRT"
            7 -> "SIGBUS"
            8 -> "SIGFPE"
            9 -> "SIGKILL"
            11 -> "SIGSEGV"
            13 -> "SIGPIPE"
            14 -> "SIGALRM"
            15 -> "SIGTERM"
            31 -> "SIGSYS"
            else -> "signal $signal"
        }

        fun errnoName(errno: Int?): String = when (errno) {
            null -> "an unknown error"
            2 -> "ENOENT (no such file)"
            7 -> "E2BIG (arguments too long)"
            8 -> "ENOEXEC (not an executable format)"
            11 -> "EAGAIN (too many processes)"
            12 -> "ENOMEM (out of memory)"
            13 -> "EACCES (permission denied)"
            20 -> "ENOTDIR (a path part is not a folder)"
            26 -> "ETXTBSY (the file is being written)"
            40 -> "ELOOP (too many symbolic links)"
            else -> "errno $errno"
        }
    }
}

/** A reader of one output stream, which runs on its own thread. */
internal interface OutputReader : Runnable {
    fun output(): CommandOutput
}

/** Reads a stream to its end, keeping its first [limit] bytes and counting all. */
internal class CappedReader(private val stream: InputStream, private val limit: Int) : OutputReader {
    private val kept = ByteArrayOutputStream(minOf(limit, 8192))

    @Volatile
    private var total = 0L

    override fun run() {
        val buffer = ByteArray(8192)
        try {
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                synchronized(kept) {
                    val room = limit - kept.size()
                    if (room > 0) kept.write(buffer, 0, minOf(room, count))
                }
                total += count
            }
        } catch (closed: IOException) {
            // Cut off (CommandRunner closes a stream that outlives its command).
        } finally {
            try {
                stream.close()
            } catch (ignored: IOException) {
                // Done either way.
            }
        }
    }

    override fun output(): CommandOutput = synchronized(kept) {
        val bytes = kept.toByteArray()
        CommandOutput(String(bytes, Charsets.UTF_8), total, total > bytes.size)
    }
}

/**
 * Reads stderr to its end like [CappedReader], keeping its first [limit]
 * bytes of lines, while progress goes to [sink] and is not kept (Phase 7
 * W2). A segment that ends in a carriage return is progress, as git redraws
 * its progress line with one, and so is the newline-ended line that closes
 * such a run (`Receiving objects: 100% (10/10), done.`), which is also kept
 * unless it ends in `done.`, since an error can follow a redrawn line. Every
 * other line is kept, so git's error stays in the text however long the
 * progress ran. A segment over [limit] bytes keeps its beginning.
 */
internal class ProgressReader(
    private val stream: InputStream,
    private val limit: Int,
    private val sink: ProgressSink,
) : OutputReader {
    private val kept = ByteArrayOutputStream(minOf(limit, 8192))
    private val segment = ByteArrayOutputStream()

    @Volatile
    private var total = 0L

    @Volatile
    private var dropped = false

    /** The last segment ended in a carriage return: a newline now closes a run of progress. */
    private var redrawing = false

    override fun run() {
        val buffer = ByteArray(8192)
        try {
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                total += count
                take(buffer, count)
            }
            if (segment.size() > 0) keep(withNewline = false)
        } catch (closed: IOException) {
            // Cut off (CommandRunner closes a stream that outlives its command).
        } finally {
            try {
                stream.close()
            } catch (ignored: IOException) {
                // Done either way.
            }
        }
    }

    private fun take(buffer: ByteArray, count: Int) {
        var start = 0
        for (i in 0 until count) {
            val byte = buffer[i]
            if (byte == RETURN || byte == NEWLINE) {
                append(buffer, start, i - start)
                end(byte)
                start = i + 1
            }
        }
        if (start < count) append(buffer, start, count - start)
    }

    private fun append(buffer: ByteArray, offset: Int, length: Int) {
        val room = limit - segment.size()
        if (length > room) dropped = true
        if (room > 0) segment.write(buffer, offset, minOf(room, length))
    }

    private fun end(byte: Byte) {
        when {
            byte == RETURN -> {
                if (segment.size() > 0) sink.progress(String(segment.toByteArray(), Charsets.UTF_8), false)
                redrawing = true
                segment.reset()
            }
            redrawing -> {
                redrawing = false
                val text = String(segment.toByteArray(), Charsets.UTF_8)
                if (text.isNotEmpty()) sink.progress(text, true)
                // An error that follows a redrawn line also comes here: only git's own closing line is left out.
                if (text.isNotEmpty() && !text.trimEnd().endsWith("done.")) keep(withNewline = true) else segment.reset()
            }
            else -> keep(withNewline = true)
        }
    }

    private fun keep(withNewline: Boolean) {
        synchronized(kept) {
            val bytes = segment.toByteArray()
            val room = limit - kept.size()
            val wanted = bytes.size + if (withNewline) 1 else 0
            if (wanted > room) dropped = true
            if (room > 0) kept.write(bytes, 0, minOf(room, bytes.size))
            if (withNewline && kept.size() < limit) kept.write(NEWLINE.toInt())
        }
        segment.reset()
    }

    override fun output(): CommandOutput = synchronized(kept) {
        CommandOutput(String(kept.toByteArray(), Charsets.UTF_8), total, dropped)
    }

    private companion object {
        const val RETURN: Byte = 13
        const val NEWLINE: Byte = 10
    }
}

/**
 * Reads a stream to its end and hands each line to [sink] as it completes
 * (Phase 4 W6). A line over [maxLine] bytes is dropped as it streams by, and
 * the sink hears of it. When the sink answers false, [stop] runs once and the
 * rest is read and dropped, so the command never blocks on a full pipe while
 * it is ended. Every byte is counted. A line ends at [separator], a byte
 * (Phase 7 W2: a NUL for git's `-z`), or only at the end when it is
 * negative.
 */
internal class LineReader(
    private val stream: InputStream,
    private val maxLine: Int,
    private val sink: LineSink,
    private val separator: Int = CommandRunner.NEWLINE_SEPARATOR,
    private val stop: () -> Unit,
) : OutputReader {
    @Volatile
    private var total = 0L

    private val line = ByteArrayOutputStream()
    private var dropping = false
    private var stopped = false

    override fun run() {
        val buffer = ByteArray(64 * 1024)
        try {
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                total += count
                if (!stopped) take(buffer, count)
            }
            if (!stopped && (line.size() > 0 || dropping)) finishLine()
        } catch (closed: IOException) {
            // Cut off (CommandRunner closes a stream that outlives its command).
        } finally {
            try {
                stream.close()
            } catch (ignored: IOException) {
                // Done either way.
            }
        }
    }

    private fun take(buffer: ByteArray, count: Int) {
        if (separator < 0) {
            append(buffer, 0, count)
            return
        }
        val end = separator.toByte()
        var start = 0
        var i = 0
        while (i < count && !stopped) {
            if (buffer[i] == end) {
                append(buffer, start, i - start)
                finishLine()
                start = i + 1
            }
            i++
        }
        if (!stopped && start < count) append(buffer, start, count - start)
    }

    private fun append(buffer: ByteArray, offset: Int, length: Int) {
        if (dropping || length == 0) return
        if (line.size() + length > maxLine) {
            dropping = true
            line.reset()
        } else {
            line.write(buffer, offset, length)
        }
    }

    private fun finishLine() {
        if (dropping) {
            sink.overlong()
        } else if (!sink.line(String(line.toByteArray(), Charsets.UTF_8))) {
            stopped = true
            stop()
        }
        line.reset()
        dropping = false
    }

    override fun output(): CommandOutput = CommandOutput("", total, total > 0)
}
