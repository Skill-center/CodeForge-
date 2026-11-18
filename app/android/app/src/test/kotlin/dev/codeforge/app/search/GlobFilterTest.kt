package dev.codeforge.app.search

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** ripgrep's `-g` rules for the scan (Phase 4 W6; ripgrep's overrides.rs). */
class GlobFilterTest {
    private fun file(filter: GlobFilter, path: String) = filter.accepts(path, path.substringAfterLast('/'), false)

    private fun folder(filter: GlobFilter, path: String) = filter.accepts(path, path.substringAfterLast('/'), true)

    @Test
    fun aGlobWithoutASlashMatchesANameAtAnyDepth() {
        val f = GlobFilter(listOf("*.js"), emptyList())
        assertTrue(file(f, "main.js"))
        assertTrue(file(f, "src/deep/x.js"))
        assertFalse(file(f, "src/x.ts"))
        assertTrue("includes never keep a walk out of a folder", folder(f, "src"))
    }

    @Test
    fun aGlobWithASlashMatchesFromTheTop() {
        val f = GlobFilter(listOf("src/*.js"), emptyList())
        assertTrue(file(f, "src/a.js"))
        assertFalse("a star stops at a slash", file(f, "src/lib/a.js"))
        assertFalse(file(f, "other/src/a.js"))
        val deep = GlobFilter(listOf("src/**/*.js"), emptyList())
        assertTrue(file(deep, "src/a.js"))
        assertTrue(file(deep, "src/lib/x/a.js"))
        val anchored = GlobFilter(listOf("/main.js"), emptyList())
        assertTrue(file(anchored, "main.js"))
        assertFalse(file(anchored, "src/main.js"))
    }

    @Test
    fun excludesLeaveFilesAndWholeFoldersOut() {
        val f = GlobFilter(emptyList(), listOf("dist", "*.min.js", "build/"))
        assertFalse(folder(f, "dist"))
        assertFalse(folder(f, "web/dist"))
        assertFalse(file(f, "app.min.js"))
        assertTrue(file(f, "app.js"))
        assertFalse("a trailing slash is for folders", folder(f, "build"))
        assertTrue(file(f, "build"))
    }

    @Test
    fun theLastGlobThatMatchesDecides() {
        val f = GlobFilter(listOf("*.js"), listOf("vendor.js"))
        assertTrue(file(f, "app.js"))
        assertFalse(file(f, "lib/vendor.js"))
        assertFalse("with includes, a file that matches none is out", file(f, "README.md"))
    }

    @Test
    fun classesAlternativesAndEscapes() {
        val f = GlobFilter(listOf("*.{ts,tsx}", "file[0-9].txt", "[!a]*.md", "lit\\*.c"), emptyList())
        assertTrue(file(f, "a.ts"))
        assertTrue(file(f, "a.tsx"))
        assertFalse(file(f, "a.tsj"))
        assertTrue(file(f, "file7.txt"))
        assertFalse(file(f, "filex.txt"))
        assertTrue(file(f, "b.md"))
        assertFalse(file(f, "a.md"))
        assertTrue(file(f, "lit*.c"))
        assertFalse(file(f, "litx.c"))
    }

    @Test
    fun aPlainNameAlsoMeansEverythingInsideIt() {
        assertEquals(listOf("src", "**/src/**", "*.js", "a/b", "a/b/**"), GlobFilter.expand(listOf(" src ", "", "*.js", "a/b")))
        val f = GlobFilter(GlobFilter.expand(listOf("src")), emptyList())
        assertTrue(file(f, "src/a.js"))
        assertTrue(file(f, "web/src/deep/a.js"))
        assertFalse(file(f, "lib/a.js"))
    }

    @Test
    fun aBraceThatNeverClosesIsRefusedWithTheGlob() {
        try {
            GlobFilter(listOf("*.{js"), emptyList())
            fail("an unclosed brace was accepted")
        } catch (bad: IllegalArgumentException) {
            assertTrue(bad.message!!.contains("*.{js"))
        }
    }
}
