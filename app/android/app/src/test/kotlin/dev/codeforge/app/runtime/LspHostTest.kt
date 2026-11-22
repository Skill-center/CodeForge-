package dev.codeforge.app.runtime

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.concurrent.withLock
import org.junit.After
import org.junit.Assert.assertEquals
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
 * The language servers' host with real processes (Phase 6 W3, gate G3): the
 * installer, the launcher, the framing and the host together, on the machine
 * that runs the tests. The launcher is compiled here from codeforge-spawn.c,
 * as in CommandRunnerTest. The "server" is a small Python program that
 * speaks LSP's base protocol, installed by LanguageServers from servers
 * built in memory; the runtime's bin/node is a script that runs it with the
 * machine's python3. Skipped without a compiler or python3, except on CI,
 * where that fails. The runtime legs run the real servers through the same
 * host (the instrumented LanguageServerTest).
 *
 * Every test checks that no session is left.
 */
class LspHostTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var root: File
    private lateinit var projects: File
    private lateinit var environment: RuntimeEnvironment
    private lateinit var sessions: SessionRegistry
    private lateinit var host: LspHost
    private val delivery = Executors.newSingleThreadExecutor()
    private lateinit var marker: String

    @Before
    fun setUp() {
        if (System.getenv("CI") == "true") {
            assertNotNull("no C compiler on CI for the launcher", launcher)
            assertNotNull("no python3 on CI", python)
        }
        assumeTrue("no C compiler here for the launcher", launcher != null)
        assumeTrue("no python3 here", python != null)
        root = temp.newFolder("harness")
        projects = temp.newFolder("workspaces")
        File(projects, "demo").mkdirs()
        val libraries = temp.newFolder("lib")
        environment = RuntimeEnvironment(
            TestPayload.configFor(root, libraries),
            mapOf("CODEFORGE_CANARY_TOKEN" to "secret", "ANDROID_ROOT" to "/system"),
        )
        // The runtime's node: here, the machine's python3, isolated from the runtime's PYTHON* variables.
        val bin = environment.bin
        bin.mkdirs()
        val node = File(bin, LspHost.NODE)
        node.writeText("#!/bin/sh\nunset PYTHONHOME PYTHONPATH\nexec ${python!!.absolutePath} -I \"$@\"\n")
        node.setExecutable(true)
        // The stub's child (a sleep), found on the runtime's PATH as its own programs are.
        listOf("/bin/sleep", "/usr/bin/sleep").map { File(it) }.firstOrNull { it.canExecute() }?.let { sleep ->
            Files.createSymbolicLink(File(bin, "sleep").toPath(), sleep.toPath())
        }
        sessions = SessionRegistry(killGroup = { group -> CommandRunnerTest.killGroup(group) }, graceMs = 300L)
        host = host()
        marker = "%d.%04d".format(400 + serial.incrementAndGet(), CommandRunnerTest.selfPid() % 10000)
    }

    private fun host(maxServers: Int = LspHost.MAX_SERVERS, source: PayloadSource = StubServers.source()): LspHost =
        LspHost(
            environment = environment,
            launcher = launcher!!,
            sessions = sessions,
            servers = LanguageServers(source, environment.root),
            stateDirectory = File(environment.root, "codeforge/lsp-sessions"),
            resolve = { workspace ->
                val name = workspace.project ?: workspace.copy ?: throw IllegalArgumentException("no workspace")
                if (name.isEmpty() || name.contains('/') || name == "." || name == "..") {
                    throw IllegalArgumentException("a workspace is named, not \"$name\"")
                }
                val folder = File(projects, name)
                if (!folder.isDirectory) throw IllegalArgumentException("no such workspace: $name")
                folder.canonicalFile
            },
            delivery = delivery,
            maxServers = maxServers,
            sampleEveryMs = 100L,
        )

    @After
    fun nothingIsLeft() {
        if (!::host.isInitialized) return
        try {
            host.stopAll()
            val deadline = System.nanoTime() + 10_000_000_000L
            while (sessions.live().isNotEmpty() && System.nanoTime() < deadline) Thread.sleep(20)
            assertEquals("sessions left", emptyList<Long>(), sessions.live().map { it.id })
            assertEquals("processes of this test left", emptyList<Int>(), sleeps())
        } finally {
            delivery.shutdownNow()
        }
    }

    private fun start(listener: Recorder, server: String = "alpha", workspace: LspWorkspace = LspWorkspace(project = "demo")): LanguageServerProcess {
        val started = host.start(server, workspace, listener)
        assertNull("${started.failure}: ${started.detail}", started.failure)
        return started.server!!
    }

    private fun request(id: Int, method: String, params: String = "{}"): String =
        "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"$method\",\"params\":$params}"

    @Test
    fun aServerAnswersInWholeMessagesWhateverItsWrites() {
        val listener = Recorder()
        val server = start(listener)
        assertNull(server.send(request(1, "echo", "{\"text\":\"héllo ✓\"}")))
        assertTrue(listener.waitForMessage { it.contains("\"id\": 1") }.contains("héllo ✓"))
        // Three messages in one write come as three.
        server.send(request(2, "burst"))
        listener.waitForMessage { it.contains("\"burst\": 3") }
        assertEquals(listOf(1, 2, 3), listener.messages().filter { it.contains("\"burst\"") }.map { Regex("\"burst\": (\\d)").find(it)!!.groupValues[1].toInt() })
        // One message in seven-byte writes comes as one.
        server.send(request(3, "split"))
        assertTrue(listener.waitForMessage { it.contains("\"split\"") }.contains("x".repeat(3000)))
        assertTrue(server.received.get() >= 5)
    }

    @Test
    fun theServerRunsInItsWorkspaceWithTheRuntimesEnvironmentAndTheHeapCap() {
        val listener = Recorder()
        val server = start(listener)
        server.send(request(1, "env"))
        val answer = listener.waitForMessage { it.contains("\"cwd\"") }
        assertTrue(answer, answer.contains("\"cwd\": \"${File(projects, "demo").canonicalPath}\""))
        assertTrue(answer, answer.contains("\"node_options\": \"--max-old-space-size=${LspHost.HEAP_MB}\""))
        assertTrue("the app's own variables leaked: $answer", answer.contains("\"canary\": null"))
        assertEquals(File(projects, "demo").canonicalFile, server.directory)
    }

    @Test
    fun itsExitCarriesItsCodeAndTheTailOfItsStderr() {
        val listener = Recorder()
        val server = start(listener)
        server.send(request(1, "stderr", "{\"bytes\":${70 * 1024}}"))
        server.send(request(2, "exit", "{\"code\":3}"))
        val exit = listener.waitForExit()
        assertEquals(LspEnd.EXITED, exit.end)
        assertEquals(3, exit.exitCode)
        assertEquals(LanguageServerProcess.STDERR_KEPT, exit.stderr.length)
        assertTrue("the tail is the end of what it wrote", exit.stderr.endsWith("END-OF-STDERR\n"))
        assertEquals(LspFailure.NO_SUCH_SERVER, host.send(server.handle, request(3, "echo")))
        assertEquals(LspFailure.NOT_RUNNING, server.send(request(3, "echo")))
    }

    @Test
    fun aServerKilledBySigkillIsReportedAsSignaled() {
        val listener = Recorder()
        val server = start(listener)
        server.send(request(1, "echo"))
        listener.waitForMessage { it.contains("\"id\": 1") }
        val child = server.child()
        assertNotNull("the launcher names its child", child)
        ProcessBuilder("kill", "-KILL", child.toString()).start().waitFor(5, TimeUnit.SECONDS)
        val exit = listener.waitForExit()
        assertEquals(LspEnd.SIGNALED, exit.end)
        assertEquals(9, exit.signal)
    }

    @Test
    fun outputThatIsNotTheBaseProtocolEndsTheServerAsBroken() {
        for ((method, reason) in listOf("garbage" to "bad_header", "huge" to "too_large", "badutf8" to "bad_utf8")) {
            val listener = Recorder()
            val server = start(listener)
            server.send(request(1, method))
            val exit = listener.waitForExit()
            assertEquals(method, LspEnd.BROKEN, exit.end)
            assertTrue("$method: ${exit.detail}", exit.detail.orEmpty().startsWith(reason))
        }
    }

    @Test
    fun stoppingEndsTheWholeTree() {
        val listener = Recorder()
        val server = start(listener)
        server.send(request(1, "child", "{\"marker\":\"$marker\"}"))
        listener.waitForMessage { it.contains("\"child\": true") }
        assertEquals(1, sleeps().size)
        assertNull(host.stop(server.handle))
        val exit = listener.waitForExit()
        assertEquals(LspEnd.STOPPED, exit.end)
        assertEquals("the server's child outlived it", emptyList<Int>(), sleeps())
        assertEquals(LspFailure.NO_SUCH_SERVER, host.stop(server.handle))
    }

    @Test
    fun oneServerPerIdAndAtMostTwoAtOnce() {
        val alpha = start(Recorder(), "alpha")
        val again = host.start("alpha", LspWorkspace(project = "demo"), Recorder())
        assertEquals(LspFailure.ALREADY_RUNNING, again.failure)
        assertEquals(alpha.handle, again.running)
        start(Recorder(), "beta")
        val third = host.start("gamma", LspWorkspace(project = "demo"), Recorder())
        assertEquals(LspFailure.TOO_MANY, third.failure)
        assertEquals(2, host.list().size)
    }

    @Test
    fun aWorkspaceIsAProjectOrACopyByNameNeverAPath() {
        for (workspace in listOf(LspWorkspace(), LspWorkspace(project = "../demo"), LspWorkspace(project = "demo", copy = "c1"), LspWorkspace(project = "missing"))) {
            val started = host.start("alpha", workspace, Recorder())
            assertEquals(workspace.toString(), LspFailure.BAD_REQUEST, started.failure)
        }
        assertEquals(LspFailure.BAD_REQUEST, host.start("../alpha", LspWorkspace(project = "demo"), Recorder()).failure)
        assertEquals(LspFailure.NOT_IN_APK, host.start("delta", LspWorkspace(project = "demo"), Recorder()).failure)
        assertTrue(sessions.live().isEmpty())
    }

    @Test
    fun itsMemoryIsSampled() {
        val server = start(Recorder())
        val deadline = System.nanoTime() + 5_000_000_000L
        while (server.memory == null && System.nanoTime() < deadline) Thread.sleep(20)
        val memory = server.memory
        assertNotNull("no memory sample in 5 s", memory)
        assertTrue("the launcher and the server: $memory", memory!!.processes >= 2)
        assertTrue("$memory", memory.rssKib > 0)
    }

    @Test
    fun stoppingForMemorySaysSo() {
        val listener = Recorder()
        start(listener)
        assertEquals(1, host.stopAll(LspEnd.MEMORY))
        assertEquals(LspEnd.MEMORY, listener.waitForExit().end)
    }

    @Test
    fun aServerThatStopsReadingFillsItsQueueAndNothingBlocks() {
        val listener = Recorder()
        val server = start(listener)
        server.send(request(1, "hang"))
        val big = request(2, "echo", "{\"text\":\"${"z".repeat(1024 * 1024)}\"}")
        var refused: LspFailure? = null
        val started = System.nanoTime()
        for (attempt in 0 until 64) {
            refused = server.send(big)
            if (refused != null) break
        }
        assertEquals(LspFailure.QUEUE_FULL, refused)
        assertTrue("sending blocked", System.nanoTime() - started < 5_000_000_000L)
    }

    @Test
    fun theFirstStartInstallsTheServerAndALaterOneReusesIt() {
        val stubs = StubServers.source()
        val opened = mutableListOf<String>()
        val counting = object : PayloadSource {
            override fun abi(): String? = null

            override fun identity(abi: String): String? = null

            override fun open(name: String) = stubs.open(name).also { opened.add(name) }
        }
        host = host(source = counting)
        val first = start(Recorder())
        assertTrue(File(environment.root, "codeforge/lsp/alpha/${StubServers.ENTRY}").isFile)
        host.stop(first.handle)
        val deadline = System.nanoTime() + 5_000_000_000L
        while (host.list().isNotEmpty() && System.nanoTime() < deadline) Thread.sleep(20)
        assertEquals(0L, start(Recorder()).installMs)
        assertEquals("the archive was read once, for the first start", 1, opened.count { it == "lsp/alpha.zip" })
    }

    /** This test's `sleep <marker>` processes. */
    private fun sleeps(): List<Int> =
        ProcessTable.read().map { it.pid }.filter { pid ->
            val arguments = try {
                String(File("/proc/$pid/cmdline").readBytes(), Charsets.UTF_8).split('\u0000')
            } catch (gone: Exception) {
                emptyList()
            }
            arguments.size >= 2 && arguments[0].endsWith("sleep") && arguments[1] == marker
        }

    /** What a server told: its messages and its exit. */
    private class Recorder : LspListener {
        private val lock = ReentrantLock()
        private val changed = lock.newCondition()
        private val received = mutableListOf<String>()
        private var exit: LspExit? = null

        override fun onMessage(handle: Long, message: String) {
            lock.withLock {
                received.add(message)
                changed.signalAll()
            }
        }

        override fun onExit(exit: LspExit) {
            lock.withLock {
                this.exit = exit
                changed.signalAll()
            }
        }

        fun messages(): List<String> = lock.withLock { received.toList() }

        fun waitForMessage(timeoutMs: Long = 10_000L, accept: (String) -> Boolean): String {
            val deadline = System.nanoTime() + timeoutMs * 1_000_000L
            lock.withLock {
                while (true) {
                    received.firstOrNull(accept)?.let { return it }
                    val left = deadline - System.nanoTime()
                    if (left <= 0) throw AssertionError("no such message in $timeoutMs ms; got ${received.map { it.take(120) }}; exit $exit")
                    changed.awaitNanos(left)
                }
            }
        }

        fun waitForExit(timeoutMs: Long = 15_000L): LspExit {
            val deadline = System.nanoTime() + timeoutMs * 1_000_000L
            lock.withLock {
                while (true) {
                    exit?.let { return it }
                    val left = deadline - System.nanoTime()
                    if (left <= 0) throw AssertionError("no exit in $timeoutMs ms")
                    changed.awaitNanos(left)
                }
            }
        }
    }

    companion object {
        private val serial = AtomicInteger()

        /** The launcher, compiled once for the class; null without a compiler. */
        private var launcher: File? = null

        /** The machine's python3, which plays node here. */
        private val python: File? =
            listOf("/usr/bin/python3", "/bin/python3", "/usr/local/bin/python3").map { File(it) }.firstOrNull { it.canExecute() }

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

/** Three servers built in memory, each the same Python stub: alpha, beta and gamma. */
private object StubServers {
    const val ENTRY = "node_modules/stub/server.py"

    /** A server that speaks LSP's base protocol, and misbehaves on request. */
    private val SERVER = """
        import json, os, subprocess, sys, time
        inp, out = sys.stdin.buffer, sys.stdout.buffer
        def frame(obj):
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            return b"Content-Length: %d\r\n\r\n" % len(body) + body
        def send(obj):
            out.write(frame(obj)); out.flush()
        def read():
            length = None
            while True:
                line = inp.readline()
                if not line:
                    return None
                line = line.rstrip(b"\r\n")
                if not line:
                    break
                key, _, value = line.partition(b":")
                if key.strip().lower() == b"content-length":
                    length = int(value.strip())
            return json.loads(inp.read(length).decode("utf-8"))
        while True:
            message = read()
            if message is None:
                sys.exit(0)
            method, ident, params = message.get("method"), message.get("id"), message.get("params") or {}
            if method == "echo":
                send({"jsonrpc": "2.0", "id": ident, "result": params})
            elif method == "burst":
                out.write(b"".join(frame({"jsonrpc": "2.0", "method": "note", "params": {"burst": n}}) for n in (1, 2, 3))); out.flush()
            elif method == "split":
                data = frame({"jsonrpc": "2.0", "id": ident, "result": {"split": "x" * 3000}})
                for start in range(0, len(data), 7):
                    out.write(data[start:start + 7]); out.flush()
            elif method == "env":
                send({"jsonrpc": "2.0", "id": ident, "result": {"cwd": os.getcwd(), "node_options": os.environ.get("NODE_OPTIONS"), "canary": os.environ.get("CODEFORGE_CANARY_TOKEN")}})
            elif method == "stderr":
                filler = ("e" * 1023 + "\n") * (params["bytes"] // 1024)
                sys.stderr.write(filler + "END-OF-STDERR\n"); sys.stderr.flush()
            elif method == "exit":
                sys.exit(params.get("code", 0))
            elif method == "garbage":
                out.write(b"this is not a header\r\n\r\n"); out.flush()
            elif method == "huge":
                out.write(b"Content-Length: 20000000\r\n\r\n"); out.flush()
            elif method == "badutf8":
                out.write(b"Content-Length: 2\r\n\r\n\xff\xfe"); out.flush()
            elif method == "child":
                subprocess.Popen(["sleep", params["marker"]])
                send({"jsonrpc": "2.0", "id": ident, "result": {"child": True}})
            elif method == "hang":
                time.sleep(3600)
    """.trimIndent() + "\n"

    fun source(): PayloadSource {
        val body = SERVER.toByteArray(Charsets.UTF_8)
        val manifest = "# sha256\tsize\tpath\n${LanguageServers.sha256(body)}\t${body.size}\t$ENTRY\n"
        val identity = LanguageServers.sha256(manifest.toByteArray(Charsets.UTF_8))
        val archive = ByteArrayOutputStream().also { bytes ->
            ZipOutputStream(bytes).use { zip ->
                zip.putNextEntry(ZipEntry(ENTRY))
                zip.write(body)
                zip.closeEntry()
            }
        }.toByteArray()
        val ids = listOf("alpha", "beta", "gamma")
        val servers = ids.joinToString(",") { id ->
            "{\"id\": \"$id\", \"languages\": [\"$id-lang\"], \"entry\": \"$ENTRY\", \"arguments\": [\"--stdio\"], " +
                "\"packages\": [{\"name\": \"stub\", \"version\": \"1.0.0\", \"license\": \"MIT\"}], " +
                "\"archive\": \"lsp/$id.zip\", \"manifest\": \"lsp/$id-manifest.txt\", \"identity\": \"$identity\", " +
                "\"files\": 1, \"bytes\": ${body.size}}"
        }
        val files = mutableMapOf(LanguageServers.SERVERS to "{\"schema\": 1, \"pins\": \"test\", \"servers\": [$servers]}".toByteArray())
        for (id in ids) {
            files["lsp/$id.zip"] = archive
            files["lsp/$id-manifest.txt"] = manifest.toByteArray(Charsets.UTF_8)
        }
        return MapPayloadSource(null, null, files)
    }
}
