package dev.codeforge.app.git

import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The credential helper's answers (Phase 7 W3, gate G3): git's protocol
 * (`get`, `store`, `erase`) and ssh's askpass, against the store and a
 * scripted user. GitRemoteRunnerTest runs them with real git and FIFOs.
 */
class CredentialBrokerTest {
    @get:Rule
    val temp = TemporaryFolder()

    private val token = "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB"

    /** A user who answers each prompt with [reply], and what they were asked. */
    private class User(var reply: CredentialReply? = null) : CredentialPrompter {
        val asked = CopyOnWriteArrayList<CredentialPrompt>()
        val withdrawn = CopyOnWriteArrayList<Long>()
        val rejected = CopyOnWriteArrayList<String>()

        override fun ask(prompt: CredentialPrompt): CompletableFuture<CredentialReply> {
            asked.add(prompt)
            val future = CompletableFuture<CredentialReply>()
            reply?.let { future.complete(it) }
            return future
        }

        override fun withdraw(promptId: Long) {
            withdrawn.add(promptId)
        }

        override fun rejected(runId: Long, host: String, username: String) {
            rejected.add("$host $username")
        }
    }

    private fun store() = CredentialStore(File(temp.root, "credentials"), CredentialStoreTest.SoftwareCipher())

    private fun get(vararg fields: String) = HelperRequest.Credential("get", pairs(*fields))
    private fun store(vararg fields: String) = HelperRequest.Credential("store", pairs(*fields))
    private fun erase(vararg fields: String) = HelperRequest.Credential("erase", pairs(*fields))
    private fun pairs(vararg fields: String) = fields.associate { it.substringBefore('=') to it.substringAfter('=') }

    @Test
    fun theHelpersWordsAreRead() {
        assertEquals(
            HelperRequest.Credential("get", mapOf("protocol" to "https", "host" to "github.com", "username" to "ada")),
            HelperRequest.parse("operation=get\nprotocol=https\nhost=github.com\nwwwauth[]=Basic realm=\"GitHub\"\nusername=ada\n\n"),
        )
        assertEquals(HelperRequest.AskPass("Enter passphrase for key '/k': "), HelperRequest.parse("operation=askpass\nEnter passphrase for key '/k': "))
        assertEquals(HelperRequest.AskPass("line one\nline two? "), HelperRequest.parse("operation=askpass\nline one\nline two? "))
        assertEquals(HelperRequest.Quit, HelperRequest.parse("operation=quit\n"))
        assertNull(HelperRequest.parse("operation=other\n"))
        assertNull(HelperRequest.parse("protocol=https\n"))
        assertNull(HelperRequest.parse(""))
        // Only the first blank line ends git's fields: a value never holds a newline, so nothing after it counts.
        assertEquals(mapOf("host" to "a"), (HelperRequest.parse("operation=get\nhost=a\n\nhost=b\n") as HelperRequest.Credential).fields)
    }

    @Test
    fun aStoredCredentialAnswersItsHostAndNoOther() {
        val store = store()
        store.put(GitCredential(CredentialKind.HTTPS, "github.com", "ada", token))
        // A user who declines whatever they are asked.
        val user = User(CredentialReply(accepted = false))
        val broker = CredentialBroker(7L, store, user)
        assertEquals("username=ada\npassword=$token\n", broker.answer(get("protocol=https", "host=github.com")))
        assertEquals("username=ada\npassword=$token\n", broker.answer(get("protocol=https", "host=github.com", "username=ada")))
        assertTrue("nobody was asked", user.asked.isEmpty())
        // Another host, another port, another user: never this one's secret.
        assertEquals("", broker.answer(get("protocol=https", "host=gitlab.com")))
        assertEquals("", broker.answer(get("protocol=https", "host=github.com:444")))
        assertEquals("", broker.answer(get("protocol=https", "host=github.com", "username=eve")))
        // Plain HTTP: never a secret, except to this device.
        assertEquals("", broker.answer(get("protocol=http", "host=github.com")))
        assertEquals(3, user.asked.size)
        assertTrue(user.asked.none { it.host == "github.com" && it.username == null })
    }

    @Test
    fun withNothingStoredTheUserIsAskedAndRememberKeepsItOnlyOnceItWorked() {
        val store = store()
        val user = User(CredentialReply(accepted = true, username = "ada", secret = token, remember = true))
        val broker = CredentialBroker(7L, store, user)
        assertEquals("username=ada\npassword=$token\n", broker.answer(get("protocol=https", "host=github.com")))
        val prompt = user.asked.single()
        assertEquals(CredentialPrompt.Kind.HTTPS, prompt.kind)
        assertEquals("github.com", prompt.host)
        assertEquals(7L, prompt.runId)
        assertNull("nothing kept before the host said yes", store.find(CredentialKind.HTTPS, "github.com"))
        // git's store after success: kept, as typed.
        assertNull(broker.answer(store("protocol=https", "host=github.com", "username=ada", "password=$token")))
        assertEquals(token, store.find(CredentialKind.HTTPS, "github.com", "ada")?.secret)
    }

    @Test
    fun storeKeepsNothingButWhatTheUserTypedAndChoseToRemember() {
        val store = store()
        val user = User(CredentialReply(accepted = true, username = "ada", secret = token, remember = false))
        val broker = CredentialBroker(7L, store, user)
        broker.answer(get("protocol=https", "host=github.com"))
        broker.answer(store("protocol=https", "host=github.com", "username=ada", "password=$token"))
        assertNull("not remembered", store.find(CredentialKind.HTTPS, "github.com"))

        val remembering = CredentialBroker(8L, store, User(CredentialReply(accepted = true, username = "ada", secret = token, remember = true)))
        remembering.answer(get("protocol=https", "host=github.com"))
        // A store for another host or secret than the one given is not the one the user typed.
        remembering.answer(store("protocol=https", "host=gitlab.com", "username=ada", "password=$token"))
        remembering.answer(store("protocol=https", "host=github.com", "username=ada", "password=other"))
        assertTrue(store.accounts().isEmpty())
        // Nothing given at all: nothing to keep.
        CredentialBroker(9L, store, User()).answer(store("protocol=https", "host=github.com", "username=ada", "password=$token"))
        assertTrue(store.accounts().isEmpty())
    }

    @Test
    fun eraseRemovesTheRefusedStoredCredentialAndSaysSo() {
        val store = store()
        store.put(GitCredential(CredentialKind.HTTPS, "github.com", "ada", token))
        val user = User()
        val broker = CredentialBroker(7L, store, user)
        broker.answer(get("protocol=https", "host=github.com"))
        assertFalse(broker.erased)
        assertNull(broker.answer(erase("protocol=https", "host=github.com", "username=ada", "password=$token")))
        assertTrue(broker.erased)
        assertNull(store.find(CredentialKind.HTTPS, "github.com"))
        assertEquals(listOf("github.com ada"), user.rejected)
        // A refused typed credential was never stored: nothing to say.
        broker.answer(erase("protocol=https", "host=github.com", "username=ada", "password=typed"))
        assertEquals(1, user.rejected.size)
    }

    @Test
    fun aCancelledPromptAnswersNothingAndARunEndingWithdrawsIt() {
        val store = store()
        val declining = CredentialBroker(7L, store, User(CredentialReply(accepted = false)))
        assertEquals("", declining.answer(get("protocol=https", "host=github.com")))
        assertTrue(declining.declined)

        // Nobody answers: the run ends, and its prompt goes.
        val silent = User(reply = null)
        val waiting = CredentialBroker(8L, store, silent, promptTimeoutMs = 60_000L)
        val answered = CompletableFuture<String?>()
        val thread = Thread { answered.complete(waiting.answer(get("protocol=https", "host=github.com"))) }.apply { start() }
        while (silent.asked.isEmpty()) Thread.sleep(5)
        waiting.cancel()
        thread.join(5_000L)
        assertEquals("", answered.getNow("still waiting"))
        assertEquals(listOf(silent.asked.single().id), silent.withdrawn)
        // After the end nothing is asked.
        assertEquals("", waiting.answer(get("protocol=https", "host=gitlab.com")))
        assertEquals(1, silent.asked.size)

        // Nobody answers in time: withdrawn.
        val late = User(reply = null)
        assertEquals("", CredentialBroker(9L, store, late, promptTimeoutMs = 50L).answer(get("protocol=https", "host=github.com")))
        assertEquals(listOf(late.asked.single().id), late.withdrawn)
    }

    @Test
    fun aTypedAnswerThatCannotBeOneLineOrDiffersFromTheUrlsUserIsNotGiven() {
        val store = store()
        assertEquals(
            "",
            CredentialBroker(1L, store, User(CredentialReply(true, "ada", "two\nlines", false))).answer(get("protocol=https", "host=github.com")),
        )
        assertEquals(
            "",
            CredentialBroker(2L, store, User(CredentialReply(true, "eve", token, false))).answer(get("protocol=https", "host=github.com", "username=ada")),
        )
        // The URL's user name stands when the user leaves it out.
        assertEquals(
            "username=ada\npassword=$token\n",
            CredentialBroker(3L, store, User(CredentialReply(true, "", token, false))).answer(get("protocol=https", "host=github.com", "username=ada")),
        )
        assertEquals(
            "username=ada\npassword=$token\n",
            CredentialBroker(4L, store, User(CredentialReply(true, "ada", token, false))).answer(get("protocol=http", "host=127.0.0.1:8080")),
        )
    }

    @Test
    fun sshGetsTheKeysPassphraseAndTheUserDecidesANewHost() {
        val store = store()
        store.put(GitCredential(CredentialKind.SSH_KEY, CredentialBroker.SSH_KEY_HOST, CredentialBroker.SSH_KEY_USER, "pass-phrase"))
        val key = "/data/user/0/dev.codeforge.app/files/home/.ssh/codeforge_ed25519"
        val user = User(CredentialReply(accepted = true))
        val broker = CredentialBroker(7L, store, user, sshKeyPath = key)
        assertEquals("pass-phrase\n", broker.answer(HelperRequest.AskPass("Enter passphrase for key '$key': ")))
        assertEquals("another key gets nothing", "", broker.answer(HelperRequest.AskPass("Enter passphrase for key '/elsewhere/id_ed25519': ")))
        // ssh cuts the path at 100 characters.
        val long = "/data/user/0/dev.codeforge.app/files/a-much-longer-runtime-folder/than/usual/home/.ssh/codeforge_ed25519"
        val longBroker = CredentialBroker(8L, store, user, sshKeyPath = long)
        assertEquals("pass-phrase\n", longBroker.answer(HelperRequest.AskPass("Enter passphrase for key '${long.take(100)}': ")))
        assertEquals("", broker.answer(HelperRequest.AskPass("git@github.com's password: ")))

        val prompt = "The authenticity of host 'github.com (140.82.121.3)' can't be established.\n" +
            "ED25519 key fingerprint is SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU.\n" +
            "This key is not known by any other names.\n" +
            "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        assertEquals("yes\n", broker.answer(HelperRequest.AskPass(prompt)))
        val asked = user.asked.single()
        assertEquals(CredentialPrompt.Kind.HOST_KEY, asked.kind)
        assertEquals("github.com", asked.host)
        assertEquals("ED25519", asked.keyType)
        assertEquals("SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU", asked.fingerprint)
        assertEquals("no\n", CredentialBroker(9L, store, User(CredentialReply(false)), sshKeyPath = key).answer(HelperRequest.AskPass(prompt)))
        assertEquals(
            CredentialBroker.HostKey("[127.0.0.1]:2222", "ECDSA", "SHA256:abc+/="),
            CredentialBroker.parseHostKeyPrompt(
                "The authenticity of host '[127.0.0.1]:2222 ([127.0.0.1]:2222)' can't be established.\n" +
                    "ECDSA key fingerprint is SHA256:abc+/=.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ",
            ),
        )
        assertNull(CredentialBroker.parseHostKeyPrompt("Are you sure you want to continue connecting (yes/no)? "))

        // A new key: ssh-keygen's two questions get the passphrase made for it, and only during that run.
        val making = CredentialBroker(10L, store, user, newPassphrase = "new-pass")
        assertEquals("new-pass\n", making.answer(HelperRequest.AskPass("Enter passphrase (empty for no passphrase): ")))
        assertEquals("new-pass\n", making.answer(HelperRequest.AskPass("Enter same passphrase again: ")))
        assertEquals("", broker.answer(HelperRequest.AskPass("Enter passphrase (empty for no passphrase): ")))
    }

    /**
     * Every wording OpenSSH uses to ask about a passphrase is answered, and
     * nothing else is. The runtime carries OpenSSH 10, which names the key
     * file where 9 did not: a question it asked went unanswered until this
     * table, and `ssh-keygen` then asked for a new key's passphrase again
     * and again until the run's time was up (CI 45673678523).
     */
    @Test
    fun everyWordingOpenSshHasForAPassphraseIsAnswered() {
        val store = store()
        store.put(GitCredential(CredentialKind.SSH_KEY, CredentialBroker.SSH_KEY_HOST, CredentialBroker.SSH_KEY_USER, "stored-pass"))
        val key = "/data/user/0/dev.codeforge.app/files/home/.ssh/codeforge_ed25519"
        val user = User(CredentialReply(accepted = true))
        fun broker(newPassphrase: String? = null, readsOwnKey: Boolean = false, keyPath: String? = key) =
            CredentialBroker(11L, store, user, sshKeyPath = keyPath, newPassphrase = newPassphrase, readsOwnKey = readsOwnKey)

        // ssh-keygen making a key: OpenSSH 9's questions, then 10's.
        val making = broker(newPassphrase = "new-pass")
        assertEquals("new-pass\n", making.answer(HelperRequest.AskPass("Enter passphrase (empty for no passphrase): ")))
        assertEquals("new-pass\n", making.answer(HelperRequest.AskPass("""Enter passphrase for "$key" (empty for no passphrase): """)))
        assertEquals("new-pass\n", making.answer(HelperRequest.AskPass("Enter same passphrase again: ")))
        assertEquals(
            "another key is not ours to answer for",
            "",
            making.answer(HelperRequest.AskPass("""Enter passphrase for "/elsewhere/id_ed25519" (empty for no passphrase): """)),
        )

        // ssh-keygen -y reading our key back: 9 names no file, 10 does.
        val reading = broker(readsOwnKey = true)
        assertEquals("stored-pass\n", reading.answer(HelperRequest.AskPass("Enter passphrase: ")))
        assertEquals("stored-pass\n", reading.answer(HelperRequest.AskPass("""Enter passphrase for "$key": """)))
        assertEquals("", reading.answer(HelperRequest.AskPass("""Enter passphrase for "/elsewhere/id_ed25519": """)))

        // A git run over ssh: our key by name, nothing else, whoever asks.
        val cloning = broker()
        assertEquals("stored-pass\n", cloning.answer(HelperRequest.AskPass("Enter passphrase for key '$key': ")))
        assertEquals("", cloning.answer(HelperRequest.AskPass("Enter passphrase for key '/elsewhere/id_ed25519': ")))
        assertEquals("a question that names no key is not ours", "", cloning.answer(HelperRequest.AskPass("Enter passphrase: ")))
        assertEquals("", cloning.answer(HelperRequest.AskPass("git@github.com's password: ")))
        assertEquals("", cloning.answer(HelperRequest.AskPass("(ada@github.com) Password: ")))
        assertEquals("", broker(keyPath = null).answer(HelperRequest.AskPass("Enter passphrase for key '$key': ")))

        // Every question asked is kept, as asked, and never an answer.
        assertTrue(making.questions.first().startsWith("Enter passphrase (empty"))
        assertFalse(making.questions.any { it.contains("new-pass") || it.contains("stored-pass") })
    }

    /** OpenSSH 10 puts a colon after "is"; 9 put a full stop after the fingerprint. */
    @Test
    fun aNewHostsKeyIsReadInBothOpenSshsWordings() {
        val nine = "The authenticity of host 'github.com (140.82.121.3)' can't be established.\n" +
            "ED25519 key fingerprint is SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU.\n" +
            "This key is not known by any other names.\n" +
            "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        val ten = "The authenticity of host 'github.com (140.82.121.4)' can't be established.\n" +
            "ED25519 key fingerprint is: SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU\n" +
            "This key is not known by any other names.\n" +
            "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        val store = store()
        for (prompt in listOf(nine, ten)) {
            val read = CredentialBroker.parseHostKeyPrompt(prompt)
            assertEquals("github.com", read?.host)
            assertEquals("ED25519", read?.keyType)
            assertEquals("SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU", read?.fingerprint)
            val user = User(CredentialReply(accepted = true))
            assertEquals("yes\n", CredentialBroker(12L, store, user).answer(HelperRequest.AskPass(prompt)))
            assertEquals(CredentialPrompt.Kind.HOST_KEY, user.asked.single().kind)
        }
        // A question about a host key this cannot read is answered no, not left unanswered.
        val unread = User(CredentialReply(accepted = true))
        assertEquals("no\n", CredentialBroker(13L, store, unread).answer(HelperRequest.AskPass("Are you sure you want to continue connecting (yes/no)? ")))
        assertTrue(unread.asked.isEmpty())
    }

    @Test
    fun loopbackIsThisDeviceOnly() {
        for (host in listOf("127.0.0.1", "127.0.0.1:8080", "127.1.2.3:1", "localhost", "LOCALHOST:3000", "[::1]", "[::1]:8080")) {
            assertTrue(host, CredentialBroker.isLoopback(host))
        }
        for (host in listOf("github.com", "128.0.0.1", "127.0.0.256", "127.0.0", "localhost.example.com", "[::2]:80", "10.0.2.2")) {
            assertFalse(host, CredentialBroker.isLoopback(host))
        }
    }
}
