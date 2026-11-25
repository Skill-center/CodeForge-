package dev.codeforge.app.git

import java.io.File
import java.security.GeneralSecurityException
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The credential store (Phase 7 W3, gate G3) with a stand-in for the
 * Keystore's key: the same AES-256-GCM in software, a key that never leaves
 * the test. GitHostTest uses the real Keystore on every target.
 */
class CredentialStoreTest {
    @get:Rule
    val temp = TemporaryFolder()

    /** AES-256-GCM with a software key, as KeystoreCipher seals with the Keystore's. */
    class SoftwareCipher(private val key: SecretKey = newKey()) : SecretCipher {
        val seals = mutableListOf<ByteArray>()

        override fun seal(plain: ByteArray, context: ByteArray): ByteArray {
            val nonce = ByteArray(SealedFormat.NONCE_BYTES).also { SecureRandom().nextBytes(it) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(SealedFormat.TAG_BITS, nonce))
            cipher.updateAAD(context)
            return SealedFormat.join(nonce, cipher.doFinal(plain)).also { seals.add(it) }
        }

        override fun open(sealed: ByteArray, context: ByteArray): ByteArray {
            val (nonce, ciphertext) = SealedFormat.split(sealed)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(SealedFormat.TAG_BITS, nonce))
            cipher.updateAAD(context)
            return cipher.doFinal(ciphertext)
        }

        companion object {
            fun newKey(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        }
    }

    private val token = "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB"
    private fun file() = File(temp.root, "no_backup/git/credentials")

    @Test
    fun aCredentialIsKeptSealedAndFoundForItsHostOnly() {
        val cipher = SoftwareCipher()
        val store = CredentialStore(file(), cipher)
        store.put(GitCredential(CredentialKind.HTTPS, "GitHub.com", "ada", token))
        assertEquals(GitCredential(CredentialKind.HTTPS, "github.com", "ada", token), store.find(CredentialKind.HTTPS, "github.com"))
        assertEquals(token, store.find(CredentialKind.HTTPS, "GITHUB.COM", "ada")?.secret)
        assertNull("another host", store.find(CredentialKind.HTTPS, "gitlab.com"))
        assertNull("a host that only ends the same", store.find(CredentialKind.HTTPS, "evilgithub.com"))
        assertNull("another port", store.find(CredentialKind.HTTPS, "github.com:8443"))
        assertNull("another user", store.find(CredentialKind.HTTPS, "github.com", "eve"))
        assertNull("another kind", store.find(CredentialKind.SSH_KEY, "github.com"))
        // On disk: the host and the user Base64, never the secret.
        val text = file().readText()
        assertFalse(text.contains(token))
        assertTrue(text.startsWith(CredentialStore.HEADER + "\n"))
        assertEquals(listOf(GitAccount(CredentialKind.HTTPS, "github.com", "ada", store.accounts().single().updatedAt)), store.accounts())
        assertFalse("never its secret", store.accounts().toString().contains(token))
        assertFalse(store.find(CredentialKind.HTTPS, "github.com").toString().contains(token))
    }

    @Test
    fun eachSecretGetsAFreshNonceAndIsBoundToItsEntry() {
        val cipher = SoftwareCipher()
        val store = CredentialStore(file(), cipher)
        store.put(GitCredential(CredentialKind.HTTPS, "github.com", "ada", token))
        store.put(GitCredential(CredentialKind.HTTPS, "github.com", "ada", token))
        assertEquals(2, cipher.seals.size)
        assertNotEquals("a fresh nonce each time", cipher.seals[0].copyOfRange(1, 13).toList(), cipher.seals[1].copyOfRange(1, 13).toList())
        assertEquals("replaced, not added", 1, store.accounts().size)

        // A sealed secret moved to another host's line no longer opens: it is bound to its kind, host and user.
        store.put(GitCredential(CredentialKind.HTTPS, "gitlab.com", "ada", "other-secret"))
        val lines = file().readLines().toMutableList()
        val github = lines.indexOfFirst { it.contains(b64("github.com")) }
        val gitlab = lines.indexOfFirst { it.contains(b64("gitlab.com")) }
        val sealedGithub = lines[github].split('\t')[3]
        lines[gitlab] = lines[gitlab].split('\t').toMutableList().also { it[3] = sealedGithub }.joinToString("\t")
        file().writeText(lines.joinToString("\n") + "\n")
        assertNull(CredentialStore(file(), cipher).find(CredentialKind.HTTPS, "gitlab.com"))
        assertEquals(token, CredentialStore(file(), cipher).find(CredentialKind.HTTPS, "github.com")?.secret)
    }

    @Test
    fun anotherKeyOpensNothingAndADamagedLineLosesOnlyItself() {
        val store = CredentialStore(file(), SoftwareCipher())
        store.put(GitCredential(CredentialKind.HTTPS, "github.com", "ada", token))
        store.put(GitCredential(CredentialKind.HTTPS, "gitlab.com", "ada", "s2"))
        assertNull("a store copied to another device: the Keystore's key stays behind", CredentialStore(file(), SoftwareCipher()).find(CredentialKind.HTTPS, "github.com"))

        val lines = file().readLines().toMutableList()
        lines.add(1, "https\tnot base64!\tx\ty\t1")
        lines.add("garbage")
        file().writeText(lines.joinToString("\n") + "\n")
        assertEquals(setOf("github.com", "gitlab.com"), store.accounts().map { it.host }.toSet())
        assertEquals(token, store.find(CredentialKind.HTTPS, "github.com")?.secret)

        file().writeText("not a store\n")
        assertTrue(store.accounts().isEmpty())
    }

    @Test
    fun eraseRemovesOnlyTheRefusedSecretAndRemoveTheNamedEntry() {
        val store = CredentialStore(file(), SoftwareCipher())
        store.put(GitCredential(CredentialKind.HTTPS, "github.com", "ada", token))
        assertFalse("a secret stored since is left alone", store.erase(CredentialKind.HTTPS, "github.com", "ada", "an-older-one"))
        assertEquals(token, store.find(CredentialKind.HTTPS, "github.com")?.secret)
        assertTrue(store.erase(CredentialKind.HTTPS, "github.com", "ada", token))
        assertNull(store.find(CredentialKind.HTTPS, "github.com"))

        store.put(GitCredential(CredentialKind.HTTPS, "github.com", "ada", token))
        store.put(GitCredential(CredentialKind.HTTPS, "github.com", "bob", "s3"))
        assertTrue(store.remove(CredentialKind.HTTPS, "github.com", "bob"))
        assertFalse(store.remove(CredentialKind.HTTPS, "github.com", "bob"))
        assertEquals(listOf("ada"), store.accounts().map { it.username })
        store.clear()
        assertTrue(store.accounts().isEmpty())
    }

    @Test
    fun theNewestForAHostComesFirst() {
        var now = 1_000L
        val store = CredentialStore(file(), SoftwareCipher(), clock = { now })
        store.put(GitCredential(CredentialKind.HTTPS, "github.com", "ada", "first"))
        now = 2_000L
        store.put(GitCredential(CredentialKind.HTTPS, "github.com", "bob", "second"))
        assertEquals("bob", store.find(CredentialKind.HTTPS, "github.com")?.username)
        assertEquals(listOf("bob", "ada"), store.accounts().map { it.username })
    }

    @Test
    fun whatCannotBeAFieldIsRefused() {
        val store = CredentialStore(file(), SoftwareCipher())
        for (bad in listOf(
            GitCredential(CredentialKind.HTTPS, "", "ada", token),
            GitCredential(CredentialKind.HTTPS, "git hub.com", "ada", token),
            GitCredential(CredentialKind.HTTPS, "github.com/path", "ada", token),
            GitCredential(CredentialKind.HTTPS, "ada@github.com", "ada", token),
            GitCredential(CredentialKind.HTTPS, "github.com", "ada\nprotocol=evil", token),
            GitCredential(CredentialKind.HTTPS, "github.com", "ada", "two\nlines"),
            GitCredential(CredentialKind.HTTPS, "github.com", "ada", ""),
        )) {
            assertThrows(bad.toString(), IllegalArgumentException::class.java) { store.put(bad) }
        }
        assertTrue(store.accounts().isEmpty())
    }

    @Test
    fun aTamperedSealDoesNotOpen() {
        val cipher = SoftwareCipher()
        val context = CredentialStore.context(CredentialKind.HTTPS, "github.com", "ada")
        val sealed = cipher.seal(token.toByteArray(), context)
        val flipped = sealed.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
        assertThrows(GeneralSecurityException::class.java) { cipher.open(flipped, context) }
        assertThrows(GeneralSecurityException::class.java) { cipher.open(byteArrayOf(9, 9, 9), context) }
        assertEquals(token, String(cipher.open(sealed, context)))
    }

    private fun b64(text: String) = java.util.Base64.getEncoder().encodeToString(text.toByteArray())
}
