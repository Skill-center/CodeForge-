package dev.codeforge.app.runtime

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import dev.codeforge.runtime.core.HarnessConfig
import dev.codeforge.runtime.sealed.ExecAudit
import java.io.File
import java.nio.file.Files
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters

/**
 * The milestone gate for a store-legal build: a real shell, shipped by the APK,
 * running at a modern targetSdkVersion.
 *
 * Every previous run proved the *mechanism* (a probe binary). This one
 * installs the sealed userland from the APK — the Termux bootstrap split into
 * data plus JNI libraries by `scripts/build-sealed-payload.py` — and then runs
 * the actual userland: `bash` and the core utilities, through the prefix paths
 * the rest of the harness uses, with the data-directory exec exemption gone
 * (targetSdk 34).
 *
 * It skips in the apt-based build, which has no payload; the workflow that
 * runs it asserts it did not skip.
 *
 * **CodeForge's port** (Phase 4 W5, gates G5 to G7) of t1's
 * `app/src/androidTest/java/io/mcyber12/codingharness/SealedShellTest.java` at
 * `d9789a2` (native/PROVENANCE.md). The assertions and their messages are
 * t1's; what they run on is CodeForge's host, because t1's runner, bootstrap
 * and packs were not vendored:
 *  - **the install:** the runtime host's [SealedRuntime] (t1's kernel, through
 *    [PayloadInstall]) instead of t1's `SealedPayloadInstaller.install`, into a
 *    root of the runtime gate's own (`files/runtime-gate/sealed-shell`). It
 *    throws a typed failure where t1's result was not ok, and verifies every
 *    file, as t1 asserts;
 *  - **the commands:** CodeForge's runner ([RuntimeCommands]: through the
 *    launcher, in the runtime's own environment, a program named from the
 *    runtime's bin) instead of t1's `HarnessCommandRunner`, which ran a path.
 *    A command's output is its stdout and then its stderr, where t1's runner
 *    merged the two;
 *  - **the app's startup path:** `RuntimeHubs.get(context).start`, the call
 *    RuntimeHost makes when a workspace opens, instead of t1's
 *    `HarnessBootstrap.ensureSealedPayload`; the next launch is a second
 *    [RuntimeHub] over the same runtime, made as RuntimeHubs makes the
 *    process's;
 *  - **t1's third test**, `packsComeFromTheStoreAndNeverFromApt`, waits for a
 *    pack: CodeForge has none before the build-tools pack (PROVENANCE);
 *  - a plain JUnit4 class (BUILD_AND_RELEASE §3), its tests in name order;
 *    the report as in [ExecModelTest]: lines to the device log (tag
 *    CodeForgeRuntimeGate), figures to files/runtime-gate/sealed-shell-report.txt.
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class SealedShellTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val gate = File(context.filesDir, "runtime-gate")
    private val nativeDir = File(context.applicationInfo.nativeLibraryDir)

    /** t1's HarnessPaths layout, under a root of the runtime gate's own. */
    private fun config(name: String): HarnessConfig {
        val root = File(gate, name)
        val rootfs = File(root, "rootfs")
        val prefix = File(rootfs, "data/data/com.termux/files/usr")
        return HarnessConfig.Builder()
            .workspace(File(root, "workspace"))
            .home(File(root, "home"))
            .prefix(prefix)
            .rootfs(rootfs)
            .toolDirectory(File(prefix, "bin"))
            .libraryDirectory(File(prefix, "lib"))
            .nativeLibraryDirectory(nativeDir)
            .build()
    }

    /** A command's outcome as t1's `CommandResult` gave it: exit code and output. */
    private class Ran(val exitCode: Int?, val output: String, val failure: CommandFailure?) {
        fun isSuccess(): Boolean = failure == null && exitCode == 0
    }

    private fun run(commands: RuntimeCommands, program: String, vararg arguments: String): Ran {
        val result = commands.runner.run(CommandRequest(program, arguments.toList(), timeoutMs = 120_000L))
        val output = result.stdout.text + result.stderr.text +
            (result.failure?.let { failure -> "\n[${failure.code}] ${result.detail ?: ""}" } ?: "")
        return Ran(result.exitCode, output, result.failure)
    }

    @Test
    fun a_shellAndToolsRunFromTheApkPayload() {
        File(gate, REPORT).delete()
        File(gate, "sealed-shell").deleteRecursively()
        val config = config("sealed-shell")
        val targetSdk = context.applicationInfo.targetSdkVersion
        val runtime = SealedRuntime(AssetPayloadSource(context), config)
        val payload = runtime.payload()
        assumeTrue("this APK carries no sealed payload (not the sealed variant)", payload != null)
        val abi = payload!!.abi
        report("sealed-shell: payload abi=$abi targetSdk=$targetSdk sdk=${Build.VERSION.SDK_INT}")
        record("abi", abi)
        record("target_sdk", targetSdk)
        record("device_sdk", Build.VERSION.SDK_INT)

        val install = runtime.install(null)
        report(
            "sealed-shell: sealed payload: ${install.files} data files (${install.bytes} bytes, " +
                "${install.verified} verified), ${install.links} data links, " +
                "${install.executables} executables from the APK, in ${install.millis} ms",
        )
        record("install_ms", install.millis)
        record("install_files", install.files)
        record("install_verified", install.verified)
        record("install_executables", install.executables)
        // The payload is hashed as it is written: every extracted file must have
        // matched its manifest record. A payload that ships without the manifest
        // reports 0 here, which is a packaging bug, not a tolerable difference.
        assertEquals(
            "payload was not verified against its manifest: ${install.verified} of ${install.files}",
            install.files,
            install.verified,
        )

        val bash = File(config.prefix, "bin/bash")
        assertTrue("bash missing from the prefix: $bash", bash.isFile)

        // The shape is the design: the prefix path is a symlink into the APK.
        assertTrue(
            "bash must be a symlink into the native library directory: $bash",
            Files.isSymbolicLink(bash.toPath()),
        )
        val target = ExecAudit.readLink(bash)
        assertTrue(
            "bash points outside the APK: $target",
            target != null && target.startsWith(nativeDir.absolutePath),
        )
        report("sealed-shell: bin/bash -> $target")

        val commands = RuntimeCommands.create(
            config = config,
            killGroup = { group -> Os.kill(-group, OsConstants.SIGKILL) },
        )

        val shell = run(
            commands,
            "bash",
            "-c",
            "echo SEALED-SHELL-OK; echo version=\$BASH_VERSION; echo prefix=\$PREFIX; " +
                "echo path=\$PATH; command -v sed; echo exit-ok",
        )
        report("sealed-shell: bash -> exit ${shell.exitCode} : ${shell.output.replace("\n", " | ").trim()}")
        assertTrue(
            "bash did not run (exit ${shell.exitCode}): ${shell.output}",
            shell.output.contains("SEALED-SHELL-OK"),
        )
        assertTrue(
            "unexpected bash version output: ${shell.output}",
            shell.output.lowercase(Locale.ROOT).contains("version"),
        )
        assertTrue("bash did not reach the end of the script: ${shell.output}", shell.output.contains("exit-ok"))
        record("bash", "ok")
        record(
            "bash_version",
            shell.output.lines().firstOrNull { it.startsWith("version=") }?.removePrefix("version=") ?: "-",
        )

        // A second, different executable from the same payload: proves the split
        // produced a usable userland, not one lucky binary.
        val sed = File(config.prefix, "bin/sed")
        assertTrue("sed missing: $sed", sed.isFile)
        val sedRun = run(commands, "bash", "-c", "printf 'a1\\na2\\nb1\\n' | sed -n 's/^a/A/p'")
        report("sealed-shell: sed -> exit ${sedRun.exitCode} : ${sedRun.output.replace("\n", " | ").trim()}")
        assertTrue(
            "sed did not filter through bash: ${sedRun.output}",
            sedRun.output.contains("A1") && sedRun.output.contains("A2") && !sedRun.output.contains("B1"),
        )
        record("sed", "ok")

        // The core tier, when this payload carries it: the same tools the apt
        // build installs on first run, executed at a store-legal targetSdk.
        val python = File(config.prefix, "bin/python")
        if (python.exists()) {
            val tools = listOf(
                listOf("bin/git", "--version"),
                listOf("bin/python", "-c", "import ssl, json, sqlite3; print('py-ssl', ssl.OPENSSL_VERSION)"),
                listOf("bin/node", "--version"),
                listOf("bin/perl", "-e", "print \$^V"),
                listOf("bin/ruby", "--version"),
                listOf("bin/rg", "--version"),
            )
            for (command in tools) {
                val tool = File(config.prefix, command[0])
                assertTrue("core tool missing from the sealed payload: $tool", tool.exists())
                val result = run(commands, command[0].removePrefix("bin/"), *command.drop(1).toTypedArray())
                var shown = result.output.replace("\n", " ").trim()
                if (shown.length > 140) shown = shown.substring(0, 140)
                report("sealed-shell: ${command[0]} -> exit ${result.exitCode} : $shown")
                assertTrue(
                    "${command[0]} failed in the sealed payload (exit ${result.exitCode}): ${result.output}",
                    result.isSuccess(),
                )
                record(command[0].removePrefix("bin/"), shown.take(60))
            }
        } else {
            report("sealed-shell: payload has no core tier (bootstrap only)")
            record("core_tier", "absent")
        }

        // And the whole prefix is executable without the exemption.
        val audit = ExecAudit.audit(config.prefix, nativeDir)
        report("sealed-shell: " + audit.toText().replace("\n", " | "))
        record("audit_outside_apk", audit.outsideApk().size)
        record("audit_shipped", audit.shippedCount())
        record("audit_scanned", audit.scanned)
        record("audit_truncated", audit.truncated)
        assertFalse("audit could not finish: " + audit.toText(), audit.truncated)
        assertTrue(
            "sealed payload leaves binaries outside the APK: " + audit.outsideApk().size,
            audit.publishable(),
        )
        assertTrue("nothing was shipped in the APK: " + audit.toText(), audit.shippedCount() > 0)
        // Scripts stay in the payload by design (they are interpreted, never
        // exec'd); the count is reported so the reliance is visible, not hidden.
        report("sealed-shell: ${audit.outsideScripts().size} scripts in the payload run through the interpreter layer")
        record("audit_scripts", audit.outsideScripts().size)
    }

    /**
     * The app's own startup path, not the installer on its own: a sealed APK
     * must install itself once and then stop re-extracting 14k files on every
     * launch, and its dpkg database must agree with what was shipped.
     */
    @Test
    fun b_startupInstallsOnceAndDpkgAgrees() {
        val appConfig = HarnessConfig.builder(context).build()
        assumeTrue(
            "this APK carries no sealed payload (not the sealed variant)",
            SealedRuntime(AssetPayloadSource(context), appConfig).payload() != null,
        )

        // The process's own hub, as RuntimeHost reaches it when a workspace opens.
        val first = startAndWait(RuntimeHubs.get(context))
        report(
            "sealed-shell: first startup -> ${first.status.state.code} installMs=${first.status.installMs} " +
                "warmStartMs=${first.status.warmStartMs} audit=${first.status.audit?.outsideApk}",
        )
        record("first_start_state", first.status.state.code)
        record("first_start_install_ms", first.status.installMs)
        record("first_start_ms", first.readyAfterMs)
        record("first_start_audit_outside_apk", first.status.audit?.outsideApk)
        assertEquals(
            "the app did not take the sealed path: ${first.status.problem?.code} ${first.status.detail}",
            RuntimeState.READY,
            first.status.state,
        )

        // The next launch: a new hub over the same runtime.
        val second = startAndWait(nextLaunch())
        val elapsed = second.readyAfterMs
        report("sealed-shell: second startup took $elapsed ms (no re-extract)")
        record("second_start_ms", elapsed)
        record("second_start_warm_ms", second.status.warmStartMs)
        record("second_start_relinked", second.status.relinked)
        record("second_start_audit_outside_apk", second.status.audit?.outsideApk)
        assertEquals(
            "the second startup did not take the sealed path: ${second.status.problem?.code} ${second.status.detail}",
            RuntimeState.READY,
            second.status.state,
        )
        assertNotNull("the second startup was not a warm start", second.status.warmStartMs)
        assertEquals("the second startup moved executables' links", 0, second.status.relinked)
        assertTrue("second startup re-extracted the payload ($elapsed ms)", elapsed < 5_000L)

        // dpkg has to know about the packages whose files came from the APK:
        // without this, apt offers to install tools that are already present.
        val status = File(appConfig.prefix, "var/lib/dpkg/status")
        assertTrue("no dpkg status in the payload: $status", status.isFile)
        val database = status.readText(Charsets.UTF_8)
        for (packageName in listOf("nodejs", "perl", "ruby", "git")) {
            val at = database.indexOf("Package: $packageName\n")
            assertTrue(
                "$packageName is not recorded as installed in dpkg",
                at >= 0 && database.startsWith("Status: install ok installed", database.indexOf("\n", at) + 1),
            )
        }
        report("sealed-shell: dpkg records the shipped packages as installed")
        record("dpkg", "ok")
    }

    /** A start's settled status, and when it first reached READY (the warm start or the install). */
    private class Started(val status: RuntimeStatus, val readyAfterMs: Long)

    /** The next launch's hub: as RuntimeHubs makes the process's, over the same runtime. */
    private fun nextLaunch(): RuntimeHub {
        val worker = Executors.newSingleThreadExecutor { task ->
            Thread(task, "sealed-shell-next-launch").apply { isDaemon = true }
        }
        return RuntimeHub(
            runtimeFactory = { SealedRuntime(AssetPayloadSource(context), HarnessConfig.builder(context).build()) },
            worker = worker,
            deliver = { task -> task.run() },
            apkBytes = { File(context.applicationInfo.sourceDir).length() },
        )
    }

    /** Starts [hub] and waits until the start has settled: audited, or failed. */
    private fun startAndWait(hub: RuntimeHub): Started {
        val begun = SystemClock.uptimeMillis()
        val readyAt = AtomicLong(-1L)
        val settled = AtomicReference<RuntimeStatus?>(null)
        val done = CountDownLatch(1)
        val watch: (RuntimeStatus) -> Unit = { status ->
            if (status.state == RuntimeState.READY) readyAt.compareAndSet(-1L, SystemClock.uptimeMillis())
            if (isSettled(status) && settled.compareAndSet(null, status)) done.countDown()
        }
        hub.addListener(watch)
        try {
            hub.start(watch)
            watch(hub.snapshot())
            assertTrue(
                "the runtime did not settle within ${SETTLE_MS / 1000} s: ${hub.snapshot()}",
                done.await(SETTLE_MS, TimeUnit.MILLISECONDS),
            )
        } finally {
            hub.removeListener(watch)
        }
        val status = settled.get()!!
        val ready = readyAt.get()
        return Started(status, if (ready < 0) -1L else ready - begun)
    }

    private fun isSettled(status: RuntimeStatus): Boolean = when (status.state) {
        RuntimeState.READY, RuntimeState.DEGRADED -> !status.auditing && status.audit != null
        RuntimeState.FAILED, RuntimeState.UNAVAILABLE -> true
        else -> false
    }

    private fun report(line: String) {
        Log.i(TAG, line)
    }

    /** A figure, as `sealed_shell_<key>=<value>`: the device log and the report file. */
    private fun record(key: String, value: Any?) {
        val line = "sealed_shell_$key=$value"
        Log.i(TAG, "RUNTIME_GATE $line")
        gate.mkdirs()
        File(gate, REPORT).appendText(line + "\n")
    }

    private companion object {
        const val TAG = "CodeForgeRuntimeGate"
        const val REPORT = "sealed-shell-report.txt"
        const val SETTLE_MS = 10 * 60 * 1000L
    }
}
