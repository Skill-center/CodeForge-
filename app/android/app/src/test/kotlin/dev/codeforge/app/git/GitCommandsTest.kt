package dev.codeforge.app.git

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the Git host lets Dart run (Phase 7 W2, PHASE_7_PLAN W2): the listed
 * operations and options only, every command behind the same fixed
 * settings, paths that stay in the project and out of `.git`, and nothing
 * that would run a program a repository or a request names.
 */
class GitCommandsTest {
    private fun refusal(operation: String, arguments: List<String>): GitFailure =
        assertThrows(GitRefused::class.java) { GitCommands.build(operation, arguments) }.failure

    @Test
    fun everyCommandStartsWithTheFixedSettingsBeforeItsOperation() {
        val status = GitCommands.build("status", listOf("--branch", "--untracked-files=all"))
        val at = status.arguments.indexOf("status")
        assertEquals(
            listOf("--no-pager", "--literal-pathspecs", "--no-optional-locks") + GitCommands.SETTINGS,
            status.arguments.subList(0, at),
        )
        assertEquals(
            listOf("status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"),
            status.arguments.subList(at, status.arguments.size),
        )
        assertEquals(GitAccess.READ, status.access)
        assertEquals(GitOutput.RECORDS, status.output)
        assertEquals(GitPlace.PROJECT, status.place)
    }

    @Test
    fun aChangeMayTakeTheIndexLockAndAReadNever() {
        val add = GitCommands.build("add", listOf("--", "a.txt"))
        assertEquals(GitAccess.WRITE, add.access)
        assertFalse(add.arguments.contains(GitCommands.NO_OPTIONAL_LOCKS))
        assertEquals(GitCommands.WRITE_TIMEOUT_MS, add.timeoutMs)
        val log = GitCommands.build("log", listOf("-n", "100"))
        assertTrue(log.arguments.contains(GitCommands.NO_OPTIONAL_LOCKS))
        assertEquals(GitCommands.READ_TIMEOUT_MS, log.timeoutMs)
    }

    @Test
    fun theSettingsShutWhatARepositoryCouldMakeGitRun() {
        val values = GitCommands.SETTINGS.chunked(2).map { (flag, value) ->
            assertEquals("-c", flag)
            value
        }
        assertTrue(
            values.containsAll(
                listOf(
                    "core.fsmonitor=false", "protocol.ext.allow=never", "core.pager=cat", "color.ui=false",
                    "core.quotePath=false", "credential.helper=", "gc.autoDetach=false",
                ),
            ),
        )
        val variables = GitCommands.variables(File("/data/projects"))
        assertEquals("0", variables["GIT_TERMINAL_PROMPT"])
        assertEquals("1", variables["GIT_CONFIG_NOSYSTEM"])
        assertEquals(":", variables["GIT_EDITOR"])
        assertEquals("/data/projects", variables["GIT_CEILING_DIRECTORIES"])
        assertNull(GitCommands.variables(null)["GIT_CEILING_DIRECTORIES"])
    }

    @Test
    fun onlyTheListedOperationsRun() {
        val unlisted = listOf(
            "clone", "fetch", "push", "pull", "remote", "gc", "submodule", "filter-branch", "daemon", "upload-pack",
            "credential", "difftool", "mergetool", "bisect", "stash", "rebase", "tag", "blame", "archive", "-c",
            "--exec-path", "!sh", "",
        )
        for (operation in unlisted) assertEquals(operation, GitFailure.REFUSED, refusal(operation, emptyList()))
        assertTrue(GitCommands.OPERATIONS.containsAll(setOf("status", "add", "commit", "log", "diff", "branch", "switch", "init", "config")))
    }

    @Test
    fun optionsThatRunProgramsOrMoveGitAreRefused() {
        val refused = listOf(
            "status" to listOf("-c", "core.fsmonitor=evil"),
            "status" to listOf("--config-env=core.pager=X"),
            "status" to listOf("--exec-path=/tmp"),
            "status" to listOf("--git-dir=/tmp"),
            "status" to listOf("--work-tree=/tmp"),
            "log" to listOf("--upload-pack=evil"),
            "log" to listOf("-p"),
            "log" to listOf("--output=/tmp/x"),
            "diff" to listOf("--ext-diff"),
            "diff" to listOf("--textconv"),
            "diff" to listOf("--output=/tmp/x"),
            "show" to listOf("--textconv", "HEAD:a"),
            "show" to listOf("--ext-diff", "HEAD"),
            "show" to listOf("--output=/tmp/x", "HEAD"),
            "cat-file" to listOf("--filters", "HEAD:a"),
            "cat-file" to listOf("--textconv", "HEAD:a"),
            "commit" to listOf("-m", "x", "--gpg-sign"),
            "commit" to listOf("--template=/etc/passwd"),
            "commit" to listOf("-F", "/etc/passwd"),
            "switch" to listOf("-c", "b"),
            "merge" to listOf("-s", "ours"),
            "init" to listOf("--template=/tmp"),
            "init" to listOf("--separate-git-dir=/tmp"),
            "rev-parse" to listOf("--git-dir"),
            "rev-parse" to listOf("--show-toplevel"),
            "log" to listOf("--format=%G?"),
            "for-each-ref" to listOf("--format=%(signature)"),
        )
        for ((operation, arguments) in refused) {
            assertEquals("$operation $arguments", GitFailure.REFUSED, refusal(operation, arguments))
        }
    }

    @Test
    fun aRefusalNeverRepeatsAValueItWasSent() {
        val token = "ghp_0123456789abcdefghijklmnopqrstuvwxyz"
        for ((operation, arguments) in listOf(
            "status" to listOf("--upload-pack=$token"),
            "clone" to listOf("https://user:$token@example.com/r.git"),
            "https://$token@example.com" to emptyList(),
            "for-each-ref" to listOf("--sort=$token!"),
        )) {
            val refused = assertThrows(GitRefused::class.java) { GitCommands.build(operation, arguments) }
            assertFalse(refused.message.orEmpty(), refused.message.orEmpty().contains(token))
        }
    }

    @Test
    fun configReadsAndSetsTheIdentityOnly() {
        assertEquals(GitAccess.READ, GitCommands.build("config", listOf("--global", "--get", "user.name")).access)
        val set = GitCommands.build("config", listOf("--global", "user.email", "ada@example.com"))
        assertEquals(GitAccess.WRITE, set.access)
        assertEquals(GitPlace.HOME, set.place)
        assertEquals(listOf("config", "--global", "user.email", "ada@example.com"), set.arguments.takeLast(4))
        assertEquals(GitAccess.WRITE, GitCommands.build("config", listOf("--global", "--unset", "user.name")).access)
        for (arguments in listOf(
            listOf("--global", "core.sshCommand", "evil"),
            listOf("--global", "--get", "credential.helper"),
            listOf("--global", "include.path", "/x"),
            listOf("--global", "--add", "user.name", "x"),
            listOf("--global", "--unset", "core.editor"),
            listOf("--system", "user.name", "x"),
            listOf("user.name", "x"),
            emptyList(),
        )) {
            assertEquals(arguments.toString(), GitFailure.REFUSED, refusal("config", arguments))
        }
        assertEquals(GitFailure.BAD_REQUEST, refusal("config", listOf("--global", "user.name", "Ada\nLovelace")))
        assertEquals(GitFailure.BAD_REQUEST, refusal("config", listOf("--global", "user.name", " ")))
        assertEquals(GitFailure.BAD_REQUEST, refusal("config", listOf("--global", "user.name", "x".repeat(GitCommands.MAX_IDENTITY + 1))))
    }

    @Test
    fun pathsStayInsideTheProjectAndOutOfGitsOwnFiles() {
        val add = GitCommands.build("add", listOf("--", "src/a.txt", "docs/", "-leading-dash.txt", "with space.txt", "ünïcode.md", ".gitignore"))
        assertEquals(listOf("--", "src/a.txt", "docs/", "-leading-dash.txt", "with space.txt", "ünïcode.md", ".gitignore"), add.arguments.takeLast(7))
        val outside = listOf("/etc/passwd", "../x", "a/../../x", "a/./b", ".git/config", "a/.git/hooks/pre-commit", ".GIT/config", "", "a//b", ".", "..", "a\u0000b")
        for (path in outside) assertEquals(path, GitFailure.BAD_REQUEST, refusal("add", listOf("--", path)))
        assertEquals("commit takes no paths", GitFailure.REFUSED, refusal("commit", listOf("-m", "x", "--", "a")))
        assertEquals("a restore names its paths", GitFailure.BAD_REQUEST, refusal("restore", listOf("--staged")))
        assertEquals("a clean never cleans the whole tree", GitFailure.BAD_REQUEST, refusal("clean", listOf("-f")))
        assertEquals("rm only unstages", GitFailure.BAD_REQUEST, refusal("rm", listOf("--", "a.txt")))
        GitCommands.build("rm", listOf("--cached", "-r", "-q", "--", "a.txt"))
    }

    @Test
    fun revisionsNeverReadAsOptionsAndTheirPathsStayInside() {
        GitCommands.build("cat-file", listOf("blob", "HEAD:src/a.txt"))
        GitCommands.build("cat-file", listOf("blob", ":0:src/a.txt"))
        GitCommands.build("cat-file", listOf("blob", ":src/a.txt"))
        GitCommands.build("log", listOf("main..origin/main"))
        GitCommands.build("diff-tree", listOf("-r", "--root", "--name-status", "-M", "abc123"))
        val show = GitCommands.build("show", listOf("--name-status", "-z", "--format=%H", "HEAD"))
        assertTrue("show never runs textconv", show.arguments.containsAll(listOf("--no-textconv", "--no-ext-diff")))
        assertEquals(GitFailure.BAD_REQUEST, refusal("show", listOf("HEAD:../x")))
        for (option in listOf("--output=/tmp/x", "-n1")) assertEquals(option, GitFailure.REFUSED, refusal("cat-file", listOf("blob", option)))
        for (revision in listOf("HEAD:../x", "HEAD:.git/config", "HEAD:/abs", "a\u0001b", ":/fix", "x".repeat(GitCommands.MAX_REVISION + 1))) {
            assertEquals(revision, GitFailure.BAD_REQUEST, refusal("cat-file", listOf("blob", revision)))
        }
        assertEquals("at most two names", GitFailure.BAD_REQUEST, refusal("log", listOf("a", "b", "c")))
    }

    @Test
    fun valuesAreCheckedForWhatTheyAre() {
        assertEquals(GitFailure.BAD_REQUEST, refusal("log", listOf("-n", "ten")))
        assertEquals(GitFailure.BAD_REQUEST, refusal("log", listOf("-n")))
        assertEquals(GitFailure.BAD_REQUEST, refusal("log", listOf("--max-count=-1")))
        assertEquals(GitFailure.BAD_REQUEST, refusal("commit", listOf("-m", "x".repeat(GitCommands.MAX_MESSAGE + 1))))
        assertEquals(GitFailure.BAD_REQUEST, refusal("for-each-ref", listOf("heads/")))
        assertEquals(GitFailure.BAD_REQUEST, refusal("log", listOf("--format=%H\n%s")))
        assertEquals(GitFailure.BAD_REQUEST, refusal("init", listOf("-b", "bad name")))
        GitCommands.build("for-each-ref", listOf("--format=%(refname)%00%(objectname)", "--sort=-committerdate", "refs/heads/", "refs/remotes/"))
        GitCommands.build("log", listOf("-n", "100", "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s"))
        // A message is a value: it may start with a dash and hold lines.
        GitCommands.build("commit", listOf("-m", "-starts with a dash\n\nand a body"))
        GitCommands.build("init", listOf("-q", "--initial-branch=main"))
    }

    @Test
    fun tooManyOrTooLongArgumentsAreRefused() {
        val many = listOf("--") + List(GitCommands.MAX_ARGUMENTS) { "f$it.txt" }
        assertEquals(GitFailure.BAD_REQUEST, refusal("add", many))
        // 600 paths of about 2,000 characters: each is allowed, together they pass 1 MiB.
        val long = listOf("--") + List(600) { "d/".repeat(1_000) + "f$it" }
        assertEquals(GitFailure.BAD_REQUEST, refusal("add", long))
    }
}
