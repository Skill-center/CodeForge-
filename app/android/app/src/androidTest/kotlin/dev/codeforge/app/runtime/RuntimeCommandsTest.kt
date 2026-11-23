package dev.codeforge.app.runtime

import android.content.Context
import android.os.Build
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import dev.codeforge.runtime.core.HarnessConfig
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters

/**
 * Gate G4 on a device (Phase 4 W4): the runtime's commands, its environment,
 * its tools and its process hygiene, over the APK's own payload installed
 * into a root of the gate's own (files/runtime-gate/commands). The emulator
 * gate's runtime group runs it with RuntimeInstallTest, in either order
 * (app/tool/ci/emulator_gate.sh); Phase 4 W5 runs it on an arm64 phone.
 *
 *   * The seven probed tools run, load their libraries, and are their
 *     packages' pinned versions.
 *   * A command's environment is exactly the one RuntimeEnvironment builds:
 *     nothing else of the app's process (a canary variable included), HOME,
 *     TMPDIR and XDG in the runtime's root, PYTHONHOME, GEM_HOME and
 *     NODE_PATH set, and CodeForge's preload.
 *   * A script with Termux's official `#!` line (npm) runs, through the
 *     preload.
 *   * Results are typed: exit codes, separate and capped output, the home as
 *     the working directory, refusals, the time limit.
 *   * Ending a session (by request, by its time limit, or when its command
 *     exits) leaves no child: no process of the command's tree, in its group
 *     or out of it, and no process of the app beyond the ones before.
 *   * Phase 5 W7, recorded and not judged: whether node loads a native addon
 *     written to the app's storage (test g).
 *
 * Every figure goes to the device log (RUNTIME_GATE key=value) and to
 * files/runtime-gate/commands-report.txt, which the gate copies out. A file
 * of its own: the runner orders the classes by name, so this one runs first,
 * and RuntimeInstallTest starts its report.txt afresh (phase gate
 * 43837693816 lost these figures from runtime.txt that way; the device log
 * kept them).
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class RuntimeCommandsTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val gate = File(context.filesDir, "runtime-gate")

    private fun record(key: String, value: Any?) {
        val line = "commands_$key=$value"
        Log.i(TAG, "RUNTIME_GATE $line")
        gate.mkdirs()
        File(gate, REPORT).appendText(line + "\n")
    }

    private fun run(program: String, vararg arguments: String, timeoutMs: Long = 60_000L, outputLimit: Int = 64 * 1024) =
        commands().runner.run(CommandRequest(program, arguments.toList(), timeoutMs = timeoutMs, outputLimit = outputLimit))

    @Test
    fun a_theToolsAreTheirPinnedVersions() {
        File(gate, REPORT).delete()
        val payload = commands()
        val pins = Toolchain.pinsFrom(info)
        assertEquals("the payload's info names every probed tool", 7, pins.size)
        val report = payload.toolchain.inspect(pins)
        record("tools_ms", report.millis)
        for (tool in report.tools) {
            record("tool_${tool.tool}", "${tool.version}/${tool.health.code} pinned=${tool.pinned} ms=${tool.millis} detail=${tool.detail}")
        }
        for (tool in report.tools) {
            assertEquals("${tool.tool}: ${tool.detail}", ToolHealth.OK, tool.health)
            assertEquals(tool.tool, Toolchain.upstream(tool.pinned!!), tool.version)
        }
    }

    @Test
    fun b_theEnvironmentIsTheRuntimesOwnAndNothingElse() {
        val payload = commands()
        val environment = payload.environment
        val result = run("env")
        assertEquals(result.stderr.text, 0, result.exitCode)
        val seen = result.stdout.text.lines().filter { it.contains('=') }
            .associate { it.substringBefore('=') to it.substringAfter('=') }
        val built = environment.variables(environment.home)
        record("environment_names", seen.keys.sorted().joinToString(","))
        assertEquals("the command sees exactly what the runtime built", built.keys.sorted(), seen.keys.sorted())
        assertTrue("the canary of the app's process leaked", seen.keys.none { it == CANARY })
        val root = environment.root.absolutePath + File.separator
        for (name in listOf("HOME", "TMPDIR", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME")) {
            assertTrue("$name=${seen[name]}", seen[name]!!.startsWith(root))
        }
        // Phase 7 W1: git's programs and templates, named in the prefix.
        for (name in listOf("PYTHONHOME", "GEM_HOME", "NODE_PATH", "GIT_EXEC_PATH", "GIT_TEMPLATE_DIR")) {
            val value = seen[name]
            record(name.lowercase(), value)
            assertNotNull("$name is not set", value)
            assertTrue("$name=$value is not a folder", File(value!!).isDirectory)
        }
        record("rubylib", seen["RUBYLIB"])
        record("perl5lib", seen["PERL5LIB"])
        assertEquals(File(context.applicationInfo.nativeLibraryDir, RuntimeEnvironment.PRELOAD).absolutePath, seen["LD_PRELOAD"])
    }

    @Test
    fun c_aScriptWithTermuxsOfficialShebangRunsThroughThePreload() {
        val npm = JSONObject(info).getJSONArray("core").let { core ->
            (0 until core.length()).map { core.getJSONObject(it) }.first { it.getString("package") == "npm" }
        }.getString("version")
        val result = run("npm", "--version")
        record("npm_version", "${result.stdout.text.trim()} exit=${result.exitCode} failure=${result.failure?.code} ms=${result.durationMs}")
        assertEquals("${result.failure} ${result.detail} ${result.stderr.text}", 0, result.exitCode)
        assertEquals(Toolchain.upstream(npm), result.stdout.text.trim())
    }

    @Test
    fun d_resultsAreTyped() {
        val failed = run("bash", "-c", "echo out; echo err >&2; exit 3")
        assertEquals(3, failed.exitCode)
        assertEquals("out\n", failed.stdout.text)
        assertEquals("err\n", failed.stderr.text)

        val big = run("bash", "-c", "head -c 300000 /dev/zero | tr '\\0' x", outputLimit = 1024)
        record("cap", "kept=${big.stdout.text.length} bytes=${big.stdout.bytes} truncated=${big.stdout.truncated}")
        assertEquals(0, big.exitCode)
        assertEquals(1024, big.stdout.text.length)
        assertEquals(300_000L, big.stdout.bytes)
        assertTrue(big.stdout.truncated)

        val home = run("pwd")
        assertEquals(File(commands().environment.home.absolutePath).canonicalPath, File(home.stdout.text.trim()).canonicalPath)

        assertEquals(CommandFailure.NOT_FOUND, run("no-such-tool").failure)
        assertEquals(CommandFailure.BAD_REQUEST, run("/system/bin/sh").failure)
        val outside = commands().runner.run(CommandRequest("pwd", directory = context.filesDir))
        assertEquals(CommandFailure.BAD_REQUEST, outside.failure)

        val slow = run("sleep", "30", timeoutMs = 500L)
        record("timeout", "failure=${slow.failure?.code} ms=${slow.durationMs} ended=${slow.leftovers}")
        assertEquals(CommandFailure.TIMED_OUT, slow.failure)
        assertTrue("took ${slow.durationMs} ms", slow.durationMs < 10_000L)
    }

    @Test
    fun e_endingASessionLeavesNoChild() {
        val payload = commands()
        val before = ownProcesses()
        val marker = "300.4711"
        // Children in the group, a subshell's orphan, and one that left the
        // group for a session of its own (util-linux's setsid, when present).
        val setsid = if (File(payload.environment.bin, "setsid").exists()) "setsid sleep $marker & " else ""
        val script = "sleep $marker & sleep $marker & (sleep $marker &) ; ${setsid}echo started; sleep $marker"
        var result: CommandResult? = null
        val thread = Thread { result = run("bash", "-c", script, timeoutMs = 120_000L) }
        thread.start()
        // The sleeps: two in the group, the subshell's orphan, the one in a
        // session of its own (with setsid), and the one bash waits for.
        val expected = if (setsid.isEmpty()) 4 else 5
        val deadline = System.nanoTime() + 30_000_000_000L
        while (sleeps(marker).size < expected && System.nanoTime() < deadline) Thread.sleep(50)
        val running = sleeps(marker)
        val session = payload.sessions.live().single()
        val group = session.group()
        record("tree", "sleeps=${running.size} with_marker=${withMarker(marker).size} group=$group " +
            "in_group=${inGroup(group).size} setsid=${setsid.isNotEmpty()}")
        assertEquals("the tree did not start", expected, running.size)

        val ended = System.nanoTime()
        assertEquals(0, payload.sessions.endAll(EndReason.ENDED))
        payload.sessions.reopen()
        thread.join(30_000L)
        val endMs = (System.nanoTime() - ended) / 1_000_000L
        val left = withMarker(marker)
        val after = ownProcesses()
        record("end", "failure=${result?.failure?.code} ended=${result?.leftovers} remaining=${result?.remaining} ms=$endMs " +
            "left=${left.size} in_group=${inGroup(group).size} processes_before=${before.size} processes_after=${after.size}")
        assertEquals(CommandFailure.ENDED, result!!.failure)
        assertEquals(0, result.remaining)
        assertEquals("processes of the tree remain: $left", emptyList<Int>(), left)
        assertEquals("processes of its group remain", emptyList<Int>(), inGroup(group))
        assertTrue("new processes remain: ${after - before}", (after - before).isEmpty())
    }

    @Test
    fun f_aTimeLimitAndAnExitEndTheirTreesToo() {
        val timed = run("bash", "-c", "sleep 300.4712 & sleep 300.4712", timeoutMs = 1000L)
        assertEquals(CommandFailure.TIMED_OUT, timed.failure)
        val leftAfterTimeout = withMarker("300.4712")

        val exited = run("bash", "-c", "sleep 300.4713 & echo started")
        val leftAfterExit = withMarker("300.4713")
        record("timeout_tree", "ended=${timed.leftovers} left=${leftAfterTimeout.size}")
        record("exit_tree", "exit=${exited.exitCode} ended=${exited.leftovers} left=${leftAfterExit.size}")
        assertEquals(emptyList<Int>(), leftAfterTimeout)
        assertEquals(0, exited.exitCode)
        assertEquals(1, exited.leftovers)
        assertEquals(emptyList<Int>(), leftAfterExit)
    }

    /**
     * Phase 5 W7, recorded and not judged: whether node loads a native addon
     * (a `.node` library) from the app's storage, where `npm install` of a
     * package with a prebuilt Android addon leaves one (PHASE_5_PLAN §9, Play's
     * Device and Network Abuse policy). The library is a copy of the APK's own
     * preload, which has no constructor. Node's `process.dlopen` either maps
     * it and then finds no module in it ("did not self-register": loaded), or
     * the system refuses to map it (refused). ExecModelTest's rule for
     * programs, refused when the app targets API 29 or later and the device
     * runs API 29 or later, is recorded beside it as what is expected; the
     * test asserts only that node ran the probe and gave one of the two.
     */
    @Test
    fun g_whetherNodeLoadsAnAddonFromTheAppsStorage() {
        val payload = commands()
        val library = File(context.applicationInfo.nativeLibraryDir, RuntimeEnvironment.PRELOAD)
        val copy = File(payload.environment.home, "cf-addon-probe.node")
        library.copyTo(copy, overwrite = true)
        val result = run("node", "-e", ADDON_PROBE, copy.absolutePath)
        copy.delete()
        val outcome = result.stdout.text.trim()
        val refusedByRule = context.applicationInfo.targetSdkVersion >= 29 && Build.VERSION.SDK_INT >= 29
        record("addon_from_storage", outcome.substringBefore(' '))
        record("addon_from_storage_expected", if (refusedByRule) "refused" else "loaded")
        record(
            "addon_from_storage_detail",
            "exit=${result.exitCode} sdk=${Build.VERSION.SDK_INT} ms=${result.durationMs} ${outcome.take(300).replace('\n', ' ')}",
        )
        assertEquals("${result.failure} ${result.detail} ${result.stderr.text}", 0, result.exitCode)
        assertTrue(outcome, outcome.startsWith("loaded") || outcome.startsWith("refused"))
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

    /** Every process of the app whose command line holds [marker]: the sleeps, bash, the launcher. */
    private fun withMarker(marker: String): List<Int> =
        ownProcesses().filter { pid -> arguments(pid).any { it.contains(marker) } }

    /** The app's `sleep <marker>` processes. */
    private fun sleeps(marker: String): List<Int> =
        ownProcesses().filter { pid ->
            val arguments = arguments(pid)
            arguments.size == 2 && arguments[0].endsWith("sleep") && arguments[1] == marker
        }

    private fun inGroup(group: Int?): List<Int> =
        if (group == null) emptyList() else ownProcesses().filter { pid -> stat(pid)?.getOrNull(2)?.toIntOrNull() == group }

    private fun state(pid: Int): Char? = stat(pid)?.getOrNull(0)?.firstOrNull()

    /** /proc/<pid>/stat after its command name: state, parent, group, ... */
    private fun stat(pid: Int): List<String>? =
        try {
            val text = File("/proc/$pid/stat").readText()
            text.substring(text.lastIndexOf(')') + 2).split(' ')
        } catch (gone: Exception) {
            null
        }

    private companion object {
        const val TAG = "CodeForgeRuntimeGate"
        const val REPORT = "commands-report.txt"
        const val CANARY = "CODEFORGE_CANARY_TOKEN"

        /** Loads its argument as a native addon and says what became of it (test g). */
        const val ADDON_PROBE =
            "const path = process.argv[1];" +
                " try { process.dlopen({ exports: {} }, path); console.log('loaded') }" +
                " catch (e) { const m = String(e && e.message);" +
                " console.log((/self-register/.test(m) ? 'loaded ' : 'refused ') + m) }"

        private var installed: RuntimeCommands? = null
        private var infoText: String? = null

        val info: String get() = infoText!!

        /** The payload installed once for the class, and its command side. */
        @Synchronized
        fun commands(): RuntimeCommands {
            installed?.let { return it }
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val root = File(context.filesDir, "runtime-gate/commands")
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
            val payload = runtime.payload() ?: throw AssertionError("this APK carries no payload")
            runtime.install(null)
            infoText = payload.info ?: throw AssertionError("the payload has no runtime-info")
            val created = RuntimeCommands.create(
                config = config,
                killGroup = { group -> Os.kill(-group, OsConstants.SIGKILL) },
                host = System.getenv() + (CANARY to "secret"),
            )
            installed = created
            return created
        }
    }
}
