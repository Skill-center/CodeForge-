package dev.codeforge.app.storage

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The broker's own path and name rules (docs/SECURITY.md §4.1, S1): Kotlin
 * checks every path again, whatever Dart sent.
 */
class StoragePathsTest {
    @Test
    fun acceptsOrdinaryNames() {
        for (name in listOf("main.js", ".gitignore", "a b", "naïve.md", "日本語.txt", "x".repeat(255), "é".repeat(127))) {
            assertNull(name, StoragePaths.nameProblem(name))
        }
    }

    @Test
    fun refusesNamesThatCouldEscapeOrConfuse() {
        val bad = listOf("", ".", "..", "a/b", "/", "a\u0000b", "tab\there", "\u001f", "del\u007f", "x".repeat(256), "é".repeat(128))
        for (name in bad) {
            assertTrue("'$name' must be refused", StoragePaths.nameProblem(name) != null)
            assertFalse(StoragePaths.isValidName(name))
        }
    }

    @Test
    fun parsesPathsIntoNames() {
        assertEquals(emptyList<String>(), StoragePaths.parse(""))
        assertEquals(listOf("src"), StoragePaths.parse("src"))
        assertEquals(listOf("src", "app", "main.js"), StoragePaths.parse("src/app/main.js"))
    }

    @Test
    fun refusesPathsThatEscapeTheFolder() {
        val bad = listOf("..", "../x", "a/../b", "a/./b", "/abs", "a/", "a//b", "a/\u0000", "a/..", ".")
        for (path in bad) {
            try {
                StoragePaths.parse(path)
                fail("'$path' must be refused")
            } catch (error: StorageException) {
                assertEquals(path, StorageProblem.INVALID_PATH, error.problem)
            }
        }
    }

    @Test
    fun refusesPathsTooLongOrTooDeep() {
        for (path in listOf(List(129) { "a" }.joinToString("/"), "a/".repeat(2100) + "a")) {
            try {
                StoragePaths.parse(path)
                fail("must be refused")
            } catch (error: StorageException) {
                assertEquals(StorageProblem.INVALID_PATH, error.problem)
            }
        }
        assertEquals(128, StoragePaths.parse(List(128) { "a" }.joinToString("/")).size)
    }

    @Test
    fun knowsWhatLiesWithinWhat() {
        assertTrue(StoragePaths.isWithin("a", "a"))
        assertTrue(StoragePaths.isWithin("a/b", "a"))
        assertTrue(StoragePaths.isWithin("anything", ""))
        assertFalse(StoragePaths.isWithin("ab", "a"))
        assertFalse(StoragePaths.isWithin("a", "a/b"))
        assertEquals("a/b", StoragePaths.join("a", "b"))
        assertEquals("b", StoragePaths.join("", "b"))
    }
}
