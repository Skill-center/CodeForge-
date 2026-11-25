package dev.codeforge.app.git

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.system.Os
import android.util.Log
import dev.codeforge.app.runtime.CommandRequest
import dev.codeforge.app.runtime.CommandResult
import dev.codeforge.app.runtime.LineSink
import dev.codeforge.app.runtime.RuntimeHub
import dev.codeforge.app.runtime.RuntimeHubs
import io.flutter.plugin.common.BinaryMessenger
import java.io.File
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * The Git host (Phase 7 W2; pigeons/git_api.dart; docs/adr/0016-git.md):
 * Dart's typed API to the runtime's own git, over the process's one
 * RuntimeHub. Orchestration only: [GitCommands] decides what may run and
 * how, [GitRunner] runs it in a project resolved from its folder's name,
 * and this class turns runs into Pigeon's messages.
 *
 * Since Phase 7 W3 a remote run gets a [CredentialChannel] of its own: git's
 * credential helper and ssh's askpass reach a [CredentialBroker], which
 * answers from the [CredentialStore] (the Keystore's key, in `no_backup/`)
 * or asks Dart ([Prompter]). [SshKeys] makes and removes CodeForge's SSH key.
 *
 * A run's records, progress and exit go to Dart through GitEvents on the
 * main thread, in order. Runs belong to this engine: when it goes ([close]),
 * they are stopped. Logs name an operation, its run, its exit and its time,
 * never an argument, a path, a URL, a host or a secret (PHASE_7_PLAN §4).
 */
class GitHost(context: Context, messenger: BinaryMessenger) : GitApi {
    private val app = context.applicationContext
    private val hub = RuntimeHubs.get(app)
    private val events = GitEvents(messenger)
    private val main = Handler(Looper.getMainLooper())
    private val threads = AtomicInteger()
    private val pool: ExecutorService = Executors.newCachedThreadPool { task ->
        Thread(task, "codeforge-git-${threads.incrementAndGet()}").apply { isDaemon = true }
    }
    private val keyRuns = AtomicLong(System.currentTimeMillis() % 1_000_000_000L * 1000L + 500L)

    @Volatile
    private var closed = false

    private val store = CredentialStore(CredentialStore.fileIn(app.noBackupFilesDir), KeystoreCipher())
    private val channels = File(app.noBackupFilesDir, CHANNELS)
    private val prompter = Prompter()

    private val sshKeys = SshKeys(
        store = store,
        run = { request -> runCollecting(hub, request).first },
        channel = { runId, passphrase ->
            val bin = hub.currentCommands()?.environment?.bin ?: throw IOException("the runtime is not ready")
            CredentialChannel.open(
                channels, runId,
                // A new key's passphrase; or, reading the key back, the stored one.
                CredentialBroker(runId, store, prompter, newPassphrase = passphrase, readsOwnKey = passphrase == null),
                bash = File(bin, "bash"), makeFifo = ::makeFifo,
            )
        },
        read = { request -> runCollecting(hub, request) },
    )

    private val runner = GitRunner(
        processes = { request, sink, maxRecordBytes, separator, started, extraRoots, progress ->
            hub.stream(request, sink, started, extraRoots, maxRecordBytes, separator, progress)
        },
        projects = File(app.filesDir, RuntimeHubs.PROJECTS),
        executor = pool,
        credentials = { runId -> openCredentials(runId) },
    )

    init {
        // What a run left when the app's process died: its FIFOs and scripts.
        pool.execute { CredentialChannel.clean(channels) }
    }

    /** A remote run's channel: CodeForge's helper, ssh's askpass, and how git runs ssh. */
    private fun openCredentials(runId: Long): GitRunCredentials {
        val environment = hub.currentCommands()?.environment ?: throw IOException("the runtime is not ready")
        val home = environment.home
        val key = SshKeys.keyFile(home)
        val channel = CredentialChannel.open(
            channels, runId,
            CredentialBroker(runId, store, prompter, sshKeyPath = key.takeIf { it.isFile }?.path),
            bash = File(environment.bin, "bash"), makeFifo = ::makeFifo,
        )
        File(home, ".ssh").mkdirs()
        val ssh = SshKeys.sshCommand(home)
        return object : GitRunCredentials {
            override val settings = channel.helperSettings()
            override val variables = channel.variables(ssh)
            override val erased: Boolean get() = channel.erased

            override fun close() = channel.close()
        }
    }

    private val listener = object : GitListener {
        override fun output(runId: Long, records: List<String>) {
            main.post {
                if (!closed) events.output(runId, records) { }
            }
        }

        override fun progress(runId: Long, text: String, closing: Boolean) {
            main.post {
                if (!closed) events.progress(runId, text, closing) { }
            }
        }

        override fun exited(exit: GitExit) {
            Log.i(
                TAG,
                "git ${exit.operation} (run ${exit.runId}): " + (exit.failure?.code ?: exit.exitCode?.let { "exit $it" } ?: "ended") +
                    ", ${exit.records} records, ${exit.elapsedMs} ms" + (if (exit.truncated) ", truncated" else ""),
            )
            val message = GitExitMessage(
                runId = exit.runId,
                operation = exit.operation,
                exitCode = exit.exitCode?.toLong(),
                failure = exit.failure?.code,
                detail = exit.detail,
                stderr = exit.stderr,
                records = exit.records.toLong(),
                chars = exit.chars,
                truncated = exit.truncated,
                elapsedMs = exit.elapsedMs,
            )
            main.post {
                if (!closed) events.exited(message) { }
            }
        }
    }

    /** Asks Dart, and holds each prompt's answer until Dart gives it. */
    private inner class Prompter : CredentialPrompter {
        private val waiting = ConcurrentHashMap<Long, CompletableFuture<CredentialReply>>()

        override fun ask(prompt: CredentialPrompt): CompletableFuture<CredentialReply> {
            val future = CompletableFuture<CredentialReply>()
            if (closed) {
                future.complete(CredentialReply(accepted = false))
                return future
            }
            waiting[prompt.id] = future
            future.whenComplete { _, _ -> waiting.remove(prompt.id, future) }
            Log.i(TAG, "git run ${prompt.runId} asks for a credential (${prompt.kind.code})")
            val message = GitCredentialPromptMessage(
                id = prompt.id,
                runId = prompt.runId,
                kind = prompt.kind.code,
                host = prompt.host,
                username = prompt.username,
                fingerprint = prompt.fingerprint,
                keyType = prompt.keyType,
            )
            main.post {
                if (closed) future.complete(CredentialReply(accepted = false)) else events.credentialRequested(message) { }
            }
            return future
        }

        override fun withdraw(promptId: Long) {
            waiting.remove(promptId)?.complete(CredentialReply(accepted = false))
            main.post {
                if (!closed) events.credentialWithdrawn(promptId) { }
            }
        }

        override fun rejected(runId: Long, host: String, username: String) {
            Log.i(TAG, "git run $runId: a stored credential was refused and removed")
            main.post {
                if (!closed) events.credentialRejected(runId, host, username) { }
            }
        }

        fun answer(id: Long, reply: CredentialReply): Boolean = waiting.remove(id)?.complete(reply) ?: false

        fun cancelAll() {
            for (future in waiting.values) future.complete(CredentialReply(accepted = false))
            waiting.clear()
        }
    }

    /** The engine is going: its runs stop, open prompts are refused, and no more events go to it. */
    fun close() {
        closed = true
        prompter.cancelAll()
        runner.stopAll()
        pool.shutdown()
    }

    override fun run(request: GitRunMessage, callback: (Result<GitStartMessage>) -> Unit) {
        if (closed) {
            callback(Result.success(GitStartMessage(failure = GitFailure.LAUNCH_FAILED.code, detail = "the git host is closed")))
            return
        }
        val maxRecords = request.maxRecords?.coerceIn(1L, GitRunner.MAX_RECORDS.toLong())?.toInt()
        val refused = runner.start(request.runId, request.project, request.operation, request.arguments, maxRecords, listener)
        if (refused != null) {
            // The operation only when it is one of ours: anything else Dart sent could be anything.
            val operation = request.operation.takeIf { it in GitCommands.OPERATIONS } ?: "(unknown operation)"
            Log.w(TAG, "git $operation (run ${request.runId}) refused: ${refused.failure.code}")
        }
        callback(Result.success(GitStartMessage(failure = refused?.failure?.code, detail = refused?.message)))
    }

    override fun stop(runId: Long, callback: (Result<Boolean>) -> Unit) {
        callback(Result.success(runner.stop(runId)))
    }

    override fun answerCredential(answer: GitCredentialAnswerMessage, callback: (Result<Unit>) -> Unit) {
        val reply = CredentialReply(
            accepted = answer.accepted,
            username = answer.username,
            secret = answer.secret,
            remember = answer.remember,
        )
        prompter.answer(answer.id, reply)
        callback(Result.success(Unit))
    }

    override fun accounts(callback: (Result<List<GitAccountMessage>>) -> Unit) {
        pool.execute {
            val accounts = try {
                store.accounts().map { GitAccountMessage(it.kind.code, it.host, it.username, it.updatedAt) }
            } catch (failure: RuntimeException) {
                emptyList()
            }
            main.post { callback(Result.success(accounts)) }
        }
    }

    override fun removeAccount(kind: String, host: String, username: String, callback: (Result<Boolean>) -> Unit) {
        pool.execute {
            val credentialKind = CredentialKind.of(kind)
            val removed = credentialKind != null && credentialKind != CredentialKind.SSH_KEY &&
                try {
                    store.remove(credentialKind, host, username)
                } catch (failure: RuntimeException) {
                    false
                }
            main.post { callback(Result.success(removed)) }
        }
    }

    override fun sshKey(callback: (Result<GitSshKeyMessage?>) -> Unit) {
        pool.execute {
            val home = hub.currentCommands()?.environment?.home
            val key = home?.let { sshKeys.current(it) }
            main.post { callback(Result.success(key?.let { GitSshKeyMessage(it.publicKey, it.fingerprint, it.comment) })) }
        }
    }

    override fun createSshKey(comment: String, callback: (Result<GitSshKeyResultMessage>) -> Unit) {
        pool.execute {
            val home = hub.currentCommands()?.environment?.home
            val result = if (home == null) {
                GitSshKeyResultMessage(failure = GitFailure.NOT_READY.code, detail = "the runtime is not ready")
            } else {
                try {
                    val key = sshKeys.create(home, comment, keyRuns.incrementAndGet())
                    Log.i(TAG, "an SSH key was made")
                    GitSshKeyResultMessage(key = GitSshKeyMessage(key.publicKey, key.fingerprint, key.comment))
                } catch (refused: GitRefused) {
                    GitSshKeyResultMessage(failure = refused.failure.code, detail = refused.message)
                } catch (failure: Exception) {
                    GitSshKeyResultMessage(failure = GitFailure.LAUNCH_FAILED.code, detail = failure.javaClass.simpleName)
                }
            }
            main.post { callback(Result.success(result)) }
        }
    }

    override fun deleteSshKey(callback: (Result<Boolean>) -> Unit) {
        pool.execute {
            val home = hub.currentCommands()?.environment?.home
            val removed = home != null && sshKeys.delete(home)
            main.post { callback(Result.success(removed)) }
        }
    }

    private companion object {
        const val TAG = "CodeForgeGit"

        /** Where each remote run's FIFOs and scripts live, in `no_backup/`. */
        const val CHANNELS = "git/run"

        private const val MODE_0600 = 384

        fun makeFifo(file: File) {
            Os.mkfifo(file.path, MODE_0600)
        }

        /** Runs [request] to its end, with its stdout's first lines (ssh-keygen's few). */
        fun runCollecting(hub: RuntimeHub, request: CommandRequest): Pair<CommandResult?, List<String>> {
            val lines = ArrayList<String>()
            val result = hub.stream(request, object : LineSink {
                override fun line(text: String): Boolean {
                    if (lines.size < 64) lines.add(text)
                    return true
                }
            }, started = { })
            return result to lines
        }
    }
}
