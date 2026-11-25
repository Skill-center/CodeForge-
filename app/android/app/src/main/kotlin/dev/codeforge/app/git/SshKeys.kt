package dev.codeforge.app.git

import dev.codeforge.app.runtime.CommandRequest
import dev.codeforge.app.runtime.CommandResult
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/**
 * CodeForge's SSH key (Phase 7 W3, decided on 2026-11-23: PHASE_7_PLAN
 * §10, item 3, (b)): an ed25519 key the runtime's `ssh-keygen` makes in the
 * runtime's home (`~/.ssh/codeforge_ed25519`), encrypted by OpenSSH with a
 * random passphrase that only the credential store holds. `ssh-keygen` and
 * ssh take the passphrase from the run's askpass ([CredentialChannel]),
 * never from an argument, a variable or a file. Its own name, not
 * `id_ed25519`, so the terminal's ssh never offers it unasked; the public
 * key is shown, to copy into a host's settings.
 */
class SshKeys(
    private val store: CredentialStore,
    /** Runs a command in the runtime with [CredentialChannel]'s variables; null when the runtime is not ready. */
    private val run: (CommandRequest) -> CommandResult?,
    /**
     * A channel for one run: with a passphrase, its broker gives
     * `ssh-keygen` that new passphrase; with null, it reads the key back
     * with the stored one.
     */
    private val channel: (runId: Long, newPassphrase: String?) -> CredentialChannel,
    /** Runs a command and gives its stdout's lines; null when the runtime is not ready. */
    private val read: (CommandRequest) -> Pair<CommandResult?, List<String>> = { request -> run(request) to emptyList() },
) {
    /** A key's public half, as `~/.ssh/codeforge_ed25519.pub` holds it. */
    data class Key(val publicKey: String, val fingerprint: String, val comment: String)

    /** The key in [home], or null. */
    fun current(home: File): Key? {
        val public = File(keyFile(home).path + ".pub")
        if (!public.isFile || !keyFile(home).isFile) return null
        val line = try {
            public.readText(Charsets.UTF_8).trim()
        } catch (unreadable: IOException) {
            return null
        }
        return parsePublicKey(line)
    }

    /**
     * Makes a new key in [home], replacing any CodeForge made before, with
     * [comment] (`codeforge@pixel`): its passphrase made at random and kept
     * in the store first, then given to `ssh-keygen` through askpass.
     */
    fun create(home: File, comment: String, runId: Long): Key {
        if (!COMMENT.matches(comment)) throw GitRefused(GitFailure.BAD_REQUEST, "a key's name is letters, digits and . _ @ + -, at most 100")
        val ssh = File(home, ".ssh")
        ssh.mkdirs()
        privateFolder(ssh)
        delete(home)
        val passphrase = newPassphrase()
        store.put(GitCredential(CredentialKind.SSH_KEY, CredentialBroker.SSH_KEY_HOST, CredentialBroker.SSH_KEY_USER, passphrase))
        val opened = channel(runId, passphrase)
        val result = try {
            run(
                CommandRequest(
                    program = "ssh-keygen",
                    arguments = listOf("-q", "-t", "ed25519", "-a", "16", "-f", keyFile(home).path, "-C", comment),
                    directory = null,
                    timeoutMs = 60_000L,
                    outputLimit = 16 * 1024,
                    variables = opened.variables(null),
                ),
            )
        } finally {
            opened.close()
        }
        val key = current(home)
        if (result == null || result.failure != null || result.exitCode != 0 || key == null) {
            delete(home)
            val why = when {
                result == null -> GitFailure.NOT_READY
                result.failure != null -> GitFailure.LAUNCH_FAILED
                else -> GitFailure.LAUNCH_FAILED
            }
            throw GitRefused(why, "ssh-keygen did not make the key" + (result?.exitCode?.let { " (exit $it)" } ?: ""))
        }
        return key
    }

    /**
     * Whether the key in [home] opens with the stored passphrase and is the
     * public key beside it: `ssh-keygen -y`, the passphrase through askpass.
     */
    fun verify(home: File, runId: Long): Boolean {
        val key = current(home) ?: return false
        val opened = channel(runId, null)
        val (result, lines) = try {
            read(
                CommandRequest(
                    program = "ssh-keygen",
                    arguments = listOf("-y", "-f", keyFile(home).path),
                    directory = null,
                    timeoutMs = 60_000L,
                    outputLimit = 16 * 1024,
                    variables = opened.variables(null),
                ),
            )
        } finally {
            opened.close()
        }
        if (result == null || result.failure != null || result.exitCode != 0) return false
        val derived = lines.firstOrNull { it.startsWith("ssh-ed25519 ") }?.split(' ')?.take(2) ?: return false
        return derived == key.publicKey.split(' ').take(2)
    }

    /** Removes the key and its passphrase; false when there was none. */
    fun delete(home: File): Boolean {
        val key = keyFile(home)
        val public = File(key.path + ".pub")
        val had = key.exists() || public.exists()
        key.delete()
        public.delete()
        store.remove(CredentialKind.SSH_KEY, CredentialBroker.SSH_KEY_HOST, CredentialBroker.SSH_KEY_USER)
        return had
    }

    companion object {
        const val KEY_NAME = "codeforge_ed25519"

        private val COMMENT = Regex("^[A-Za-z0-9._@+-]{1,100}$")
        private val random = SecureRandom()

        fun keyFile(home: File): File = File(home, ".ssh/$KEY_NAME")

        /**
         * How git runs ssh for a remote run: the runtime home's
         * `known_hosts`, a new host asked about once (through askpass), no
         * password or keyboard prompt, and CodeForge's key when there is one.
         * Set as `GIT_SSH_COMMAND`, which a repository's `core.sshCommand`
         * cannot override.
         */
        fun sshCommand(home: File): String {
            val known = File(home, ".ssh/known_hosts").path
            val key = keyFile(home)
            return buildString {
                append("ssh")
                if (key.isFile) append(" -o IdentitiesOnly=yes -i '").append(key.path).append("'")
                append(" -o UserKnownHostsFile='").append(known).append("'")
                append(" -o StrictHostKeyChecking=ask")
                append(" -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no")
                append(" -o ConnectTimeout=30")
            }
        }

        /** 32 random bytes, Base64 without padding: only the store ever holds it. */
        fun newPassphrase(): String {
            val bytes = ByteArray(32)
            random.nextBytes(bytes)
            return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        }

        /** `ssh-ed25519 <base64> <comment>` read, with its SHA-256 fingerprint as ssh-keygen prints it. */
        fun parsePublicKey(line: String): Key? {
            val parts = line.split(' ', limit = 3)
            if (parts.size < 2 || parts[0] != "ssh-ed25519") return null
            val blob = try {
                Base64.getDecoder().decode(parts[1])
            } catch (malformed: IllegalArgumentException) {
                return null
            }
            val digest = MessageDigest.getInstance("SHA-256").digest(blob)
            val fingerprint = "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(digest)
            return Key("${parts[0]} ${parts[1]}" + (parts.getOrNull(2)?.let { " $it" } ?: ""), fingerprint, parts.getOrNull(2) ?: "")
        }

        private fun privateFolder(folder: File) {
            folder.setReadable(false, false)
            folder.setWritable(false, false)
            folder.setExecutable(false, false)
            folder.setReadable(true, true)
            folder.setWritable(true, true)
            folder.setExecutable(true, true)
        }
    }
}
