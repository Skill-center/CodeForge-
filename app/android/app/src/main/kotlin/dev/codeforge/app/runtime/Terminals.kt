package dev.codeforge.app.runtime

import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ScheduledExecutorService

/**
 * What a terminal session should be (docs/TERMINAL_ARCHITECTURE.md §1): a
 * folder, environment overrides, the shell, rows, columns and the buffer.
 */
data class TerminalSpec(
    /**
     * A project's folder name in the projects' folder (`<filesDir>/workspaces`),
     * which the host resolves itself: never a path (docs/SECURITY.md §2.1,
     * E3). The runtime's home when null.
     */
    val project: String? = null,
    /** A name in the runtime's bin; null is bash, interactive, with CodeForge's rc file. */
    val program: String? = null,
    val arguments: List<String> = emptyList(),
    /** Variables to add; the runtime's own and any LD_* cannot be overridden. */
    val environment: Map<String, String> = emptyMap(),
    val rows: Int = 24,
    val columns: Int = 80,
    /** The output buffer kept while no view is attached (1 MiB when null, 64 KiB to 8 MiB). */
    val bufferBytes: Int? = null,
    val label: String? = null,
)

/** A started session, or why none started. */
data class TerminalStart(val session: TerminalSession?, val failure: TerminalFailure?, val detail: String?) {
    companion object {
        fun failed(failure: TerminalFailure, detail: String?) = TerminalStart(null, failure, detail)
    }
}

/**
 * The runtime's terminal sessions (Phase 5 W2): it checks a [TerminalSpec],
 * starts its launcher in terminal mode (codeforge-spawn.c) with
 * [RuntimeEnvironment]'s variables for a terminal, and keeps the sessions,
 * the exited ones included (at most [maxExited], the oldest forgotten first),
 * until they are removed.
 *
 * Kotlin checks every request again and never trusts Dart (docs/SECURITY.md
 * §2.1, E8): the program is a name in the runtime's bin (E1); the folder is
 * the runtime's home or a project's folder that this class resolves from a
 * name, inside the projects' folder once links are resolved (E3); overrides
 * cannot touch the runtime's own variables or any LD_* (E2's invariants);
 * the sizes are brought into range. At most [SessionRegistry.maxTerminals]
 * sessions run at once: the place is reserved before anything starts.
 *
 * The shell is bash, interactive, with CodeForge's rc file ([RC_FILE]): a
 * prompt, then the user's ~/.bashrc when there is one. Without bash in the
 * runtime, a session does not start (NOT_FOUND): it never falls back to
 * another shell silently.
 *
 * No Android type: the JVM tests drive it with real processes.
 */
class Terminals(
    private val environment: RuntimeEnvironment,
    private val launcher: File,
    private val sessions: SessionRegistry,
    /** The terminal's own files in the runtime's root: the rc file, the launchers' status files. */
    private val stateDirectory: File,
    /** Where projects live (`<filesDir>/workspaces`); null when there are none. */
    private val projects: File?,
    /** The one thread that delivers every session's output and changes. */
    private val delivery: ScheduledExecutorService,
    private val clock: () -> Long = System::nanoTime,
    private val window: Int = TerminalSession.DEFAULT_WINDOW,
    private val maxExited: Int = DEFAULT_MAX_EXITED,
) {
    private val all = ConcurrentHashMap<Long, TerminalSession>()

    /** Told of every session's start and exit, on the delivery thread. */
    @Volatile
    var changed: (TerminalSession) -> Unit = {}

    /** The sessions, running and exited, oldest first. */
    fun list(): List<TerminalSession> = all.values.sortedBy { it.id }

    fun get(id: Long): TerminalSession? = all[id]

    /**
     * Starts a session for [spec], with [view] attached from its first byte
     * when given. Blocks for as long as starting a process takes: never on
     * Android's main thread.
     */
    fun start(spec: TerminalSpec, view: TerminalOutputListener? = null): TerminalStart {
        val program = spec.program ?: SHELL
        if (!isProgramName(program)) {
            return TerminalStart.failed(TerminalFailure.BAD_REQUEST, "a program is a name in the runtime's bin, not \"$program\"")
        }
        if (spec.arguments.size > MAX_ARGUMENTS || spec.arguments.any { it.contains('\u0000') }) {
            return TerminalStart.failed(TerminalFailure.BAD_REQUEST, "too many arguments, or one holds a NUL byte")
        }
        val directory = try {
            directoryFor(spec.project)
        } catch (refused: IllegalArgumentException) {
            return TerminalStart.failed(TerminalFailure.BAD_REQUEST, refused.message)
        }
        val variables = try {
            variablesFor(directory, spec.environment)
        } catch (refused: IllegalArgumentException) {
            return TerminalStart.failed(TerminalFailure.BAD_REQUEST, refused.message)
        }
        val executable = File(environment.bin, program)
        if (!executable.exists()) {
            return TerminalStart.failed(TerminalFailure.NOT_FOUND, "the runtime has no $program")
        }
        if (!launcher.isFile) {
            return TerminalStart.failed(TerminalFailure.LAUNCH_FAILED, "the launcher is missing: $launcher")
        }
        val place = sessions.reserveTerminal()
            ?: return if (sessions.isRefusing) {
                TerminalStart.failed(TerminalFailure.NOT_READY, "the runtime is being installed")
            } else {
                TerminalStart.failed(TerminalFailure.TOO_MANY, "${sessions.maxTerminals} terminal sessions are running already")
            }
        val rows = spec.rows.coerceIn(1, TerminalSession.MAX_DIMENSION)
        val columns = spec.columns.coerceIn(1, TerminalSession.MAX_DIMENSION)
        val bufferBytes = (spec.bufferBytes ?: TerminalSession.DEFAULT_BUFFER_BYTES)
            .coerceIn(TerminalSession.MIN_BUFFER_BYTES, TerminalSession.MAX_BUFFER_BYTES)
        var statusFile: File? = null
        var errorFile: File? = null
        val process = try {
            environment.prepare()
            if (!stateDirectory.isDirectory && !stateDirectory.mkdirs() && !stateDirectory.isDirectory) {
                throw IOException("could not create $stateDirectory")
            }
            val arguments = if (spec.program == null) {
                listOf("--noprofile", "--rcfile", writeRcFile().absolutePath, "-i")
            } else {
                spec.arguments
            }
            val status = File.createTempFile("terminal-", ".status", stateDirectory)
            statusFile = status
            val error = File(status.path.removeSuffix(".status") + ".err")
            errorFile = error
            val command = listOf(
                launcher.absolutePath,
                "--status", status.absolutePath,
                "--grace", sessions.graceMs.toString(),
                "--terminal", "${rows}x$columns",
                "--", executable.absolutePath,
            ) + arguments
            val builder = ProcessBuilder(command).directory(directory).redirectError(error)
            builder.environment().clear()
            builder.environment().putAll(variables)
            builder.start()
        } catch (failure: IOException) {
            place.release()
            statusFile?.delete()
            errorFile?.delete()
            return TerminalStart.failed(TerminalFailure.LAUNCH_FAILED, "could not start the launcher: ${failure.message}")
        }
        val label = (spec.label ?: program).take(MAX_LABEL)
        val registered = sessions.register(process, statusFile!!, label, 0L, SessionKind.TERMINAL, place)
        val session = TerminalSession(
            id = registered.id,
            label = label,
            rows = rows,
            columns = columns,
            registered = registered,
            registry = sessions,
            errorFile = errorFile,
            bufferBytes = bufferBytes,
            window = window,
            delivery = delivery,
            clock = clock,
            changed = { changed(it) },
        )
        all[session.id] = session
        if (view != null) session.attach(view)
        session.start()
        forgetOldExited()
        return TerminalStart(session, null, null)
    }

    /** Forgets an exited session and its buffer. False while it runs, or when there is none. */
    fun remove(id: Long): Boolean {
        val session = all[id] ?: return false
        if (session.state != TerminalState.EXITED) return false
        return all.remove(id, session)
    }

    /**
     * The user's *End all*: ends every terminal session with everything it
     * started, and waits for them (new ones are not refused). Answers how
     * many are still running.
     */
    fun endAll(): Int = sessions.endAll(EndReason.ENDED, kind = SessionKind.TERMINAL, refuse = false)

    /** The folder a session starts in: the runtime's home, or a project's folder named by [project]. */
    fun directoryFor(project: String?): File {
        if (project == null) return environment.home
        if (project.isEmpty() || project == "." || project == ".." || project.contains('/') || project.contains('\u0000')) {
            throw IllegalArgumentException("a project is named by its folder's name, not \"$project\"")
        }
        val root = projects ?: throw IllegalArgumentException("there are no projects here")
        val canonicalRoot = try {
            root.canonicalFile
        } catch (unreadable: IOException) {
            throw IllegalArgumentException("the projects' folder cannot be read")
        }
        val folder = try {
            File(canonicalRoot, project).canonicalFile
        } catch (unreadable: IOException) {
            throw IllegalArgumentException("not a project's folder: $project")
        }
        if (folder.parentFile != canonicalRoot) {
            throw IllegalArgumentException("a project's folder lies in the projects' folder, links resolved: $project")
        }
        if (!folder.isDirectory) throw IllegalArgumentException("no such project: $project")
        return folder
    }

    /** The runtime's variables for a terminal in [directory], with [overrides] added. */
    fun variablesFor(directory: File, overrides: Map<String, String>): Map<String, String> {
        val variables = environment.variables(directory, terminal = true)
        if (overrides.isEmpty()) return variables
        if (overrides.size > MAX_OVERRIDES) throw IllegalArgumentException("more than $MAX_OVERRIDES variables")
        var size = 0
        for ((name, value) in overrides) {
            if (!VARIABLE_NAME.matches(name)) throw IllegalArgumentException("not a variable's name: \"$name\"")
            if (name in variables || PROTECTED.any { name.startsWith(it) } || name in RuntimeEnvironment.PASSED_FROM_ANDROID) {
                throw IllegalArgumentException("$name is the runtime's own")
            }
            if (value.contains('\u0000')) throw IllegalArgumentException("$name's value holds a NUL byte")
            size += name.length + value.length
        }
        if (size > MAX_OVERRIDE_CHARS) throw IllegalArgumentException("the variables are longer than $MAX_OVERRIDE_CHARS characters")
        return LinkedHashMap(variables).apply { putAll(overrides) }
    }

    /** CodeForge's rc file, written when it differs: a prompt, then the user's ~/.bashrc. */
    private fun writeRcFile(): File {
        val file = File(stateDirectory, RC_FILE)
        val current = try {
            if (file.isFile) file.readText(Charsets.UTF_8) else null
        } catch (unreadable: IOException) {
            null
        }
        if (current != RC_TEXT) {
            val part = File(stateDirectory, "$RC_FILE.part")
            part.writeText(RC_TEXT, Charsets.UTF_8)
            if (!part.renameTo(file)) {
                part.delete()
                throw IOException("could not write $file")
            }
        }
        return file
    }

    private fun forgetOldExited() {
        val exited = list().filter { it.state == TerminalState.EXITED }
        for (session in exited.take(maxOf(0, exited.size - maxExited))) all.remove(session.id, session)
    }

    private fun isProgramName(name: String): Boolean =
        name.isNotEmpty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\u0000')

    companion object {
        /** The shell: the runtime's bash. */
        const val SHELL = "bash"

        const val RC_FILE = "bashrc"

        /** Exited sessions kept, for their screens, until removed. */
        const val DEFAULT_MAX_EXITED = 8

        const val MAX_ARGUMENTS = 256
        const val MAX_OVERRIDES = 64
        const val MAX_OVERRIDE_CHARS = 32 * 1024
        const val MAX_LABEL = 64

        private val VARIABLE_NAME = Regex("[A-Za-z_][A-Za-z0-9_]*")

        /** Prefixes no override may have: the linker's and Termux's. */
        private val PROTECTED = listOf("LD_", "TERMUX_")

        /**
         * CodeForge's rc file (Phase 5 W2). bash reads it instead of
         * ~/.bashrc, so it reads ~/.bashrc itself: the user's settings win.
         */
        val RC_TEXT = """
            |# CodeForge's terminal (Phase 5 W2). The app writes this file before
            |# every session, so changes here are lost: your own settings go in
            |# ~/.bashrc, which this file reads when it is there.
            |PS1='\[\e[1;32m\]\W\[\e[0m\] \$ '
            |if [ -r "${'$'}HOME/.bashrc" ]; then
            |    . "${'$'}HOME/.bashrc"
            |fi
            |""".trimMargin()
    }
}
