package dev.codeforge.app.runtime

import java.io.File
import java.nio.file.Files
import java.util.Collections
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import org.junit.After
import org.junit.Assert.assertArrayEquals
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
 * Terminal sessions with real processes (Phase 5 W2, gate G2): [Terminals],
 * [TerminalSession], the session registry and the launcher's terminal mode
 * together, on the machine that runs the tests. The launcher is compiled
 * here from codeforge-spawn.c, as in CommandRunnerTest (skipped without a
 * compiler, except on CI, where that fails); the programs are the machine's
 * bash, sh and coreutils, linked into a runtime's bin. The runtime legs run
 * the same on Android (the instrumented TerminalSessionTest).
 *
 * Every test checks that no process it started is left.
 */
class TerminalSessionTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var root: File
    private lateinit var projects: File
    private lateinit var environment: RuntimeEnvironment
    private lateinit var sessions: SessionRegistry
    private lateinit var delivery: RecordingExecutor
    private lateinit var marker: String
    private val started = mutableListOf<TerminalSession>()

    @Before
    fun setUp() {
        // On CI a missing compiler or bash is a failure, so these tests never pass by being skipped.
        if (System.getenv("CI") == "true") {
            assertNotNull("no C compiler on CI for the launcher", launcher)
            assertNotNull("no bash on CI", locate("bash"))
        }
        assumeTrue("no C compiler here for the launcher", launcher != null)
        assumeTrue("no bash here", locate("bash") != null)
        root = temp.newFolder("harness")
        projects = temp.newFolder("workspaces")
        val libraries = temp.newFolder("lib")
        environment = RuntimeEnvironment(
            TestPayload.configFor(root, libraries),
            mapOf("CODEFORGE_CANARY_TOKEN" to "secret", "ANDROID_ROOT" to "/system"),
        )
        val bin = environment.bin
        bin.mkdirs()
        for (name in PROGRAMS) {
            val target = locate(name) ?: continue
            Files.createSymbolicLink(File(bin, name).toPath(), target.toPath())
        }
        sessions = SessionRegistry(killGroup = { group -> CommandRunnerTest.killGroup(group) }, graceMs = 300L)
        delivery = RecordingExecutor()
        // A sleep of a few minutes that no other process runs: its duration names this test's processes.
        marker = "%d.%04d".format(200 + serial.incrementAndGet(), CommandRunnerTest.selfPid() % 10000)
    }

    @After
    fun noProcessIsLeft() {
        if (!::marker.isInitialized) return
        try {
            for (session in started) {
                if (session.state != TerminalState.EXITED) session.end()
            }
            for (session in started) awaitExit(session, 15_000L)
            var left = leftovers()
            val deadline = System.nanoTime() + 3_000_000_000L
            while (left.isNotEmpty() && System.nanoTime() < deadline) {
                Thread.sleep(50)
                left = leftovers()
            }
            for (pid in left) ProcessBuilder("kill", "-KILL", pid.toString()).start().waitFor(5, TimeUnit.SECONDS)
            assertEquals("processes left behind", emptyList<Long>(), left)
        } finally {
            delivery.shutdownNow()
        }
    }

    // ── The shell ────────────────────────────────────────────────────

    @Test
    fun bashEchoesWhatIsTypedAndAnswers() {
        val screen = Screen()
        val session = start(terminals(), TerminalSpec(), screen)
        assertEquals(TerminalState.RUNNING, session.state)
        assertEquals("bash", session.label)
        assertNull(session.write("echo forty-$((40 + 2))\r".toByteArray()))
        // The typed line comes back as typed; the answer only from bash.
        val typed = screen.waitFor("echo forty-")
        screen.waitFor("forty-42", typed)
        assertEquals(0, screen.gaps)
    }

    @Test
    fun theSessionsEnvironmentIsTheTerminalsAndTheRcFileIsCodeForges() {
        val screen = Screen()
        val session = start(terminals(), TerminalSpec(environment = mapOf("CODEFORGE_EXTRA" to "seen")), screen)
        session.write("printf '<%s|%s|%s|%s>\\n' \"\$TERM\" \"\$COLORTERM\" \"\$CODEFORGE_EXTRA\" \"\${CODEFORGE_CANARY_TOKEN-none}\"\r".toByteArray())
        screen.waitFor("<xterm-256color|truecolor|seen|none>")
        // CodeForge's rc file is bash's, and it read the user's own ~/.bashrc.
        assertTrue(File(root, "codeforge/terminal/${Terminals.RC_FILE}").readText().contains(".bashrc"))
        File(environment.home, ".bashrc").writeText("CODEFORGE_FROM_BASHRC=read\n")
        val secondScreen = Screen()
        val second = start(terminals(), TerminalSpec(), secondScreen)
        second.write("echo \"rc-\$CODEFORGE_FROM_BASHRC-done\"\r".toByteArray())
        secondScreen.waitFor("rc-read-done")
    }

    @Test
    fun sttySizeFollowsAResize() {
        val screen = Screen()
        val session = start(terminals(), TerminalSpec(rows = 24, columns = 80), screen)
        session.write("stty size\r".toByteArray())
        val first = screen.waitFor("24 80")
        assertNull(session.resize(40, 120))
        assertEquals(40, session.rows)
        assertEquals(120, session.columns)
        session.write("stty size\r".toByteArray())
        screen.waitFor("40 120", first)
        // Sizes are brought into range rather than refused.
        assertNull(session.resize(0, 100_000))
        assertEquals(1, session.rows)
        assertEquals(TerminalSession.MAX_DIMENSION, session.columns)
    }

    @Test
    fun ctrlCReachesTheForegroundJob() {
        val screen = Screen()
        val session = start(terminals(), TerminalSpec(), screen)
        session.write("sleep $marker\r".toByteArray())
        awaitProcesses(1)
        session.write(byteArrayOf(3))
        awaitProcesses(0)
        session.write("echo rc-\$?-done\r".toByteArray())
        screen.waitFor("rc-130-done")
        assertEquals(TerminalState.RUNNING, session.state)
    }

    @Test
    fun theShellsExitCodeIsTheSessions() {
        val changes = mutableListOf<String>()
        val terminals = terminals()
        terminals.changed = { session -> synchronized(changes) { changes.add("${session.id}:${session.state.code}") } }
        val session = start(terminals, TerminalSpec(), Screen())
        session.write("exit 7\r".toByteArray())
        val exit = awaitExit(session)
        assertEquals(7, exit.exitCode)
        assertNull(exit.signal)
        assertNull(exit.detail, exit.failure)
        assertEquals(0, exit.remaining)
        assertEquals(TerminalState.EXITED, session.state)
        assertEquals(TerminalFailure.NOT_RUNNING, session.write("echo late\r".toByteArray()))
        assertEquals(TerminalFailure.NOT_RUNNING, session.resize(30, 90))
        assertFalse("an exited session is not ended again", session.end())
        synchronized(changes) { assertEquals(listOf("${session.id}:running", "${session.id}:exited"), changes) }
        // Its place is free, and it stays listed until removed.
        assertTrue(sessions.live(SessionKind.TERMINAL).isEmpty())
        assertEquals(listOf(session.id), terminals.list().map { it.id })
        assertTrue(terminals.remove(session.id))
        assertTrue(terminals.list().isEmpty())
    }

    @Test
    fun endEndsTheShellAndEverythingItStarted() {
        val screen = Screen()
        val session = start(terminals(), TerminalSpec(), screen)
        session.write("sleep $marker &\r".toByteArray())
        session.write("sleep $marker\r".toByteArray())
        awaitProcesses(2)
        assertTrue(session.end())
        assertFalse("ended once", session.end())
        val exit = awaitExit(session)
        assertEquals(TerminalFailure.ENDED, exit.failure)
        assertTrue("bash and both sleeps were ended: ${exit.leftovers}", exit.leftovers >= 3)
        assertEquals(0, exit.remaining)
        awaitProcesses(0)
    }

    @Test
    fun withoutBashNoSessionStartsAndNothingElseIsTried() {
        assertTrue(File(environment.bin, "bash").delete())
        val result = terminals().start(TerminalSpec())
        assertNull(result.session)
        assertEquals(TerminalFailure.NOT_FOUND, result.failure)
        assertTrue(result.detail.orEmpty(), result.detail.orEmpty().contains("bash"))
        assertTrue("no place is held", sessions.live().isEmpty())
    }

    // ── Output, credit and the buffer ────────────────────────────────

    @Test
    fun aFloodArrivesWholeAndTheCreditBoundsWhatIsHeld() {
        val window = 128 * 1024
        val total = 10L * 1024 * 1024
        val screen = Screen(keep = false)
        screen.acknowledging = false
        val session = start(
            terminals(window = window),
            TerminalSpec(program = "sh", arguments = listOf("-c", "head -c $total /dev/zero | tr '\\0' Z")),
            screen,
        )
        // Without acknowledgements the reader stops at the window: the producer blocks in the kernel.
        val filled = System.nanoTime() + 20_000_000_000L
        while (session.received < window && System.nanoTime() < filled) Thread.sleep(10)
        assertEquals("the reader filled the window", window.toLong(), session.received)
        Thread.sleep(500)
        assertEquals("and read nothing more without credit", window.toLong(), session.received)
        assertEquals("the view has it all", window.toLong(), screen.received)
        // With acknowledgements everything arrives, in order, and never more than the window unacknowledged.
        screen.acknowledging = true
        session.acknowledge(screen.end)
        val exit = awaitExit(session, 120_000L)
        assertEquals(0, exit.exitCode)
        assertEquals(total, screen.zs)
        assertEquals(total, screen.received)
        assertEquals(0, screen.gaps)
        assertTrue("held ${session.unacknowledgedHighWater} > $window", session.unacknowledgedHighWater <= window)
        // At most one batch every 16 ms.
        val span = screen.span()
        assertTrue("${screen.batches} batches in $span ns", screen.batches <= span / TerminalSession.BATCH_NS + 2)
        println("TERMINAL_FLOOD bytes=${screen.received} batches=${screen.batches} ms=${span / 1_000_000} window=$window")
    }

    @Test
    fun anEchoAfterAQuietMomentIsNotHeldForABatch() {
        val screen = Screen()
        val session = start(terminals(), TerminalSpec(program = "cat"), screen)
        Thread.sleep(200)
        val samples = ArrayList<Long>()
        repeat(25) {
            Thread.sleep(40)
            val before = screen.received
            val sent = System.nanoTime()
            session.write("x".toByteArray())
            screen.waitForBytes(before + 1)
            samples.add(System.nanoTime() - sent)
        }
        samples.sort()
        val median = samples[samples.size / 2]
        println("TERMINAL_ECHO p50_us=${median / 1000} p95_us=${samples[samples.size * 95 / 100] / 1000} n=${samples.size}")
        // ADR-0006's budget for a keystroke is 50 ms; a batch would add 16.
        assertTrue("median echo ${median / 1000} µs", median < 50_000_000L)
    }

    @Test
    fun theFirstBytesAfterAQuietMomentGoAtOnceAndAFloodGoesInBatches() {
        val screen = Screen()
        val session = start(terminals(), TerminalSpec(program = "cat"), screen)
        Thread.sleep(100)
        repeat(5) {
            Thread.sleep(40)
            val before = screen.received
            val recorded = delivery.delays.size
            session.write("x".toByteArray())
            screen.waitForBytes(before + 1)
            val asked = delivery.since(recorded)
            assertTrue("an echo after a quiet moment waited for a batch: $asked", asked.isNotEmpty() && asked.all { it == 0L })
        }
        val recorded = delivery.delays.size
        val flood = start(
            terminals(),
            TerminalSpec(program = "sh", arguments = listOf("-c", "head -c 4000000 /dev/zero | tr '\\0' Z")),
            Screen(keep = false),
        )
        assertEquals(0, awaitExit(flood, 60_000L).exitCode)
        val asked = delivery.since(recorded)
        assertTrue("a flood went in batches: $asked", asked.any { it > 0L })
        assertTrue("no batch waited more than 16 ms: $asked", asked.all { it <= TerminalSession.BATCH_NS })
    }

    @Test
    fun anEndFromTheRegistryReachesASessionWhoseViewStoppedAcknowledging() {
        val screen = Screen(keep = false)
        screen.acknowledging = false
        val session = start(
            terminals(window = 64 * 1024),
            TerminalSpec(program = "sh", arguments = listOf("-c", "head -c 50000000 /dev/zero | tr '\\0' Z; sleep $marker")),
            screen,
        )
        screen.waitForBytes(64L * 1024)
        // End all, or a reinstall: the registry ends it, not the session's own end().
        val ending = System.nanoTime()
        assertEquals(0, sessions.endAll(EndReason.ENDED, refuse = false))
        assertEquals(TerminalFailure.ENDED, awaitExit(session, 10_000L).failure)
        val millis = (System.nanoTime() - ending) / 1_000_000
        // Well before the 2 s a reader waits for credit after its launcher exits.
        assertTrue("ended in $millis ms", millis < 1_800L)
    }

    @Test
    fun aDetachedSessionKeepsItsLastOutputForTheNextView() {
        val script = "i=0; while [ \$i -lt 10000 ]; do echo line-\$i; i=\$((i + 1)); done"
        val session = start(
            terminals(),
            TerminalSpec(program = "sh", arguments = listOf("-c", script), bufferBytes = 1),
        )
        assertEquals("brought up to the smallest buffer", TerminalSession.MIN_BUFFER_BYTES, session.bufferBytes)
        assertEquals(0, awaitExit(session).exitCode)
        assertTrue("more than the buffer was written", session.received > session.bufferBytes)
        val replay = session.attach(Screen())
        val text = String(replay.bytes, Charsets.ISO_8859_1)
        assertTrue("at most the buffer", replay.bytes.size <= session.bufferBytes)
        assertEquals("the replay reaches the end", session.received, replay.offset + replay.bytes.size)
        assertTrue("it starts at a line: ${text.take(20)}", text.startsWith("line-"))
        assertTrue("it ends with the last line", text.endsWith("line-9999\r\n"))
    }

    @Test
    fun theRingKeepsTheLastBytesByTheirOffset() {
        val ring = OutputRing(8)
        ring.write("abcdef".toByteArray(), 0, 6)
        assertEquals(0L, ring.start)
        assertEquals("abcdef", String(ring.copy(0, 6)))
        ring.write("ghij".toByteArray(), 0, 4)
        assertEquals(2L, ring.start)
        assertEquals(10L, ring.end)
        assertEquals("cdefghij", String(ring.copy(2, 10)))
        assertEquals("fgh", String(ring.copy(5, 8)))
        // More than it holds at once: only the last 8 stay.
        ring.write("0123456789ABC".toByteArray(), 0, 13)
        assertEquals(23L, ring.end)
        assertEquals("56789ABC", String(ring.copy(15, 23)))
        assertTrue(runCatching { ring.copy(14, 23) }.isFailure)
    }

    // ── The cap and End all ──────────────────────────────────────────

    @Test
    fun theNinthSessionIsRefusedAndEndAllEndsThemAll() {
        val terminals = terminals()
        val eight = (1..SessionRegistry.DEFAULT_MAX_TERMINALS).map {
            start(terminals, TerminalSpec(program = "sleep", arguments = listOf(marker)))
        }
        // Each one's launcher names the sleep's duration too: two processes a session.
        awaitProcesses(2 * SessionRegistry.DEFAULT_MAX_TERMINALS)
        val ninth = terminals.start(TerminalSpec(program = "sleep", arguments = listOf(marker)))
        assertNull(ninth.session)
        assertEquals(TerminalFailure.TOO_MANY, ninth.failure)
        assertEquals(0, terminals.endAll())
        for (session in eight) assertEquals(TerminalFailure.ENDED, awaitExit(session).failure)
        awaitProcesses(0)
        // End all does not refuse: the places are free again.
        val again = start(terminals, TerminalSpec(program = "sleep", arguments = listOf(marker)))
        assertEquals(TerminalState.RUNNING, again.state)
    }

    @Test
    fun anInstallsEndAllRefusesNewSessionsUntilReopened() {
        val terminals = terminals()
        val session = start(terminals, TerminalSpec(program = "sleep", arguments = listOf(marker)))
        assertEquals(0, sessions.endAll(EndReason.ENDED))
        assertEquals(TerminalFailure.ENDED, awaitExit(session).failure)
        assertEquals(TerminalFailure.NOT_READY, terminals.start(TerminalSpec()).failure)
        sessions.reopen()
        start(terminals, TerminalSpec(program = "sleep", arguments = listOf(marker)))
    }

    // ── What Kotlin refuses (docs/SECURITY.md §2.1, E1, E2, E3) ──────

    @Test
    fun aProgramIsANameInTheRuntimesBin() {
        val terminals = terminals()
        for (program in listOf("/bin/sh", "../bin/sh", "bin/sh", "", ".", "..", "sh\u0000")) {
            assertEquals(program, TerminalFailure.BAD_REQUEST, terminals.start(TerminalSpec(program = program)).failure)
        }
        assertEquals(TerminalFailure.NOT_FOUND, terminals.start(TerminalSpec(program = "no-such-program")).failure)
        assertTrue(sessions.live().isEmpty())
    }

    @Test
    fun aSessionStartsInTheHomeOrInAProjectTheHostNames() {
        val terminals = terminals()
        val demo = File(projects, "demo").apply { mkdirs() }
        val outside = temp.newFolder("outside")
        Files.createSymbolicLink(File(projects, "escape").toPath(), outside.toPath())
        assertEquals(environment.home, terminals.directoryFor(null))
        assertEquals(demo.canonicalFile, terminals.directoryFor("demo"))
        for (name in listOf("", ".", "..", "../outside", "demo/sub", "/tmp", "escape", "absent", "a\u0000b")) {
            assertTrue(name, runCatching { terminals.directoryFor(name) }.isFailure)
            assertEquals(name, TerminalFailure.BAD_REQUEST, terminals.start(TerminalSpec(project = name)).failure)
        }
        val screen = Screen()
        val session = start(terminals, TerminalSpec(project = "demo"), screen)
        session.write("pwd\r".toByteArray())
        screen.waitFor(demo.canonicalPath)
    }

    @Test
    fun overridesCannotReplaceTheRuntimesOwnVariables() {
        val terminals = terminals()
        val home = environment.home
        assertEquals("1", terminals.variablesFor(home, mapOf("FOO" to "1"))["FOO"])
        for (name in listOf("PATH", "HOME", "TERM", "LD_PRELOAD", "LD_ANYTHING", "TERMUX_X", "ANDROID_ROOT", "1BAD", "A-B", "")) {
            assertTrue(name, runCatching { terminals.variablesFor(home, mapOf(name to "x")) }.isFailure)
        }
        assertTrue(runCatching { terminals.variablesFor(home, mapOf("FOO" to "a\u0000b")) }.isFailure)
        assertEquals(TerminalFailure.BAD_REQUEST, terminals.start(TerminalSpec(environment = mapOf("PATH" to "/bin"))).failure)
    }

    @Test
    fun aTerminalsVariablesDifferFromACommandsInFour() {
        val command = environment.variables(environment.home)
        val terminal = environment.variables(environment.home, terminal = true)
        assertEquals("dumb", command["TERM"])
        assertEquals("xterm-256color", terminal["TERM"])
        assertEquals("truecolor", terminal["COLORTERM"])
        assertNull(command["COLORTERM"])
        assertEquals(File(environment.bin, "bash").absolutePath, terminal["SHELL"])
        assertEquals(File(environment.bin, "sh").absolutePath, command["SHELL"])
        assertNull("no descriptions in this payload", terminal["TERMINFO"])
        val descriptions = File(environment.prefix, "share/terminfo").apply { mkdirs() }
        assertEquals(descriptions.absolutePath, environment.variables(environment.home, terminal = true)["TERMINFO"])
        assertNull(environment.variables(environment.home)["TERMINFO"])
        assertNull(terminal["CODEFORGE_CANARY_TOKEN"])
    }

    // ── The parts ────────────────────────────────────────────────────

    @Test
    fun framesCarryTheirTypeAndLength() {
        val frame = TerminalSession.frame(TerminalSession.FRAME_INPUT, "xabc".toByteArray(), 1, 3)
        assertArrayEquals(byteArrayOf(1, 0, 3, 'a'.code.toByte(), 'b'.code.toByte(), 'c'.code.toByte()), frame)
        val long = TerminalSession.frame(TerminalSession.FRAME_SIZE, ByteArray(300), 0, 300)
        assertEquals(1.toByte(), long[1])
        assertEquals(44.toByte(), long[2])
        assertTrue(runCatching { TerminalSession.frame(1, ByteArray(70_000), 0, 70_000) }.isFailure)
    }

    @Test
    fun theLaunchersStatusSaysHowASessionEnded() {
        fun status(text: String) = LauncherStatus.parse(text)
        val exited = TerminalSession.interpret(status("pid=5\nmode=terminal\nchild=6\nreason=exited\nexit=3\nended=0\nremaining=0\n"), 3, null, "")
        assertEquals(3, exited.exitCode)
        assertNull(exited.failure)
        val ended = TerminalSession.interpret(status("pid=5\nreason=stopped\nsignal=1\nstop_cause=signal\nended=4\nremaining=0\n"), 129, EndReason.ENDED, "")
        assertEquals(TerminalFailure.ENDED, ended.failure)
        assertEquals(1, ended.signal)
        assertEquals(4, ended.leftovers)
        val lost = TerminalSession.interpret(status("pid=5\nreason=stopped\nsignal=1\nstop_cause=protocol\nended=2\n"), 125, null, "")
        assertEquals(TerminalFailure.LOST, lost.failure)
        assertTrue(lost.detail.orEmpty(), lost.detail.orEmpty().contains("protocol"))
        assertEquals(TerminalFailure.SIGNALED, TerminalSession.interpret(status("pid=5\nreason=signaled\nsignal=11\n"), 139, null, "").failure)
        assertEquals(TerminalFailure.CANNOT_START, TerminalSession.interpret(status("pid=5\nreason=exec_failed\nexec_errno=13\n"), 126, null, "").failure)
        assertEquals(TerminalFailure.TERMINAL_FAILED, TerminalSession.interpret(status("pid=5\nreason=terminal_failed\nexec_errno=2\n"), 125, null, "").failure)
        assertEquals(TerminalFailure.LAUNCH_FAILED, TerminalSession.interpret(null, 127, null, "no such file").failure)
        assertEquals(TerminalFailure.ENDED, TerminalSession.interpret(status("pid=5\n"), null, EndReason.ENDED, "").failure)
    }

    @Test
    fun theProcessTableReadsStatLinesWithAnyCommandName() {
        val entry = ProcessTable.parse(42, "42 (a b) c) S 7 40 39 34816 40 4194560 0 0")
        assertEquals(ProcessTable.Entry(42, 7, 40, 39, 'S'), entry)
        assertNull(ProcessTable.parse(1, "garbage"))
        val entries = listOf(
            ProcessTable.Entry(10, 1, 10, 10, 'S'),
            ProcessTable.Entry(11, 10, 11, 10, 'S'),
            ProcessTable.Entry(12, 11, 11, 10, 'Z'),
            ProcessTable.Entry(13, 10, 13, 10, 'R'),
            ProcessTable.Entry(20, 1, 20, 20, 'S'),
        )
        assertEquals(setOf(10, 11, 13), ProcessTable.groupsInSession(entries, 10))
        // This machine's own table holds this process.
        assertTrue(ProcessTable.read().any { it.pid.toLong() == CommandRunnerTest.selfPid() })
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private fun terminals(window: Int = TerminalSession.DEFAULT_WINDOW) = Terminals(
        environment = environment,
        launcher = launcher!!,
        sessions = sessions,
        stateDirectory = File(root, "codeforge/terminal"),
        projects = projects,
        delivery = delivery,
        window = window,
    )

    private fun start(terminals: Terminals, spec: TerminalSpec, view: Screen? = null): TerminalSession {
        val result = terminals.start(spec, view)
        val session = result.session ?: throw AssertionError("not started: ${result.failure} ${result.detail}")
        started.add(session)
        return session
    }

    private fun awaitExit(session: TerminalSession, timeoutMs: Long = 20_000L): TerminalExit {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000L
        while (System.nanoTime() < deadline) {
            val exit = session.exit
            if (exit != null) return exit
            Thread.sleep(20)
        }
        throw AssertionError("session ${session.id} did not exit in $timeoutMs ms")
    }

    /** Waits until exactly [count] processes run this test's sleep. */
    private fun awaitProcesses(count: Int, timeoutMs: Long = 10_000L) {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000L
        var seen = CommandRunnerTest.processesWith(marker)
        while (seen.size != count && System.nanoTime() < deadline) {
            Thread.sleep(25)
            seen = CommandRunnerTest.processesWith(marker)
        }
        assertEquals("processes running sleep $marker", count, seen.size)
    }

    /** This test's processes: its sleeps, and everything whose command line names its runtime root. */
    private fun leftovers(): List<Long> =
        (CommandRunnerTest.processesWith(marker) + CommandRunnerTest.processesWith(root.absolutePath)).distinct()

    /** The delivery thread, recording the delay of every flush asked of it (and of every task: 0). */
    private class RecordingExecutor : ScheduledThreadPoolExecutor(1) {
        val delays: MutableList<Long> = Collections.synchronizedList(ArrayList<Long>())

        override fun schedule(command: Runnable, delay: Long, unit: TimeUnit): ScheduledFuture<*> {
            delays.add(unit.toNanos(delay))
            return super.schedule(command, delay, unit)
        }

        /** The delays asked for after the first [count]. */
        fun since(count: Int): List<Long> = synchronized(delays) { delays.drop(count) }
    }

    /**
     * A view, attached from a session's first byte: takes every batch,
     * checks that the offsets start at 0 and follow on, and acknowledges
     * unless told not to.
     */
    private class Screen(private val keep: Boolean = true) : TerminalOutputListener {
        private val lock = ReentrantLock()
        private val grew = lock.newCondition()
        private val text = StringBuilder()
        private var next = 0L
        private var first = 0L
        private var last = 0L

        @Volatile
        var acknowledging = true

        @Volatile
        var received = 0L
            private set

        @Volatile
        var batches = 0
            private set

        @Volatile
        var gaps = 0
            private set

        @Volatile
        var zs = 0L
            private set

        /** The offset after the last byte received. */
        val end: Long get() = lock.withLock { next }

        override fun output(session: TerminalSession, offset: Long, bytes: ByteArray) {
            lock.withLock {
                if (offset != next) gaps += 1
                next = offset + bytes.size
                received += bytes.size
                batches += 1
                val now = System.nanoTime()
                if (first == 0L) first = now
                last = now
                var z = 0L
                for (byte in bytes) if (byte == Z) z += 1
                zs += z
                if (keep) text.append(String(bytes, Charsets.ISO_8859_1))
                grew.signalAll()
            }
            if (acknowledging) session.acknowledge(offset + bytes.size)
        }

        /** From the first batch to the last, in nanoseconds. */
        fun span(): Long = lock.withLock { last - first }

        /** Waits until the screen holds [pattern] at or after [from]; answers where it ends. */
        fun waitFor(pattern: String, from: Int = 0, timeoutMs: Long = 20_000L): Int {
            val deadline = System.nanoTime() + timeoutMs * 1_000_000L
            lock.lock()
            try {
                while (true) {
                    val at = text.indexOf(pattern, from)
                    if (at >= 0) return at + pattern.length
                    val left = deadline - System.nanoTime()
                    if (left <= 0) {
                        val seen = text.substring(minOf(from, text.length)).replace(ESCAPES, "")
                        throw AssertionError("no \"$pattern\" in $timeoutMs ms; the screen shows: $seen")
                    }
                    grew.awaitNanos(left)
                }
            } finally {
                lock.unlock()
            }
        }

        /** Waits until at least [count] bytes have arrived. */
        fun waitForBytes(count: Long, timeoutMs: Long = 20_000L) {
            val deadline = System.nanoTime() + timeoutMs * 1_000_000L
            lock.withLock {
                while (received < count) {
                    val left = deadline - System.nanoTime()
                    if (left <= 0) throw AssertionError("$received of $count bytes in $timeoutMs ms")
                    grew.awaitNanos(left)
                }
            }
        }
    }

    companion object {
        private val PROGRAMS = listOf("bash", "sh", "sleep", "stty", "cat", "head", "tr", "pwd")
        private val serial = AtomicInteger()
        private val Z = 'Z'.code.toByte()
        private val ESCAPES = Regex("\u001b\\[[0-9;?]*[A-Za-z]")

        /** The launcher, compiled once for the class; null without a compiler. */
        private var launcher: File? = null

        /** A program of this machine's, by name. */
        fun locate(name: String): File? =
            listOf("/bin", "/usr/bin").map { File(it, name) }.firstOrNull { it.canExecute() }

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
