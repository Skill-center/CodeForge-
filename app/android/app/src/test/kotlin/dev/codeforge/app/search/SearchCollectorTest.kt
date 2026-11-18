package dev.codeforge.app.search

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The collector both engines feed (Phase 4 W6): batches, the cap, and previews. */
class SearchCollectorTest {
    private var now = 0L
    private val batches = mutableListOf<List<SearchFile>>()

    private fun collector(maxLines: Int = 100) = SearchCollector(
        SearchLimits(maxLines = maxLines),
        emit = { batches.add(it) },
        clock = { now },
    )

    private fun line(n: Int) = SearchCollector.lineOf(n, "x$n", intArrayOf(0, 1))

    @Test
    fun theFirstFileGoesAtOnceThenBatchesWaitForTheirTime() {
        val c = collector()
        c.add("a", listOf(line(1)))
        assertEquals(1, batches.size)
        now += 50_000_000L
        c.add("b", listOf(line(1)))
        c.add("c", listOf(line(1)))
        assertEquals("under 100 ms, the files wait", 1, batches.size)
        now += 60_000_000L
        c.poll()
        assertEquals(listOf("b", "c"), batches[1].map { it.path })
        c.add("d", listOf(line(1)))
        c.flush()
        assertEquals(listOf("d"), batches[2].map { it.path })
        assertEquals(4, c.filesMatched)
        assertEquals(0L, c.firstResultMs)
    }

    @Test
    fun theCapKeepsExactlyItsLinesAndStops() {
        val c = collector(maxLines = 3)
        assertTrue(c.add("a", listOf(line(1), line(2))))
        assertFalse(c.add("b", listOf(line(1), line(2), line(3))))
        assertTrue(c.full)
        assertFalse("nothing more once full", c.add("c", listOf(line(1))))
        c.flush()
        val kept = batches.flatten()
        assertEquals(listOf("a", "b"), kept.map { it.path })
        assertEquals(1, kept[1].lines.size)
        assertEquals(3, c.lines)
    }

    @Test
    fun aShortLineIsItsOwnPreview() {
        val l = SearchCollector.lineOf(7, "let x = foo(foo);", intArrayOf(8, 11, 12, 15))
        assertEquals("let x = foo(foo);", l.preview)
        assertEquals(0, l.previewStart)
        assertFalse(l.cutEnd)
        assertEquals(9, l.column)
        assertEquals(listOf(8, 11, 12, 15), l.ranges)
        assertEquals(2, l.matches)
    }

    @Test
    fun aLongLineIsCutAroundItsFirstMatch() {
        val text = "a".repeat(1000) + "NEEDLE" + "b".repeat(1000)
        val l = SearchCollector.lineOf(1, text, intArrayOf(1000, 1006), count = 7)
        assertEquals(1000 - SearchCollector.PREVIEW_BEFORE, l.previewStart)
        assertEquals(SearchCollector.PREVIEW_MAX, l.preview.length)
        assertTrue(l.cutEnd)
        assertEquals(1001, l.column)
        assertEquals(listOf(SearchCollector.PREVIEW_BEFORE, SearchCollector.PREVIEW_BEFORE + 6), l.ranges)
        assertEquals("NEEDLE", l.preview.substring(l.ranges[0], l.ranges[1]))
        assertEquals(7, l.matches)
    }

    @Test
    fun aCutNeverSplitsASurrogatePair() {
        // U+1F600 is two UTF-16 units. Here the cut 40 units before the match
        // would fall on its second half, so it moves back to keep it whole.
        val emoji = "\uD83D\uDE00"
        val before = "x".repeat(300) + emoji + "y".repeat(39) + "Z" + "w".repeat(10)
        val l = SearchCollector.lineOf(1, before, intArrayOf(341, 342))
        assertEquals(300, l.previewStart)
        assertTrue(l.preview.startsWith(emoji))
        assertEquals("Z", l.preview.substring(l.ranges[0], l.ranges[1]))

        // And here the end of the preview would fall between its halves.
        val after = "Z" + "y".repeat(248) + emoji + "w".repeat(300)
        val m = SearchCollector.lineOf(1, after, intArrayOf(0, 1))
        assertEquals(SearchCollector.PREVIEW_MAX - 1, m.preview.length)
        assertFalse(Character.isHighSurrogate(m.preview.last()))
        assertTrue(m.cutEnd)
    }
}
