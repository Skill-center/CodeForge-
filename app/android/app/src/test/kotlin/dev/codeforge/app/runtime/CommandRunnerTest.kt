package dev.codeforge.app.runtime

import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
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
 * The runtime's commands with real processes (Phase 4 W4, gate G4): the
 * runner, the session registry and the launcher together, on the machine
 * that runs the tests. The launcher is compiled here from
 * native/runtime-core/src/main/jni/codeforge-spawn.c with the machine's C
 * compiler (the tests are skipped without one, except on CI, where that
 * fails); the programs are the
 * machine's /bin/sh and sleep, linked into a runtime's bin. The emulator
 * gate runs the same on Android (RuntimeCommandsTest).
 *
 * Every test checks that no process it started is left.
 */
class CommandRunnerTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var root: File
    private lateinit var environment: RuntimeEnvironment
    private lateinit var sessions: SessionRegistry
    private lateinit var runner: CommandRunner
    private lateinit var marker: String

    @Before
    fun setUp() {
        // On CI a missing compiler is a failure, so these tests never pass by being skipped.
        if (System.getenv("CI") == "true") assertNotNull("no C compiler on CI for the launcher", launcher)
        assumeTrue("no C compiler here for the launcher", launcher != null)
        root = temp.newFolder("harness")
        val libraries = temp.newFolder("lib")
        environment = RuntimeEnvironment(
            TestPayload.configFor(root, libraries),
            mapOf("CODEFORGE_CANARY_TOKEN" to "secret", "ANDROID_ROOT" to "/system"),
        )
        val bin = environment.bin
        bin.mkdirs()
        for ((name, target) in mapOf("sh" to SH, "sleep" to SLEEP)) {
            Files.createSymbolicLink(File(bin, name).toPath(), target.toPath())
        }
        sessions = SessionRegistry(killGroup = ::killGroup, graceMs = 300L)
        runner = CommandRunner(environment, launcher!!, sessions, File(root, "codeforge/sessions"))
        // A sleep of about a minute that no other process runs: its
        // duration names this test's processes.
        marker = "%d.%04d".format(60 + serial.incrementAndGet(), selfPid() % 10000)
    }

    @After
    fun noProcessIsLeft() {
        if (!::marker.isInitialized) return
        var left = processesWith(marker)
        val deadline = System.nanoTime() + 2_000_000_000L
        while (left.isNotEmpty() && System.nanoTime() < deadline) {
            Thread.sleep(50)
            left = processesWith(marker)
        }
        for (pid in left) ProcessBuilder("kill", "-KILL", pid.toString()).start().waitFor(5, TimeUnit.SECONDS)
        assertEquals("processes left behind", emptyList<Long>(), left)
    }

    private fun sh(script: String, timeoutMs: Long = 20_000L, outputLimit: Int = CommandRunner.DEFAULT_OUTPUT_LIMIT) =
        runner.run(CommandRequest("sh", listOf("-c", script), timeoutMs = timeoutMs, outputLimit = outputLimit))

    @Test
    fun stdoutStderrAndTheExitCodeComeBackApart() {
        val result = sh("echo out; echo err >&2; exit 3")
        assertNull(result.detail, result.failure)
        assertEquals(3, result.exitCode)
        assertEquals("out\n", result.stdout.text)
        assertEquals("err\n", result.stderr.text)
        assertFalse(result.succeeded)
        assertEquals(0, result.leftovers)
        assertEquals(0, result.remaining)
    }

    @Test
    fun streamedLinesArriveInOrderAndTheSinkCanEndTheCommand() {
        val lines = mutableListOf<String>()
        var started = false
        // Three lines, then a long sleep: the sink ends it all at the second line.
        val result = runner.stream(
            CommandRequest("sh", listOf("-c", "echo one; echo two; echo three; sleep $marker"), timeoutMs = 20_000L),
            object : LineSink {
                override fun line(text: String): Boolean {
                    lines.add(text)
                    return lines.size < 2
                }
            },
            started = { started = true },
        )
        assertTrue("the session was handed over", started)
        assertEquals(listOf("one", "two"), lines)
        assertEquals(CommandFailure.ENDED, result.failure)
        assertEquals("", result.stdout.text)
        assertTrue("ended at once, not after the sleep", result.durationMs < 10_000L)
    }

    @Test
    fun aStreamedLineOverTheLimitIsDroppedAndTheRestGoesOn() {
        val lines = mutableListOf<String>()
        var overlong = 0
        val script = "echo short; i=0; while [ \$i -lt 600 ]; do printf xxxxxxxxxx; i=\$((i + 1)); done; echo; echo last"
        val result = runner.stream(
            CommandRequest("sh", listOf("-c", script), timeoutMs = 20_000L),
            object : LineSink {
                override fun line(text: String): Boolean {
                    lines.add(text)
                    return true
                }

                override fun overlong() {
                    overlong += 1
                }
            },
            maxLineBytes = 1000,
        )
        assertNull(result.detail, result.failure)
        assertEquals(0, result.exitCode)
        assertEquals(listOf("short", "last"), lines)
        assertEquals(1, overlong)
        assertEquals(6L + 6001L + 5L, result.stdout.bytes)
    }

    @Test
    fun outputPastTheLimitIsCountedNotKept() {
        val line = "0123456789".repeat(4)
        val result = sh("i=0; while [ \$i -lt 3000 ]; do echo $line; i=\$((i + 1)); done", outputLimit = 1024)
        assertEquals(0, result.exitCode)
        assertEquals(1024, result.stdout.text.length)
        assertEquals(3000L * 41, result.stdout.bytes)
        assertTrue(result.stdout.truncated)
        assertFalse(result.stderr.truncated)
    }

    @Test
    fun aCommandGetsItsOwnVariablesAndCannotReplaceTheRuntimes() {
        val given = runner.run(
            CommandRequest("sh", listOf("-c", "echo \"\$GIT_TERMINAL_PROMPT|\$HOME\""), variables = mapOf("GIT_TERMINAL_PROMPT" to "0")),
        )
        assertNull(given.detail, given.failure)
        assertEquals("0|${environment.home.absolutePath}", given.stdout.text.trim())
        for (variables in listOf(mapOf("HOME" to "/tmp"), mapOf("PATH" to "/bin"), mapOf("A=B" to "c"), mapOf("" to "c"), mapOf("A" to "b\u0000c"))) {
            val refused = runner.run(CommandRequest("sh", listOf("-c", "true"), variables = variables))
            assertEquals(variables.keys.toString(), CommandFailure.BAD_REQUEST, refused.failure)
        }
    }

    @Test
    fun streamedRecordsMayEndAtANulByteOrOnlyAtTheEnd() {
        val records = mutableListOf<String>()
        val sink = object : LineSink {
            override fun line(text: String): Boolean = records.add(text)
        }
        // git's -z: a record may hold a newline; an empty record is still one.
        val nul = runner.stream(
            CommandRequest("sh", listOf("-c", "printf 'a\\000b\\nc\\000\\000d'"), timeoutMs = 20_000L),
            sink,
            separator = CommandRunner.NUL_SEPARATOR,
        )
        assertNull(nul.detail, nul.failure)
        assertEquals(listOf("a", "b\nc", "", "d"), records)

        records.clear()
        val whole = runner.stream(
            CommandRequest("sh", listOf("-c", "printf 'one\\ntwo\\000three\\n'"), timeoutMs = 20_000L),
            sink,
            separator = CommandRunner.NO_SEPARATOR,
        )
        assertNull(whole.detail, whole.failure)
        assertEquals(listOf("one\ntwo\u0000three\n"), records)

        records.clear()
        val empty = runner.stream(CommandRequest("sh", listOf("-c", "true"), timeoutMs = 20_000L), sink, separator = CommandRunner.NO_SEPARATOR)
        assertEquals(0, empty.exitCode)
        assertEquals("no output, no record", emptyList<String>(), records)
    }

    @Test
    fun aWholeOutputOverTheLimitIsDroppedAndSaidSo() {
        val records = mutableListOf<String>()
        var overlong = 0
        val result = runner.stream(
            CommandRequest("sh", listOf("-c", "i=0; while [ \$i -lt 300 ]; do printf xxxxxxxxxx; i=\$((i + 1)); done"), timeoutMs = 20_000L),
            object : LineSink {
                override fun line(text: String): Boolean = records.add(text)

                override fun overlong() {
                    overlong += 1
                }
            },
            maxLineBytes = 1000,
            separator = CommandRunner.NO_SEPARATOR,
        )
        assertNull(result.detail, result.failure)
        assertEquals(emptyList<String>(), records)
        assertEquals(1, overlong)
        assertEquals(3000L, result.stdout.bytes)
    }

    @Test
    fun progressGoesToItsSinkAndTheOtherLinesAreKept() {
        val progress = mutableListOf<Pair<String, Boolean>>()
        val script = "printf 'Updating files:  10%% (1/10)\\rUpdating files: 100%% (10/10), done.\\n' >&2; " +
            "printf 'Switched to a new branch\\n' >&2; printf 'Counting: 1\\rfatal: it broke\\n' >&2"
        val result = runner.stream(
            CommandRequest("sh", listOf("-c", script), timeoutMs = 20_000L),
            object : LineSink {
                override fun line(text: String): Boolean = true
            },
            progress = { text, closing -> progress.add(text to closing) },
        )
        assertNull(result.detail, result.failure)
        assertEquals(
            listOf(
                "Updating files:  10% (1/10)" to false,
                "Updating files: 100% (10/10), done." to true,
                "Counting: 1" to false,
                "fatal: it broke" to true,
            ),
            progress,
        )
        // git's own closing line is left out of the text; an error after a redrawn line is kept.
        assertEquals("Switched to a new branch\nfatal: it broke\n", result.stderr.text)
        assertFalse(result.stderr.truncated)
    }

    @Test
    fun itRunsInTheHomeWithTheRuntimesVariablesOnly() {
        val result = sh("pwd; echo \"\$HOME|\$TMPDIR|\$CODEFORGE_CANARY_TOKEN|\$ANDROID_ROOT\"")
        val lines = result.stdout.text.trim().lines()
        assertEquals(environment.home.canonicalPath, File(lines[0]).canonicalPath)
        assertEquals("${environment.home.absolutePath}|${environment.tmp.absolutePath}||/system", lines[1])
    }

    @Test
    fun aFolderInsideTheWorkspaceIsAllowedAndOutsideIsNot() {
        val project = File(environment.workspace, "demo").apply { mkdirs() }
        val inside = runner.run(CommandRequest("sh", listOf("-c", "pwd"), directory = project))
        assertEquals(project.canonicalPath, inside.stdout.text.trim())

        val outside = runner.run(CommandRequest("sh", listOf("-c", "pwd"), directory = temp.root))
        assertEquals(CommandFailure.BAD_REQUEST, outside.failure)
        val escape = runner.run(CommandRequest("sh", listOf("-c", "pwd"), directory = File(project, "../../..")))
        assertEquals(CommandFailure.BAD_REQUEST, escape.failure)
    }

    @Test
    fun aStreamMayRunInTheExtraRootsItIsGivenAndNowhereElse() {
        val projects = temp.newFolder("projects")
        val project = File(projects, "p").apply { mkdirs() }
        val sink = object : LineSink {
            val lines = mutableListOf<String>()

            override fun line(text: String): Boolean = lines.add(text)
        }
        val allowed = runner.stream(
            CommandRequest("sh", listOf("-c", "pwd"), directory = project, timeoutMs = 20_000L),
            sink,
            extraRoots = listOf(projects),
        )
        assertNull(allowed.detail, allowed.failure)
        assertEquals(listOf(project.canonicalPath), sink.lines)
        val refused = runner.stream(CommandRequest("sh", listOf("-c", "pwd"), directory = project), sink)
        assertEquals("without the extra root, the project is outside", CommandFailure.BAD_REQUEST, refused.failure)
    }

    @Test
    fun onlyProgramsInTheRuntimesBinRun() {
        assertEquals(CommandFailure.BAD_REQUEST, runner.run(CommandRequest("/bin/sh")).failure)
        assertEquals(CommandFailure.BAD_REQUEST, runner.run(CommandRequest("../sh")).failure)
        assertEquals(CommandFailure.BAD_REQUEST, runner.run(CommandRequest("sh", listOf("a\u0000b"))).failure)
        assertEquals(CommandFailure.NOT_FOUND, runner.run(CommandRequest("node")).failure)
    }

    @Test
    fun aProgramThatCannotRunSaysWhy() {
        val plain = File(environment.bin, "plain").apply { writeText("not a program\n") }
        plain.setExecutable(false)
        val notExecutable = runner.run(CommandRequest("plain"))
        assertEquals(CommandFailure.CANNOT_EXECUTE, notExecutable.failure)
        assertTrue(notExecutable.detail!!, notExecutable.detail.contains("EACCES"))

        File(environment.bin, "orphan").apply {
            writeText("#!/nonexistent/interpreter\n")
            setExecutable(true)
        }
        assertEquals(CommandFailure.NOT_FOUND, runner.run(CommandRequest("orphan")).failure)
    }

    @Test
    fun aChildLeftRunningIsEndedWhenTheCommandExits() {
        val result = sh("sleep $marker & echo started")
        assertEquals(0, result.exitCode)
        assertEquals("started\n", result.stdout.text)
        assertEquals(1, result.leftovers)
        assertTrue("took ${result.durationMs} ms", result.durationMs < 5000)
    }

    @Test
    fun aCommandPastItsTimeLimitIsEndedWithEverythingItStarted() {
        val result = sh("sleep $marker & sleep $marker & sleep $marker", timeoutMs = 400L)
        assertEquals(CommandFailure.TIMED_OUT, result.failure)
        assertTrue(result.detail!!, result.detail.contains("time limit"))
        // The shell and its three sleeps (dash may run the last in its own place).
        assertTrue("ended ${result.leftovers}", result.leftovers >= 3)
        assertEquals(0, result.remaining)
        assertTrue("took ${result.durationMs} ms", result.durationMs < 8000)
    }

    @Test
    fun aCommandThatIgnoresSigtermIsKilled() {
        val result = sh("trap '' TERM; sleep $marker; sleep $marker", timeoutMs = 300L)
        assertEquals(CommandFailure.TIMED_OUT, result.failure)
        assertEquals(0, result.remaining)
    }

    @Test
    fun endingEverySessionEndsTheirTreesAndRefusesNewOnes() {
        val results = mutableListOf<CommandResult>()
        val thread = Thread {
            results.add(sh("sleep $marker & sleep $marker"))
        }
        thread.start()
        val deadline = System.nanoTime() + 10_000_000_000L
        while (sessions.live().isEmpty() && System.nanoTime() < deadline) Thread.sleep(20)
        Thread.sleep(200)
        assertEquals(1, sessions.live().size)

        assertEquals(0, sessions.endAll(EndReason.ENDED))
        thread.join(10_000L)
        assertEquals(CommandFailure.ENDED, results.single().failure)
        assertTrue(sessions.live().isEmpty())

        // Refused until reopened: a new command is ended at once.
        assertEquals(CommandFailure.ENDED, sh("sleep $marker").failure)
        sessions.reopen()
        assertEquals(0, sh("exit 0").exitCode)
    }

    @Test
    fun aCrashIsReportedAsTheSignalThatEndedIt() {
        val result = sh("kill -SEGV \$\$")
        assertEquals(CommandFailure.SIGNALED, result.failure)
        assertEquals(11, result.signal)
        assertTrue(result.detail!!, result.detail.contains("SIGSEGV"))
    }

    @Test
    fun aMissingLauncherIsALaunchFailure() {
        val broken = CommandRunner(environment, File(root, "missing-launcher"), sessions, File(root, "codeforge/sessions"))
        assertEquals(CommandFailure.LAUNCH_FAILED, broken.run(CommandRequest("sh", listOf("-c", "true"))).failure)
    }

    @Test
    fun theLaunchersStatusIsRead() {
        val status = LauncherStatus.parse("pid=41\ngroup=41\nsubreaper=1\nreason=stopped\nsignal=15\nstop_signal=15\nended=3\nremaining=0\n")
        assertEquals(41, status.pid)
        assertEquals(41, status.group)
        assertTrue(status.subreaper)
        assertEquals("stopped", status.reason)
        assertNull(status.exit)
        assertEquals(15, status.signal)
        assertEquals(3, status.ended)
        assertNull(LauncherStatus.read(File(root, "absent")))
    }

    companion object {
        private val SH = File("/bin/sh")
        private val SLEEP = listOf(File("/bin/sleep"), File("/usr/bin/sleep")).firstOrNull { it.exists() } ?: File("/bin/sleep")
        private val serial = AtomicInteger()

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

        /** SIGKILL to a process group, as Os.kill(-group) does on a device. */
        fun killGroup(group: Int) {
            ProcessBuilder("kill", "-KILL", "--", "-$group").start().waitFor(5, TimeUnit.SECONDS)
        }

        /** This JVM's process id. (android.jar, which the tests compile against, has no ProcessHandle.) */
        fun selfPid(): Long = File("/proc/self").canonicalFile.name.toLong()

        /** Processes whose command line holds [marker] (zombies have none). */
        fun processesWith(marker: String): List<Long> {
            val self = selfPid()
            return File("/proc").listFiles().orEmpty()
                .mapNotNull { it.name.toLongOrNull() }
                .filter { pid -> pid != self }
                .filter { pid ->
                    try {
                        String(File("/proc/$pid/cmdline").readBytes(), Charsets.UTF_8).contains(marker)
                    } catch (gone: Exception) {
                        false
                    }
                }
        }
    }
}
