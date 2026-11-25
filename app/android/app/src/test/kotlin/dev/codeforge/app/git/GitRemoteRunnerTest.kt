package dev.codeforge.app.git

import dev.codeforge.app.runtime.CommandRunner
import dev.codeforge.app.runtime.CommandRunnerTest
import dev.codeforge.app.runtime.RuntimeEnvironment
import dev.codeforge.app.runtime.SessionRegistry
import dev.codeforge.app.runtime.TestPayload
import java.io.File
import java.nio.file.Files
import java.util.Base64
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
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
 * Remote runs with real processes (Phase 7 W3, gate G3): the runner,
 * CommandRunner, the launcher, the credential channel's FIFOs and scripts,
 * and the machine's git, against `git http-backend` behind Basic
 * authentication, served by python on 127.0.0.1 as W1's GitTest serves it on
 * a device. The credential comes from the store (a software stand-in for
 * the Keystore's key) or from a scripted user, and only through git's
 * credential helper. GitHostTest runs the same through the host on Android.
 */
class GitRemoteRunnerTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var environment: RuntimeEnvironment
    private lateinit var commands: CommandRunner
    private lateinit var projects: File
    private lateinit var channels: File
    private lateinit var pool: ExecutorService
    private lateinit var store: CredentialStore
    private lateinit var served: File
    private var server: Process? = null
    private var url = ""
    private val ids = AtomicLong(9_000)
    private val user = User()

    private val secret = "tok-" + java.util.UUID.randomUUID().toString().replace("-", "")

    /** The scripted user: answers each prompt with [reply]; null leaves it waiting. */
    private class User : CredentialPrompter {
        @Volatile
        var reply: CredentialReply? = null
        val asked = CopyOnWriteArrayList<CredentialPrompt>()
        val withdrawn = CopyOnWriteArrayList<Long>()
        val rejected = CopyOnWriteArrayList<String>()

        override fun ask(prompt: CredentialPrompt): CompletableFuture<CredentialReply> {
            asked.add(prompt)
            return CompletableFuture<CredentialReply>().also { future -> reply?.let { future.complete(it) } }
        }

        override fun withdraw(promptId: Long) {
            withdrawn.add(promptId)
        }

        override fun rejected(runId: Long, host: String, username: String) {
            rejected.add("$host $username")
        }
    }

    private class Recorder : GitListener {
        val records = CopyOnWriteArrayList<String>()
        val progress = CopyOnWriteArrayList<String>()
        val exits = LinkedBlockingQueue<GitExit>()

        override fun output(runId: Long, records: List<String>) {
            this.records.addAll(records)
        }

        override fun progress(runId: Long, text: String, closing: Boolean) {
            progress.add(text)
        }

        override fun exited(exit: GitExit) {
            exits.add(exit)
        }

        fun exit(): GitExit = exits.poll(90, TimeUnit.SECONDS) ?: throw AssertionError("no exit within 90 s")
    }

    @Before
    fun setUp() {
        if (System.getenv("CI") == "true") {
            assertNotNull("no C compiler on CI for the launcher", launcher)
            assertNotNull("no git on CI", GIT)
            assertNotNull("no python3 on CI", PYTHON)
        }
        assumeTrue("no C compiler here for the launcher", launcher != null)
        assumeTrue("no git here", GIT != null)
        assumeTrue("no python3 here", PYTHON != null)
        val root = temp.newFolder("harness")
        environment = RuntimeEnvironment(TestPayload.configFor(root, temp.newFolder("lib")), mapOf("ANDROID_ROOT" to "/system"))
        environment.bin.mkdirs()
        // The runtime's bin as the helper needs it: git, bash for the helper, sh for askpass, cat.
        for ((name, target) in mapOf("git" to GIT!!, "bash" to tool("bash"), "sh" to tool("sh"), "cat" to tool("cat"))) {
            Files.createSymbolicLink(File(environment.bin, name).toPath(), target.toPath())
        }
        val sessions = SessionRegistry(killGroup = { group -> CommandRunnerTest.killGroup(group) }, graceMs = 300L)
        commands = CommandRunner(environment, launcher!!, sessions, File(root, "codeforge/sessions"))
        projects = temp.newFolder("workspaces")
        channels = File(temp.root, "no_backup/git/run")
        pool = Executors.newCachedThreadPool()
        store = CredentialStore(File(temp.root, "no_backup/git/credentials"), CredentialStoreTest.SoftwareCipher())
        served = temp.newFolder("served")
        // The served repository: one commit on main.
        val seed = temp.newFolder("seed")
        sh(seed, GIT!!.path, "init", "-q", "--initial-branch=main")
        File(seed, "README.md").writeText("served\n")
        sh(seed, GIT!!.path, "add", "-A")
        sh(seed, GIT!!.path, "-c", "user.name=Seed", "-c", "user.email=seed@example.com", "commit", "-q", "-m", "seed")
        sh(served, GIT!!.path, "clone", "-q", "--bare", seed.path, "repo.git")
        sh(File(served, "repo.git"), GIT!!.path, "config", "http.receivepack", "true")
        val script = File(temp.root, "server.py").apply { writeText(SERVER_PY) }
        val credentials = File(temp.root, "server-credentials").apply {
            writeText(Base64.getEncoder().encodeToString("ada:$secret".toByteArray()))
        }
        val portFile = File(temp.root, "port")
        server = ProcessBuilder(PYTHON!!.path, script.path, served.path, portFile.path, credentials.path).redirectErrorStream(true).start()
        val deadline = System.nanoTime() + 20_000_000_000L
        while (!portFile.isFile && System.nanoTime() < deadline) Thread.sleep(20)
        assertTrue("the server listens", portFile.isFile)
        url = "http://127.0.0.1:${portFile.readText().trim()}/repo.git"
    }

    @After
    fun tearDown() {
        if (!::pool.isInitialized) return
        server?.destroyForcibly()?.waitFor(5, TimeUnit.SECONDS)
        pool.shutdownNow()
        // Nothing a run started is left: git and the helper name the channels' folder on their command lines.
        var left = CommandRunnerTest.processesWith(channels.path)
        val deadline = System.nanoTime() + 2_000_000_000L
        while (left.isNotEmpty() && System.nanoTime() < deadline) {
            Thread.sleep(50)
            left = CommandRunnerTest.processesWith(channels.path)
        }
        for (pid in left) ProcessBuilder("kill", "-KILL", pid.toString()).start().waitFor(5, TimeUnit.SECONDS)
        assertEquals("processes left behind", emptyList<Long>(), left)
        assertTrue("no channel left: ${channels.list()?.toList()}", channels.list().isNullOrEmpty())
    }

    private fun runner() = GitRunner(
        processes = { request, sink, maxRecordBytes, separator, started, extraRoots, progress ->
            commands.stream(request, sink, maxRecordBytes, started, extraRoots, separator, progress)
        },
        projects = projects,
        executor = pool,
        credentials = { runId ->
            val channel = CredentialChannel.open(
                channels, runId, CredentialBroker(runId, store, user, promptTimeoutMs = 30_000L),
                bash = File(environment.bin, "bash"), makeFifo = ::mkfifo,
            )
            object : GitRunCredentials {
                override val settings = channel.helperSettings()
                override val variables = channel.variables(null)
                override val erased: Boolean get() = channel.erased

                override fun close() = channel.close()
            }
        },
    )

    private fun start(runner: GitRunner, project: String?, operation: String, vararg arguments: String): Pair<Long, Recorder> {
        val recorder = Recorder()
        val id = ids.incrementAndGet()
        val refused = runner.start(id, project, operation, arguments.toList(), null, recorder)
        assertNull("$operation refused: ${refused?.failure} ${refused?.message}", refused)
        return id to recorder
    }

    private fun run(runner: GitRunner, project: String?, operation: String, vararg arguments: String): GitExit =
        start(runner, project, operation, *arguments).second.exit()

    private fun assertOk(exit: GitExit) {
        assertNull("${exit.operation}: ${exit.failure} ${exit.detail} ${exit.stderr}", exit.failure)
        assertEquals("${exit.operation}: ${exit.stderr}", 0, exit.exitCode)
    }

    @Test
    fun aCloneAsksOnceRemembersAndIsMovedIntoPlace() {
        val runner = runner()
        user.reply = CredentialReply(accepted = true, username = "ada", secret = secret, remember = true)
        val (_, recorder) = start(runner, "first", "clone", url)
        val exit = recorder.exit()
        assertOk(exit)
        val prompt = user.asked.single()
        assertEquals(CredentialPrompt.Kind.HTTPS, prompt.kind)
        assertEquals(url.removePrefix("http://").substringBefore('/'), prompt.host)
        assertEquals("kept once the server took it", secret, store.find(CredentialKind.HTTPS, prompt.host, "ada")?.secret)
        val first = File(projects, "first")
        assertEquals("served\n", File(first, "README.md").readText())
        assertTrue("progress came", recorder.progress.isNotEmpty() || exit.stderr.isNotEmpty())
        assertEquals("no staging folder is left", listOf("first"), projects.list()!!.toList())
        assertFalse("the clone's config holds no secret", File(first, ".git/config").readText().contains(secret))

        // The next clone takes it from the store: nobody is asked.
        user.reply = null
        assertOk(run(runner, "second", "clone", url))
        assertEquals(1, user.asked.size)

        // Push, fetch and pull with the stored credential.
        sh(first, GIT!!.path, "-c", "user.name=Ada", "-c", "user.email=ada@example.com", "commit", "-q", "--allow-empty", "-m", "from the test")
        assertOk(run(runner, "first", "push", "--set-upstream", "origin", "main"))
        assertOk(run(runner, "second", "fetch", "--prune", "origin"))
        assertOk(run(runner, "second", "pull", "--ff-only", "origin", "main"))
        assertEquals(sh(first, GIT!!.path, "rev-parse", "HEAD"), sh(File(projects, "second"), GIT!!.path, "rev-parse", "HEAD"))
        assertEquals(1, user.asked.size)

        // The secret is in no file: the store holds it sealed.
        val leaks = temp.root.walkTopDown().filter { it.isFile && it.length() < 4_000_000 && it.readText(Charsets.ISO_8859_1).contains(secret) }
            .map { it.relativeTo(temp.root).path }.toList()
        assertEquals("the secret in a file", emptyList<String>(), leaks)
        assertEquals(0, runner.runningCount())
    }

    @Test
    fun aRefusedStoredCredentialIsErasedAndTheCloneLeavesNothing() {
        val host = url.removePrefix("http://").substringBefore('/')
        store.put(GitCredential(CredentialKind.HTTPS, host, "ada", "wrong-$secret"))
        val runner = runner()
        val exit = run(runner, "refused", "clone", url)
        assertNull(exit.failure)
        assertEquals(128, exit.exitCode)
        assertTrue(exit.stderr, exit.stderr.contains("Authentication failed"))
        assertNull("erased", store.find(CredentialKind.HTTPS, host))
        assertEquals(listOf("$host ada"), user.rejected)
        assertTrue("no folder left: ${projects.list()?.toList()}", projects.list().isNullOrEmpty())
    }

    @Test
    fun aCancelledPromptFailsWithoutAPromptOfGitsOwn() {
        user.reply = CredentialReply(accepted = false)
        val exit = run(runner(), "cancelled", "clone", url)
        assertEquals(128, exit.exitCode)
        assertTrue(exit.stderr, exit.stderr.contains("could not read Username"))
        assertEquals(1, user.asked.size)
        assertTrue(projects.list().isNullOrEmpty())
    }

    @Test
    fun stopWhileTheUserIsAskedEndsEverythingAndWithdrawsThePrompt() {
        user.reply = null
        val runner = runner()
        val (id, recorder) = start(runner, "stopped", "clone", url)
        val deadline = System.nanoTime() + 30_000_000_000L
        while (user.asked.isEmpty() && System.nanoTime() < deadline) Thread.sleep(20)
        assertEquals(1, user.asked.size)
        assertTrue(runner.stop(id))
        val exit = recorder.exit()
        assertEquals(GitFailure.STOPPED, exit.failure)
        assertEquals(listOf(user.asked.single().id), user.withdrawn)
        assertTrue("no folder left: ${projects.list()?.toList()}", projects.list().isNullOrEmpty())
        assertEquals(0, runner.runningCount())
    }

    /**
     * ssh runs its askpass with the question as the one argument, and that
     * askpass is the runtime's bash with the relay as `BASH_ENV`: the half
     * that answers, proved without ssh-keygen, so a failure says which half
     * broke. A question is answered; a real script bash is given still runs.
     */
    @Test
    fun theRelayAnswersAQuestionAndLeavesARealScriptAlone() {
        val passphrase = "pass-" + java.util.UUID.randomUUID().toString()
        val channel = CredentialChannel.open(
            channels, ids.incrementAndGet(),
            CredentialBroker(1L, store, user, newPassphrase = passphrase, promptTimeoutMs = 10_000L),
            bash = File(environment.bin, "bash"), makeFifo = ::mkfifo,
        )
        val said: (List<String>) -> Pair<dev.codeforge.app.runtime.CommandResult?, List<String>> = { arguments ->
            val lines = CopyOnWriteArrayList<String>()
            val result = commands.stream(
                dev.codeforge.app.runtime.CommandRequest(
                    program = "bash",
                    arguments = arguments,
                    directory = null,
                    timeoutMs = 60_000L,
                    variables = channel.variables(null),
                ),
                object : dev.codeforge.app.runtime.LineSink {
                    override fun line(text: String): Boolean {
                        lines.add(text)
                        return true
                    }
                },
            )
            result to lines.toList()
        }
        try {
            // As ssh-keygen asks for a new key's passphrase, twice.
            val (first, firstLines) = said(listOf("Enter passphrase (empty for no passphrase): "))
            assertEquals("bash as askpass: ${first?.failure} ${first?.stderr?.text}", 0, first?.exitCode)
            assertEquals(listOf(passphrase), firstLines)
            val (again, againLines) = said(listOf("Enter same passphrase again: "))
            assertEquals(0, again?.exitCode)
            assertEquals(listOf(passphrase), againLines)
            assertEquals(
                listOf("Enter passphrase (empty for no passphrase):", "Enter same passphrase again:"),
                channel.questions,
            )
            // A question nobody has an answer for ends the run, with nothing said.
            val (strange, strangeLines) = said(listOf("What is your name? "))
            assertEquals(0, strange?.exitCode)
            assertEquals(emptyList<String>(), strangeLines)
            // A real script still runs: the relay lets bash get on with it.
            val script = File(temp.root, "real.sh").apply { writeText("echo ran\n") }
            val (ran, ranLines) = said(listOf(script.path))
            assertEquals(0, ran?.exitCode)
            assertEquals(listOf("ran"), ranLines)
        } finally {
            channel.close()
        }
        assertTrue("no channel left", channels.list().isNullOrEmpty())
    }

    @Test
    fun anSshKeyIsMadeWithAPassphraseOnlyTheStoreHolds() {
        val keygen = listOf(File("/usr/bin/ssh-keygen"), File("/bin/ssh-keygen")).firstOrNull { it.canExecute() }
        if (System.getenv("CI") == "true") assertNotNull("no ssh-keygen on CI", keygen)
        assumeTrue("no ssh-keygen here", keygen != null)
        Files.createSymbolicLink(File(environment.bin, "ssh-keygen").toPath(), keygen!!.toPath())
        val home = environment.home.apply { mkdirs() }
        fun collect(request: dev.codeforge.app.runtime.CommandRequest): Pair<dev.codeforge.app.runtime.CommandResult?, List<String>> {
            val lines = CopyOnWriteArrayList<String>()
            val result = commands.stream(
                request,
                object : dev.codeforge.app.runtime.LineSink {
                    override fun line(text: String): Boolean {
                        lines.add(text)
                        return true
                    }
                },
            )
            return result to lines.toList()
        }
        val keys = SshKeys(
            store = store,
            run = { request -> collect(request).first },
            channel = { runId, passphrase ->
                CredentialChannel.open(
                    channels, runId,
                    CredentialBroker(
                        runId, store, user, sshKeyPath = SshKeys.keyFile(home).path,
                        newPassphrase = passphrase, readsOwnKey = passphrase == null,
                    ),
                    bash = File(environment.bin, "bash"), makeFifo = ::mkfifo,
                )
            },
            read = { request -> collect(request) },
        )
        val key = keys.create(home, "codeforge@test", ids.incrementAndGet())
        assertTrue(key.publicKey, key.publicKey.startsWith("ssh-ed25519 ") && key.publicKey.endsWith(" codeforge@test"))
        val passphrase = store.find(CredentialKind.SSH_KEY, CredentialBroker.SSH_KEY_HOST, CredentialBroker.SSH_KEY_USER)?.secret
        assertNotNull(passphrase)
        // The key is encrypted: it opens with the store's passphrase, through the relay, and not without.
        assertTrue(keys.verify(home, ids.incrementAndGet()))
        val bare = ProcessBuilder(keygen.path, "-y", "-P", "", "-f", SshKeys.keyFile(home).path).redirectErrorStream(true).start()
        bare.inputStream.readBytes()
        assertTrue(bare.waitFor(30, TimeUnit.SECONDS))
        assertTrue("an empty passphrase does not open it", bare.exitValue() != 0)
        assertFalse(SshKeys.keyFile(home).readText().contains(passphrase!!))
        assertEquals(key, keys.current(home))
        assertTrue(keys.delete(home))
        assertNull(keys.current(home))
        assertNull(store.find(CredentialKind.SSH_KEY, CredentialBroker.SSH_KEY_HOST, CredentialBroker.SSH_KEY_USER))
        assertTrue("no channel left", channels.list().isNullOrEmpty())
    }

    @Test
    fun aTakenNameOrAUrlWithASecretIsRefusedBeforeAnythingRuns() {
        File(projects, "Taken").mkdirs()
        val runner = runner()
        val recorder = Recorder()
        assertEquals(GitFailure.EXISTS, runner.start(1L, "taken", "clone", listOf(url), null, recorder)?.failure)
        assertEquals(GitFailure.BAD_REQUEST, runner.start(2L, "fresh", "clone", listOf(url.replace("http://", "http://ada:$secret@")), null, recorder)?.failure)
        assertEquals(GitFailure.BAD_REQUEST, runner.start(3L, ".hidden", "clone", listOf(url), null, recorder)?.failure)
        assertEquals(GitFailure.BAD_REQUEST, runner.start(4L, null, "clone", listOf(url), null, recorder)?.failure)
        assertTrue(recorder.exits.isEmpty())
        assertEquals(listOf("Taken"), projects.list()!!.toList())
    }

    companion object {
        private val GIT: File? = listOf(File("/usr/bin/git"), File("/bin/git"), File("/usr/local/bin/git")).firstOrNull { it.canExecute() }
        private val PYTHON: File? = listOf(File("/usr/bin/python3"), File("/bin/python3"), File("/usr/local/bin/python3")).firstOrNull { it.canExecute() }

        private var launcher: File? = null

        private fun tool(name: String): File =
            listOf(File("/bin/$name"), File("/usr/bin/$name")).firstOrNull { it.canExecute() } ?: throw AssertionError("no $name here")

        /** A FIFO with mode 600, as Os.mkfifo makes on a device. */
        fun mkfifo(file: File) {
            val process = ProcessBuilder("mkfifo", "-m", "600", file.path).redirectErrorStream(true).start()
            if (!process.waitFor(10, TimeUnit.SECONDS) || process.exitValue() != 0) throw java.io.IOException("mkfifo failed")
        }

        /** Runs a command directly, not through the runner, and returns its stdout. */
        fun sh(directory: File, vararg command: String): String {
            val process = ProcessBuilder(*command).directory(directory).redirectErrorStream(true).start()
            val output = process.inputStream.bufferedReader().readText()
            if (!process.waitFor(60, TimeUnit.SECONDS) || process.exitValue() != 0) throw AssertionError("${command.toList()}: $output")
            return output.trim()
        }

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

        /** git http-backend behind Basic authentication, as W1's GitTest serves it on a device. */
        val SERVER_PY = """
import http.server
import os
import subprocess
import sys

root, port_file, credential_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(credential_file, encoding="ascii") as handle:
    expected = "Basic " + handle.read().strip()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    return b"".join(chunks)
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def answer(self, status, headers, payload):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def serve(self):
        data = self.body()
        if self.headers.get("Authorization", "") != expected:
            self.answer(401, [("WWW-Authenticate", 'Basic realm="codeforge-test"')], b"authentication required\n")
            return
        path, _, query = self.path.partition("?")
        env = dict(os.environ)
        env.update({
            "GIT_PROJECT_ROOT": root,
            "GIT_HTTP_EXPORT_ALL": "1",
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "REQUEST_METHOD": self.command,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(data)),
            "REMOTE_USER": "ada",
            "REMOTE_ADDR": "127.0.0.1",
        })
        if self.headers.get("Content-Encoding"):
            env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
        if self.headers.get("Git-Protocol"):
            env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
        out = subprocess.run(["git", "http-backend"], input=data, env=env, capture_output=True).stdout
        separator, skip = out.find(b"\r\n\r\n"), 4
        if separator < 0:
            separator, skip = out.find(b"\n\n"), 2
        head, payload = (out[:separator], out[separator + skip:]) if separator >= 0 else (b"", out)
        status, headers = 200, []
        for line in head.splitlines():
            name, _, value = line.decode("latin-1").partition(":")
            if name.lower() == "status":
                status = int(value.strip().split()[0])
            elif name and name.lower() != "content-length":
                headers.append((name, value.strip()))
        self.answer(status, headers, payload)

    do_GET = serve
    do_POST = serve


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w", encoding="ascii") as handle:
    handle.write(str(server.server_address[1]))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
"""
    }
}
