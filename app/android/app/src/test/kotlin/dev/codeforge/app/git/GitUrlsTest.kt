package dev.codeforge.app.git

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The URLs a clone may take (Phase 7 W3, gate G3), from the fixture Dart's
 * git_urls_test.dart reads too (test/fixtures/git/urls.tsv), so both sides
 * refuse the same URLs; and the clone and remote operations as GitCommands
 * builds them.
 */
class GitUrlsTest {
    private val fixture: File = generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
        .map { File(it, "test/fixtures/git/urls.tsv") }
        .firstOrNull { it.isFile } ?: throw AssertionError("test/fixtures/git/urls.tsv not found")

    @Test
    fun theFixturesUrlsAreAcceptedAndRefusedAsItSays() {
        var accepted = 0
        var refused = 0
        for (line in fixture.readLines(Charsets.UTF_8)) {
            if (line.isEmpty() || line.startsWith("#")) continue
            val (verdict, first, second, url) = line.split('\t', limit = 4)
            when (verdict) {
                "accept" -> {
                    val remote = GitUrls.check(url)
                    assertEquals(url, first, remote.scheme)
                    assertEquals(url, second, remote.host)
                    accepted += 1
                }
                "refuse" -> {
                    val refusal = assertThrows("$first: $url", GitRefused::class.java) { GitUrls.check(url) }
                    assertEquals(GitFailure.BAD_REQUEST, refusal.failure)
                    refused += 1
                }
                else -> throw AssertionError("not a verdict: $line")
            }
        }
        assertTrue(accepted >= 10 && refused >= 20)
    }

    @Test
    fun aRefusalSaysWhyAndNeverRepeatsTheSecret() {
        val token = "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB"
        for (url in listOf("https://ada:$token@github.com/o/r.git", "https://$token@github.com/o/r.git", "https://github.com/o/r.git?t=$token")) {
            val refusal = assertThrows(GitRefused::class.java) { GitUrls.check(url) }
            assertFalse(refusal.message.orEmpty(), refusal.message.orEmpty().contains(token))
            assertTrue(refusal.message.orEmpty(), refusal.message.orEmpty().isNotBlank())
        }
        assertTrue(GitUrls.looksLikeToken("glpat-abc"))
        assertFalse(GitUrls.looksLikeToken("git"))
        assertFalse(GitUrls.looksLikeToken("ada.lovelace.analytical-engine"))
    }

    @Test
    fun cloneTakesOneCheckedUrlAndTheRemotesTakeNamesOnly() {
        val clone = GitCommands.build("clone", listOf("https://github.com/octocat/Hello-World.git"))
        assertEquals(GitPlace.NEW_PROJECT, clone.place)
        assertTrue(clone.network)
        assertEquals(GitAccess.WRITE, clone.access)
        assertEquals(listOf("clone", "--progress", "--", "https://github.com/octocat/Hello-World.git"), clone.arguments.takeLast(4))
        assertTrue("the transports are pinned", clone.arguments.containsAll(GitCommands.NETWORK_SETTINGS))
        for (arguments in listOf(
            emptyList(),
            listOf("https://github.com/o/r.git", "elsewhere"),
            listOf("--upload-pack=evil"),
            listOf("-u", "evil"),
            listOf("file:///data/r.git"),
        )) {
            assertEquals(arguments.toString(), GitFailure.BAD_REQUEST, assertThrows(GitRefused::class.java) { GitCommands.build("clone", arguments) }.failure)
        }

        val push = GitCommands.build("push", listOf("--set-upstream", "origin", "feature/x"))
        assertTrue(push.network)
        assertEquals(listOf("push", "--progress", "--set-upstream", "origin", "feature/x"), push.arguments.takeLast(5))
        val pull = GitCommands.build("pull", listOf("origin", "main"))
        assertEquals(listOf("pull", "--progress", "--no-rebase", "--no-edit", "origin", "main"), pull.arguments.takeLast(6))
        assertNotNull(GitCommands.build("fetch", listOf("--prune", "origin")))
        assertNotNull(GitCommands.build("fetch", emptyList()))

        val refused = listOf(
            "push" to listOf("--force", "origin", "main"),
            "push" to listOf("--force-with-lease", "origin", "main"),
            "push" to listOf("--delete", "origin", "main"),
            "push" to listOf("--mirror"),
            "push" to listOf("--tags"),
            "push" to listOf("--receive-pack=evil", "origin"),
            "push" to listOf("--exec=evil", "origin"),
            "push" to listOf("-u", "origin", "main"),
            "fetch" to listOf("--upload-pack=evil"),
            "fetch" to listOf("--recurse-submodules"),
            "pull" to listOf("--rebase"),
            "pull" to listOf("-s", "ours"),
        )
        for ((operation, arguments) in refused) {
            assertEquals("$operation $arguments", GitFailure.REFUSED, assertThrows(GitRefused::class.java) { GitCommands.build(operation, arguments) }.failure)
        }
        val malformed = listOf(
            "push" to listOf("origin", "main:other"),
            "push" to listOf("origin", ":main"),
            "push" to listOf("https://github.com/o/r.git", "main"),
            "fetch" to listOf("https://github.com/o/r.git"),
            "fetch" to listOf("../elsewhere"),
            "pull" to listOf("origin", "main", "extra"),
            "push" to listOf("origin", "--", "main"),
        )
        for ((operation, arguments) in malformed) {
            assertThrows("$operation $arguments", GitRefused::class.java) { GitCommands.build(operation, arguments) }
        }
    }

    @Test
    fun theHelperGoesAfterTheFixedSettingsAndBeforeTheOperation() {
        val push = GitCommands.build("push", listOf("origin", "main"))
        val helper = listOf("-c", "credential.helper=!bash '/h' '/d'")
        val arguments = GitCommands.withSettings(push, helper)
        val emptied = arguments.indexOf("credential.helper=")
        val ours = arguments.indexOf(helper[1])
        assertTrue("an empty helper first, so no other runs", emptied in 0 until ours)
        assertEquals("push", arguments[ours + 1])
        assertEquals(push.arguments.size + 2, arguments.size)
        val status = GitCommands.build("status", emptyList())
        assertEquals(status.arguments, GitCommands.withSettings(status, emptyList()))
    }
}
