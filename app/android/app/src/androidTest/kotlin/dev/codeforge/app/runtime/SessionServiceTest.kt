package dev.codeforge.app.runtime

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.Os
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import dev.codeforge.app.terminal.SessionService
import dev.codeforge.runtime.core.HarnessConfig
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters

/**
 * Gate G5 on a device (Phase 5 W5): sessions that last, through the app's
 * own hub (RuntimeHubs: the runtime where the app keeps it), SessionKeeper
 * and SessionService, as a session the user starts gets them. The runtime
 * legs run it on API 26 to 36 (app/tool/ci/runtime_gate_leg.sh), and Test
 * Lab on an arm64 phone.
 *
 *   * The foreground service starts with the first session, in the
 *     foreground, its notification counting the sessions ("1 terminal
 *     session running", "2 terminal sessions running"; on Android 13 and
 *     later once the notification is allowed, and without it the service
 *     runs all the same), and stops after the last session ends.
 *   * End all, sent through the notification's own action, ends every tree:
 *     no process of them is left, and the service stops.
 *   * The limits a session runs under, measured in one: the file size, the
 *     count of processes and the OOM score (SessionLimits), each as the
 *     kernel holds the session to it, beside the app's own and the count of
 *     the app's user's processes and threads; no CPU limit.
 *   * The ledger on the device's storage: what a new process reads there
 *     leaves a tombstone for each session, "system" for one that still ran.
 *
 * Every figure goes to the device log (RUNTIME_GATE key=value) and to
 * files/runtime-gate/session-service-report.txt, which the gate copies out.
 * Process death itself, and what becomes of the sessions' processes then,
 * is the phase gate's (app/tool/ci/emulator_gate.sh, the sessions group).
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class SessionServiceTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val gate = File(context.filesDir, "runtime-gate")

    private fun record(key: String, value: Any?) {
        val line = "service_$key=$value"
        Log.i(TAG, "RUNTIME_GATE $line")
        gate.mkdirs()
        File(gate, REPORT).appendText(line + "\n")
    }

    @After
    fun endWhatIsLeft() {
        val terminals = RuntimeHubs.get(context).terminals() ?: return
        terminals.endAll()
        for (session in terminals.list()) {
            awaitExit(session, 10_000L)
            terminals.remove(session.id)
        }
        for (tombstone in terminals.tombstones()) terminals.remove(tombstone.id)
    }

    @Test
    fun a_theServiceStartsWithTheFirstSessionAndStopsAfterTheLast() {
        File(gate, REPORT).delete()
        ready()
        assertEquals("no session, no service", "none", service())

        val asked = SystemClock.uptimeMillis()
        val first = start(TerminalSpec(program = "sleep", arguments = listOf(MARKER_A), label = "first"))
        awaitService("foreground")
        record("start_ms", SystemClock.uptimeMillis() - asked)
        record("started_with_first", 1)
        // Android 13 and later show it once the user allows notifications;
        // the app asks at the first session in its UI, and this test is no
        // user. The service runs in the foreground either way.
        val allowed = notificationsAllowed()
        record("notifications_allowed_at_first", if (allowed) 1 else 0)
        if (allowed) {
            awaitTitle("1 terminal session running")
        } else {
            assertEquals(null, title())
            record("first_without_notification", "foreground")
            shell("pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS")
            assertTrue("the notification permission was not granted", notificationsAllowed())
        }

        val second = start(TerminalSpec(program = "sleep", arguments = listOf(MARKER_A), label = "second"))
        record("title_two", awaitTitle("2 terminal sessions running"))
        assertTrue(first.end())
        awaitExit(first)
        record("title_one", awaitTitle("1 terminal session running"))
        assertEquals("foreground", service())

        assertTrue(second.end())
        awaitExit(second)
        val ended = SystemClock.uptimeMillis()
        awaitService("none")
        record("stop_ms", SystemClock.uptimeMillis() - ended)
        awaitTitle(null)
        record("stopped_after_last", 1)
        assertEquals(false, SessionService.active)
    }

    @Test
    fun b_endAllFromTheNotificationEndsEveryTree() {
        ready()
        if (!notificationsAllowed()) shell("pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS")
        val before = ownProcesses()
        // An interactive shell gives each job a group of its own; a subshell's
        // orphan; and a plain script's children in the launcher's group.
        val shell = start(TerminalSpec(label = "shell"))
        assertEquals(null, shell.write("sleep $MARKER_B &\rsleep $MARKER_B &\r(sleep $MARKER_B &)\r".toByteArray()))
        val script = start(TerminalSpec(program = "bash", arguments = listOf("-c", "sleep $MARKER_B & sleep $MARKER_B"), label = "script"))
        val deadline = SystemClock.uptimeMillis() + 60_000L
        while (sleeps(MARKER_B).size < 5 && SystemClock.uptimeMillis() < deadline) Thread.sleep(50)
        assertEquals("the trees did not start", 5, sleeps(MARKER_B).size)
        awaitTitle("2 terminal sessions running")

        val action = notification()?.actions?.firstOrNull { it.title?.toString() == "End all" }
        assertNotNull("the notification has no End all", action)
        val sent = SystemClock.uptimeMillis()
        action!!.actionIntent.send()
        val shellExit = awaitExit(shell)
        val scriptExit = awaitExit(script)
        val endMs = SystemClock.uptimeMillis() - sent
        awaitService("none")
        val leftover = withMarker(MARKER_B)
        val after = ownProcesses()
        record(
            "end_all",
            "ms=$endMs shell=${shellExit.failure?.code}/${shellExit.leftovers} " +
                "script=${scriptExit.failure?.code}/${scriptExit.leftovers} " +
                "processes_before=${before.size} processes_after=${after.size}",
        )
        record("end_all_left", listOf(shell, script).count { it.state != TerminalState.EXITED })
        record("end_all_processes_left", leftover.size + (after - before).size)
        record("end_all_stopped", if (SessionService.active) 0 else 1)
        assertEquals(TerminalFailure.ENDED, shellExit.failure)
        assertEquals(TerminalFailure.ENDED, scriptExit.failure)
        assertEquals("processes of the trees remain: $leftover", emptyList<Int>(), leftover)
        assertTrue("new processes remain: ${after - before}", (after - before).isEmpty())
    }

    @Test
    fun c_theLimitsAreMeasuredInASession() {
        ready()
        // What the app's process has: what the launcher starts from.
        val limits = File("/proc/self/limits").readLines()
        fun soft(name: String): String =
            limits.firstOrNull { it.startsWith(name) }?.substring(name.length)?.trim()?.split(Regex("\\s+"))?.firstOrNull() ?: "?"
        val appFsize = soft("Max file size")
        val appNproc = soft("Max processes")
        val appScore = File("/proc/self/oom_score_adj").readText().trim().toInt()
        record("app_fsize", appFsize)
        record("app_nproc", appNproc)
        record("app_oom_score_adj", appScore)
        val tasks = userTasks()
        record("uid_tasks", tasks)

        // One session measures itself, then shows the kernel holding it to a
        // file size (64 KiB for the measure) and to a count of processes (a
        // little above what the user runs now), on this device's kernel.
        val out = File(context.cacheDir, "session-limits.txt")
        out.delete()
        File(out.path + ".big").delete()
        val fork = "import os, sys, time\n" +
            "started = refused = 0\n" +
            "for _ in range(120):\n" +
            "    try:\n" +
            "        pid = os.fork()\n" +
            "    except BlockingIOError:\n" +
            "        refused += 1\n" +
            "        continue\n" +
            "    if pid == 0:\n" +
            "        time.sleep(float(sys.argv[1]))\n" +
            "        os._exit(0)\n" +
            "    started += 1\n" +
            "print('nproc_started=%d' % started)\n" +
            "print('nproc_refused=%d' % refused)\n"
        val path = out.absolutePath
        val script = "{\n" +
            " echo \"fsize_blocks=\$(ulimit -f)\"\n" +
            " echo \"fsize_hard_blocks=\$(ulimit -Hf)\"\n" +
            " echo \"nproc=\$(ulimit -u)\"\n" +
            " echo \"nproc_hard=\$(ulimit -Hu)\"\n" +
            " echo \"cpu=\$(ulimit -t)\"\n" +
            " echo \"core=\$(ulimit -c)\"\n" +
            " echo \"oom_score_adj=\$(cat /proc/self/oom_score_adj)\"\n" +
            " ( ulimit -f 64; head -c 100000 /dev/zero > '$path.big'; echo \"fsize_enforced_exit=\$?\" )\n" +
            " echo \"fsize_enforced_bytes=\$(wc -c < '$path.big')\"\n" +
            " ( ulimit -u ${tasks + NPROC_MARGIN}; python3 -c \"\$FORK\" $MARKER_C )\n" +
            "} > '$path.part' 2>&1\n" +
            "mv '$path.part' '$path'\n"
        val session = start(
            TerminalSpec(
                program = "bash",
                arguments = listOf("-c", script),
                environment = mapOf("FORK" to fork),
                label = "limits",
            ),
        )
        val exit = awaitExit(session, 120_000L)
        assertTrue("the session wrote no measures (exit ${exit.exitCode} ${exit.failure})", out.isFile)
        val measured = out.readLines().mapNotNull { line ->
            val equals = line.indexOf('=')
            if (equals <= 0) null else line.substring(0, equals) to line.substring(equals + 1).trim()
        }.toMap()
        Log.i(TAG, "session limits: $measured")
        val fsize = measured["fsize_blocks"]?.toLongOrNull()?.times(1024)
        val nproc = measured["nproc"]?.toLongOrNull()
        val score = measured["oom_score_adj"]?.toIntOrNull()
        record("session_fsize_bytes", fsize ?: measured["fsize_blocks"])
        record("session_fsize_hard_bytes", measured["fsize_hard_blocks"]?.toLongOrNull()?.times(1024) ?: measured["fsize_hard_blocks"])
        record("session_nproc", nproc ?: measured["nproc"])
        record("session_nproc_hard", measured["nproc_hard"])
        record("session_cpu", measured["cpu"])
        record("session_core", measured["core"])
        record("session_oom_score_adj", score ?: measured["oom_score_adj"])
        record("oom_score_raised", if (score != null && score > appScore) 1 else 0)
        val headroom = (nproc ?: 0L) - tasks
        record("nproc_headroom", headroom)
        record("nproc_safe", if (headroom >= NPROC_SAFE_HEADROOM) 1 else 0)
        val fsizeEnforced = measured["fsize_enforced_exit"] == "153" && measured["fsize_enforced_bytes"] == "65536"
        record("fsize_enforced", if (fsizeEnforced) 1 else 0)
        record("fsize_enforced_detail", "exit=${measured["fsize_enforced_exit"]} bytes=${measured["fsize_enforced_bytes"]}")
        val refused = measured["nproc_refused"]?.toIntOrNull() ?: 0
        record("nproc_enforced", if (refused > 0) 1 else 0)
        record("nproc_enforced_detail", "limit=${tasks + NPROC_MARGIN} started=${measured["nproc_started"]} refused=$refused")

        val expectedNproc = appNproc.toLongOrNull()?.let { minOf(it, SessionLimits.SESSION.processes!!.toLong()) }
            ?: SessionLimits.SESSION.processes!!.toLong()
        assertEquals(SessionLimits.SESSION.fileBytes, fsize)
        assertEquals(expectedNproc, nproc)
        assertEquals("unlimited", measured["cpu"])
        assertEquals("0", measured["core"])
        assertTrue("the OOM score went down: $score < $appScore", score != null && score >= appScore)
        assertTrue("the file size limit did not hold: $measured", fsizeEnforced)
        assertTrue("no fork was refused at ${tasks + NPROC_MARGIN}: $measured", refused > 0)
        File(out.path + ".big").delete()
    }

    @Test
    fun d_aNewProcessFindsTombstonesInTheLedger() {
        ready()
        val running = start(TerminalSpec(program = "sleep", arguments = listOf(MARKER_D), label = "still running"))
        val done = start(TerminalSpec(program = "bash", arguments = listOf("-c", "exit 7"), label = "done"))
        assertEquals(7, awaitExit(done).exitCode)
        // What the next process reads: the same file, on this device's storage.
        val environment = RuntimeEnvironment(HarnessConfig.builder(context).build())
        val ledger = SessionLedger(File(environment.root, "codeforge/terminal/${Terminals.LEDGER_FILE}"))
        val deadline = SystemClock.uptimeMillis() + 10_000L
        var graves = SessionLedger.tombstonesOf(ledger.read())
        while (SystemClock.uptimeMillis() < deadline && graves.none { it.id == done.id && it.exitCode == 7 }) {
            Thread.sleep(50)
            graves = SessionLedger.tombstonesOf(ledger.read())
        }
        val ofRunning = graves.firstOrNull { it.id == running.id }
        val ofDone = graves.firstOrNull { it.id == done.id }
        record("ledger_running_tombstone", ofRunning?.failure?.code)
        record("ledger_exited_tombstone", ofDone?.exitCode?.let { "exit:$it" } ?: ofDone?.failure?.code)
        assertEquals(TerminalFailure.SYSTEM, ofRunning?.failure)
        assertEquals("still running", ofRunning?.label)
        assertEquals(7, ofDone?.exitCode)
        assertTrue(running.end())
        awaitExit(running)
    }

    // ── Helpers ──────────────────────────────────────────────────────

    /** The app's hub with its runtime ready: started now (warm, or installed) if no test before did. */
    private fun ready(): RuntimeHub {
        val hub = RuntimeHubs.get(context)
        val settled = AtomicReference<RuntimeStatus?>(null)
        val done = CountDownLatch(1)
        val watch: (RuntimeStatus) -> Unit = { status ->
            val over = when (status.state) {
                RuntimeState.READY, RuntimeState.DEGRADED, RuntimeState.FAILED, RuntimeState.UNAVAILABLE -> true
                else -> false
            }
            if (over && settled.compareAndSet(null, status)) done.countDown()
        }
        hub.addListener(watch)
        try {
            hub.start(watch)
            watch(hub.snapshot())
            assertTrue("the runtime did not settle: ${hub.snapshot()}", done.await(SETTLE_MS, TimeUnit.MILLISECONDS))
        } finally {
            hub.removeListener(watch)
        }
        val status = settled.get()!!
        assertTrue(
            "the runtime is ${status.state.code}: ${status.problem?.code} ${status.detail}",
            status.state == RuntimeState.READY || status.state == RuntimeState.DEGRADED,
        )
        return hub
    }

    /** Starts a session through the hub, as TerminalHost does, with no view. */
    private fun start(spec: TerminalSpec): TerminalSession {
        val result = AtomicReference<TerminalStart?>(null)
        val done = CountDownLatch(1)
        RuntimeHubs.get(context).startTerminal(spec, null) { start ->
            result.set(start)
            done.countDown()
        }
        assertTrue("no answer to the start", done.await(60, TimeUnit.SECONDS))
        val started = result.get()!!
        return started.session ?: throw AssertionError("not started: ${started.failure} ${started.detail}")
    }

    private fun awaitExit(session: TerminalSession, timeoutMs: Long = 30_000L): TerminalExit {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() < deadline) {
            session.exit?.let { return it }
            Thread.sleep(20)
        }
        throw AssertionError("session ${session.id} did not exit in $timeoutMs ms")
    }

    /** The service as Android lists it: foreground, background (started, not in the foreground) or none. */
    private fun service(): String {
        val manager = context.getSystemService(ActivityManager::class.java)
        @Suppress("DEPRECATION")
        val ours = manager.getRunningServices(Int.MAX_VALUE).firstOrNull { it.service.className == SessionService::class.java.name }
        return when {
            ours == null -> "none"
            ours.foreground -> "foreground"
            else -> "background"
        }
    }

    private fun awaitService(expected: String, timeoutMs: Long = 15_000L) {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (service() != expected && SystemClock.uptimeMillis() < deadline) Thread.sleep(50)
        assertEquals("the session service", expected, service())
    }

    private fun notificationsAllowed(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission("android.permission.POST_NOTIFICATIONS") == PackageManager.PERMISSION_GRANTED

    private fun notification(): Notification? =
        context.getSystemService(NotificationManager::class.java).activeNotifications
            .firstOrNull { it.id == SessionService.NOTIFICATION_ID }?.notification

    private fun title(): String? = notification()?.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()

    /** Waits for the notification's title to be [expected] (null: no notification); answers it. */
    private fun awaitTitle(expected: String?, timeoutMs: Long = 15_000L): String? {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (title() != expected && SystemClock.uptimeMillis() < deadline) Thread.sleep(50)
        assertEquals("the notification's title", expected, title())
        return expected
    }

    /** Runs [command] as the shell user (UiAutomation), and answers what it printed. */
    private fun shell(command: String): String {
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
        return ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { it.readText() }
    }

    /** The app's processes (its user id's), zombies aside. */
    private fun ownProcesses(): Set<Int> {
        val uid = Os.getuid().toString()
        return File("/proc").listFiles().orEmpty().mapNotNull { it.name.toIntOrNull() }
            .filter { pid -> field(pid, "Uid:")?.split(Regex("\\s+"))?.firstOrNull() == uid }
            .filter { pid -> field(pid, "State:")?.startsWith("Z") != true }
            .toSet()
    }

    /** Every process and thread of the app's user: what Linux holds RLIMIT_NPROC against. */
    private fun userTasks(): Int = ownProcesses().sumOf { pid -> field(pid, "Threads:")?.toIntOrNull() ?: 0 }

    /** A field of /proc/<pid>/status, after its name. */
    private fun field(pid: Int, name: String): String? =
        try {
            File("/proc/$pid/status").readLines().firstOrNull { it.startsWith(name) }?.substring(name.length)?.trim()
        } catch (gone: Exception) {
            null
        }

    private fun arguments(pid: Int): List<String> =
        try {
            String(File("/proc/$pid/cmdline").readBytes(), Charsets.UTF_8).split('\u0000').filter { it.isNotEmpty() }
        } catch (gone: Exception) {
            emptyList()
        }

    private fun withMarker(marker: String): List<Int> =
        ownProcesses().filter { pid -> arguments(pid).any { it.contains(marker) } }

    private fun sleeps(marker: String): List<Int> =
        ownProcesses().filter { pid ->
            val arguments = arguments(pid)
            arguments.size == 2 && arguments[0].endsWith("sleep") && arguments[1] == marker
        }

    private companion object {
        const val TAG = "CodeForgeRuntimeGate"
        const val REPORT = "session-service-report.txt"
        const val SETTLE_MS = 10 * 60 * 1000L

        /** Sleeps no other process runs: their durations name each test's processes. */
        const val MARKER_A = "300.5101"
        const val MARKER_B = "300.5102"
        const val MARKER_C = "20.5103"
        const val MARKER_D = "300.5104"

        /** The process limit the fork measure sets: this far above what the user runs. */
        const val NPROC_MARGIN = 16

        /** What the user may start beyond what it runs, for the session limit to count as safe. */
        const val NPROC_SAFE_HEADROOM = 1024L
    }
}
