package dev.codeforge.app.search

/**
 * What a search looks for (Phase 4 W6): the Search panel's query and its
 * switches. [includes] and [excludes] are globs as the user typed them;
 * [GlobFilter.expand] turns a plain name into the name and everything
 * inside it, for both engines alike.
 */
data class SearchQuery(
    val text: String,
    val caseSensitive: Boolean = false,
    val regex: Boolean = false,
    val wholeWord: Boolean = false,
    /** A file must match one of these to be searched; none means every file. */
    val includes: List<String> = emptyList(),
    /** Files and folders these match are left out. */
    val excludes: List<String> = emptyList(),
)

/** The caps on one search. */
data class SearchLimits(
    /** Matching lines kept; the search stops when it has this many. */
    val maxLines: Int = DEFAULT_MAX_LINES,
    /** Files a scan reads. */
    val maxFiles: Int = DEFAULT_MAX_FILES,
    /** Larger files are not searched: the editor opens nothing larger (core/files/text_codec.dart). */
    val maxFileBytes: Int = DEFAULT_MAX_FILE_BYTES,
    /** Folders deeper than this are not entered, as in Go to File's index. */
    val maxDepth: Int = DEFAULT_MAX_DEPTH,
    /** The longest a search runs. */
    val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
) {
    companion object {
        const val DEFAULT_MAX_LINES = 10_000
        const val DEFAULT_MAX_FILES = 50_000
        const val DEFAULT_MAX_FILE_BYTES = 10 * 1024 * 1024
        const val DEFAULT_MAX_DEPTH = 64
        const val DEFAULT_TIMEOUT_MS = 5 * 60_000L

        /** Folders no search enters, at any depth: Go to File's (lib/application/file_index.dart). */
        val SKIPPED_FOLDERS = setOf(".git", "node_modules")
    }
}

/** One matching line, ready to show. Offsets count UTF-16 code units, as Dart and the editor do. */
data class SearchLine(
    /** 1-based. */
    val line: Int,
    /** 1-based, in the whole line: where the editor puts the cursor (its first match). */
    val column: Int,
    /** The line, or the part of it around its first match when it is long. */
    val preview: String,
    /** Where [preview] starts in the line: 0 unless the line was cut before it. */
    val previewStart: Int,
    /** Whether the line goes on after [preview]. */
    val cutEnd: Boolean,
    /** The matches inside [preview], as start and end offsets in pairs. */
    val ranges: List<Int>,
    /** Matches in the whole line. */
    val matches: Int,
)

/** One file's matching lines, in order. [path] is relative to the searched folder, '/'-separated. */
data class SearchFile(val path: String, val lines: List<SearchLine>)

/** How a search ended. */
enum class SearchOutcome(val code: String) {
    /** It looked everywhere it could. */
    DONE("done"),

    /** It stopped at a cap: [SearchLimits.maxLines] lines or [SearchLimits.maxFiles] files. */
    LIMIT("limit"),

    /** Dart cancelled it, or a newer search replaced it. */
    CANCELLED("cancelled"),

    FAILED("failed"),
}

/** Why a search failed. Each code travels to Dart. */
enum class SearchFailure(val code: String) {
    /** Nothing to look for, or a pattern or glob that does not compile. */
    BAD_QUERY("bad_query"),

    /** The folder is gone. */
    NOT_FOUND("not_found"),

    /** The app keeps no grant for the folder. */
    ACCESS_LOST("access_lost"),

    /** It ran past [SearchLimits.timeoutMs]. */
    TIMED_OUT("timed_out"),

    /** Anything else: ripgrep failed, or the provider did. */
    FAILED("failed"),
}

/** Which engine searched. */
enum class SearchEngine(val code: String) {
    /** The runtime's ripgrep, for a project while the runtime is ready. */
    RIPGREP("ripgrep"),

    /** [TextScan]: a folder from shared storage, or a project while the runtime is not ready. */
    SCAN("scan"),
}

/** The end of a search, with its counts. */
data class SearchSummary(
    val outcome: SearchOutcome,
    val engine: SearchEngine,
    val failure: SearchFailure? = null,
    /** Why it failed, or a warning (files ripgrep could not read). */
    val detail: String? = null,
    /**
     * Files read; null for ripgrep, whose `--json` summary counts only the
     * files it printed (checked against ripgrep 13 and 14).
     */
    val filesSearched: Int? = 0,
    val filesMatched: Int = 0,
    val lines: Int = 0,
    val matches: Int = 0,
    /** Files left out as binary: a NUL byte, as the editor decides. */
    val skippedBinary: Int = 0,
    /** Files over [SearchLimits.maxFileBytes]. */
    val skippedLarge: Int = 0,
    /** Files that are not UTF-8 text the editor can open. */
    val skippedNotText: Int = 0,
    /** Lines too long to pass on (ripgrep's output over its line limit). */
    val skippedLongLines: Int = 0,
    /** Folders or files that could not be read. */
    val unreadable: Int = 0,
    val firstResultMs: Long? = null,
    val elapsedMs: Long = 0,
)
