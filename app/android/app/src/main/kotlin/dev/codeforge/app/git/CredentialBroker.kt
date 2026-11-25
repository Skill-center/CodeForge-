package dev.codeforge.app.git

import java.util.Collections
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicLong

/** What a run's helper asked: git's credential helper protocol, or ssh's askpass. */
sealed class HelperRequest {
    /** git's `get`, `store` or `erase`, with its fields (`protocol`, `host`, `username`, `password`, ...). */
    data class Credential(val operation: String, val fields: Map<String, String>) : HelperRequest() {
        override fun toString(): String = "Credential($operation, ${fields.keys})"
    }

    /** ssh's question through SSH_ASKPASS: a key's passphrase, or whether to trust a new host. */
    data class AskPass(val prompt: String) : HelperRequest()

    /** The host ends the run's channel. */
    data object Quit : HelperRequest()

    companion object {
        /**
         * Reads what the helper wrote (CredentialChannel's scripts): a first
         * line `operation=<name>`, then git's `key=value` lines up to a blank
         * one, or for `askpass` the prompt itself, to the end. Null when it
         * is neither.
         */
        fun parse(text: String): HelperRequest? {
            val firstEnd = text.indexOf('\n').let { if (it < 0) text.length else it }
            val first = text.substring(0, firstEnd)
            if (!first.startsWith("operation=")) return null
            val operation = first.removePrefix("operation=")
            val rest = if (firstEnd < text.length) text.substring(firstEnd + 1) else ""
            return when (operation) {
                "quit" -> Quit
                "askpass" -> AskPass(rest)
                "get", "store", "erase" -> {
                    val fields = LinkedHashMap<String, String>()
                    for (line in rest.split('\n')) {
                        if (line.isEmpty()) break
                        val equals = line.indexOf('=')
                        if (equals <= 0) continue
                        val key = line.substring(0, equals)
                        // Arrays (wwwauth[], capability[], state[]) say how a host asks, not who.
                        if (key.endsWith("[]")) continue
                        fields[key] = line.substring(equals + 1)
                    }
                    Credential(operation, fields)
                }
                else -> null
            }
        }
    }
}

/** What the host asks the user, through Dart. */
data class CredentialPrompt(
    val id: Long,
    val runId: Long,
    val kind: Kind,
    /** git's host (`github.com`, `127.0.0.1:8080`), or ssh's host for a host key. */
    val host: String,
    /** The user name the URL names, for a token. */
    val username: String?,
    /** A new host's key fingerprint (`SHA256:...`) and its type (`ED25519`). */
    val fingerprint: String? = null,
    val keyType: String? = null,
) {
    enum class Kind(val code: String) {
        /** A user name and a token (or password) for a host over HTTPS. */
        HTTPS("https"),

        /** Whether to trust a host ssh has not seen, by its key's fingerprint. */
        HOST_KEY("host_key"),
    }
}

/** The user's answer. [accepted] false: they cancelled, or refused the host. */
data class CredentialReply(
    val accepted: Boolean,
    val username: String? = null,
    val secret: String? = null,
    /** Keep the credential once the host accepts it. */
    val remember: Boolean = false,
) {
    override fun toString(): String = "CredentialReply(accepted=$accepted, username=$username, remember=$remember)"
}

/** Asks the user, through Dart; and tells Dart what became of a stored credential. */
interface CredentialPrompter {
    /** Shows [prompt]; the answer completes the future, once. */
    fun ask(prompt: CredentialPrompt): CompletableFuture<CredentialReply>

    /** The run no longer waits for [promptId]: its dialog goes. */
    fun withdraw(promptId: Long)

    /** A host refused the credential stored for [host] and [username], and it was removed. */
    fun rejected(runId: Long, host: String, username: String)
}

/**
 * Answers one run's helper (Phase 7 W3, PHASE_7_PLAN W3; ADR-0016):
 * - `get` from the store, for exactly the host that asks, or else from the
 *   user through [prompter]. Never over plain HTTP, except to this device
 *   (a loopback address), so no secret crosses a network unencrypted.
 * - `store` keeps what the user typed, when they chose *Remember*, once the
 *   host has accepted it: nothing else is ever stored.
 * - `erase` removes a stored credential the host refused, and says so.
 * - ssh's askpass: the passphrase of CodeForge's own key ([sshKeyPath]),
 *   from the store, to a question naming that key and no other; a new
 *   host's fingerprint, to the user, and `no` to a question about a host
 *   key that cannot be read; with [newPassphrase], the passphrase
 *   `ssh-keygen` asks for a new key. Anything else gets no answer.
 *   See PASSPHRASE_QUESTION for the wordings OpenSSH 9 and 10 use.
 *
 * Nothing here logs a field's value.
 */
class CredentialBroker(
    private val runId: Long,
    private val store: CredentialStore,
    private val prompter: CredentialPrompter,
    private val sshKeyPath: String? = null,
    private val newPassphrase: String? = null,
    private val promptTimeoutMs: Long = PROMPT_TIMEOUT_MS,
    /**
     * A run that reads CodeForge's own key back (`ssh-keygen -y`, SshKeys.verify),
     * whose question names no key: it gets the key's passphrase too.
     */
    private val readsOwnKey: Boolean = false,
) {
    /** What the run handed git last, and whether to keep it once it works. */
    private class Offered(val host: String, val username: String, val secret: String, val fromStore: Boolean, val remember: Boolean)

    @Volatile
    private var offered: Offered? = null

    @Volatile
    private var cancelled = false

    @Volatile
    private var waiting: Pair<Long, CompletableFuture<CredentialReply>>? = null

    /** Whether a stored credential was refused and erased in this run. */
    @Volatile
    var erased = false
        private set

    /** Whether the user cancelled a prompt in this run. */
    @Volatile
    var declined = false
        private set

    /**
     * The questions ssh asked this run, as it asked them, cut at
     * [QUESTION_CHARS]: a question, never an answer, so the gate's report and
     * a failing test can say what was asked. A password is never a question.
     */
    val questions: MutableList<String> = Collections.synchronizedList(ArrayList<String>())

    /** The answer to write back, for `get` and askpass; null for what expects none. */
    fun answer(request: HelperRequest): String? = when (request) {
        is HelperRequest.Credential -> when (request.operation) {
            "get" -> get(request.fields)
            "store" -> {
                store(request.fields)
                null
            }
            "erase" -> {
                erase(request.fields)
                null
            }
            else -> null
        }
        is HelperRequest.AskPass -> askPass(request.prompt)
        HelperRequest.Quit -> null
    }

    /** The run ends: a prompt still open is withdrawn, and the next ones get no answer. */
    fun cancel() {
        cancelled = true
        waiting?.let { (id, future) -> giveUp(id, future) }
    }

    /** Ends a prompt's wait once, whoever gets there first: the run's end, the time limit, or the user. */
    private fun giveUp(id: Long, future: CompletableFuture<CredentialReply>) {
        if (future.complete(CredentialReply(accepted = false))) prompter.withdraw(id)
    }

    private fun get(fields: Map<String, String>): String {
        val protocol = fields["protocol"] ?: return ""
        val host = fields["host"]?.let(CredentialStore::normalHost) ?: return ""
        if (!(protocol == "https" || (protocol == "http" && isLoopback(host)))) return ""
        val named = fields["username"]?.takeIf { it.isNotEmpty() }
        store.find(CredentialKind.HTTPS, host, named)?.let { stored ->
            offered = Offered(host, stored.username, stored.secret, fromStore = true, remember = false)
            return credentialAnswer(stored.username, stored.secret)
        }
        val reply = ask(CredentialPrompt(nextId(), runId, CredentialPrompt.Kind.HTTPS, host, named)) ?: return ""
        val username = reply.username?.takeIf { it.isNotEmpty() } ?: named ?: return ""
        val secret = reply.secret?.takeIf { it.isNotEmpty() } ?: return ""
        if (!oneLine(username) || !oneLine(secret)) return ""
        if (named != null && username != named) return ""
        offered = Offered(host, username, secret, fromStore = false, remember = reply.remember)
        return credentialAnswer(username, secret)
    }

    private fun store(fields: Map<String, String>) {
        val given = offered ?: return
        if (given.fromStore || !given.remember) return
        val host = fields["host"]?.let(CredentialStore::normalHost) ?: return
        if (host != given.host || fields["username"] != given.username || fields["password"] != given.secret) return
        try {
            store.put(GitCredential(CredentialKind.HTTPS, host, given.username, given.secret))
        } catch (full: RuntimeException) {
            // Not kept: the next operation asks again.
        }
    }

    private fun erase(fields: Map<String, String>) {
        val host = fields["host"]?.let(CredentialStore::normalHost) ?: return
        val username = fields["username"] ?: return
        val password = fields["password"] ?: return
        if (store.erase(CredentialKind.HTTPS, host, username, password)) {
            erased = true
            prompter.rejected(runId, host, username)
        }
    }

    private fun askPass(prompt: String): String {
        val text = prompt.trim()
        questions.add(text.take(QUESTION_CHARS))
        if (text.contains("Are you sure you want to continue connecting")) {
            val hostKey = parseHostKeyPrompt(text) ?: return "no\n"
            val reply = ask(
                CredentialPrompt(
                    nextId(), runId, CredentialPrompt.Kind.HOST_KEY, hostKey.host, null,
                    fingerprint = hostKey.fingerprint, keyType = hostKey.keyType,
                ),
            )
            return if (reply != null) "yes\n" else "no\n"
        }
        if (!PASSPHRASE_QUESTION.containsMatchIn(text)) return ""
        // A question about another key is not CodeForge's to answer.
        val named = namedKey(text)
        if (named != null && !isOwnKey(named)) return ""
        // ssh-keygen asks twice for a new key's passphrase; since OpenSSH 10
        // the first question names the file it is making.
        if (newPassphrase != null && (text.contains(FOR_A_NEW_KEY) || text.startsWith("Enter same passphrase again"))) {
            return newPassphrase + "\n"
        }
        // CodeForge's own key's passphrase: to a question that names that key,
        // or to a run of ours that reads it back, whose question names no file
        // before OpenSSH 10 (`ssh-keygen -y`, SshKeys.verify).
        if (named == null && !readsOwnKey) return ""
        return store.find(CredentialKind.SSH_KEY, SSH_KEY_HOST, SSH_KEY_USER)?.secret?.let { it + "\n" } ?: ""
    }

    /** The key file a passphrase question names, as ssh and ssh-keygen name one; null when it names none. */
    private fun namedKey(text: String): String? =
        (SSH_KEY_PROMPT.find(text) ?: KEYGEN_KEY_PROMPT.find(text))?.groupValues?.get(1)

    /** Whether [named] is CodeForge's own key, which ssh cuts at 100 characters. */
    private fun isOwnKey(named: String): Boolean {
        val key = sshKeyPath ?: return false
        return named == key || (named.length == SSH_PROMPT_PATH_CHARS && key.startsWith(named))
    }

    /** Asks the user; null when they cancel, the run ends, or nobody answers in time. */
    private fun ask(prompt: CredentialPrompt): CredentialReply? {
        if (cancelled) return null
        val future = prompter.ask(prompt)
        waiting = prompt.id to future
        try {
            // The run may have ended while the prompt went out.
            if (cancelled) giveUp(prompt.id, future)
            val reply = try {
                future.get(promptTimeoutMs, TimeUnit.MILLISECONDS)
            } catch (late: TimeoutException) {
                giveUp(prompt.id, future)
                null
            } catch (failed: ExecutionException) {
                null
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                null
            }
            if (reply == null || !reply.accepted) {
                declined = true
                return null
            }
            return reply
        } finally {
            waiting = null
        }
    }

    /** A new host's name and key, from ssh's question. */
    data class HostKey(val host: String, val keyType: String, val fingerprint: String)

    companion object {
        /** How long a prompt waits for the user. */
        const val PROMPT_TIMEOUT_MS = 5L * 60_000L

        /** The most characters of a question [questions] keeps. */
        const val QUESTION_CHARS = 120

        /** The SSH key's passphrase is stored as this host and user. */
        const val SSH_KEY_HOST = "codeforge-ssh-key"
        const val SSH_KEY_USER = "codeforge"

        private val ids = AtomicLong(System.currentTimeMillis() % 1_000_000_000L * 1000L)

        fun nextId(): Long = ids.incrementAndGet()

        private fun credentialAnswer(username: String, secret: String): String = "username=$username\npassword=$secret\n"

        private fun oneLine(value: String): Boolean = value.none { it == '\n' || it == '\r' || it == '\u0000' }

        /** 127.0.0.0/8, `localhost` and `[::1]`, with or without a port. */
        fun isLoopback(host: String): Boolean {
            val name = when {
                host.startsWith("[") -> host.substringBefore(']').removePrefix("[")
                host.count { it == ':' } == 1 -> host.substringBefore(':')
                else -> host
            }.lowercase()
            if (name == "localhost" || name == "::1") return true
            val parts = name.split('.')
            return parts.size == 4 && parts[0] == "127" && parts.all { part -> part.toIntOrNull()?.let { it in 0..255 } == true }
        }

        /**
         * What OpenSSH asks about a passphrase, in every wording it uses:
         *
         *     ssh         Enter passphrase for key '<file, cut at 100>':
         *     ssh-keygen  Enter passphrase:                             (to 9)
         *     ssh-keygen  Enter passphrase for "<file>":                (10)
         *     ssh-keygen  Enter passphrase (empty for no passphrase):   (to 9)
         *     ssh-keygen  Enter passphrase for "<file>" (empty for no passphrase):  (10)
         *     ssh-keygen  Enter same passphrase again:
         *
         * Anything else is not a question about a passphrase and gets no
         * answer. OpenSSH 10 is what the runtime carries; 9 is what a
         * machine running the JVM tests may have.
         */
        private val PASSPHRASE_QUESTION = Regex("""^Enter (same )?passphrase""")
        private val SSH_KEY_PROMPT = Regex("""^Enter passphrase for key '(.*)':?$""")
        private val KEYGEN_KEY_PROMPT = Regex("^Enter passphrase for \"([^\"]*)\"")
        private const val FOR_A_NEW_KEY = "(empty for no passphrase)"
        private const val SSH_PROMPT_PATH_CHARS = 100

        private val HOST_LINE = Regex("""The authenticity of host '([^' ]+)(?: \([^)]*\))?' can't be established""")

        /** OpenSSH 10 puts a colon after "is"; before it, a full stop after the fingerprint. */
        private val KEY_LINE = Regex("""([A-Z0-9-]+) key fingerprint is:? (SHA256:[A-Za-z0-9+/=]+)""")

        /** ssh's \"The authenticity of host ... can't be established\" question, read; null when it is not one. */
        fun parseHostKeyPrompt(prompt: String): HostKey? {
            val host = HOST_LINE.find(prompt)?.groupValues?.get(1) ?: return null
            val key = KEY_LINE.find(prompt) ?: return null
            return HostKey(host, key.groupValues[1], key.groupValues[2])
        }
    }
}
