package dev.codeforge.app.search

import dev.codeforge.app.runtime.CommandFailure
import dev.codeforge.app.runtime.CommandResult
import dev.codeforge.app.runtime.LineSink
import java.io.File

/**
 * A project's search through the runtime's ripgrep (Phase 4 W6): its
 * arguments, and its `--json` lines into a [SearchCollector]. It is the line
 * sink of CommandRunner.stream, so answering false stops ripgrep with
 * everything it started.
 *
 * - **Where it runs:** in [root], searching `.`. ripgrep matches its `-g`
 *   globs relative to the folder it runs in, so a glob with a slash in it
 *   would match nothing from anywhere else. Naming `.` keeps
 *   ripgrep from reading its standard input instead, which it does when it
 *   is given no path and that input is not a terminal.
 *
 * - **What it reads:** the project's `.gitignore` and `.ignore` files count
 *   with no git repository (`--no-require-git`), but none above the project
 *   (`--no-ignore-parent`) and no configuration file (`--no-config`).
 *   Dotfiles are searched (`--hidden`), as Go to File lists them; links are
 *   never followed, and [SearchLimits.SKIPPED_FOLDERS] never entered.
 * - **Binary files are skipped:** ripgrep stops reading a file at a NUL
 *   byte, and a file it found binary is dropped whole, with any lines before
 *   the NUL. Nothing is transcoded (`--encoding none`), so a UTF-16 file has
 *   NUL bytes and is binary, as the editor refuses it.
 * - **A file with a line that is not UTF-8** is dropped whole: the editor
 *   would not open it. Files over [SearchLimits.maxFileBytes] are skipped.
 * - **What it cannot count:** ripgrep reports neither the files it read nor
 *   the binary files it skipped before a match (its `--json` summary counts
 *   only the files it printed), so the summary leaves both out.
 */
class RipgrepSearch(
    private val root: File,
    private val query: SearchQuery,
    private val limits: SearchLimits,
    private val collector: SearchCollector,
    private val stopped: () -> Boolean,
) : LineSink {
    private val prefix = root.path.trimEnd('/') + "/"
    private var currentPath: String? = null
    private val currentLines = ArrayList<SearchLine>()
    private var currentNotText = false

    var binary = 0
        private set
    var notText = 0
        private set
    var longLines = 0
        private set
    var unparsed = 0
        private set

    fun arguments(): List<String> {
        val args = mutableListOf(
            "--json",
            "--no-config",
            "--no-require-git",
            "--no-ignore-parent",
            "--hidden",
            "--encoding", "none",
            "--max-filesize", limits.maxFileBytes.toString(),
            "--max-depth", (limits.maxDepth + 1).toString(),
            if (query.caseSensitive) "--case-sensitive" else "--ignore-case",
        )
        if (!query.regex) args += "--fixed-strings"
        if (query.wholeWord) args += "--word-regexp"
        for (folder in SearchLimits.SKIPPED_FOLDERS) args += listOf("--glob", "!$folder")
        for (glob in query.includes) args += listOf("--glob", glob)
        for (glob in query.excludes) args += listOf("--glob", "!$glob")
        // After --regexp a leading '-' is part of the pattern, never an option.
        args += listOf("--regexp", query.text, "--", ".")
        return args
    }

    override fun line(text: String): Boolean {
        if (stopped()) return false
        val message = try {
            MiniJson.parse(text) as? Map<*, *>
        } catch (bad: IllegalArgumentException) {
            unparsed += 1
            null
        }
        if (message != null) take(message)
        collector.poll()
        return !collector.full && !stopped()
    }

    override fun overlong() {
        longLines += 1
    }

    private fun take(message: Map<*, *>) {
        val data = message["data"] as? Map<*, *> ?: return
        when (message["type"]) {
            "begin" -> {
                currentPath = textOf(data["path"])
                currentLines.clear()
                currentNotText = currentPath == null
            }
            "match" -> match(data)
            "end" -> end(data)
        }
    }

    private fun match(data: Map<*, *>) {
        if (currentNotText) return
        val raw = textOf(data["lines"])
        if (raw == null) {
            currentNotText = true
            currentLines.clear()
            return
        }
        val number = (data["line_number"] as? Long)?.toInt() ?: return
        val submatches = data["submatches"] as? List<*> ?: return
        val bytes = ArrayList<Int>()
        for (sub in submatches) {
            if (bytes.size >= SearchCollector.RANGES_MAX * 2) break
            val match = sub as? Map<*, *> ?: continue
            val start = (match["start"] as? Long)?.toInt() ?: continue
            val end = (match["end"] as? Long)?.toInt() ?: continue
            bytes.add(start)
            bytes.add(end)
        }
        if (bytes.isEmpty()) return
        val offsets = utf16Offsets(raw, bytes.toIntArray())
        var line = raw.removeSuffix("\n").removeSuffix("\r")
        var shift = 0
        if (number == 1 && line.startsWith("\uFEFF")) {
            // The editor takes a UTF-8 byte-order mark off, so columns start after it.
            line = line.substring(1)
            shift = 1
        }
        val ranges = IntArray(offsets.size) { (offsets[it] - shift).coerceIn(0, line.length) }
        currentLines.add(SearchCollector.lineOf(number, line, ranges, submatches.size))
    }

    private fun end(data: Map<*, *>) {
        val path = currentPath ?: textOf(data["path"])
        when {
            data["binary_offset"] != null -> binary += 1
            currentNotText -> notText += 1
            path != null && currentLines.isNotEmpty() -> collector.add(relative(path), currentLines.toList())
        }
        currentPath = null
        currentLines.clear()
        currentNotText = false
    }

    private fun relative(path: String): String = when {
        path.startsWith("./") -> path.substring(2)
        path.startsWith(prefix) -> path.substring(prefix.length)
        else -> path
    }

    /** The summary once ripgrep has ended; [cancelled] when Dart stopped it. */
    fun summary(result: CommandResult, cancelled: Boolean): SearchSummary {
        collector.flush()
        val stderr = result.stderr.text
        val complaints = stderr.lineSequence().filter { it.startsWith("rg: ") && "regex parse error" !in it }.toList()
        val base = SearchSummary(
            outcome = SearchOutcome.DONE,
            engine = SearchEngine.RIPGREP,
            filesSearched = null,
            filesMatched = collector.filesMatched,
            lines = collector.lines,
            matches = collector.matches,
            skippedBinary = binary,
            skippedNotText = notText,
            skippedLongLines = longLines,
            unreadable = complaints.size,
            firstResultMs = collector.firstResultMs,
            elapsedMs = collector.elapsedMs(),
        )
        return when {
            cancelled -> base.copy(outcome = SearchOutcome.CANCELLED)
            collector.full -> base.copy(outcome = SearchOutcome.LIMIT)
            result.failure == CommandFailure.TIMED_OUT -> base.copy(
                outcome = SearchOutcome.FAILED,
                failure = SearchFailure.TIMED_OUT,
                detail = "The search ran past its time limit.",
            )
            result.failure != null -> base.copy(
                outcome = SearchOutcome.FAILED,
                failure = SearchFailure.FAILED,
                detail = "ripgrep did not run: ${result.failure.code}${result.detail?.let { ": $it" } ?: ""}",
            )
            result.exitCode == 0 || result.exitCode == 1 -> base
            "regex parse error" in stderr -> base.copy(
                outcome = SearchOutcome.FAILED,
                failure = SearchFailure.BAD_QUERY,
                detail = regexError(stderr),
            )
            result.exitCode == 2 && complaints.isNotEmpty() -> base.copy(
                detail = complaints.first().removePrefix("rg: ").removePrefix("./").replace(prefix, ""),
            )
            else -> base.copy(
                outcome = SearchOutcome.FAILED,
                failure = SearchFailure.FAILED,
                detail = "ripgrep exited with ${result.exitCode}: ${stderr.lineSequence().firstOrNull().orEmpty()}",
            )
        }
    }

    companion object {
        /** The text of ripgrep's `{"text": …}`, or null for `{"bytes": …}` (not UTF-8). */
        internal fun textOf(value: Any?): String? = (value as? Map<*, *>)?.get("text") as? String

        /** ripgrep's own words for a pattern it can't compile. */
        internal fun regexError(stderr: String): String {
            val why = stderr.lineSequence().map { it.trim() }.firstOrNull { it.startsWith("error:") }
                ?.removePrefix("error:")?.trim()
            return "Not a valid regular expression for ripgrep" + (why?.let { ": $it" } ?: ".")
        }

        /** The UTF-16 index in [text] of each UTF-8 byte offset in [byteOffsets]. */
        internal fun utf16Offsets(text: String, byteOffsets: IntArray): IntArray {
            val order = byteOffsets.indices.sortedBy { byteOffsets[it] }
            val out = IntArray(byteOffsets.size)
            var bytes = 0
            var i = 0
            for (k in order) {
                val target = byteOffsets[k]
                while (bytes < target && i < text.length) {
                    val cp = text.codePointAt(i)
                    bytes += when {
                        cp < 0x80 -> 1
                        cp < 0x800 -> 2
                        cp < 0x10000 -> 3
                        else -> 4
                    }
                    i += Character.charCount(cp)
                }
                out[k] = i
            }
            return out
        }
    }
}
