package dev.codeforge.app.runtime

import android.content.Context
import android.os.Debug
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import dev.codeforge.runtime.core.HarnessConfig
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters

/**
 * Gate G2 on a device (Phase 5 W2): terminal sessions on the APK's own
 * payload, installed into a root of the gate's own
 * (files/runtime-gate/terminal), through the same Terminals, TerminalSession
 * and launcher the app uses. The runtime legs run it on API 26 to 36
 * (app/tool/ci/runtime_gate_leg.sh), and Test Lab on an arm64 phone.
 *
 *   * The runtime's bash echoes and answers, with TERM=xterm-256color and
 *     the payload's terminal descriptions (TERMINFO).
 *   * `stty size` follows a resize.
 *   * node's REPL answers 1+1.
 *   * A keystroke's echo through the whole path (the writer thread, the
 *     launcher's relay, the terminal, the reader, the batching) is well
 *     inside ADR-0006's 50 ms: W2's measurement of design (a).
 *   * A 10 MiB flood arrives whole, in order, with never more than the
 *     credit window unacknowledged, and the app's memory bounded.
 *   * The ninth session is refused.
 *   * End all leaves no process: none of the sessions' trees, in their
 *     groups or out of them, and no process of the app beyond the ones
 *     before.
 *
 * Every figure goes to the device log (RUNTIME_GATE key=value) and to
 * files/runtime-gate/terminal-report.txt, which the gate copies out.
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class TerminalSessionTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val gate = File(context.filesDir, "runtime-gate")

    private fun record(key: String, value: Any?) {
        val line = "terminal_$key=$value"
        Log.i(TAG, "RUNTIME_GATE $line")
        gate.mkdirs()
        File(gate, REPORT).appendText(line + "\n")
    }

    @After
    fun endWhatIsLeft() {
        val terminals = installed?.terminals ?: return
        terminals.endAll()
        for (session in terminals.list()) terminals.remove(session.id)
    }

    @Test
    fun a_bashEchoesAndAnswersInAnXtermTerminal() {
        File(gate, REPORT).delete()
        val terminals = terminals()
        val screen = Screen()
        val started = System.nanoTime()
        val session = start(terminals, TerminalSpec(), screen)
        session.write("echo forty-$((40 + 2))\r".toByteArray())
        val typed = screen.waitFor("echo forty-", timeoutMs = 60_000L)
        screen.waitFor("forty-42", typed)
        record("first_answer_ms", (System.nanoTime() - started) / 1_000_000L)
        // The terminal's descriptions are the payload's: ncurses has Termux's prefix compiled in.
        session.write("[ -r \"\$TERMINFO/x/xterm-256color\" ] && echo \"terminfo-\$TERM-ok\"\r".toByteArray())
        screen.waitFor("terminfo-xterm-256color-ok")
        record("bash", "ok")
        session.write("exit 3\r".toByteArray())
        val exit = awaitExit(session)
        record("bash_exit", exit.exitCode)
        assertEquals(3, exit.exitCode)
        assertNull(exit.detail, exit.failure)
    }

    @Test
    fun b_sttySizeFollowsAResize() {
        val screen = Screen()
        val session = start(terminals(), TerminalSpec(rows = 24, columns = 80), screen)
        session.write("stty size\r".toByteArray())
        val first = screen.waitFor("24 80", timeoutMs = 60_000L)
        assertNull(session.resize(40, 120))
        session.write("stty size\r".toByteArray())
        screen.waitFor("40 120", first)
        record("stty", "24x80,40x120")
    }

    @Test
    fun c_nodesReplAnswers() {
        val screen = Screen()
        val started = System.nanoTime()
        val session = start(terminals(), TerminalSpec(program = "node"), screen)
        screen.waitForPlain("> ", timeoutMs = 120_000L)
        record("node_prompt_ms", (System.nanoTime() - started) / 1_000_000L)
        session.write("1+1\r".toByteArray())
        // The answer comes coloured, and the REPL redraws its line: escapes stripped.
        val echoed = screen.waitForPlain("1+1")
        screen.waitForPlain("2", echoed)
        session.write(".exit\r".toByteArray())
        val exit = awaitExit(session)
        record("node_repl", "ok exit=${exit.exitCode}")
        assertEquals(0, exit.exitCode)
    }

    @Test
    fun d_aKeystrokesEchoIsWellInsideTheBudget() {
        val screen = Screen()
        val session = start(terminals(), TerminalSpec(program = "cat"), screen)
        Thread.sleep(500)
        val samples = ArrayList<Long>()
        repeat(ECHO_SAMPLES) {
            // A quiet moment first, as between keystrokes: no batch is due.
            Thread.sleep(40)
            val before = screen.received
            val sent = System.nanoTime()
            assertNull(session.write("x".toByteArray()))
            screen.waitForBytes(before + 1)
            samples.add(System.nanoTime() - sent)
        }
        samples.sort()
        val p50 = samples[samples.size / 2] / 1000
        val p95 = samples[samples.size * 95 / 100] / 1000
        val max = samples.last() / 1000
        record("echo_us", "p50=$p50 p95=$p95 max=$max n=${samples.size}")
        record("echo_p95_under_budget", if (p95 < ECHO_BUDGET_US) 1 else 0)
        assertTrue("echo p95 $p95 µs against ADR-0006's 50 ms", p95 < ECHO_BUDGET_US)
    }

    @Test
    fun e_aFloodArrivesWholeWithTheMemoryBounded() {
        val terminals = terminals()
        val total = 10L * 1024 * 1024
        val runtime = Runtime.getRuntime()
        System.gc()
        val heapBefore = runtime.totalMemory() - runtime.freeMemory()
        val nativeBefore = Debug.getNativeHeapAllocatedSize()
        val screen = Screen(keep = false)
        val started = System.nanoTime()
        val session = start(
            terminals,
            TerminalSpec(program = "bash", arguments = listOf("-c", "head -c $total /dev/zero | tr '\\0' Z")),
            screen,
        )
        val exit = awaitExit(session, 300_000L)
        val ms = (System.nanoTime() - started) / 1_000_000L
        System.gc()
        val heapGrowth = (runtime.totalMemory() - runtime.freeMemory() - heapBefore) / 1024
        val nativeGrowth = (Debug.getNativeHeapAllocatedSize() - nativeBefore) / 1024
        val whole = screen.zs == total && screen.received == total && screen.gaps == 0
        record(
            "flood",
            "bytes=${screen.received} batches=${screen.batches} ms=$ms high_water=${session.unacknowledgedHighWater} " +
                "window=${session.window} buffer=${session.bufferBytes} heap_growth_kib=$heapGrowth native_growth_kib=$nativeGrowth",
        )
        record("flood_whole", if (whole) 1 else 0)
        record("flood_within_window", if (session.unacknowledgedHighWater <= session.window) 1 else 0)
        assertEquals(0, exit.exitCode)
        assertEquals(total, screen.zs)
        assertEquals(total, screen.received)
        assertEquals(0, screen.gaps)
        assertTrue("held ${session.unacknowledgedHighWater}", session.unacknowledgedHighWater <= session.window)
        assertTrue("the heap grew by $heapGrowth KiB", heapGrowth < HEAP_GROWTH_LIMIT_KIB)
    }

    @Test
    fun f_theNinthSessionIsRefused() {
        val terminals = terminals()
        val marker = "300.4721"
        repeat(SessionRegistry.DEFAULT_MAX_TERMINALS) {
            start(terminals, TerminalSpec(program = "sleep", arguments = listOf(marker)))
        }
        val deadline = System.nanoTime() + 30_000_000_000L
        while (sleeps(marker).size < SessionRegistry.DEFAULT_MAX_TERMINALS && System.nanoTime() < deadline) Thread.sleep(50)
        assertEquals(SessionRegistry.DEFAULT_MAX_TERMINALS, sleeps(marker).size)
        val ninth = terminals.start(TerminalSpec(program = "sleep", arguments = listOf(marker)))
        record("ninth", ninth.failure?.code)
        assertNull(ninth.session)
        assertEquals(TerminalFailure.TOO_MANY, ninth.failure)
    }

    @Test
    fun g_endAllLeavesNoProcess() {
        val terminals = terminals()
        val before = ownProcesses()
        val marker = "300.4722"
        // An interactive shell gives each job a group of its own; a subshell's
        // orphan; and a plain script's children in the launcher's group.
        val screen = Screen()
        val shell = start(terminals, TerminalSpec(), screen)
        shell.write("sleep $marker &\rsleep $marker &\r(sleep $marker &)\r".toByteArray())
        val script = start(terminals, TerminalSpec(program = "bash", arguments = listOf("-c", "sleep $marker & sleep $marker")))
        val deadline = System.nanoTime() + 60_000_000_000L
        while (sleeps(marker).size < 5 && System.nanoTime() < deadline) Thread.sleep(50)
        val running = sleeps(marker).size
        record("end_all_tree", "sleeps=$running with_marker=${withMarker(marker).size}")
        assertEquals("the trees did not start", 5, running)

        val ending = System.nanoTime()
        val left = terminals.endAll()
        val endMs = (System.nanoTime() - ending) / 1_000_000L
        val shellExit = awaitExit(shell)
        val scriptExit = awaitExit(script)
        val leftover = withMarker(marker)
        val after = ownProcesses()
        record(
            "end_all",
            "left=$left ms=$endMs shell=${shellExit.failure?.code}/${shellExit.leftovers} " +
                "script=${scriptExit.failure?.code}/${scriptExit.leftovers} remaining=${shellExit.remaining + scriptExit.remaining} " +
                "processes_before=${before.size} processes_after=${after.size}",
        )
        record("end_all_left", left)
        record("end_all_processes_left", leftover.size + (after - before).size)
        assertEquals(0, left)
        assertEquals(TerminalFailure.ENDED, shellExit.failure)
        assertEquals(TerminalFailure.ENDED, scriptExit.failure)
        assertEquals(0, shellExit.remaining + scriptExit.remaining)
        assertEquals("processes of the trees remain: $leftover", emptyList<Int>(), leftover)
        assertTrue("new processes remain: ${after - before}", (after - before).isEmpty())
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private fun start(terminals: Terminals, spec: TerminalSpec, view: Screen? = null): TerminalSession {
        val result = terminals.start(spec, view)
        return result.session ?: throw AssertionError("not started: ${result.failure} ${result.detail}")
    }

    private fun awaitExit(session: TerminalSession, timeoutMs: Long = 30_000L): TerminalExit {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000L
        while (System.nanoTime() < deadline) {
            val exit = session.exit
            if (exit != null) return exit
            Thread.sleep(20)
        }
        throw AssertionError("session ${session.id} did not exit in $timeoutMs ms")
    }

    /** The app's processes (its user id's), zombies aside. */
    private fun ownProcesses(): Set<Int> {
        val uid = Os.getuid().toString()
        return File("/proc").listFiles().orEmpty().mapNotNull { it.name.toIntOrNull() }
            .filter { pid -> uidOf(pid) == uid }
            .filter { pid -> state(pid) != 'Z' }
            .toSet()
    }

    /** The real user id in /proc/<pid>/status ("Uid:\treal\teffective..."). */
    private fun uidOf(pid: Int): String? =
        try {
            File("/proc/$pid/status").readLines().firstOrNull { it.startsWith("Uid:") }
                ?.substringAfter(':')?.trim()?.split(Regex("\\s+"))?.firstOrNull()
        } catch (gone: Exception) {
            null
        }

    private fun arguments(pid: Int): List<String> =
        try {
            String(File("/proc/$pid/cmdline").readBytes(), Charsets.UTF_8).split('\u0000').filter { it.isNotEmpty() }
        } catch (gone: Exception) {
            emptyList()
        }

    /** Every process of the app whose command line holds [marker]: the sleeps, bash, the launchers. */
    private fun withMarker(marker: String): List<Int> =
        ownProcesses().filter { pid -> arguments(pid).any { it.contains(marker) } }

    /** The app's `sleep <marker>` processes. */
    private fun sleeps(marker: String): List<Int> =
        ownProcesses().filter { pid ->
            val arguments = arguments(pid)
            arguments.size == 2 && arguments[0].endsWith("sleep") && arguments[1] == marker
        }

    private fun state(pid: Int): Char? =
        try {
            val text = File("/proc/$pid/stat").readText()
            text.substring(text.lastIndexOf(')') + 2).firstOrNull()
        } catch (gone: Exception) {
            null
        }

    /**
     * A view, attached from a session's first byte: takes every batch,
     * checks that the offsets start at 0 and follow on, and acknowledges it.
     */
    private class Screen(private val keep: Boolean = true) : TerminalOutputListener {
        private val lock = ReentrantLock()
        private val grew = lock.newCondition()
        private val text = StringBuilder()
        private var next = 0L

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

        override fun output(session: TerminalSession, offset: Long, bytes: ByteArray) {
            lock.withLock {
                if (offset != next) gaps += 1
                next = offset + bytes.size
                received += bytes.size
                batches += 1
                var z = 0L
                for (byte in bytes) if (byte == Z) z += 1
                zs += z
                if (keep) text.append(String(bytes, Charsets.ISO_8859_1))
                grew.signalAll()
            }
            session.acknowledge(offset + bytes.size)
        }

        /** Waits until the screen holds [pattern] at or after [from]; answers where it ends. */
        fun waitFor(pattern: String, from: Int = 0, timeoutMs: Long = 30_000L): Int =
            await(timeoutMs, { text.toString() }, pattern, from)

        /** As [waitFor], in the screen without its escape sequences (colours, cursor moves). */
        fun waitForPlain(pattern: String, from: Int = 0, timeoutMs: Long = 30_000L): Int =
            await(timeoutMs, { text.toString().replace(ESCAPES, "") }, pattern, from)

        private fun await(timeoutMs: Long, screen: () -> String, pattern: String, from: Int): Int {
            val deadline = System.nanoTime() + timeoutMs * 1_000_000L
            lock.lock()
            try {
                while (true) {
                    val shown = screen()
                    val at = shown.indexOf(pattern, from)
                    if (at >= 0) return at + pattern.length
                    val left = deadline - System.nanoTime()
                    if (left <= 0) {
                        val tail = shown.substring(minOf(from, shown.length)).replace(ESCAPES, "").takeLast(600)
                        throw AssertionError("no \"$pattern\" in $timeoutMs ms; the screen shows: $tail")
                    }
                    grew.awaitNanos(left)
                }
            } finally {
                lock.unlock()
            }
        }

        /** Waits until at least [count] bytes have arrived. */
        fun waitForBytes(count: Long, timeoutMs: Long = 30_000L) {
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

    private companion object {
        const val TAG = "CodeForgeRuntimeGate"
        const val REPORT = "terminal-report.txt"
        const val ECHO_SAMPLES = 50

        /** ADR-0006's budget for a keystroke's echo. */
        const val ECHO_BUDGET_US = 50_000L

        /** The flood's bound on the app's Java heap: the buffer is 1 MiB, the window 256 KiB. */
        const val HEAP_GROWTH_LIMIT_KIB = 32L * 1024
        val Z = 'Z'.code.toByte()
        val ESCAPES = Regex("\u001b\\[[0-9;?]*[ -/]*[@-~]|\u001b\\][^\u0007]*\u0007|\u001b[()][A-Za-z0-9]|\u001b[=>]")

        private var installed: RuntimeCommands? = null

        /** The payload installed once for the class, and its terminals. */
        @Synchronized
        fun terminals(): Terminals {
            installed?.terminals?.let { return it }
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val root = File(context.filesDir, "runtime-gate/terminal")
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
            runtime.payload() ?: throw AssertionError("this APK carries no payload")
            runtime.install(null)
            val created = RuntimeCommands.create(
                config = config,
                killGroup = { group -> Os.kill(-group, OsConstants.SIGKILL) },
                projects = File(root, "projects"),
            )
            installed = created
            return created.terminals ?: throw AssertionError("the command side has no terminals")
        }
    }
}
