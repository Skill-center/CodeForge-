package dev.codeforge.app.git

import dev.codeforge.app.runtime.CommandRunner
import java.io.File

/** Whether an operation changes the repository: one change at a time per repository, reads alongside. */
enum class GitAccess(val code: String) {
    READ("read"),
    WRITE("write"),
}

/** How an operation's stdout is cut into records for Dart. */
enum class GitOutput(val separator: Int, val maxRecordBytes: Int) {
    /** git's `-z` output: NUL-separated records, which may hold newlines (a path may). */
    RECORDS(CommandRunner.NUL_SEPARATOR, 1024 * 1024),

    /** Lines: refs and revisions, which never hold a newline. */
    LINES(CommandRunner.NEWLINE_SEPARATOR, 1024 * 1024),

    /** The whole output as one record: a file's text at a revision, or a diff, up to 4 MiB. */
    WHOLE(CommandRunner.NO_SEPARATOR, 4 * 1024 * 1024),
}

/** Why the host would not run an operation, or how one ended without git's own answer. */
enum class GitFailure(val code: String) {
    /** The runtime is not ready, or an install holds it. */
    NOT_READY("not_ready"),

    /** A malformed request: a path that leaves the project, a value that is not a number, too many paths. */
    BAD_REQUEST("bad_request"),

    /** An operation or an option the host does not run. */
    REFUSED("refused"),

    /** No such project. */
    NO_SUCH_PROJECT("no_such_project"),

    /** Another change to the same repository runs. */
    BUSY("busy"),

    /** The launcher or git could not start. */
    LAUNCH_FAILED("launch_failed"),

    /** It ran past its time limit, and was ended with everything it started. */
    TIMED_OUT("timed_out"),

    /** Dart stopped it, and it was ended with everything it started. */
    STOPPED("stopped"),

    /** A signal ended it by itself (a crash). */
    SIGNALED("signaled"),

    /** Its one record (a file's text) was larger than the host passes on. */
    TOO_LARGE("too_large"),
}

/** The host's refusal of a request, with why. */
class GitRefused(val failure: GitFailure, message: String) : Exception(message)

/** Where an operation runs. */
enum class GitPlace {
    /** In a project's folder, named by Dart. */
    PROJECT,

    /** In the runtime's home: `config --global`, the identity the terminal's git shares. */
    HOME,

    /** Either: `check-ref-format` needs no repository. */
    EITHER,
}

/** One git command as the host runs it. */
data class GitCommand(
    val operation: String,
    val access: GitAccess,
    val output: GitOutput,
    /** Everything after `git`: the global options, the fixed settings, the operation and its arguments. */
    val arguments: List<String>,
    val timeoutMs: Long,
    val place: GitPlace,
)

/**
 * The operations the Git host runs (Phase 7 W2, PHASE_7_PLAN W2; ADR-0016),
 * and nothing else. Dart names an operation and its arguments; each
 * operation allows the options it lists and no others, so anything that
 * would run a program or move git elsewhere (`-c`, `--config-env`,
 * `--exec-path`, `--git-dir`, `--work-tree`, `--upload-pack`,
 * `--receive-pack`, `--exec`, `--template`, ...) is refused because it is
 * not listed. Paths come after `--`: relative, inside the project, never
 * `.git`, and taken literally (`--literal-pathspecs`).
 *
 * Every command gets the same global options and settings first, which a
 * repository's own configuration cannot change for that command
 * ([SETTINGS]), and the same variables ([variables]). A read never takes
 * the index's optional lock, so it never holds up the terminal's git.
 */
object GitCommands {
    /** The settings every command runs with: no program a repository's configuration names runs through them. */
    val SETTINGS: List<String> = listOf(
        // fsmonitor may name a program to run on every status.
        "-c", "core.fsmonitor=false",
        // The ext:: transport runs any command a URL names.
        "-c", "protocol.ext.allow=never",
        "-c", "core.pager=cat",
        "-c", "color.ui=false",
        // Paths as they are, so Dart compares them with the explorer's.
        "-c", "core.quotePath=false",
        // No helper from any configuration: Phase 7 W3 adds CodeForge's own after this.
        "-c", "credential.helper=",
        // Housekeeping in the foreground: the launcher ends whatever a command leaves running.
        "-c", "gc.autoDetach=false",
        "-c", "maintenance.autoDetach=false",
        // The identity set in Settings, never one git guesses from the system (u0_a123@localhost).
        "-c", "user.useConfigOnly=true",
        // Signatures would run gpg, which the runtime does not carry (PHASE_7_PLAN §2).
        "-c", "log.showSignature=false",
        "-c", "merge.verifySignatures=false",
        "-c", "commit.gpgSign=false",
    )

    /** Before the operation: no pager, pathspecs taken literally. */
    val GLOBAL_OPTIONS: List<String> = listOf("--no-pager", "--literal-pathspecs")

    /** A read's extra option: it never writes the index, so it never takes its lock. */
    const val NO_OPTIONAL_LOCKS = "--no-optional-locks"

    const val READ_TIMEOUT_MS = 2L * 60_000L
    const val WRITE_TIMEOUT_MS = 10L * 60_000L

    const val MAX_ARGUMENTS = 8_192
    const val MAX_ARGUMENT_CHARS = 1024 * 1024
    const val MAX_PATH = 4_096
    const val MAX_REVISION = 1_024
    const val MAX_MESSAGE = 64 * 1024
    const val MAX_FORMAT = 512
    const val MAX_IDENTITY = 256

    /** The identity's keys, which `config --global` may read and set. */
    val IDENTITY_KEYS: Set<String> = setOf("user.name", "user.email")

    /**
     * The variables every command gets: no terminal prompt (stdin is closed
     * and there is no terminal), no system configuration, no editor (`:` is
     * git's own word for none), no pager, and in a project no search for a
     * repository above the projects' folder ([projects]): a `.git` the
     * terminal made higher up would claim every project.
     */
    fun variables(projects: File?): Map<String, String> = buildMap {
        put("GIT_TERMINAL_PROMPT", "0")
        put("GIT_CONFIG_NOSYSTEM", "1")
        put("GIT_EDITOR", ":")
        put("GIT_PAGER", "cat")
        if (projects != null) put("GIT_CEILING_DIRECTORIES", projects.path)
    }

    /** The command for [operation] with [arguments], or why not ([GitRefused]). */
    fun build(operation: String, arguments: List<String>): GitCommand {
        if (operation == "config") return config(arguments)
        val spec = SPECS[operation] ?: throw GitRefused(GitFailure.REFUSED, "not an operation the app runs")
        checkSizes(arguments)
        val checked = ArrayList<String>(arguments.size + spec.forced.size)
        checked.addAll(spec.forced)
        var positionals = 0
        var paths = 0
        val seenFlags = HashSet<String>()
        var index = 0
        while (index < arguments.size) {
            val argument = arguments[index]
            when {
                argument == "--" -> {
                    if (!spec.paths) throw GitRefused(GitFailure.REFUSED, "git $operation takes no paths")
                    checked.add(argument)
                    for (path in arguments.subList(index + 1, arguments.size)) {
                        checkPath(path)
                        checked.add(path)
                        paths += 1
                    }
                    index = arguments.size
                    continue
                }
                argument in spec.flags -> {
                    checked.add(argument)
                    seenFlags.add(argument)
                }
                spec.valued.containsKey(argument) -> {
                    val value = arguments.getOrNull(index + 1)
                        ?: throw GitRefused(GitFailure.BAD_REQUEST, "$argument needs a value")
                    checkValue(spec.valued.getValue(argument), value, argument)
                    checked.add(argument)
                    checked.add(value)
                    seenFlags.add(argument)
                    index += 1
                }
                spec.prefixed.keys.any { argument.startsWith(it) } -> {
                    val key = spec.prefixed.keys.first { argument.startsWith(it) }
                    checkValue(spec.prefixed.getValue(key), argument.substring(key.length), key)
                    checked.add(argument)
                    seenFlags.add(key)
                }
                argument.startsWith("-") ->
                    throw GitRefused(GitFailure.REFUSED, "git $operation does not take ${optionName(argument)} here")
                else -> {
                    positionals += 1
                    if (positionals > spec.maxPositionals) {
                        throw GitRefused(GitFailure.BAD_REQUEST, "git $operation takes at most ${spec.maxPositionals} names")
                    }
                    checkPositional(spec.positional, argument)
                    checked.add(argument)
                }
            }
            index += 1
        }
        if (spec.pathsRequired && paths == 0) throw GitRefused(GitFailure.BAD_REQUEST, "git $operation needs at least one path")
        for (required in spec.required) {
            if (required !in seenFlags) throw GitRefused(GitFailure.BAD_REQUEST, "git $operation needs $required")
        }
        return command(operation, spec.access, spec.output, checked, spec.timeoutMs, spec.place)
    }

    /** `config --global`: the identity's two keys only, read, set or unset. */
    private fun config(arguments: List<String>): GitCommand {
        val (access, checked) = when {
            arguments.size == 3 && arguments[0] == "--global" && arguments[1] == "--get" -> {
                checkIdentityKey(arguments[2])
                GitAccess.READ to arguments
            }
            arguments.size == 3 && arguments[0] == "--global" && arguments[1] == "--unset" -> {
                checkIdentityKey(arguments[2])
                GitAccess.WRITE to arguments
            }
            arguments.size == 3 && arguments[0] == "--global" && !arguments[1].startsWith("-") -> {
                checkIdentityKey(arguments[1])
                val value = arguments[2]
                if (value.isBlank() || value.length > MAX_IDENTITY || value.any { it < ' ' || it == '\u007f' }) {
                    throw GitRefused(GitFailure.BAD_REQUEST, "a name or an email is one line of at most $MAX_IDENTITY characters")
                }
                GitAccess.WRITE to arguments
            }
            else -> throw GitRefused(GitFailure.REFUSED, "git config is run only to read or set the identity")
        }
        val timeout = if (access == GitAccess.READ) READ_TIMEOUT_MS else WRITE_TIMEOUT_MS
        return command("config", access, GitOutput.LINES, checked, timeout, GitPlace.HOME)
    }

    private fun command(
        operation: String,
        access: GitAccess,
        output: GitOutput,
        checked: List<String>,
        timeoutMs: Long,
        place: GitPlace,
    ): GitCommand {
        val full = ArrayList<String>(GLOBAL_OPTIONS.size + 1 + SETTINGS.size + 1 + checked.size)
        full.addAll(GLOBAL_OPTIONS)
        if (access == GitAccess.READ) full.add(NO_OPTIONAL_LOCKS)
        full.addAll(SETTINGS)
        full.add(operation)
        full.addAll(checked)
        return GitCommand(operation, access, output, full, timeoutMs, place)
    }

    private fun checkIdentityKey(key: String) {
        if (key !in IDENTITY_KEYS) throw GitRefused(GitFailure.REFUSED, "git config is run only for user.name and user.email")
    }

    private fun checkSizes(arguments: List<String>) {
        if (arguments.size > MAX_ARGUMENTS) {
            throw GitRefused(GitFailure.BAD_REQUEST, "more than $MAX_ARGUMENTS arguments: stage them all at once instead")
        }
        var chars = 0L
        for (argument in arguments) {
            if (argument.contains('\u0000')) throw GitRefused(GitFailure.BAD_REQUEST, "an argument holds a NUL character")
            chars += argument.length
        }
        if (chars > MAX_ARGUMENT_CHARS) throw GitRefused(GitFailure.BAD_REQUEST, "the arguments are too long")
    }

    /** A path relative to the project, inside it, never in `.git`; one trailing `/` names a folder. */
    fun checkPath(path: String) {
        val bare = if (path.length > 1 && path.endsWith("/")) path.dropLast(1) else path
        if (bare.isEmpty() || bare.length > MAX_PATH || bare.startsWith("/") || bare.contains('\u0000')) {
            throw GitRefused(GitFailure.BAD_REQUEST, "a path is relative to the project, and names something in it")
        }
        for (part in bare.split('/')) {
            if (part.isEmpty() || part == "." || part == "..") {
                throw GitRefused(GitFailure.BAD_REQUEST, "a path stays inside the project")
            }
            if (part.equals(".git", ignoreCase = true)) {
                throw GitRefused(GitFailure.BAD_REQUEST, "git's own files are not a path the app touches")
            }
        }
    }

    /** A revision, a ref, or `<revision>:<path>`: no option, no control character, and a path inside the project. */
    fun checkRevision(value: String) {
        if (value.isEmpty() || value.length > MAX_REVISION || value.startsWith("-")) {
            throw GitRefused(GitFailure.BAD_REQUEST, "not a revision: it is empty, too long, or reads as an option")
        }
        if (value.any { it < ' ' || it == '\u007f' }) {
            throw GitRefused(GitFailure.BAD_REQUEST, "a revision holds no control character")
        }
        val colon = value.indexOf(':')
        if (colon >= 0) {
            var path = value.substring(colon + 1)
            // :0:path to :3:path name the index's stages.
            if (colon == 0 && path.length >= 2 && path[0] in '0'..'3' && path[1] == ':') path = path.substring(2)
            if (path.isNotEmpty()) checkPath(path)
        }
    }

    private fun checkPositional(kind: Value, value: String) {
        when (kind) {
            Value.REF_PATTERN -> {
                if (!value.startsWith("refs/") || value.length > 256 || value.contains("..") || value.any { it <= ' ' || it == '\u007f' }) {
                    throw GitRefused(GitFailure.BAD_REQUEST, "a ref pattern starts with refs/")
                }
            }
            else -> checkRevision(value)
        }
    }

    private fun checkValue(kind: Value, value: String, option: String) {
        when (kind) {
            Value.NUMBER -> if (value.isEmpty() || value.length > 9 || value.any { it !in '0'..'9' }) {
                throw GitRefused(GitFailure.BAD_REQUEST, "$option takes a number")
            }
            Value.MESSAGE -> if (value.length > MAX_MESSAGE) {
                throw GitRefused(GitFailure.BAD_REQUEST, "a commit message is at most $MAX_MESSAGE characters")
            }
            Value.LOG_FORMAT -> {
                checkFormat(value, option)
                // %G? and its kin verify a signature: they would run gpg.
                if (value.contains("%G")) throw GitRefused(GitFailure.REFUSED, "a format that checks signatures runs gpg")
            }
            Value.REF_FORMAT -> {
                checkFormat(value, option)
                if (value.contains("signature")) throw GitRefused(GitFailure.REFUSED, "a format that checks signatures runs gpg")
            }
            Value.SORT -> if (value.isEmpty() || value.length > 64 || value.any { !(it.isLetterOrDigit() || it in "-:()") }) {
                throw GitRefused(GitFailure.BAD_REQUEST, "$option takes a sort key")
            }
            Value.BRANCH -> {
                checkRevision(value)
                if (value.contains(':') || value.contains(' ')) throw GitRefused(GitFailure.BAD_REQUEST, "not a branch name")
            }
            Value.REVISION, Value.REF_PATTERN -> checkPositional(kind, value)
        }
    }

    /** An option's name for a message, never its value: what Dart sent could hold anything. */
    private fun optionName(argument: String): String {
        val name = argument.substringBefore('=')
        return if (name.length <= 40 && OPTION_NAME.matches(name)) name else "that option"
    }

    private val OPTION_NAME = Regex("--?[A-Za-z][A-Za-z0-9-]*")

    private fun checkFormat(value: String, option: String) {
        if (value.length > MAX_FORMAT || value.any { it < ' ' || it == '\u007f' }) {
            throw GitRefused(GitFailure.BAD_REQUEST, "$option takes a format of one line, at most $MAX_FORMAT characters")
        }
    }

    /** What a value or a name must be. */
    private enum class Value { NUMBER, MESSAGE, LOG_FORMAT, REF_FORMAT, SORT, BRANCH, REVISION, REF_PATTERN }

    /** One operation: what it may be given, and how it runs. */
    private class Spec(
        val access: GitAccess,
        val output: GitOutput = GitOutput.LINES,
        /** Added first, so the output is always the form the host cuts it into. */
        val forced: List<String> = emptyList(),
        val flags: Set<String> = emptySet(),
        /** Options followed by their value as the next argument. */
        val valued: Map<String, Value> = emptyMap(),
        /** Options with their value after `=`, by their prefix (`--format=`). */
        val prefixed: Map<String, Value> = emptyMap(),
        val maxPositionals: Int = 0,
        val positional: Value = Value.REVISION,
        val paths: Boolean = false,
        val pathsRequired: Boolean = false,
        val required: Set<String> = emptySet(),
        val timeoutMs: Long = if (access == GitAccess.READ) READ_TIMEOUT_MS else WRITE_TIMEOUT_MS,
        val place: GitPlace = GitPlace.PROJECT,
    )

    private val SPECS: Map<String, Spec> = mapOf(
        "status" to Spec(
            access = GitAccess.READ,
            output = GitOutput.RECORDS,
            forced = listOf("--porcelain=v2", "-z"),
            flags = setOf(
                "--branch", "--untracked-files=all", "--untracked-files=normal", "--untracked-files=no",
                "--ignored=no", "--ignored=matching", "--no-renames", "--find-renames", "--ahead-behind",
                "--no-ahead-behind", "--show-stash",
            ),
            paths = true,
        ),
        "add" to Spec(GitAccess.WRITE, flags = setOf("-A", "--all", "-u", "--update"), paths = true),
        // Unstaging on a branch with no commit yet, where restore has no HEAD to restore from.
        "rm" to Spec(
            GitAccess.WRITE,
            flags = setOf("--cached", "-r", "-q", "--quiet", "--ignore-unmatch"),
            paths = true,
            pathsRequired = true,
            required = setOf("--cached"),
        ),
        "restore" to Spec(
            GitAccess.WRITE,
            flags = setOf("--staged", "-S", "--worktree", "-W", "-q", "--quiet"),
            prefixed = mapOf("--source=" to Value.REVISION),
            paths = true,
            pathsRequired = true,
        ),
        // Discarding a new file: only the paths named, never the whole tree.
        "clean" to Spec(
            GitAccess.WRITE,
            flags = setOf("-f", "--force", "-d", "-q", "--quiet"),
            paths = true,
            pathsRequired = true,
        ),
        "commit" to Spec(
            GitAccess.WRITE,
            flags = setOf("--amend", "--no-edit", "-q", "--quiet", "--allow-empty"),
            valued = mapOf("-m" to Value.MESSAGE),
        ),
        "log" to Spec(
            access = GitAccess.READ,
            output = GitOutput.RECORDS,
            forced = listOf("-z", "--no-color"),
            flags = setOf("--first-parent", "--no-merges", "--topo-order", "--date-order"),
            valued = mapOf("-n" to Value.NUMBER),
            prefixed = mapOf("--format=" to Value.LOG_FORMAT, "--max-count=" to Value.NUMBER, "--skip=" to Value.NUMBER),
            maxPositionals = 2,
            paths = true,
        ),
        "diff-tree" to Spec(
            access = GitAccess.READ,
            output = GitOutput.RECORDS,
            forced = listOf("-z"),
            flags = setOf("-r", "--root", "--name-status", "--numstat", "--no-commit-id", "-M", "--find-renames", "-m"),
            maxPositionals = 2,
            paths = true,
        ),
        "diff" to Spec(
            access = GitAccess.READ,
            output = GitOutput.WHOLE,
            forced = listOf("--no-color", "--no-ext-diff", "--no-textconv"),
            flags = setOf(
                "--cached", "--staged", "--name-status", "--numstat", "--stat", "-z", "-M", "--find-renames",
                "--no-renames", "-R",
            ),
            prefixed = mapOf("--unified=" to Value.NUMBER),
            maxPositionals = 2,
            paths = true,
        ),
        // A commit's message and files, or a file's text at a revision: no textconv or external diff
        // program runs (show runs textconv on a blob by default).
        "show" to Spec(
            access = GitAccess.READ,
            output = GitOutput.WHOLE,
            forced = listOf("--no-color", "--no-ext-diff", "--no-textconv"),
            flags = setOf("--name-status", "--numstat", "-z", "--no-patch", "-s", "-M", "--find-renames", "--first-parent", "-m", "--root"),
            prefixed = mapOf("--format=" to Value.LOG_FORMAT),
            maxPositionals = 1,
        ),
        // A file's text at a revision (`blob HEAD:path`, `blob :path` for the index): no filter runs.
        "cat-file" to Spec(
            access = GitAccess.READ,
            output = GitOutput.WHOLE,
            flags = setOf("-e", "-s", "-t"),
            maxPositionals = 2,
        ),
        "for-each-ref" to Spec(
            access = GitAccess.READ,
            prefixed = mapOf("--format=" to Value.REF_FORMAT, "--sort=" to Value.SORT, "--count=" to Value.NUMBER),
            maxPositionals = 4,
            positional = Value.REF_PATTERN,
        ),
        "rev-parse" to Spec(
            access = GitAccess.READ,
            // Nothing that answers with a path: the host never hands Dart one.
            flags = setOf("--verify", "-q", "--quiet", "--short", "--abbrev-ref", "--symbolic-full-name", "--is-inside-work-tree"),
            maxPositionals = 2,
        ),
        "branch" to Spec(
            GitAccess.WRITE,
            flags = setOf("-d", "-D", "--delete", "-m", "-M", "--move", "-q", "--quiet", "--unset-upstream"),
            prefixed = mapOf("--set-upstream-to=" to Value.REVISION),
            maxPositionals = 2,
        ),
        "switch" to Spec(
            GitAccess.WRITE,
            // --create, never -c, which reads as git's own -c to anyone checking a command line.
            flags = setOf("--create", "--detach", "-q", "--quiet", "--no-guess", "--progress", "--no-progress"),
            maxPositionals = 2,
        ),
        "merge" to Spec(
            GitAccess.WRITE,
            flags = setOf(
                "--no-edit", "--ff-only", "--no-ff", "--ff", "--abort", "--continue", "-q", "--quiet",
                "--progress", "--no-progress", "--no-stat", "--stat",
            ),
            maxPositionals = 1,
        ),
        "init" to Spec(
            GitAccess.WRITE,
            flags = setOf("-q", "--quiet"),
            valued = mapOf("-b" to Value.BRANCH),
            prefixed = mapOf("--initial-branch=" to Value.BRANCH),
        ),
        "check-ref-format" to Spec(
            access = GitAccess.READ,
            flags = setOf("--branch", "--allow-onelevel", "--normalize"),
            maxPositionals = 1,
            place = GitPlace.EITHER,
        ),
    )

    /** The operations the host runs, for its tests and its log. */
    val OPERATIONS: Set<String> get() = SPECS.keys + "config"
}
