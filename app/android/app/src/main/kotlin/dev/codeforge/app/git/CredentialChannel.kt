package dev.codeforge.app.git

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.security.SecureRandom

/**
 * One run's way to the host for git's credential helper and ssh's askpass
 * (Phase 7 W3; ADR-0016, measured in W1): a folder of its own, private to
 * the app, holding two FIFOs (`request`, `answer`, mode 600) and the scripts
 * that use them, and a thread that reads each request, has [broker] answer
 * it, and writes the answer back.
 *
 * - git runs the helper as `bash '<credential.sh>' '<folder>' get|store|erase`,
 *   named on that command's line after the fixed settings' empty
 *   `credential.helper` ([helperSettings]), so no other helper runs.
 * - ssh runs `SSH_ASKPASS` with its question as the one argument
 *   (`SSH_ASKPASS_REQUIRE=force`, since there is no display). That program is
 *   the runtime's own bash, never a file of the app's to execute, which
 *   Android forbids from API 29: bash reads the relay ([askPassRelay]) first,
 *   as `BASH_ENV`, before it would open its argument as a script, and the
 *   relay sends the question here and prints the answer. A question never
 *   names a file and ends in `: ` or `? `; any real script or command bash
 *   runs during the operation (the helper, a hook) runs as it would.
 * - git's own prompts get nothing: an empty `GIT_ASKPASS` stops git looking
 *   further (a repository's `core.askPass`, `SSH_ASKPASS`), and
 *   `GIT_TERMINAL_PROMPT=0` leaves it no terminal, so the helper is the only
 *   way a credential reaches git.
 *
 * A secret passes only through the FIFOs: never an argument, a variable or
 * a file. A blocked open of either FIFO is released by opening it for
 * reading and writing at once, which never blocks ([poke]): that is how
 * [close] ends the thread whatever it waits for.
 */
class CredentialChannel private constructor(
    val directory: File,
    private val broker: CredentialBroker,
    runId: Long,
    /** The runtime's bash: ssh's askpass, and the helper's interpreter. */
    private val bash: File,
) {
    private val request = File(directory, REQUEST)
    private val answer = File(directory, ANSWER)

    val helperScript = File(directory, "credential.sh")
    val askPassRelay = File(directory, "askpass.bash")

    @Volatile
    private var closing = false

    private val thread = Thread({ serve() }, "codeforge-git-credential-$runId").apply { isDaemon = true }

    /** After the fixed settings' `credential.helper=`: CodeForge's helper, the only one. */
    fun helperSettings(): List<String> =
        listOf("-c", "credential.helper=!bash '${helperScript.path}' '${directory.path}'")

    /** The variables that send ssh's questions here and git's own prompts nowhere; with [sshCommand], how git runs ssh. */
    fun variables(sshCommand: String?): Map<String, String> = buildMap {
        put("GIT_ASKPASS", "")
        put("SSH_ASKPASS", bash.path)
        put("SSH_ASKPASS_REQUIRE", "force")
        put("BASH_ENV", askPassRelay.path)
        if (sshCommand != null) put("GIT_SSH_COMMAND", sshCommand)
    }

    /** Whether a stored credential was refused and erased during the run. */
    val erased: Boolean get() = broker.erased

    /** Whether the user cancelled a prompt during the run. */
    val declined: Boolean get() = broker.declined

    /** The questions ssh asked this run, as [CredentialBroker.questions] keeps them. */
    val questions: List<String> get() = broker.questions.toList()

    private fun start(): CredentialChannel {
        thread.start()
        return this
    }

    private fun serve() {
        while (!closing) {
            val text = try {
                readRequest()
            } catch (gone: IOException) {
                break
            }
            if (closing) break
            val parsed = HelperRequest.parse(text) ?: continue
            if (parsed == HelperRequest.Quit) break
            val reply = broker.answer(parsed)
            val expected = parsed is HelperRequest.AskPass || (parsed is HelperRequest.Credential && parsed.operation == "get")
            if (!expected) continue
            if (closing) break
            try {
                // Opens once the helper reads: it waits for this answer.
                FileOutputStream(answer).use { it.write((reply ?: "").toByteArray(Charsets.UTF_8)) }
            } catch (gone: IOException) {
                break
            }
        }
    }

    /** One request: opens once a helper writes, and reads to its end, up to [MAX_REQUEST] bytes. */
    private fun readRequest(): String {
        FileInputStream(request).use { input ->
            val buffer = ByteArray(8192)
            val out = java.io.ByteArrayOutputStream()
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (out.size() < MAX_REQUEST) out.write(buffer, 0, minOf(count, MAX_REQUEST - out.size()))
            }
            return String(out.toByteArray(), Charsets.UTF_8)
        }
    }

    /** The run ended: a prompt still open is withdrawn, the thread ends, and the folder goes. */
    fun close() {
        closing = true
        broker.cancel()
        val deadline = System.nanoTime() + CLOSE_MS * 1_000_000L
        while (thread.isAlive && System.nanoTime() < deadline) {
            poke(request)
            poke(answer)
            try {
                thread.join(POKE_INTERVAL_MS)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                break
            }
        }
        directory.deleteRecursively()
    }

    companion object {
        const val REQUEST = "request"
        const val ANSWER = "answer"

        /** A request's most bytes: git's fields, or ssh's prompt. */
        const val MAX_REQUEST = 64 * 1024

        private const val CLOSE_MS = 3_000L
        private const val POKE_INTERVAL_MS = 50L

        /**
         * Opens a channel for run [runId] in a new folder under [root]:
         * [makeFifo] makes a FIFO with mode 600 (`Os.mkfifo` on a device),
         * and [bash] is the runtime's bash, which ssh runs as its askpass.
         */
        fun open(root: File, runId: Long, broker: CredentialBroker, bash: File, makeFifo: (File) -> Unit): CredentialChannel {
            root.mkdirs()
            privateFolder(root)
            val name = "run-$runId-${hex(8)}"
            val directory = File(root, name)
            if (!directory.mkdir()) throw IOException("the credential channel's folder could not be made")
            privateFolder(directory)
            if (directory.path.contains('\'') || directory.path.contains('\n')) {
                directory.deleteRecursively()
                throw IOException("a path the scripts cannot quote")
            }
            try {
                makeFifo(File(directory, REQUEST))
                makeFifo(File(directory, ANSWER))
                val channel = CredentialChannel(directory, broker, runId, bash)
                writePrivate(channel.helperScript, HELPER)
                writePrivate(channel.askPassRelay, relay(directory))
                return channel.start()
            } catch (failure: IOException) {
                directory.deleteRecursively()
                throw failure
            } catch (failure: Exception) {
                // Os.mkfifo's ErrnoException among them.
                directory.deleteRecursively()
                throw IOException("the credential channel could not be made", failure)
            }
        }

        /** Removes what a run left, as after the app's process died. */
        fun clean(root: File) {
            root.listFiles()?.forEach { it.deleteRecursively() }
        }

        /**
         * git's credential helper protocol over the run's FIFOs: `$1` is
         * their folder, `$2` the operation git appends. The request is git's
         * fields; `get` waits for the answer.
         */
        val HELPER = """
            request=$(cat)
            printf 'operation=%s\n%s\n\n' "${'$'}2" "${'$'}request" > "${'$'}1/$REQUEST"
            if [ "${'$'}2" = get ]; then
              cat "${'$'}1/$ANSWER"
            fi
        """.trimIndent() + "\n"

        /**
         * ssh's askpass relay, which bash reads first as `BASH_ENV`: when
         * bash's script name is a question (it ends in `: ` or `? ` and is no
         * file), it goes to the host and the answer comes back on stdout;
         * otherwise bash goes on with its script.
         */
        fun relay(directory: File): String = """
            case "${'$'}0" in
              *': '|*'? ')
                if [ ! -e "${'$'}0" ]; then
                  printf 'operation=askpass\n%s' "${'$'}0" > '${directory.path}/$REQUEST'
                  cat '${directory.path}/$ANSWER'
                  exit 0
                fi
                ;;
            esac
        """.trimIndent() + "\n"

        /** Opening a FIFO to read and write at once never blocks, and releases whoever waits at its other end. */
        private fun poke(fifo: File) {
            if (!fifo.exists()) return
            try {
                RandomAccessFile(fifo, "rw").close()
            } catch (ignored: IOException) {
                // Gone already.
            }
        }

        private fun privateFolder(folder: File) {
            folder.setReadable(false, false)
            folder.setWritable(false, false)
            folder.setExecutable(false, false)
            folder.setReadable(true, true)
            folder.setWritable(true, true)
            folder.setExecutable(true, true)
        }

        /** A file only the app reads and writes: bash reads it, nothing executes it. */
        private fun writePrivate(file: File, text: String) {
            file.writeText(text, Charsets.UTF_8)
            file.setReadable(false, false)
            file.setWritable(false, false)
            file.setExecutable(false, false)
            file.setReadable(true, true)
            file.setWritable(true, true)
        }

        private val random = SecureRandom()

        private fun hex(bytes: Int): String {
            val value = ByteArray(bytes)
            random.nextBytes(value)
            return value.joinToString("") { "%02x".format(it) }
        }
    }
}
