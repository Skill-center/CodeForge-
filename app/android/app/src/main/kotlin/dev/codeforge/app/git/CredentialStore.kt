package dev.codeforge.app.git

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Seals and opens a secret with AES-256-GCM: a fresh nonce each time, bound
 * to [context] as GCM's associated data, so a sealed secret moved to
 * another entry no longer opens.
 */
interface SecretCipher {
    fun seal(plain: ByteArray, context: ByteArray): ByteArray

    /** [sealed] opened; a [GeneralSecurityException] when it was altered, moved, or sealed with another key. */
    fun open(sealed: ByteArray, context: ByteArray): ByteArray
}

/** The sealed form both ciphers write: a version, the nonce, then the ciphertext with its tag. */
internal object SealedFormat {
    const val VERSION: Byte = 1
    const val NONCE_BYTES = 12
    const val TAG_BITS = 128

    fun join(nonce: ByteArray, ciphertext: ByteArray): ByteArray {
        require(nonce.size == NONCE_BYTES) { "a GCM nonce is $NONCE_BYTES bytes" }
        return byteArrayOf(VERSION) + nonce + ciphertext
    }

    /** The nonce and the ciphertext of [sealed]. */
    fun split(sealed: ByteArray): Pair<ByteArray, ByteArray> {
        if (sealed.size < 1 + NONCE_BYTES + TAG_BITS / 8 || sealed[0] != VERSION) {
            throw GeneralSecurityException("not a sealed secret")
        }
        return sealed.copyOfRange(1, 1 + NONCE_BYTES) to sealed.copyOfRange(1 + NONCE_BYTES, sealed.size)
    }
}

/**
 * The Android Keystore's AES-256-GCM key (Phase 7 W3, PHASE_7_PLAN W3):
 * made in the Keystore the first time it is needed, never exportable, and
 * never in a backup, since Keystore keys do not leave the device. The
 * Keystore picks each nonce itself.
 */
class KeystoreCipher(private val alias: String = ALIAS) : SecretCipher {
    @Synchronized
    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    override fun seal(plain: ByteArray, context: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(context)
        val ciphertext = cipher.doFinal(plain)
        return SealedFormat.join(cipher.iv, ciphertext)
    }

    override fun open(sealed: ByteArray, context: ByteArray): ByteArray {
        val (nonce, ciphertext) = SealedFormat.split(sealed)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(SealedFormat.TAG_BITS, nonce))
        cipher.updateAAD(context)
        return cipher.doFinal(ciphertext)
    }

    /** Removes the key: every secret sealed with it is lost. */
    fun delete() {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
    }

    companion object {
        const val ALIAS = "codeforge-git-credentials"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}

/** What a credential is for. */
enum class CredentialKind(val code: String) {
    /** A token or password for a host over HTTPS, which git's credential helper asks for. */
    HTTPS("https"),

    /** The passphrase of CodeForge's SSH key, which ssh asks for through SSH_ASKPASS. */
    SSH_KEY("ssh_key"),
    ;

    companion object {
        fun of(code: String): CredentialKind? = entries.firstOrNull { it.code == code }
    }
}

/** One stored credential. Never logged, never in an argument, the environment or a plain file. */
data class GitCredential(
    val kind: CredentialKind,
    /** git's `host`: a name, with `:port` when not the protocol's own; lower case. */
    val host: String,
    val username: String,
    val secret: String,
) {
    override fun toString(): String = "GitCredential(${kind.code}, $host, $username, <secret>)"
}

/** What Settings lists of a credential: never its secret. */
data class GitAccount(val kind: CredentialKind, val host: String, val username: String, val updatedAt: Long)

/**
 * The Git credentials (Phase 7 W3, PHASE_7_PLAN W3; docs/GIT_ARCHITECTURE.md
 * §4): each secret sealed by [cipher] (the Keystore's key on a device) with
 * a fresh nonce, bound to its kind, host and user name, in [file], which
 * lies in app-private storage that Android's backup never takes
 * (`no_backup/`, ADR-0012). The file holds one line per credential, its
 * fields Base64; a line that does not read or open is dropped, so a
 * damaged store loses those credentials and nothing else. Written whole
 * and renamed into place.
 */
class CredentialStore(
    private val file: File,
    private val cipher: SecretCipher,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private class Entry(val kind: CredentialKind, val host: String, val username: String, val sealed: ByteArray, val updatedAt: Long)

    /** The credentials' hosts and user names, newest first. */
    @Synchronized
    fun accounts(): List<GitAccount> = read().sortedByDescending { it.updatedAt }.map { GitAccount(it.kind, it.host, it.username, it.updatedAt) }

    /**
     * The credential of [kind] for exactly [host], for [username] when
     * given, else the newest for that host; null when none opens.
     */
    @Synchronized
    fun find(kind: CredentialKind, host: String, username: String? = null): GitCredential? {
        val wanted = normalHost(host) ?: return null
        val candidates = read()
            .filter { it.kind == kind && it.host == wanted && (username == null || it.username == username) }
            .sortedByDescending { it.updatedAt }
        for (entry in candidates) {
            val secret = openSecret(entry) ?: continue
            return GitCredential(entry.kind, entry.host, entry.username, secret)
        }
        return null
    }

    /** Keeps [credential], replacing one of the same kind, host and user name. */
    @Synchronized
    fun put(credential: GitCredential) {
        val host = normalHost(credential.host) ?: throw IllegalArgumentException("not a host")
        checkField(credential.username, MAX_USERNAME, "a user name")
        checkField(credential.secret, MAX_SECRET, "a secret")
        if (credential.secret.isEmpty()) throw IllegalArgumentException("an empty secret")
        val sealed = cipher.seal(credential.secret.toByteArray(Charsets.UTF_8), context(credential.kind, host, credential.username))
        val kept = read().filterNot { it.kind == credential.kind && it.host == host && it.username == credential.username }
        if (kept.size >= MAX_ENTRIES) throw IllegalStateException("at most $MAX_ENTRIES credentials are kept")
        write(kept + Entry(credential.kind, host, credential.username, sealed, clock()))
    }

    /** Removes the credential of [kind] for [host] and [username]; false when there was none. */
    @Synchronized
    fun remove(kind: CredentialKind, host: String, username: String): Boolean {
        val wanted = normalHost(host) ?: return false
        val entries = read()
        val kept = entries.filterNot { it.kind == kind && it.host == wanted && it.username == username }
        if (kept.size == entries.size) return false
        write(kept)
        return true
    }

    /**
     * Removes the credential for [host] and [username] only while its
     * secret is still [refused]: a host refused it, and one stored since is
     * left alone.
     */
    @Synchronized
    fun erase(kind: CredentialKind, host: String, username: String, refused: String): Boolean {
        val wanted = normalHost(host) ?: return false
        val entries = read()
        val kept = entries.filterNot { entry ->
            entry.kind == kind && entry.host == wanted && entry.username == username && openSecret(entry) == refused
        }
        if (kept.size == entries.size) return false
        write(kept)
        return true
    }

    /** Removes every credential. */
    @Synchronized
    fun clear() {
        file.delete()
    }

    private fun openSecret(entry: Entry): String? = try {
        String(cipher.open(entry.sealed, context(entry.kind, entry.host, entry.username)), Charsets.UTF_8)
    } catch (unopened: GeneralSecurityException) {
        null
    } catch (unopened: RuntimeException) {
        // A Keystore that lost its key (the device's lock screen removed, on some phones) throws its own.
        null
    }

    private fun read(): List<Entry> {
        val lines = try {
            if (!file.isFile) return emptyList()
            file.readLines(Charsets.UTF_8)
        } catch (unreadable: IOException) {
            return emptyList()
        }
        if (lines.firstOrNull() != HEADER) return emptyList()
        return lines.drop(1).mapNotNull(::parse)
    }

    private fun parse(line: String): Entry? {
        val fields = line.split('\t')
        if (fields.size != 5) return null
        return try {
            val kind = CredentialKind.of(fields[0]) ?: return null
            val host = normalHost(decode(fields[1])) ?: return null
            val username = decode(fields[2])
            val sealed = Base64.getDecoder().decode(fields[3])
            val updatedAt = fields[4].toLong()
            Entry(kind, host, username, sealed, updatedAt)
        } catch (malformed: IllegalArgumentException) {
            null
        }
    }

    private fun write(entries: List<Entry>) {
        file.parentFile?.mkdirs()
        val text = buildString {
            append(HEADER).append('\n')
            for (entry in entries) {
                append(entry.kind.code).append('\t')
                append(encode(entry.host)).append('\t')
                append(encode(entry.username)).append('\t')
                append(Base64.getEncoder().encodeToString(entry.sealed)).append('\t')
                append(entry.updatedAt).append('\n')
            }
        }
        val partial = File(file.path + ".partial")
        partial.writeText(text, Charsets.UTF_8)
        if (!partial.renameTo(file)) {
            partial.delete()
            throw IOException("the credential store could not be written")
        }
    }

    companion object {
        const val HEADER = "codeforge-git-credentials 1"
        const val MAX_ENTRIES = 256
        const val MAX_USERNAME = 256
        const val MAX_SECRET = 16 * 1024
        const val MAX_HOST = 300

        /** The file in app-private storage that backup leaves out: `no_backup/git/credentials`. */
        fun fileIn(noBackupFilesDir: File): File = File(noBackupFilesDir, "git/credentials")

        /** [host] as git names it, lower case; null when it is not one (empty, too long, a control character, a space, `/` or `@`). */
        fun normalHost(host: String): String? {
            if (host.isEmpty() || host.length > MAX_HOST) return null
            if (host.any { it <= ' ' || it == '\u007f' || it == '/' || it == '@' || it == '\\' }) return null
            return host.lowercase()
        }

        private fun checkField(value: String, max: Int, what: String) {
            if (value.length > max || value.any { it == '\n' || it == '\r' || it == '\u0000' }) {
                throw IllegalArgumentException("$what is one line of at most $max characters")
            }
        }

        private fun encode(text: String): String = Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8))

        private fun decode(text: String): String = String(Base64.getDecoder().decode(text), Charsets.UTF_8)

        /** What a sealed secret is bound to: moved to another entry, it no longer opens. */
        internal fun context(kind: CredentialKind, host: String, username: String): ByteArray =
            "codeforge-git-credential\u0000${kind.code}\u0000$host\u0000$username".toByteArray(Charsets.UTF_8)
    }
}
