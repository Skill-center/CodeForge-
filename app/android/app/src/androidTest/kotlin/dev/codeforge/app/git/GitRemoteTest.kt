package dev.codeforge.app.git

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import dev.codeforge.app.runtime.AssetPayloadSource
import dev.codeforge.app.runtime.CommandRequest
import dev.codeforge.app.runtime.CommandResult
import dev.codeforge.app.runtime.EndReason
import dev.codeforge.app.runtime.LineSink
import dev.codeforge.app.runtime.RuntimeCommands
import dev.codeforge.app.runtime.SealedRuntime
import dev.codeforge.app.runtime.SessionRegistry
import dev.codeforge.runtime.core.HarnessConfig
import java.io.File
import java.security.SecureRandom
import java.util.Collections
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters

/**
 * Phase 7 W3, gate G3 (PHASE_7_PLAN §3 W3): remotes and credentials with the
 * sealed runtime's own git, bash and ssh, on every target. The runner as
 * GitHost makes it: each remote run gets a CredentialChannel (FIFOs made
 * with Os.mkfifo, the scripts run by the runtime's bash and sh), its
 * CredentialBroker answering from a CredentialStore sealed by the real
 * Android Keystore, or from a scripted user standing in for Dart's dialog.
 *
 *   a. The store with the Keystore's AES-256-GCM key: a secret sealed and
 *      opened, never in the file, gone with the key.
 *   b. Clone, push, fetch and pull against `git http-backend` behind Basic
 *      authentication on 127.0.0.1 (W1's server): the first clone asks the
 *      user, Remember keeps the token once the server took it, the next runs
 *      take it from the store; the secret in no file of the runtime's home,
 *      the projects or the store.
 *   c. A refused stored token is erased and said; a clone stopped while the
 *      user is asked ends with its prompt withdrawn, no staging folder and
 *      nothing running; a URL with a token and a taken name are refused.
 *   d. SSH: a key made by the runtime's ssh-keygen with a passphrase from
 *      the store through askpass, and read back with it; then GitHub over
 *      SSH, recorded and not judged (a network can fail): its host key
 *      asked about once with its published fingerprint, CodeForge's key
 *      offered with its passphrase from the store, and refused, as an
 *      unknown key must be.
 *
 * Every figure goes to the device log (RUNTIME_GATE gitremote_...) and to
 * files/runtime-gate/gitremote-report.txt, which the gate copies out.
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class GitRemoteTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val gate = File(context.filesDir, "runtime-gate")

    private fun record(key: String, value: Any?) {
        val line = "gitremote_$key=$value"
        Log.i(TAG, "RUNTIME_GATE $line")
        gate.mkdirs()
        File(gate, REPORT).appendText(line + "\n")
    }

    /** The scripted user: answers each prompt with [reply]; null leaves it waiting. */
    private class User : CredentialPrompter {
        @Volatile
        var reply: CredentialReply? = null
        val asked: MutableList<CredentialPrompt> = Collections.synchronizedList(ArrayList())
        val withdrawn: MutableList<Long> = Collections.synchronizedList(ArrayList())
        val rejected: MutableList<String> = Collections.synchronizedList(ArrayList())

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
        val progress: MutableList<String> = Collections.synchronizedList(ArrayList())
        val exits = LinkedBlockingQueue<GitExit>()

        override fun output(runId: Long, records: List<String>) {}

        override fun progress(runId: Long, text: String, closing: Boolean) {
            progress.add(text)
        }

        override fun exited(exit: GitExit) {
            exits.add(exit)
        }

        fun exit(): GitExit = exits.poll(LONG_MS, TimeUnit.MILLISECONDS) ?: throw AssertionError("no exit in time")
    }

    private fun start(runner: GitRunner, project: String?, operation: String, vararg arguments: String): Pair<Long, Recorder> {
        val recorder = Recorder()
        val id = ids.incrementAndGet()
        val refused = runner.start(id, project, operation, arguments.toList(), null, recorder)
        assertNull("git $operation refused: ${refused?.failure} ${refused?.message}", refused)
        return id to recorder
    }

    private fun run(runner: GitRunner, project: String?, operation: String, vararg arguments: String): GitExit =
        start(runner, project, operation, *arguments).second.exit()

    private fun assertOk(exit: GitExit) {
        assertNull("git ${exit.operation}: ${exit.failure} ${exit.detail} ${exit.stderr}", exit.failure)
        assertEquals("git ${exit.operation}: ${exit.stderr}", 0, exit.exitCode)
    }

    @Test
    fun a_theStoreSealsWithTheKeystore() {
        File(gate, REPORT).delete()
        val cipher = KeystoreCipher(TEST_ALIAS)
        cipher.delete()
        val file = File(root(), "store/credentials")
        val store = CredentialStore(file, cipher)
        val started = System.nanoTime()
        store.put(GitCredential(CredentialKind.HTTPS, "github.com", "ada", SECRET))
        val putMs = (System.nanoTime() - started) / 1_000_000
        val opening = System.nanoTime()
        assertEquals(SECRET, store.find(CredentialKind.HTTPS, "github.com")?.secret)
        val findMs = (System.nanoTime() - opening) / 1_000_000
        assertFalse("the secret is not in the file", file.readText().contains(SECRET))
        assertNull(store.find(CredentialKind.HTTPS, "gitlab.com"))
        // Gone with the key: nothing opens without it.
        cipher.delete()
        assertNull(CredentialStore(file, KeystoreCipher(TEST_ALIAS)).find(CredentialKind.HTTPS, "github.com"))
        cipher.delete()
        record("store", "ok put_ms=$putMs find_ms=$findMs")
    }

    @Test
    fun b_cloneAsksOnceRemembersThenPushFetchAndPullUseTheStore() {
        val server = serve()
        try {
            val user = User().apply { reply = CredentialReply(true, USER, SECRET, remember = true) }
            val store = store()
            val runner = runner(store, user)
            val first = run(runner, "first", "clone", server.url)
            assertOk(first)
            val prompt = user.asked.single()
            assertEquals(CredentialPrompt.Kind.HTTPS, prompt.kind)
            assertEquals("127.0.0.1:${server.port}", prompt.host)
            assertEquals("kept once the server took it", SECRET, store.find(CredentialKind.HTTPS, prompt.host, USER)?.secret)
            assertTrue(File(projects(), "first/README.md").isFile)
            assertFalse("no staging folder left", projects().list()!!.any { it.startsWith(GitRunner.STAGING_PREFIX) })
            record("clone_asked", "ok ms=${first.elapsedMs}")

            user.reply = null
            val second = run(runner, "second", "clone", server.url)
            assertOk(second)
            assertEquals("the store answered", 1, user.asked.size)
            record("clone_stored", "ok ms=${second.elapsedMs}")

            File(projects(), "first/NEWS.md").writeText("pushed from the device\n")
            assertOk(run(runner, "first", "add", "-A"))
            identity(runner)
            assertOk(run(runner, "first", "commit", "-q", "-m", "From the device"))
            val push = run(runner, "first", "push", "--set-upstream", "origin", "main")
            assertOk(push)
            val fetch = run(runner, "second", "fetch", "--prune", "origin")
            assertOk(fetch)
            val pull = run(runner, "second", "pull", "--ff-only", "origin", "main")
            assertOk(pull)
            assertTrue(File(projects(), "second/NEWS.md").isFile)
            assertEquals(1, user.asked.size)
            record("push_fetch_pull", "ok push_ms=${push.elapsedMs} fetch_ms=${fetch.elapsedMs} pull_ms=${pull.elapsedMs}")

            val leaks = listOf(commands().environment.home, projects(), File(root(), "store")).flatMap { filesContaining(it, SECRET) }
            assertTrue("the secret in a file: $leaks", leaks.isEmpty())
            assertTrue("no channel left", channels().list().isNullOrEmpty())
            record("secret_in_files", leaks.size)
        } finally {
            server.stop()
        }
    }

    @Test
    fun c_aRefusedTokenIsErasedAStopLeavesNothingAndSecretsInUrlsAreRefused() {
        val server = serve()
        try {
            val user = User()
            val store = store()
            val host = "127.0.0.1:${server.port}"
            store.put(GitCredential(CredentialKind.HTTPS, host, USER, "wrong-$SECRET"))
            val runner = runner(store, user)
            val refused = run(runner, "refused", "clone", server.url)
            assertNull(refused.failure)
            assertEquals(128, refused.exitCode)
            assertTrue(refused.stderr, refused.stderr.contains("Authentication failed"))
            assertNull("erased", store.find(CredentialKind.HTTPS, host))
            assertEquals(listOf("$host $USER"), user.rejected)
            assertFalse(File(projects(), "refused").exists())
            record("wrong_token", "refused erased=1 ms=${refused.elapsedMs}")

            // Stopped while the user is asked: the prompt withdrawn, nothing left.
            user.reply = null
            val (id, recorder) = start(runner, "stopped", "clone", server.url)
            val deadline = System.nanoTime() + 60_000_000_000L
            while (user.asked.isEmpty() && System.nanoTime() < deadline) Thread.sleep(20)
            assertEquals(1, user.asked.size)
            assertTrue(runner.stop(id))
            val stopped = recorder.exit()
            assertEquals(GitFailure.STOPPED, stopped.failure)
            assertEquals(listOf(user.asked.single().id), user.withdrawn)
            assertEquals(0, runner.runningCount())
            assertFalse(projects().list()!!.any { it == "stopped" || it.startsWith(GitRunner.STAGING_PREFIX) })
            assertTrue("no channel left", channels().list().isNullOrEmpty())
            record("stop_while_asked", "ok ms=${stopped.elapsedMs}")

            val recorderOfRefusals = Recorder()
            assertEquals(
                GitFailure.BAD_REQUEST,
                runner.start(ids.incrementAndGet(), "secret", "clone", listOf(server.url.replace("http://", "http://$USER:$SECRET@")), null, recorderOfRefusals)?.failure,
            )
            File(projects(), "taken").mkdirs()
            assertEquals(GitFailure.EXISTS, runner.start(ids.incrementAndGet(), "Taken", "clone", listOf(server.url), null, recorderOfRefusals)?.failure)
            assertTrue(recorderOfRefusals.exits.isEmpty())
            record("refusals", "ok")
        } finally {
            server.stop()
        }
    }

    @Test
    fun d_anSshKeyIsMadeAndGitHubIsAskedAbout() {
        val store = store()
        val user = User().apply { reply = CredentialReply(accepted = true) }
        val home = commands().environment.home
        val keys = SshKeys(
            store = store,
            run = { request -> collecting(request).first },
            channel = { runId, passphrase ->
                channel(
                    runId,
                    CredentialBroker(
                        runId, store, user, sshKeyPath = SshKeys.keyFile(home).path,
                        newPassphrase = passphrase, readsOwnKey = passphrase == null,
                    ),
                )
            },
            read = { request -> collecting(request) },
        )
        val making = System.nanoTime()
        val key = keys.create(home, "codeforge@gate", ids.incrementAndGet())
        val madeMs = (System.nanoTime() - making) / 1_000_000
        assertTrue(key.publicKey.startsWith("ssh-ed25519 "))
        assertTrue(key.fingerprint.startsWith("SHA256:"))
        val passphrase = store.find(CredentialKind.SSH_KEY, CredentialBroker.SSH_KEY_HOST, CredentialBroker.SSH_KEY_USER)?.secret
        assertNotNull("the passphrase is in the store", passphrase)
        val keyFile = SshKeys.keyFile(home)
        assertFalse("the passphrase is not in the key file", keyFile.readText().contains(passphrase!!))
        // Read back with the passphrase, which ssh-keygen takes from askpass too.
        assertTrue("the key opens with the stored passphrase", keys.verify(home, ids.incrementAndGet()))
        record("ssh_key", "ok made_ms=$madeMs")

        // GitHub over SSH: recorded, never judged.
        val runner = runner(store, user)
        val sshClone = run(runner, "ssh-clone", "clone", "git@github.com:octocat/Hello-World.git")
        val hostKey = user.asked.firstOrNull { it.kind == CredentialPrompt.Kind.HOST_KEY }
        record(
            "github_ssh",
            "exit=${sshClone.exitCode} failure=${sshClone.failure?.code} ms=${sshClone.elapsedMs} " +
                "host_key_asked=${hostKey != null} fingerprint_ok=${hostKey?.fingerprint == GITHUB_ED25519} " +
                "publickey_refused=${sshClone.stderr.contains("Permission denied (publickey)")} " +
                "detail=${sshClone.stderr.lines().lastOrNull { it.isNotBlank() }?.take(160)?.replace('=', ':')}",
        )
        if (hostKey != null) assertEquals(GITHUB_ED25519, hostKey.fingerprint)
        assertFalse(File(projects(), "ssh-clone").exists())
        assertTrue(keys.delete(home))
        assertNull(store.find(CredentialKind.SSH_KEY, CredentialBroker.SSH_KEY_HOST, CredentialBroker.SSH_KEY_USER))
    }

    private fun identity(runner: GitRunner) {
        assertOk(run(runner, null, "config", "--global", "user.name", "CodeForge Gate"))
        assertOk(run(runner, null, "config", "--global", "user.email", "gate@codeforge.invalid"))
    }

    /** W1's server: git http-backend behind Basic authentication, on 127.0.0.1, in the runtime's python. */
    private class Server(val port: Int, val url: String, private val stopIt: () -> Unit) {
        fun stop() = stopIt()
    }

    private fun serve(): Server {
        val home = commands().environment.home
        val served = File(home, "served").apply {
            deleteRecursively()
            mkdirs()
        }
        val seed = File(home, "seed").apply {
            deleteRecursively()
            mkdirs()
        }
        File(seed, "README.md").writeText("served\n")
        direct(seed, "init", "-q", "--initial-branch=main")
        direct(seed, "add", "-A")
        direct(seed, "-c", "user.name=Seed", "-c", "user.email=seed@codeforge.invalid", "commit", "-q", "-m", "seed")
        direct(served, "clone", "-q", "--bare", seed.path, "repo.git")
        direct(File(served, "repo.git"), "config", "http.receivepack", "true")
        val script = File(home, "git-remote-server.py").apply { writeText(SERVER_PY) }
        val credentials = File(home, "git-remote-credentials").apply {
            writeText(Base64.encodeToString("$USER:$SECRET".toByteArray(), Base64.NO_WRAP))
        }
        val portFile = File(home, "git-remote-port").apply { delete() }
        val session = AtomicReference<SessionRegistry.Session?>()
        val thread = Thread {
            commands().runner.stream(
                CommandRequest("python", listOf(script.path, served.path, portFile.path, credentials.path), directory = null, timeoutMs = 9 * 60_000L),
                object : LineSink {
                    override fun line(text: String): Boolean = true
                },
                started = { session.set(it) },
            )
        }.apply {
            isDaemon = true
            start()
        }
        val deadline = System.nanoTime() + 30_000_000_000L
        var port: Int? = null
        while (port == null && System.nanoTime() < deadline) {
            port = portFile.takeIf { it.isFile }?.readText()?.trim()?.toIntOrNull()
            if (port == null) Thread.sleep(50)
        }
        assertNotNull("the server listens", port)
        return Server(port!!, "http://127.0.0.1:$port/repo.git") {
            session.get()?.end(EndReason.ENDED)
            thread.join(15_000L)
            credentials.delete()
        }
    }

    /** git run directly through the launcher, outside the host: the server's fixtures. */
    private fun direct(directory: File, vararg arguments: String) {
        val result = commands().runner.run(
            CommandRequest("git", listOf("-c", "core.pager=cat", "-c", "init.defaultBranch=main") + arguments, directory = directory, timeoutMs = 60_000L),
        )
        assertTrue("git ${arguments.toList()}: ${result.stderr.text}", result.succeeded)
    }

    /** A command through the launcher, with its stdout's first lines. */
    private fun collecting(request: CommandRequest): Pair<CommandResult?, List<String>> {
        val lines = ArrayList<String>()
        val result = commands().runner.stream(
            request,
            object : LineSink {
                override fun line(text: String): Boolean {
                    if (lines.size < 64) lines.add(text)
                    return true
                }
            },
        )
        return result to lines
    }

    private companion object {
        const val TAG = "CodeForgeRuntimeGate"
        const val REPORT = "gitremote-report.txt"
        const val USER = "gate"
        const val TEST_ALIAS = "codeforge-git-credentials-gate"
        const val LONG_MS = 10L * 60_000L
        const val MODE_0600 = 384

        /** GitHub's published Ed25519 host key fingerprint. */
        const val GITHUB_ED25519 = "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"

        val SECRET: String = ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
        val ids = AtomicLong(System.currentTimeMillis() % 1_000_000L * 1000L)

        private var installed: RuntimeCommands? = null
        private var rootDir: File? = null
        private var pool: ExecutorService? = null

        fun root(): File {
            commands()
            return rootDir!!
        }

        fun projects(): File = File(root(), "workspaces").apply { mkdirs() }

        fun channels(): File = File(root(), "no_backup/git/run")

        fun store(): CredentialStore = CredentialStore(File(root(), "store/credentials"), KeystoreCipher(TEST_ALIAS))

        fun channel(runId: Long, broker: CredentialBroker): CredentialChannel = CredentialChannel.open(
            channels(), runId, broker,
            bash = File(commands().environment.bin, "bash"),
            makeFifo = { file -> Os.mkfifo(file.path, MODE_0600) },
        )

        /** The runner as GitHost makes it: a channel for each remote run, the runtime home's ssh settings. */
        fun runner(store: CredentialStore, user: CredentialPrompter): GitRunner {
            val commands = commands()
            val threads = pool ?: Executors.newCachedThreadPool().also { pool = it }
            return GitRunner(
                processes = { request, sink, maxRecordBytes, separator, started, extraRoots, progress ->
                    commands.runner.stream(request, sink, maxRecordBytes, started, extraRoots, separator, progress)
                },
                projects = projects(),
                executor = threads,
                credentials = { runId ->
                    val home = commands.environment.home
                    val key = SshKeys.keyFile(home)
                    val opened = channel(runId, CredentialBroker(runId, store, user, sshKeyPath = key.takeIf { it.isFile }?.path))
                    File(home, ".ssh").mkdirs()
                    val ssh = SshKeys.sshCommand(home)
                    object : GitRunCredentials {
                        override val settings = opened.helperSettings()
                        override val variables = opened.variables(ssh)
                        override val erased: Boolean get() = opened.erased

                        override fun close() = opened.close()
                    }
                },
            )
        }

        /** The payload installed once for the class, in a root of its own, and its command side. */
        @Synchronized
        fun commands(): RuntimeCommands {
            installed?.let { return it }
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val root = File(context.filesDir, "runtime-gate/gitremote")
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

        /** The class's runtime root and its Keystore key go once its tests are done. */
        @JvmStatic
        @AfterClass
        fun removeTheRuntime() {
            pool?.shutdownNow()
            KeystoreCipher(TEST_ALIAS).delete()
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            File(context.filesDir, "runtime-gate/gitremote").deleteRecursively()
            installed = null
            rootDir = null
            pool = null
        }

        /** Regular files under [root], up to 4 MB each, that hold [secret]. */
        fun filesContaining(root: File, secret: String): List<String> {
            if (!root.exists()) return emptyList()
            val needle = secret.toByteArray()
            return root.walkTopDown()
                .filter { it.isFile && it.length() <= 4L * 1024 * 1024 }
                .filter { file -> contains(file.readBytes(), needle) }
                .map { it.relativeTo(root).path }
                .toList()
        }

        private fun contains(haystack: ByteArray, needle: ByteArray): Boolean {
            if (needle.isEmpty() || haystack.size < needle.size) return false
            outer@ for (start in 0..haystack.size - needle.size) {
                for (index in needle.indices) {
                    if (haystack[start + index] != needle[index]) continue@outer
                }
                return true
            }
            return false
        }

        /** git http-backend behind Basic authentication (W1's GitTest), for b and c. */
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
            self.answer(401, [("WWW-Authenticate", 'Basic realm="codeforge-gate"')], b"authentication required\n")
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
            "REMOTE_USER": "gate",
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
