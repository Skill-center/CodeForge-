package dev.codeforge.app.git

import dev.codeforge.app.runtime.CommandRunner
import dev.codeforge.app.runtime.CommandRunnerTest
import dev.codeforge.app.runtime.RuntimeEnvironment
import dev.codeforge.app.runtime.SessionRegistry
import dev.codeforge.app.runtime.TestPayload
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The Git host's runner with real processes (Phase 7 W2, gate G2): the
 * runner, CommandRunner and the launcher together on the machine that runs
 * the tests, with the machine's git linked into a runtime's bin, as
 * CommandRunnerTest does with sh. Where a test needs git to hang or to
 * write a lot, a stub script stands in for it. GitHostTest runs the same
 * through the host on Android, with the runtime's own git.
 *
 * Every test checks that no process it started is left.
 */
class GitRunnerTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var environment: RuntimeEnvironment
    private lateinit var commands: CommandRunner
    private lateinit var projects: File
    private lateinit var project: File
    private lateinit var pool: ExecutorService
    private lateinit var marker: String
    private val ids = AtomicLong()

    @Before
    fun setUp() {
        // On CI a missing compiler or git is a failure, so these tests never pass by being skipped.
        if (System.getenv("CI") == "true") {
            assertNotNull("no C compiler on CI for the launcher", launcher)
            assertNotNull("no git on CI", GIT)
        }
        assumeTrue("no C compiler here for the launcher", launcher != null)
        assumeTrue("no git here", GIT != null)
        val root = temp.newFolder("harness")
        environment = RuntimeEnvironment(TestPayload.configFor(root, temp.newFolder("lib")), mapOf("ANDROID_ROOT" to "/system"))
        environment.bin.mkdirs()
        Files.createSymbolicLink(File(environment.bin, "git").toPath(), GIT!!.toPath())
        Files.createSymbolicLink(File(environment.bin, "sleep").toPath(), SLEEP.toPath())
        val sessions = SessionRegistry(killGroup = { group -> CommandRunnerTest.killGroup(group) }, graceMs = 300L)
        commands = CommandRunner(environment, launcher!!, sessions, File(root, "codeforge/sessions"))
        projects = temp.newFolder("workspaces")
        project = File(projects, "demo").apply { mkdirs() }
        pool = Executors.newCachedThreadPool()
        marker = "%d.%04d".format(60 + serial.incrementAndGet(), CommandRunnerTest.selfPid() % 10000)
    }

    @After
    fun noProcessIsLeft() {
        if (!::marker.isInitialized) return
        pool.shutdownNow()
        var left = CommandRunnerTest.processesWith(marker)
        val deadline = System.nanoTime() + 2_000_000_000L
        while (left.isNotEmpty() && System.nanoTime() < deadline) {
            Thread.sleep(50)
            left = CommandRunnerTest.processesWith(marker)
        }
        for (pid in left) ProcessBuilder("kill", "-KILL", pid.toString()).start().waitFor(5, TimeUnit.SECONDS)
        assertEquals("processes left behind", emptyList<Long>(), left)
    }

    private fun runner(maxChars: Long = GitRunner.MAX_CHARS, batchRecords: Int = GitRunner.BATCH_RECORDS) = GitRunner(
        processes = { request, sink, maxRecordBytes, separator, started, extraRoots, progress ->
            commands.stream(request, sink, maxRecordBytes, started, extraRoots, separator, progress)
        },
        projects = projects,
        executor = pool,
        maxChars = maxChars,
        batchRecords = batchRecords,
    )

    /** One run's events. */
    private class Recorder : GitListener {
        val records = CopyOnWriteArrayList<String>()
        val batches = CopyOnWriteArrayList<Int>()
        val progress = CopyOnWriteArrayList<Pair<String, Boolean>>()
        val exits = LinkedBlockingQueue<GitExit>()

        @Volatile
        var outputAfterExit = false

        override fun output(runId: Long, records: List<String>) {
            if (exits.isNotEmpty()) outputAfterExit = true
            this.records.addAll(records)
            batches.add(records.size)
        }

        override fun progress(runId: Long, text: String, closing: Boolean) {
            progress.add(text to closing)
        }

        override fun exited(exit: GitExit) {
            exits.add(exit)
        }

        fun exit(): GitExit = exits.poll(60, TimeUnit.SECONDS) ?: throw AssertionError("no exit within a minute")
    }

    /** Runs git through [runner] to its exit. */
    private fun git(
        runner: GitRunner,
        operation: String,
        vararg arguments: String,
        project: String? = "demo",
        maxRecords: Int? = null,
    ): Pair<Recorder, GitExit> {
        val recorder = Recorder()
        val refused = runner.start(ids.incrementAndGet(), project, operation, arguments.toList(), maxRecords, recorder)
        assertNull(refused?.message, refused)
        val exit = recorder.exit()
        assertFalse("records after the exit", recorder.outputAfterExit)
        return recorder to exit
    }

    private fun ok(result: Pair<Recorder, GitExit>): Recorder {
        val (recorder, exit) = result
        assertNull("${exit.operation}: ${exit.detail} ${exit.stderr}", exit.failure)
        assertEquals("${exit.operation}: ${exit.stderr}", 0, exit.exitCode)
        return recorder
    }

    /** A repository with an identity in the runtime's home. */
    private fun repository(runner: GitRunner) {
        ok(git(runner, "init", "-q", "--initial-branch=main"))
        ok(git(runner, "config", "--global", "user.name", "Ada Lovelace", project = null))
        ok(git(runner, "config", "--global", "user.email", "ada@example.com", project = null))
    }

    /** git replaced by a script that runs [script] whatever it is asked. */
    private fun stubGit(script: String) {
        val git = File(environment.bin, "git")
        git.delete()
        git.writeText("#!/bin/sh\n$script\n")
        assertTrue(git.setExecutable(true))
    }

    @Test
    fun aRepositoryIsMadeAndItsStatusComesBackAsRecords() {
        val runner = runner()
        repository(runner)
        File(project, "a.txt").writeText("hello\n")
        File(project, "new\nline.txt").writeText("n\n")
        val status = ok(git(runner, "status", "--branch", "--untracked-files=all"))
        assertTrue(status.records.toString(), status.records.contains("# branch.oid (initial)"))
        assertTrue(status.records.toString(), status.records.contains("# branch.head main"))
        // NUL-separated: a name with a newline is one record, unquoted.
        assertTrue(status.records.toString(), status.records.containsAll(listOf("? a.txt", "? new\nline.txt")))
        assertEquals("the identity is in the runtime's home", true, File(environment.home, ".gitconfig").readText().contains("Ada Lovelace"))
    }

    @Test
    fun aCommitIsMadeAndReadBack() {
        val runner = runner()
        repository(runner)
        File(project, "a.txt").writeText("hello\n")
        ok(git(runner, "add", "-A"))
        ok(git(runner, "commit", "-q", "-m", "first"))
        assertEquals(listOf("Ada Lovelace\u001ffirst"), ok(git(runner, "log", "-n", "1", "--format=%an%x1f%s")).records)
        val status = ok(git(runner, "status", "--branch"))
        assertEquals(2, status.records.size)
        assertTrue(status.records[0], Regex("# branch\\.oid [0-9a-f]{40}").matches(status.records[0]))
        assertEquals("# branch.head main", status.records[1])
        assertEquals(listOf("hello\n"), ok(git(runner, "cat-file", "blob", "HEAD:a.txt")).records)
        val head = ok(git(runner, "rev-parse", "--verify", "-q", "HEAD")).records
        assertEquals(1, head.size)
        assertTrue(head[0], Regex("[0-9a-f]{40}").matches(head[0]))
        // Staged, then unstaged again.
        File(project, "a.txt").writeText("changed\n")
        ok(git(runner, "add", "--", "a.txt"))
        assertEquals(listOf("1 M. N... 100644 100644 100644"), ok(git(runner, "status")).records.map { it.split(' ').take(6).joinToString(" ") })
        ok(git(runner, "restore", "--staged", "--", "a.txt"))
        assertEquals(listOf("1 .M N... 100644 100644 100644"), ok(git(runner, "status")).records.map { it.split(' ').take(6).joinToString(" ") })
    }

    @Test
    fun aFolderThatIsNoRepositorySaysSoAndNothingAboveIsFound() {
        // The projects' folder holds a repository of its own: a project must not take it for its own.
        ProcessBuilder(GIT!!.path, "init", "-q", projects.path).start().waitFor(30, TimeUnit.SECONDS)
        val (_, exit) = git(runner(), "status")
        assertNull(exit.failure)
        assertEquals(128, exit.exitCode)
        assertTrue(exit.stderr, exit.stderr.contains("not a git repository"))
    }

    @Test
    fun theRepositorysOwnConfigurationRunsNothing() {
        val runner = runner()
        repository(runner)
        File(project, "a.txt").writeText("one\n")
        ok(git(runner, "add", "-A"))
        ok(git(runner, "commit", "-q", "-m", "one"))
        val ran = File(environment.home, "ran")
        val hook = File(temp.root, "hook.sh")
        hook.writeText("#!/bin/sh\necho \"\$0\" >> '${ran.absolutePath}'\nexit 0\n")
        assertTrue(hook.setExecutable(true))
        File(project, ".git/config").appendText(
            "[core]\n\tfsmonitor = ${hook.absolutePath}\n\tpager = ${hook.absolutePath}\n[diff]\n\texternal = ${hook.absolutePath}\n",
        )
        File(project, "a.txt").writeText("two\n")
        ok(git(runner, "status"))
        ok(git(runner, "diff"))
        ok(git(runner, "log", "-n", "1"))
        assertFalse("a program the repository named ran", ran.exists())
        // Plain git, with the same configuration, runs it: the settings are what kept it out.
        val control = ProcessBuilder(GIT!!.path, "diff").directory(project)
        control.environment()["HOME"] = environment.home.path
        control.environment()["GIT_CONFIG_NOSYSTEM"] = "1"
        control.start().waitFor(30, TimeUnit.SECONDS)
        assertTrue("plain git runs a repository's diff.external", ran.exists())
    }

    @Test
    fun projectsAndOptionsAreCheckedBeforeAnythingRuns() {
        val runner = runner()
        val recorder = Recorder()
        fun refused(project: String?, operation: String, vararg arguments: String): GitFailure? =
            runner.start(ids.incrementAndGet(), project, operation, arguments.toList(), null, recorder)?.failure
        val outside = temp.newFolder("elsewhere")
        Files.createSymbolicLink(File(projects, "link").toPath(), outside.toPath())
        assertEquals(GitFailure.BAD_REQUEST, refused("..", "status"))
        assertEquals(GitFailure.BAD_REQUEST, refused("a/b", "status"))
        assertEquals(GitFailure.BAD_REQUEST, refused("", "status"))
        assertEquals(GitFailure.NO_SUCH_PROJECT, refused("missing", "status"))
        assertEquals("a link out of the projects' folder", GitFailure.BAD_REQUEST, refused("link", "status"))
        assertEquals("status runs in a project", GitFailure.BAD_REQUEST, refused(null, "status"))
        assertEquals("the identity is not a project's", GitFailure.BAD_REQUEST, refused("demo", "config", "--global", "user.name", "x"))
        assertEquals(GitFailure.REFUSED, refused("demo", "status", "--git-dir=/tmp"))
        assertEquals(GitFailure.REFUSED, refused("demo", "gc"))
        assertEquals(GitFailure.BAD_REQUEST, refused("demo", "add", "--", "../outside.txt"))
        Thread.sleep(200)
        assertTrue("nothing ran", recorder.records.isEmpty() && recorder.exits.isEmpty())
        assertEquals(0, runner.runningCount())
    }

    @Test
    fun oneChangeAtATimePerRepositoryWhileReadsRunAlongside() {
        stubGit("exec sleep $marker")
        val runner = runner()
        File(projects, "other").mkdirs()
        val first = Recorder()
        assertNull(runner.start(1, "demo", "add", listOf("-A"), null, first))
        assertEquals(GitFailure.BUSY, runner.start(2, "demo", "commit", listOf("-m", "x"), null, Recorder())?.failure)
        val read = Recorder()
        assertNull("a read runs alongside a change", runner.start(3, "demo", "status", emptyList(), null, read))
        val elsewhere = Recorder()
        assertNull("another repository's change runs", runner.start(4, "other", "add", listOf("-A"), null, elsewhere))
        assertEquals("a run's id is its own", GitFailure.BAD_REQUEST, runner.start(1, "demo", "status", emptyList(), null, Recorder())?.failure)
        assertTrue(runner.stop(1))
        val stopped = first.exit()
        assertEquals(GitFailure.STOPPED, stopped.failure)
        assertNull(stopped.exitCode)
        // The change has exited: the repository takes the next.
        val next = Recorder()
        assertNull(runner.start(5, "demo", "commit", listOf("-m", "x"), null, next))
        runner.stopAll()
        for (recorder in listOf(read, elsewhere, next)) assertEquals(GitFailure.STOPPED, recorder.exit().failure)
        assertEquals(0, runner.runningCount())
        assertFalse("nothing left to stop", runner.stop(1))
    }

    @Test
    fun runsPastTheCapAreRefused() {
        stubGit("exec sleep $marker")
        val runner = runner()
        val recorders = List(GitRunner.MAX_RUNNING) { Recorder() }
        recorders.forEachIndexed { index, recorder -> assertNull(runner.start(100L + index, "demo", "status", emptyList(), null, recorder)) }
        assertEquals(GitFailure.BUSY, runner.start(200, "demo", "status", emptyList(), null, Recorder())?.failure)
        runner.stopAll()
        for (recorder in recorders) assertEquals(GitFailure.STOPPED, recorder.exit().failure)
    }

    @Test
    fun recordsArriveInBatchesBeforeTheExit() {
        stubGit("i=0; while [ \$i -lt 5000 ]; do printf 'r%d\\000' \$i; i=\$((i + 1)); done")
        val (recorder, exit) = git(runner(batchRecords = 2000), "status")
        assertEquals(0, exit.exitCode)
        assertEquals(listOf(2000, 2000, 1000), recorder.batches)
        assertEquals((0 until 5000).map { "r$it" }, recorder.records)
        assertEquals(5000, exit.records)
        assertFalse(exit.truncated)
    }

    @Test
    fun theCapsEndARunAsTruncatedNotFailed() {
        stubGit("i=0; while [ \$i -lt 5000 ]; do printf 'r%d\\000' \$i; i=\$((i + 1)); done; exec sleep $marker")
        val (byRecords, recordsExit) = git(runner(), "status", maxRecords = 100)
        assertEquals((0 until 100).map { "r$it" }, byRecords.records)
        assertTrue(recordsExit.truncated)
        assertNull(recordsExit.failure)
        assertNull(recordsExit.exitCode)

        val (byChars, charsExit) = git(runner(maxChars = 1000), "status")
        assertTrue(charsExit.truncated)
        assertNull(charsExit.failure)
        assertTrue(charsExit.chars <= 1000)
        assertEquals(charsExit.records, byChars.records.size)
    }

    @Test
    fun aWholeOutputOverItsLimitIsTooLarge() {
        // 5,000,000 bytes, over the 4 MiB a file's text may be.
        stubGit("s=\$(printf '%01000d' 0); i=0; while [ \$i -lt 5000 ]; do printf %s \"\$s\"; i=\$((i + 1)); done")
        val (recorder, exit) = git(runner(), "cat-file", "blob", "HEAD:big.bin")
        assertEquals(GitFailure.TOO_LARGE, exit.failure)
        assertTrue(recorder.records.isEmpty())
    }

    @Test
    fun progressIsThrottledAndItsClosingLinePasses() {
        stubGit(
            "i=0; while [ \$i -lt 500 ]; do printf 'Updating files: %d%%\\r' \$i >&2; i=\$((i + 1)); done; " +
                "printf 'Updating files: 100%%, done.\\n' >&2; printf 'Switched to branch x\\n' >&2",
        )
        val (recorder, exit) = git(runner(), "switch", "--progress", "x")
        assertEquals(0, exit.exitCode)
        assertEquals("Updating files: 0%" to false, recorder.progress.first())
        assertEquals("Updating files: 100%, done." to true, recorder.progress.last())
        assertTrue("throttled: ${recorder.progress.size}", recorder.progress.size < 100)
        assertEquals("Switched to branch x\n", exit.stderr)
    }

    companion object {
        private val GIT: File? = listOf(File("/usr/bin/git"), File("/bin/git"), File("/usr/local/bin/git")).firstOrNull { it.canExecute() }
        private val SLEEP = listOf(File("/bin/sleep"), File("/usr/bin/sleep")).firstOrNull { it.exists() } ?: File("/bin/sleep")
        private val serial = AtomicInteger(500)

        /** The launcher, compiled once for the class; null without a compiler. */
        private var launcher: File? = null

        @BeforeClass
        @JvmStatic
        fun compileTheLauncher() {
            val source = generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
                .map { File(it, "native/runtime-core/src/main/jni/codeforge-spawn.c") }
                .firstOrNull { it.isFile } ?: return
            val compiler = listOf("cc", "gcc", "clang").firstOrNull { name ->
                System.getenv("PATH").orEmpty().split(File.pathSeparator).any { File(it, name).canExecute() }
            } ?: return
            val output = Files.createTempDirectory("codeforge-spawn").toFile().resolve("codeforge-spawn")
            val process = ProcessBuilder(compiler, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-o", output.absolutePath, source.absolutePath)
                .redirectErrorStream(true)
                .start()
            val log = process.inputStream.bufferedReader().readText()
            if (!process.waitFor(120, TimeUnit.SECONDS) || process.exitValue() != 0 || !output.canExecute()) {
                throw AssertionError("the launcher did not compile:\n$log")
            }
            launcher = output
        }
    }
}
