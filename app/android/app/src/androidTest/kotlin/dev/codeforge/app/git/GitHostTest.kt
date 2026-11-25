package dev.codeforge.app.git

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import dev.codeforge.app.runtime.AssetPayloadSource
import dev.codeforge.app.runtime.CommandRequest
import dev.codeforge.app.runtime.RuntimeCommands
import dev.codeforge.app.runtime.SealedRuntime
import dev.codeforge.runtime.core.HarnessConfig
import java.io.File
import java.util.Collections
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters

/**
 * Phase 7 W2, gate G2 (PHASE_7_PLAN §3 W2): the Git host's runner
 * (GitRunner over GitCommands, as GitHost runs it) with the sealed runtime's
 * own git on every target. Over the APK's payload installed into a root of
 * the class's own (files/runtime-gate/githost), with its projects' folder
 * beside it. GitRunnerTest runs the same logic on the JVM with the
 * machine's git.
 *
 *   a. Each operation of the fixed set with the fixed settings, in a project
 *      named by its folder: the identity in the runtime's home, init,
 *      status, add, unstaging before and after the first commit, commit,
 *      log, rev-parse, cat-file from HEAD and the index, diff-tree, a
 *      branch made and switched to, a fast-forward merge, a branch deleted,
 *      for-each-ref, clean, check-ref-format; each output as git gives it.
 *   b. A merge with a conflict: exit 1 and git's CONFLICT line in the
 *      records, the file unmerged in the status, then the merge aborted.
 *   c. What is refused before anything runs (options off the list, paths
 *      and project names that leave the project or the projects' folder),
 *      and a repository above the projects' folder never found.
 *   d. One change at a time per repository: a second is BUSY while the
 *      first runs, a read runs alongside, and the next change runs after.
 *   e. A run stopped as it starts ends STOPPED; a status capped at 100
 *      records ends truncated, not failed (ended at the cap, or exited 0
 *      when git had written everything before the end reached it).
 *   f. 10,000 new files: their status as 10,000 records in five batches,
 *      then added, committed, and the clean status 20 times. Recorded.
 *
 * Every figure goes to the device log (RUNTIME_GATE githost_...) and to
 * files/runtime-gate/githost-report.txt, which the gate copies out.
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class GitHostTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val gate = File(context.filesDir, "runtime-gate")
    private val ids = AtomicLong()

    private fun record(key: String, value: Any?) {
        val line = "githost_$key=$value"
        Log.i(TAG, "RUNTIME_GATE $line")
        gate.mkdirs()
        File(gate, REPORT).appendText(line + "\n")
    }

    /** One run's events. */
    private class Recorder : GitListener {
        val records: MutableList<String> = Collections.synchronizedList(ArrayList())
        val batches: MutableList<Int> = Collections.synchronizedList(ArrayList())
        val progress: MutableList<String> = Collections.synchronizedList(ArrayList())
        val exits = LinkedBlockingQueue<GitExit>()

        override fun output(runId: Long, records: List<String>) {
            this.records.addAll(records)
            batches.add(records.size)
        }

        override fun progress(runId: Long, text: String, closing: Boolean) {
            progress.add(text)
        }

        override fun exited(exit: GitExit) {
            exits.add(exit)
        }

        fun exit(): GitExit = exits.poll(LONG_MS, TimeUnit.MILLISECONDS) ?: throw AssertionError("no exit in time")
    }

    /** git through the runner, to its exit. */
    private fun git(
        operation: String,
        vararg arguments: String,
        project: String? = PROJECT,
        maxRecords: Int? = null,
    ): Pair<Recorder, GitExit> {
        val recorder = Recorder()
        val refused = runner().start(ids.incrementAndGet(), project, operation, arguments.toList(), maxRecords, recorder)
        assertNull("git $operation refused: ${refused?.failure} ${refused?.message}", refused)
        return recorder to recorder.exit()
    }

    /** [ran]'s records; it must have exited 0. */
    private fun ok(ran: Pair<Recorder, GitExit>): List<String> {
        val (recorder, exit) = ran
        assertNull("git ${exit.operation}: ${exit.failure} ${exit.detail} ${exit.stderr}", exit.failure)
        assertEquals("git ${exit.operation}: ${exit.stderr}", 0, exit.exitCode)
        return recorder.records.toList()
    }

    /** The first three fields of each status record: the kind, XY and the submodule field. */
    private fun kinds(records: List<String>): List<String> = records.map { it.split(' ').take(3).joinToString(" ") }

    /** A project's folder, empty. */
    private fun freshProject(name: String): File = File(projects(), name).apply {
        deleteRecursively()
        mkdirs()
    }

    /** A project that is a repository with one commit of [files]. */
    private fun freshRepository(name: String, files: Map<String, String> = mapOf("base.txt" to "base\n")): File {
        val folder = freshProject(name)
        ok(git("init", "-q", "--initial-branch=main", project = name))
        for ((path, text) in files) write(folder, path, text)
        ok(git("add", "-A", project = name))
        ok(git("commit", "-q", "-m", "base", project = name))
        return folder
    }

    private fun write(directory: File, path: String, text: String) {
        File(directory, path).apply {
            parentFile?.mkdirs()
            writeText(text)
        }
    }

    private fun identity() {
        ok(git("config", "--global", "user.name", NAME, project = null))
        ok(git("config", "--global", "user.email", EMAIL, project = null))
    }

    @Test
    fun a_eachOperationRunsWithTheFixedSettings() {
        File(gate, REPORT).delete()
        val started = System.nanoTime()
        identity()
        assertEquals(listOf(NAME), ok(git("config", "--global", "--get", "user.name", project = null)))
        assertTrue("the identity is the runtime home's", File(home(), ".gitconfig").readText().contains(NAME))
        val project = freshProject(PROJECT)
        ok(git("init", "-q", "--initial-branch=main"))
        write(project, "a.txt", "alpha\n")
        write(project, "src/b c.txt", "bravo\n")
        assertEquals(
            listOf("# branch.oid (initial)", "# branch.head main", "? a.txt", "? src/b c.txt"),
            ok(git("status", "--branch", "--untracked-files=all")),
        )
        // Before the first commit there is no HEAD to restore from: unstaging is rm --cached.
        ok(git("add", "--", "a.txt"))
        assertEquals(listOf("1 A. N...", "? src/b c.txt"), kinds(ok(git("status", "--untracked-files=all"))))
        assertEquals("no HEAD before the first commit", 1, git("rev-parse", "--verify", "-q", "HEAD").second.exitCode)
        ok(git("rm", "--cached", "-r", "-q", "--ignore-unmatch", "--", "a.txt"))
        assertEquals(listOf("? a.txt", "? src/b c.txt"), ok(git("status", "--untracked-files=all")))

        ok(git("add", "-A"))
        ok(git("commit", "-q", "-m", "first"))
        val log = ok(git("log", "-n", "10", "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s"))
        assertEquals(1, log.size)
        val fields = log.single().split('\u001f')
        assertEquals(listOf("", NAME, EMAIL, "first"), listOf(fields[1], fields[2], fields[3], fields[5]))
        val first = fields[0]
        assertEquals(listOf(first), ok(git("rev-parse", "--verify", "-q", "HEAD")))
        assertEquals(listOf("alpha\n"), ok(git("cat-file", "blob", "HEAD:a.txt")))
        assertEquals(
            listOf("A", "a.txt", "A", "src/b c.txt"),
            ok(git("diff-tree", "-r", "--root", "--name-status", "-M", "--no-commit-id", first)),
        )

        // A branch: made and switched to, a change staged, unstaged, committed.
        ok(git("switch", "-q", "--create", "topic"))
        write(project, "a.txt", "alpha\nmore\n")
        ok(git("add", "--", "a.txt"))
        assertEquals(listOf("1 M. N..."), kinds(ok(git("status"))))
        ok(git("restore", "--staged", "-q", "--", "a.txt"))
        assertEquals(listOf("1 .M N..."), kinds(ok(git("status"))))
        ok(git("add", "-A"))
        ok(git("commit", "-q", "-m", "second"))
        ok(git("switch", "-q", "main"))
        assertEquals("the index has main's text", listOf("alpha\n"), ok(git("cat-file", "blob", ":a.txt")))
        ok(git("merge", "--no-edit", "--ff-only", "topic"))
        assertEquals("alpha\nmore\n", File(project, "a.txt").readText())
        ok(git("branch", "-d", "-q", "topic"))
        assertEquals(listOf("refs/heads/main\u0000*"), ok(git("for-each-ref", "--format=%(refname)%00%(HEAD)", "refs/heads/")))

        // A new file, discarded; a change, discarded.
        write(project, "scratch.txt", "x\n")
        ok(git("clean", "-f", "-q", "--", "scratch.txt"))
        assertFalse(File(project, "scratch.txt").exists())
        write(project, "a.txt", "changed\n")
        ok(git("restore", "--worktree", "-q", "--", "a.txt"))
        assertEquals("alpha\nmore\n", File(project, "a.txt").readText())
        assertEquals(listOf("# branch.head main"), ok(git("status", "--branch")).filter { it.startsWith("# branch.head") })

        assertEquals(listOf("feature/x"), ok(git("check-ref-format", "--branch", "feature/x", project = null)))
        assertEquals(128, git("check-ref-format", "--branch", "bad..name", project = null).second.exitCode)
        record("operations", "ok ms=${(System.nanoTime() - started) / 1_000_000}")
    }

    @Test
    fun b_aConflictIsReportedAsGitSaysIt() {
        identity()
        val project = freshRepository("conflict", mapOf("f.txt" to "base\n"))
        ok(git("switch", "-q", "--create", "other", project = "conflict"))
        write(project, "f.txt", "theirs\n")
        ok(git("add", "-A", project = "conflict"))
        ok(git("commit", "-q", "-m", "theirs", project = "conflict"))
        ok(git("switch", "-q", "main", project = "conflict"))
        write(project, "f.txt", "ours\n")
        ok(git("add", "-A", project = "conflict"))
        ok(git("commit", "-q", "-m", "ours", project = "conflict"))
        val (merge, exit) = git("merge", "--no-edit", "other", project = "conflict")
        assertNull(exit.failure)
        assertEquals(1, exit.exitCode)
        assertTrue(merge.records.toString(), merge.records.any { it == "CONFLICT (content): Merge conflict in f.txt" })
        val status = ok(git("status", "--branch", project = "conflict"))
        assertTrue(status.toString(), status.any { it.startsWith("u UU ") && it.endsWith(" f.txt") })
        ok(git("merge", "--abort", project = "conflict"))
        assertEquals("ours\n", File(project, "f.txt").readText())
        assertTrue(ok(git("status", project = "conflict")).isEmpty())
        record("conflict", "ok merge_ms=${exit.elapsedMs}")
    }

    @Test
    fun c_whatIsRefusedAndWhereGitLooks() {
        val runner = runner()
        val recorder = Recorder()
        fun refused(project: String?, operation: String, vararg arguments: String): GitFailure? =
            runner.start(ids.incrementAndGet(), project, operation, arguments.toList(), null, recorder)?.failure
        freshProject(PROJECT)
        assertEquals(GitFailure.REFUSED, refused(PROJECT, "status", "--git-dir=/"))
        assertEquals(GitFailure.REFUSED, refused(PROJECT, "log", "--output=/data/local/tmp/x"))
        assertEquals(GitFailure.REFUSED, refused(PROJECT, "diff", "--ext-diff"))
        assertEquals(GitFailure.REFUSED, refused(PROJECT, "push"))
        assertEquals(GitFailure.REFUSED, refused(null, "config", "--global", "core.sshCommand", "x"))
        assertEquals(GitFailure.BAD_REQUEST, refused(PROJECT, "add", "--", "../escape.txt"))
        assertEquals(GitFailure.BAD_REQUEST, refused(PROJECT, "add", "--", ".git/config"))
        assertEquals(GitFailure.BAD_REQUEST, refused("..", "status"))
        assertEquals(GitFailure.NO_SUCH_PROJECT, refused("missing", "status"))
        val outside = File(home(), "outside").apply { mkdirs() }
        val link = File(projects(), "link")
        link.delete()
        Os.symlink(outside.path, link.path)
        assertEquals("a link out of the projects' folder", GitFailure.BAD_REQUEST, refused("link", "status"))
        link.delete()
        Thread.sleep(200)
        assertTrue("nothing ran", recorder.records.isEmpty() && recorder.exits.isEmpty())

        // A repository made above the projects' folder, as the terminal could, claims no project.
        val above = commands().runner.run(
            CommandRequest("git", listOf("init", "-q", projects().path), directory = null, timeoutMs = 60_000L),
        )
        assertTrue("git init above: ${above.stderr.text}", above.succeeded)
        try {
            freshProject("plain")
            val (_, exit) = git("status", project = "plain")
            assertEquals(128, exit.exitCode)
            assertTrue(exit.stderr, exit.stderr.contains("not a git repository"))
        } finally {
            File(projects(), ".git").deleteRecursively()
        }
        record("refusals", "ok")
    }

    @Test
    fun d_oneChangeAtATimePerRepository() {
        identity()
        val project = freshRepository("busy")
        for (i in 0 until 500) write(project, "many/f$i.txt", "$i\n")
        val runner = runner()
        val first = Recorder()
        val firstId = ids.incrementAndGet()
        assertNull(runner.start(firstId, "busy", "add", listOf("-A"), null, first))
        // The first is still starting: the repository is taken.
        val second = runner.start(ids.incrementAndGet(), "busy", "commit", listOf("-q", "-m", "x"), null, Recorder())
        assertEquals(GitFailure.BUSY, second?.failure)
        val read = Recorder()
        assertNull("a read runs alongside", runner.start(ids.incrementAndGet(), "busy", "status", emptyList(), null, read))
        val added = first.exit()
        assertEquals(0, added.exitCode)
        assertNull(read.exit().failure)
        ok(git("commit", "-q", "-m", "many", project = "busy"))
        assertTrue(ok(git("status", project = "busy")).isEmpty())
        record("busy", "ok add_ms=${added.elapsedMs}")
    }

    @Test
    fun e_aStopAndTheCap() {
        identity()
        freshRepository("stop")
        val runner = runner()
        val recorder = Recorder()
        val id = ids.incrementAndGet()
        assertNull(runner.start(id, "stop", "log", listOf("-n", "1"), null, recorder))
        assertTrue("it runs", runner.stop(id))
        val stopped = recorder.exit()
        assertEquals(GitFailure.STOPPED, stopped.failure)
        assertNull(stopped.exitCode)
        assertEquals(0, runner.runningCount())

        val project = freshProject("cap")
        ok(git("init", "-q", "--initial-branch=main", project = "cap"))
        for (i in 0 until 300) write(project, "f$i.txt", "$i\n")
        val (capped, exit) = git("status", "--untracked-files=all", project = "cap", maxRecords = 100)
        assertNull(exit.failure)
        // Ended at the cap, or, on a fast target, git wrote all 300 into the pipe and exited 0 before the
        // end reached it (API 36 in phase gate 45620932879): either way only the first 100 come, truncated.
        assertTrue("exit ${exit.exitCode}", exit.exitCode == null || exit.exitCode == 0)
        assertTrue(exit.truncated)
        assertEquals(100, capped.records.size)
        assertEquals(100, exit.records)
        val capEnd = if (exit.exitCode == null) "ended" else "git_done_first"
        record("stop", "ok stopped_ms=${stopped.elapsedMs} capped_ms=${exit.elapsedMs} cap=$capEnd")
    }

    @Test
    fun f_tenThousandFiles() {
        identity()
        val project = freshProject("big")
        ok(git("init", "-q", "--initial-branch=main", project = "big"))
        val writing = System.nanoTime()
        for (folder in 0 until 100) {
            for (file in 0 until 100) {
                write(project, "d%02d/f%03d.txt".format(folder, file), "$folder.$file\n")
            }
        }
        record("10k_write_ms", (System.nanoTime() - writing) / 1_000_000)
        val (untracked, untrackedExit) = git("status", "--untracked-files=all", project = "big")
        assertEquals(0, untrackedExit.exitCode)
        assertEquals(10_000, untracked.records.size)
        assertEquals("records in batches of 2,000", listOf(2_000, 2_000, 2_000, 2_000, 2_000), untracked.batches.toList())
        record("10k_untracked_status_ms", untrackedExit.elapsedMs)
        record("10k_untracked_status_chars", untrackedExit.chars)
        val (_, added) = git("add", "-A", project = "big")
        assertEquals(0, added.exitCode)
        record("10k_add_ms", added.elapsedMs)
        val (_, committed) = git("commit", "-q", "-m", "10,000 files", project = "big")
        assertEquals(0, committed.exitCode)
        record("10k_commit_ms", committed.elapsedMs)
        val times = LongArray(20) {
            val (status, exit) = git("status", "--branch", project = "big")
            assertEquals(0, exit.exitCode)
            assertEquals(2, status.records.size)
            exit.elapsedMs
        }
        record("10k_status_ms", spread(times))
        record("10k", "ok")
    }

    private fun spread(times: LongArray): String {
        val sorted = times.sorted()
        fun at(fraction: Double) = sorted[((sorted.size - 1) * fraction).toInt()]
        return "p50=${at(0.5)} p95=${at(0.95)} max=${sorted.last()}"
    }

    private companion object {
        const val TAG = "CodeForgeRuntimeGate"
        const val REPORT = "githost-report.txt"
        const val PROJECT = "demo"
        const val NAME = "CodeForge Gate"
        const val EMAIL = "gate@codeforge.invalid"
        const val LONG_MS = 10L * 60_000L

        private var installed: RuntimeCommands? = null
        private var rootDir: File? = null
        private var gitRunner: GitRunner? = null
        private var pool: ExecutorService? = null

        fun home(): File = commands().environment.home

        fun projects(): File {
            commands()
            return File(rootDir!!, "workspaces").apply { mkdirs() }
        }

        /** The payload installed once for the class, in a root of its own, and its command side. */
        @Synchronized
        fun commands(): RuntimeCommands {
            installed?.let { return it }
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val root = File(context.filesDir, "runtime-gate/githost")
            root.deleteRecursively()
            val rootfs = File(root, "rootfs")
            val prefix = File(rootfs, "data/data/com.termux/files/usr")
            val config = HarnessConfig.Builder()
                .workspace(File(root, "workspace"))
                .home(File(root, "home"))
                .prefix(prefix)
                .rootfs(rootfs)
                .toolDirectory(File(prefix, "bin"))
                .libraryDirectory(File(prefix, "lib"))
                .nativeLibraryDirectory(File(context.applicationInfo.nativeLibraryDir))
                .build()
            val runtime = SealedRuntime(AssetPayloadSource(context), config)
            if (runtime.payload() == null) throw AssertionError("this APK carries no payload")
            runtime.install(null)
            val created = RuntimeCommands.create(
                config = config,
                killGroup = { group -> Os.kill(-group, OsConstants.SIGKILL) },
            )
            created.environment.prepare()
            rootDir = root
            installed = created
            return created
        }

        /** The runner over the class's runtime, as GitHost makes it over the app's. */
        @Synchronized
        fun runner(): GitRunner {
            gitRunner?.let { return it }
            val commands = commands()
            val threads = Executors.newCachedThreadPool()
            val created = GitRunner(
                processes = { request, sink, maxRecordBytes, separator, started, extraRoots, progress ->
                    commands.runner.stream(request, sink, maxRecordBytes, started, extraRoots, separator, progress)
                },
                projects = projects(),
                executor = threads,
            )
            pool = threads
            gitRunner = created
            return created
        }

        /** The class's runtime root goes once its tests are done: each gate class installs its own. */
        @JvmStatic
        @AfterClass
        fun removeTheRuntime() {
            gitRunner?.stopAll()
            pool?.shutdown()
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            File(context.filesDir, "runtime-gate/githost").deleteRecursively()
            installed = null
            rootDir = null
            gitRunner = null
            pool = null
        }
    }
}
