package dev.codeforge.app.runtime

import java.io.File
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The runtime hub's states (Phase 4 W3, gate G3): the install is lazy, a
 * start is a warm start or an install and then the audit, READY never
 * follows a failed install, and a new process finds the install it left.
 * Since W4 (gate G4): commands and the tool probes wait for a ready
 * runtime. The worker and the main thread are the test's own thread here.
 */
class RuntimeHubTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var root: File
    private lateinit var libraries: File
    private val direct = Executor { task -> task.run() }

    @Before
    fun setUp() {
        root = temp.newFolder("harness")
        libraries = temp.newFolder("lib")
        TestPayload.writeLibraries(libraries)
    }

    /** A hub as a new process would make it, and every snapshot it publishes. */
    private fun newHub(
        payload: TestPayload = TestPayload(),
        source: PayloadSource = payload.source(),
        clock: () -> Long = System::nanoTime,
    ): Pair<RuntimeHub, MutableList<RuntimeStatus>> {
        val seen = mutableListOf<RuntimeStatus>()
        val hub = RuntimeHub(
            runtimeFactory = { SealedRuntime(source, TestPayload.configFor(root, libraries)) },
            worker = direct,
            deliver = { task -> task.run() },
            apkBytes = { 42L },
            clock = clock,
        )
        hub.addListener { seen.add(it) }
        return hub to seen
    }

    private fun states(seen: List<RuntimeStatus>): List<RuntimeState> =
        seen.map { it.state }.fold(mutableListOf()) { states, state ->
            if (states.lastOrNull() != state) states.add(state)
            states
        }

    @Test
    fun nothingInstallsUntilSomethingStartsIt() {
        val (hub, seen) = newHub()
        var answer: RuntimeStatus? = null
        hub.status { answer = it }
        assertEquals(RuntimeState.NOT_INSTALLED, answer!!.state)
        assertEquals("x86_64", answer.abi)
        assertEquals("0123456789abcdef", answer.payloadId)
        assertNotNull(answer.info)
        assertFalse(seen.any { it.state == RuntimeState.INSTALLING })
    }

    @Test
    fun aFirstStartInstallsThenAudits() {
        val (hub, seen) = newHub()
        var answer: RuntimeStatus? = null
        hub.start { answer = it }

        assertEquals(
            listOf(RuntimeState.CHECKING, RuntimeState.INSTALLING, RuntimeState.READY),
            states(seen),
        )
        val last = hub.snapshot()
        assertEquals(RuntimeState.READY, last.state)
        assertFalse(last.auditing)
        assertTrue(last.audit!!.clean)
        assertNotNull(last.installMs)
        assertNull(last.warmStartMs)
        assertEquals(3, last.total)
        assertEquals(last.total, last.done)
        assertNull(last.problem)
        assertEquals(RuntimeState.READY, answer!!.state)
        // The audit ran after READY, and READY stayed.
        assertTrue(seen.any { it.state == RuntimeState.READY && it.auditing })
    }

    @Test
    fun aNewProcessFindsTheInstallAndStartsWarm() {
        newHub().first.start { }
        val (hub, seen) = newHub()
        hub.status { }
        assertEquals(RuntimeState.INSTALLED, hub.snapshot().state)
        assertNotNull(hub.snapshot().installMs)

        hub.start { }
        assertEquals(listOf(RuntimeState.INSTALLED, RuntimeState.CHECKING, RuntimeState.READY), states(seen))
        val last = hub.snapshot()
        assertNotNull(last.warmStartMs)
        assertEquals(0, last.relinked)
        assertTrue(last.audit!!.clean)
    }

    @Test
    fun aCorruptPayloadEndsFailedAndNeverReady() {
        val payload = TestPayload(wrongDigestFor = "etc/profile")
        val (hub, seen) = newHub(payload)
        hub.start { }
        assertFalse(seen.any { it.state == RuntimeState.READY || it.state == RuntimeState.DEGRADED })
        val last = hub.snapshot()
        assertEquals(RuntimeState.FAILED, last.state)
        assertEquals(RuntimeProblem.CORRUPT, last.problem)
        assertTrue(last.detail!!.contains("digest differs"))
        // Starting again does not retry: the same payload would fail the same way.
        val before = seen.size
        hub.start { }
        assertEquals(before, seen.size)
        // And a new process does not take the failed install for a finished one.
        val (again, _) = newHub(payload)
        again.status { }
        assertEquals(RuntimeState.NOT_INSTALLED, again.snapshot().state)
    }

    @Test
    fun aFlippedByteEndsFailedAndNeverReady() {
        val payload = TestPayload()
        val flipped = payload.source { name, data ->
            if (name.startsWith("userland-")) TestPayload.flip(data, data.size / 2) else data
        }
        val (hub, seen) = newHub(payload, flipped)
        hub.start { }
        assertFalse(seen.any { it.state == RuntimeState.READY })
        assertEquals(RuntimeState.FAILED, hub.snapshot().state)
        val problem = hub.snapshot().problem
        assertTrue("$problem", problem == RuntimeProblem.CORRUPT || problem == RuntimeProblem.INCOMPLETE)
    }

    @Test
    fun aSecondStartDoesNothing() {
        val (hub, seen) = newHub()
        hub.start { }
        val before = seen.size
        var answer: RuntimeStatus? = null
        hub.start { answer = it }
        assertEquals(before, seen.size)
        assertEquals(RuntimeState.READY, answer!!.state)
    }

    @Test
    fun aReinstallInstallsAgainAndAudits() {
        val (hub, seen) = newHub()
        hub.start { }
        seen.clear()
        hub.reinstall { }
        assertEquals(listOf(RuntimeState.INSTALLING, RuntimeState.READY), states(seen))
        assertTrue(hub.snapshot().audit!!.clean)
    }

    @Test
    fun aReinstallAfterAFailureCanSucceed() {
        val (failed, _) = newHub(TestPayload(wrongDigestFor = "etc/profile"))
        failed.start { }
        assertEquals(RuntimeState.FAILED, failed.snapshot().state)
        val (hub, _) = newHub()
        hub.reinstall { }
        assertEquals(RuntimeState.READY, hub.snapshot().state)
    }

    @Test
    fun withoutAPayloadTheRuntimeIsUnavailable() {
        val (hub, seen) = newHub(source = TestPayload().source(abi = null))
        hub.status { }
        assertEquals(RuntimeState.UNAVAILABLE, hub.snapshot().state)
        assertEquals(RuntimeProblem.NO_PAYLOAD, hub.snapshot().problem)
        hub.start { }
        hub.reinstall { }
        assertFalse(seen.any { it.state == RuntimeState.INSTALLING })
        assertEquals(RuntimeState.UNAVAILABLE, hub.snapshot().state)
    }

    @Test
    fun anExecutableOutsideTheApkDegradesTheRuntime() {
        val (hub, _) = newHub()
        hub.start { }
        val rogue = File(root, "rootfs/data/data/com.termux/files/usr/bin/rogue")
        rogue.writeBytes(TestPayload.ELF)
        assertTrue(rogue.setExecutable(true))
        var answer: RuntimeStatus? = null
        hub.audit { answer = it }
        assertEquals(RuntimeState.DEGRADED, answer!!.state)
        assertEquals(RuntimeProblem.OUTSIDE_APK, answer.problem)
        assertEquals(1, answer.audit!!.outsideApk)
        // Clean again once it is gone.
        rogue.delete()
        hub.audit { answer = it }
        assertEquals(RuntimeState.READY, answer.state)
        assertNull(answer.problem)
    }

    @Test
    fun progressArrivesAboutFiveTimesASecond() {
        val many = TestPayload(
            files = (1..50).associate { "share/f$it.txt" to "file $it\n".toByteArray() },
        )
        // Every reading of the clock is 10 ms later.
        var now = 0L
        val (hub, seen) = newHub(many, clock = { now += 10_000_000L; now })
        hub.start { }
        val notices = seen.filter { it.state == RuntimeState.INSTALLING && it.total > 0 }
        assertTrue("${notices.size} progress notices", notices.size in 2..10)
        assertEquals(50, notices.last().done)
        assertEquals(50, notices.last().total)
    }

    @Test
    fun revisionsOnlyGrow() {
        val (hub, seen) = newHub()
        hub.start { }
        hub.audit { }
        assertTrue(seen.size > 3)
        seen.zipWithNext().forEach { (before, after) -> assertTrue(after.revision > before.revision) }
    }

    @Test
    fun sizesAreMeasuredOnTheWorker() {
        val (hub, _) = newHub()
        hub.start { }
        var sizes: RuntimeSizes? = null
        hub.sizes { sizes = it }
        assertEquals(TestPayload().bytes, sizes!!.prefixBytes)
        assertEquals(42L, sizes.apkBytes)
    }

    /** The command side over this test's runtime, with the probes' commands answered by [answer]. */
    private fun commandsFor(answer: (CommandRequest) -> CommandResult): RuntimeCommands {
        val environment = RuntimeEnvironment(TestPayload.configFor(root, libraries), emptyMap())
        val sessions = SessionRegistry(killGroup = {})
        // No launcher here: a command that reaches the runner fails to launch.
        val runner = CommandRunner(environment, File(root, "no-launcher"), sessions, File(root, "codeforge/sessions"))
        return RuntimeCommands(environment, sessions, runner, Toolchain(run = answer, present = { true }))
    }

    @Test
    fun commandsAndProbesWaitForAReadyRuntime() {
        var made = 0
        val asked = mutableListOf<String>()
        val source = TestPayload().source()
        val hub = RuntimeHub(
            runtimeFactory = { SealedRuntime(source, TestPayload.configFor(root, libraries)) },
            worker = direct,
            deliver = { task -> task.run() },
            apkBytes = { 42L },
            commandsFactory = {
                made++
                commandsFor { request ->
                    asked.add(request.program)
                    // Each in its tool's shape, at a version no pin names.
                    val text = when (request.program) {
                        "git" -> "git version 1.0.0\n"
                        "rg" -> "ripgrep 1.0.0\n"
                        else -> "1.0.0\n"
                    }
                    CommandResult(0, null, CommandOutput(text, text.length.toLong(), false), CommandOutput.EMPTY, 5L, null, null, 0, 0)
                }
            },
            commandExecutor = direct,
        )

        var result: CommandResult? = null
        hub.exec(CommandRequest("sh")) { result = it }
        assertEquals(CommandFailure.NOT_READY, result!!.failure)
        var tools: ToolsReport? = null
        hub.tools { tools = it }
        assertTrue(tools!!.tools.all { it.health == ToolHealth.UNAVAILABLE })
        assertNotNull(tools!!.failure)
        assertEquals("nothing is made before the runtime is ready", 0, made)

        hub.start { }
        assertEquals(RuntimeState.READY, hub.snapshot().state)
        hub.tools { tools = it }
        assertNull(tools!!.failure)
        assertEquals(listOf("node", "python", "git", "bash", "perl", "ruby", "rg"), asked)
        // This payload's info has no tools' pins: no version is taken for the pinned one.
        assertTrue(tools!!.tools.all { it.health == ToolHealth.MISMATCH })

        hub.exec(CommandRequest("sh")) { result = it }
        assertEquals("the command reached the runner", CommandFailure.LAUNCH_FAILED, result!!.failure)
        assertEquals(1, made)
        assertNotNull(hub.currentCommands())
    }

    @Test
    fun aFailedInstallTakesNoCommands() {
        val payload = TestPayload(wrongDigestFor = "etc/profile")
        val hub = RuntimeHub(
            runtimeFactory = { SealedRuntime(payload.source(), TestPayload.configFor(root, libraries)) },
            worker = direct,
            deliver = { task -> task.run() },
            apkBytes = { 42L },
            commandsFactory = { commandsFor { CommandResult.failed(CommandFailure.LAUNCH_FAILED, "unused") } },
            commandExecutor = direct,
        )
        hub.start { }
        assertEquals(RuntimeState.FAILED, hub.snapshot().state)
        var result: CommandResult? = null
        hub.exec(CommandRequest("sh")) { result = it }
        assertEquals(CommandFailure.NOT_READY, result!!.failure)
        assertTrue(result!!.detail!!.contains("failed"))
    }
}
