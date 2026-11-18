package dev.codeforge.app.search

/**
 * Collects one search's results for either engine (Phase 4 W6): keeps at
 * most [SearchLimits.maxLines] matching lines, and hands finished files to
 * [emit] in batches. The first file goes at once, so the first result shows
 * as soon as there is one; after that a batch goes when [batchMs] have
 * passed or [batchLines] lines wait, so Dart is not called for every file.
 *
 * Used from the engine's thread only.
 */
class SearchCollector(
    private val limits: SearchLimits,
    private val emit: (List<SearchFile>) -> Unit,
    private val clock: () -> Long = System::nanoTime,
    private val batchMs: Long = BATCH_MS,
    private val batchLines: Int = BATCH_LINES,
) {
    private val startedAt = clock()
    private var pending = ArrayList<SearchFile>()
    private var pendingLines = 0
    private var emitted = false
    private var lastEmitAt = startedAt

    var lines = 0
        private set
    var matches = 0
        private set
    var filesMatched = 0
        private set
    var firstResultMs: Long? = null
        private set

    /** Whether the line cap is reached: the engine stops. */
    var full = false
        private set

    fun elapsedMs(): Long = (clock() - startedAt) / 1_000_000L

    /** Adds one file's matching lines, in order. False once the cap is reached. */
    fun add(path: String, fileLines: List<SearchLine>): Boolean {
        if (full) return false
        if (fileLines.isEmpty()) return true
        val room = limits.maxLines - lines
        val kept = if (fileLines.size > room) fileLines.subList(0, room).toList() else fileLines.toList()
        lines += kept.size
        matches += kept.sumOf { it.matches }
        filesMatched += 1
        if (firstResultMs == null) firstResultMs = elapsedMs()
        pending.add(SearchFile(path, kept))
        pendingLines += kept.size
        if (lines >= limits.maxLines) full = true
        if (!emitted || pendingLines >= batchLines) flush() else poll()
        return !full
    }

    /** Sends what waits when its time has come; engines call it as they go. */
    fun poll() {
        if (pending.isNotEmpty() && clock() - lastEmitAt >= batchMs * 1_000_000L) flush()
    }

    /** Sends everything that waits. */
    fun flush() {
        if (pending.isEmpty()) return
        val batch = pending
        pending = ArrayList()
        pendingLines = 0
        emitted = true
        lastEmitAt = clock()
        emit(batch)
    }

    companion object {
        const val BATCH_MS = 100L
        const val BATCH_LINES = 500

        /** UTF-16 code units kept before the first match when a line is cut. */
        const val PREVIEW_BEFORE = 40

        /** The longest preview, in UTF-16 code units. */
        const val PREVIEW_MAX = 250

        /** Matches highlighted per line. */
        const val RANGES_MAX = 50

        /**
         * A matching line as the panel shows it. [text] is the whole line
         * without its line break; [ranges] holds the first matches' start and
         * end (UTF-16 offsets into [text]) in pairs, in order, at least one
         * pair; [count] is how many matches the line has in all.
         */
        fun lineOf(number: Int, text: String, ranges: IntArray, count: Int = ranges.size / 2): SearchLine {
            require(ranges.size >= 2 && ranges.size % 2 == 0) { "a matching line has a match" }
            val first = ranges[0].coerceIn(0, text.length)
            var start = 0
            var end = text.length
            if (text.length > PREVIEW_MAX) {
                start = (first - PREVIEW_BEFORE).coerceAtLeast(0)
                end = (start + PREVIEW_MAX).coerceAtMost(text.length)
                // Never half a surrogate pair at either end.
                if (start > 0 && Character.isLowSurrogate(text[start])) start -= 1
                if (end < text.length && end > start && Character.isHighSurrogate(text[end - 1])) end -= 1
            }
            val kept = ArrayList<Int>()
            var i = 0
            while (i + 1 < ranges.size && kept.size < RANGES_MAX * 2) {
                val from = ranges[i]
                val to = ranges[i + 1]
                if (from >= start && from <= end && to >= from) {
                    kept.add(from - start)
                    kept.add(to.coerceAtMost(end) - start)
                }
                i += 2
            }
            return SearchLine(
                line = number,
                column = first + 1,
                preview = text.substring(start, end),
                previewStart = start,
                cutEnd = end < text.length,
                ranges = kept,
                matches = maxOf(count, ranges.size / 2),
            )
        }
    }
}
