package dev.codeforge.app.search

import dev.codeforge.app.runtime.CommandFailure
import dev.codeforge.app.runtime.CommandOutput
import dev.codeforge.app.runtime.CommandResult
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * A project's search through ripgrep (Phase 4 W6): its arguments, and its
 * `--json` lines in the format ripgrep 15 documents (crates/printer/src/json.rs),
 * written here by hand. The emulator gate runs the real ripgrep.
 */
class RipgrepSearchTest {
    private val root = File("/data/user/0/dev.codeforge.app/files/workspaces/demo")
    private val batches = mutableListOf<List<SearchFile>>()
    private var cancelled = false

    private fun search(query: SearchQuery = SearchQuery("greet"), maxLines: Int = 100): RipgrepSearch {
        val limits = SearchLimits(maxLines = maxLines)
        val collector = SearchCollector(limits, emit = { batches.add(it) })
        return RipgrepSearch(root, query, limits, collector) { cancelled }
    }

    // ripgrep runs in the project and searches ".", so its paths start "./".
    private fun path(rel: String) = "{\"text\":\"./$rel\"}"

    private fun begin(rel: String) = "{\"type\":\"begin\",\"data\":{\"path\":${path(rel)}}}"

    private fun match(rel: String, line: Int, text: String, vararg spans: Pair<Int, Int>): String {
        val subs = spans.joinToString(",") { (s, e) -> "{\"match\":{\"text\":\"m\"},\"start\":$s,\"end\":$e}" }
        return "{\"type\":\"match\",\"data\":{\"path\":${path(rel)},\"lines\":{\"text\":${quote(text)}}," +
            "\"line_number\":$line,\"absolute_offset\":0,\"submatches\":[$subs]}}"
    }

    private fun end(rel: String, binaryOffset: Long? = null) =
        "{\"type\":\"end\",\"data\":{\"path\":${path(rel)},\"binary_offset\":${binaryOffset ?: "null"}," +
            "\"stats\":{\"elapsed\":{\"secs\":0,\"nanos\":1,\"human\":\"0s\"},\"searches\":1," +
            "\"searches_with_match\":1,\"bytes_searched\":10,\"bytes_printed\":10,\"matched_lines\":1,\"matches\":1}}}"

    private fun summaryLine(searches: Int) =
        "{\"data\":{\"elapsed_total\":{\"human\":\"0.01s\",\"nanos\":1,\"secs\":0},\"stats\":{\"searches\":$searches," +
            "\"searches_with_match\":1,\"matches\":1}},\"type\":\"summary\"}"

    private fun quote(text: String): String {
        val out = StringBuilder("\"")
        for (c in text) {
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                else -> if (c.code < 0x20) out.append("\\u%04x".format(c.code)) else out.append(c)
            }
        }
        return out.append('"').toString()
    }

    private fun result(exit: Int?, stderr: String = "", failure: CommandFailure? = null) =
        CommandResult(exit, null, CommandOutput.EMPTY, CommandOutput(stderr, stderr.length.toLong(), false), 5L, failure, null, 0, 0)

    @Test
    fun theArgumentsKeepToTheProjectAndItsRules() {
        val args = search(
            SearchQuery("-e x", regex = false, wholeWord = true, includes = listOf("src/**"), excludes = listOf("dist")),
        ).arguments()
        for (flag in listOf("--json", "--no-config", "--no-require-git", "--no-ignore-parent", "--hidden", "--fixed-strings", "--word-regexp", "--ignore-case")) {
            assertTrue("missing $flag", flag in args)
        }
        assertEquals("none", args[args.indexOf("--encoding") + 1])
        assertEquals((10 * 1024 * 1024).toString(), args[args.indexOf("--max-filesize") + 1])
        // The pattern follows --regexp, and "." (ripgrep runs in the root) follows --.
        assertEquals(listOf("--regexp", "-e x", "--", "."), args.takeLast(4))
        val globs = args.withIndex().filter { it.value == "--glob" }.map { args[it.index + 1] }
        assertEquals(listOf("!.git", "!node_modules", "src/**", "!dist"), globs)
        val sensitive = search(SearchQuery("x", caseSensitive = true, regex = true)).arguments()
        assertTrue("--case-sensitive" in sensitive)
        assertFalse("--fixed-strings" in sensitive)
    }

    @Test
    fun filesArriveWithTheirLinesAndUtf16Columns() {
        val rg = search()
        rg.line(begin("src/a.js"))
        // "é" is two UTF-8 bytes and one UTF-16 unit; "😀" four bytes and two units.
        rg.line(match("src/a.js", 3, "é😀 greet\n", 7 to 12))
        rg.line(match("src/a.js", 9, "greet greet\r\n", 0 to 5, 6 to 11))
        rg.line(end("src/a.js"))
        rg.line(summaryLine(12))
        val summary = rg.summary(result(0), cancelled = false)
        val file = batches.flatten().single()
        assertEquals("src/a.js", file.path)
        val first = file.lines[0]
        assertEquals(3, first.line)
        assertEquals(5, first.column)
        assertEquals("é😀 greet", first.preview)
        assertEquals(listOf(4, 9), first.ranges)
        val second = file.lines[1]
        assertEquals("greet greet", second.preview)
        assertEquals(listOf(0, 5, 6, 11), second.ranges)
        assertEquals(2, second.matches)
        assertEquals(SearchOutcome.DONE, summary.outcome)
        assertEquals(SearchEngine.RIPGREP, summary.engine)
        assertNull("ripgrep's summary counts only what it printed", summary.filesSearched)
        assertEquals(1, summary.filesMatched)
        assertEquals(3, summary.matches)
    }

    @Test
    fun aByteOrderMarkOnTheFirstLineIsNotAColumn() {
        val rg = search()
        rg.line(begin("bom.txt"))
        rg.line(match("bom.txt", 1, "\uFEFFgreet\n", 3 to 8))
        rg.line(end("bom.txt"))
        rg.summary(result(0), cancelled = false)
        val line = batches.flatten().single().lines.single()
        assertEquals("greet", line.preview)
        assertEquals(1, line.column)
        assertEquals(listOf(0, 5), line.ranges)
    }

    @Test
    fun binaryAndNonUtf8FilesAreDroppedWhole() {
        val rg = search()
        rg.line(begin("bin.dat"))
        rg.line(match("bin.dat", 1, "greet\n", 0 to 5))
        rg.line(end("bin.dat", binaryOffset = 4096))
        rg.line(begin("latin1.txt"))
        rg.line(match("latin1.txt", 1, "greet\n", 0 to 5))
        rg.line("{\"type\":\"match\",\"data\":{\"path\":${path("latin1.txt")},\"lines\":{\"bytes\":\"Z3JlZXTp\"},\"line_number\":2,\"absolute_offset\":6,\"submatches\":[{\"match\":{\"text\":\"greet\"},\"start\":0,\"end\":5}]}}")
        rg.line(end("latin1.txt"))
        rg.line(begin("ok.txt"))
        rg.line(match("ok.txt", 1, "greet\n", 0 to 5))
        rg.line(end("ok.txt"))
        val summary = rg.summary(result(0), cancelled = false)
        assertEquals(listOf("ok.txt"), batches.flatten().map { it.path })
        assertEquals(1, summary.skippedBinary)
        assertEquals(1, summary.skippedNotText)
    }

    @Test
    fun theCapStopsRipgrepAndSaysLimit() {
        val rg = search(maxLines = 2)
        assertTrue(rg.line(begin("a")))
        assertTrue(rg.line(match("a", 1, "greet\n", 0 to 5)))
        assertTrue(rg.line(match("a", 2, "greet\n", 0 to 5)))
        assertFalse("full: stop ripgrep", rg.line(end("a")))
        val summary = rg.summary(result(null, failure = CommandFailure.ENDED), cancelled = false)
        assertEquals(SearchOutcome.LIMIT, summary.outcome)
        assertEquals(2, summary.lines)
    }

    @Test
    fun aCancelStopsAtTheNextLine() {
        val rg = search()
        assertTrue(rg.line(begin("a")))
        cancelled = true
        assertFalse(rg.line(match("a", 1, "greet\n", 0 to 5)))
        val summary = rg.summary(result(null, failure = CommandFailure.ENDED), cancelled = true)
        assertEquals(SearchOutcome.CANCELLED, summary.outcome)
    }

    @Test
    fun ripgrepsOwnWordsForAPatternItRefuses() {
        val stderr = "rg: regex parse error:\n    (?<=a)b\n    ^^^^^^\nerror: look-around, including look-ahead and look-behind, is not supported\n"
        val summary = search(SearchQuery("(?<=a)b", regex = true)).summary(result(2, stderr), cancelled = false)
        assertEquals(SearchOutcome.FAILED, summary.outcome)
        assertEquals(SearchFailure.BAD_QUERY, summary.failure)
        assertEquals(
            "Not a valid regular expression for ripgrep: look-around, including look-ahead and look-behind, is not supported",
            summary.detail,
        )
    }

    @Test
    fun unreadableFilesAreCountedAndTheSearchStillCounts() {
        val stderr = "rg: ./secret: Permission denied (os error 13)\n"
        val summary = search().summary(result(2, stderr), cancelled = false)
        assertEquals(SearchOutcome.DONE, summary.outcome)
        assertEquals(1, summary.unreadable)
        assertEquals("secret: Permission denied (os error 13)", summary.detail)
        val timedOut = search().summary(result(null, failure = CommandFailure.TIMED_OUT), cancelled = false)
        assertEquals(SearchFailure.TIMED_OUT, timedOut.failure)
        val missing = search().summary(result(null, failure = CommandFailure.NOT_FOUND), cancelled = false)
        assertEquals(SearchFailure.FAILED, missing.failure)
    }

    @Test
    fun anOverlongLineIsCountedAndTheRestGoesOn() {
        val rg = search()
        rg.line(begin("min.js"))
        rg.overlong()
        rg.line(match("min.js", 2, "greet\n", 0 to 5))
        rg.line(end("min.js"))
        val summary = rg.summary(result(0), cancelled = false)
        assertEquals(1, summary.skippedLongLines)
        assertEquals(1, batches.flatten().single().lines.size)
    }

    @Test
    fun utf8OffsetsBecomeUtf16Indexes() {
        val text = "aé😀b"
        // Bytes: a=1, é=2, 😀=4, b=1.
        val out = RipgrepSearch.utf16Offsets(text, intArrayOf(0, 1, 3, 7, 8, 99))
        assertEquals(listOf(0, 1, 2, 4, 5, 5), out.toList())
    }

    @Test
    fun miniJsonReadsWhatRipgrepWrites() {
        val parsed = MiniJson.parse("{\"a\":[1,-2.5e1,true,false,null],\"s\":\"q\\\"\\\\\\/\\b\\f\\n\\r\\t\\u00e9\\ud83d\\ude00\",\"o\":{}}") as Map<*, *>
        assertEquals(listOf(1L, -25.0, true, false, null), parsed["a"])
        assertEquals("q\"\\/\b\u000C\n\r\té😀", parsed["s"])
        assertEquals(emptyMap<String, Any?>(), parsed["o"])
        assertNull(MiniJson.parse("null"))
        for (bad in listOf("", "{", "{\"a\":}", "[1,]", "\"open", "{} x", "tru")) {
            try {
                MiniJson.parse(bad)
                fail("accepted $bad")
            } catch (expected: IllegalArgumentException) {
                // Refused, as it must be.
            }
        }
    }
}
