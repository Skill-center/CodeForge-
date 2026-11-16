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
    fun run(request: CommandRequest): CommandResult {
        val started = clock()
        fun elapsed(): Long = (clock() - started) / 1_000_000L

        val program = request.program
        if (program.isEmpty() || program == "." || program == ".." || program.contains('/') || program.contains('\u0000')) {
            return CommandResult.failed(CommandFailure.BAD_REQUEST, "a program is a name in the runtime's bin, not \"$program\"")
        }
        if (request.arguments.any { it.contains('\u0000') }) {
            return CommandResult.failed(CommandFailure.BAD_REQUEST, "an argument holds a NUL byte")
        }
        val executable = File(environment.bin, program)
        if (!executable.exists()) {
            return CommandResult.failed(CommandFailure.NOT_FOUND, "the runtime has no $program")
        }
        val directory = try {
            directoryFor(request.directory)
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
        val builder = ProcessBuilder(command).directory(directory)
        builder.environment().clear()
        builder.environment().putAll(environment.variables(directory))

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
            val stdout = CappedReader(process.inputStream, limit)
            val stderr = CappedReader(process.errorStream, limit)
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

    /** The folder a command runs in: the home, or one inside the home or the workspace. */
    fun directoryFor(requested: File?): File {
        if (requested == null) return environment.home
        val canonical = try {
            requested.canonicalFile
        } catch (unreadable: IOException) {
            throw IllegalArgumentException("not a folder the runtime can use: $requested")
        }
        val allowed = listOf(environment.home, environment.workspace).map { it.canonicalFile }
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

/** Reads a stream to its end, keeping its first [limit] bytes and counting all. */
internal class CappedReader(private val stream: InputStream, private val limit: Int) : Runnable {
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

    fun output(): CommandOutput = synchronized(kept) {
        val bytes = kept.toByteArray()
        CommandOutput(String(bytes, Charsets.UTF_8), total, total > bytes.size)
    }
}
