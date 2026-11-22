package dev.codeforge.app.runtime

import dev.codeforge.app.search.MiniJson
import dev.codeforge.runtime.sealed.PayloadExtractor
import dev.codeforge.runtime.sealed.RuntimeManifest
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.zip.ZipException

/** Why a language server can't be used. Each code travels to Dart (W3, W4). */
enum class LanguageServerProblem(val code: String) {
    /** This APK carries no such server. */
    NOT_IN_APK("not_in_apk"),

    /** The server's archive, manifest or description is damaged, or a file differs from its manifest. */
    DAMAGED("damaged"),

    /** The device could not store the server: no space, or a write failed. */
    STORAGE("storage"),
}

/** A typed failure of a language server's install. */
class LanguageServerFailure(
    val problem: LanguageServerProblem,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/**
 * The language servers this APK carries, and their install into the runtime
 * (Phase 6 W2; docs/adr/0015-language-servers.md, docs/LSP_ARCHITECTURE.md
 * §2). CodeForge's own.
 *
 * runtime/language_servers.py builds them into the APK's assets, from the
 * pins in runtime/language-servers/:
 *   * `lsp/servers.json` describes each server: its id, its languages, its
 *     npm packages, the file node runs and its arguments, its archive and its
 *     manifest, and its identity (the manifest's SHA-256);
 *   * `lsp/<id>.zip` holds the server's packages under node_modules/;
 *   * `lsp/<id>-manifest.txt` lists every file with its SHA-256 and size, in
 *     the sealed manifest's format.
 *
 * A server is installed the first time it is asked for, never with the
 * runtime: the userland's install would otherwise grow by Pyright's 5,423
 * files. The kernel's PayloadExtractor, which installs the userland, extracts
 * the archive into a staging folder, refusing any path outside it and
 * checking each file's size and SHA-256 against the manifest as it writes.
 * Every file the manifest lists must be there, and no other. Only then is a
 * marker with the identity written and the folder renamed into place, so a
 * server is either whole at its place or not there. A later ask finds the
 * marker and reuses the server without extracting it again. A server whose
 * identity changed (a new APK) is installed afresh and the old one removed.
 *
 * A failure is a [LanguageServerFailure] with its problem and leaves nothing
 * at the server's place: its languages stay without a server. The servers
 * live in the runtime's state folder (`<root>/codeforge/lsp/<id>`), apart
 * from the user's home. Nothing in them is executable: node runs their
 * JavaScript.
 */
class LanguageServers(
    private val source: PayloadSource,
    /** The runtime's root (RuntimeEnvironment.root), whose codeforge/ folder holds the runtime's state. */
    root: File,
    private val clock: () -> Long = System::nanoTime,
    private val freeSpace: (File) -> Long = { it.usableSpace },
) {
    data class Package(val name: String, val version: String, val license: String)

    /** One server, as lsp/servers.json describes it. */
    data class Server(
        val id: String,
        val languages: List<String>,
        /** The file node runs, relative to the server's folder. */
        val entry: String,
        val arguments: List<String>,
        val packages: List<Package>,
        val archive: String,
        val manifest: String,
        val identity: String,
        val files: Int,
        val bytes: Long,
    )

    /** A server at its place, ready for node to run. */
    data class Installed(
        val server: Server,
        val directory: File,
        val entry: File,
        /** True when an earlier install was found, and nothing was extracted. */
        val reused: Boolean,
        val millis: Long,
        val files: Int,
    )

    /** Where the servers live: one folder per server, each with its marker. */
    val directory: File = File(root, "codeforge/lsp")

    private var described: List<Server>? = null

    /** The servers this APK carries; none when it carries no lsp/servers.json. */
    @Synchronized
    fun available(): List<Server> {
        described?.let { return it }
        val text = try {
            source.open(SERVERS).use { String(it.readBytes(), Charsets.UTF_8) }
        } catch (absent: IOException) {
            described = emptyList()
            return emptyList()
        }
        val parsed = try {
            parse(text)
        } catch (malformed: IllegalArgumentException) {
            throw LanguageServerFailure(LanguageServerProblem.DAMAGED, "$SERVERS is malformed: ${malformed.message}", malformed)
        }
        described = parsed
        return parsed
    }

    /** The server for [language] ("python", "typescript", ...), or null. */
    fun forLanguage(language: String): Server? = available().firstOrNull { language in it.languages }

    /** The server [id] at its place from an earlier install, or null. */
    fun installed(id: String): Installed? {
        val server = available().firstOrNull { it.id == id } ?: return null
        return installedCopy(server, clock())
    }

    /**
     * The server [id], installed now if it is not at its place already.
     * [progress] gets each file as it is written. Throws [LanguageServerFailure].
     */
    @Synchronized
    fun ensure(id: String, progress: ProgressListener? = null): Installed {
        val started = clock()
        val server = available().firstOrNull { it.id == id }
            ?: throw LanguageServerFailure(LanguageServerProblem.NOT_IN_APK, "this app carries no language server $id")
        installedCopy(server, started)?.let { return it }
        return install(server, started, progress)
    }

    private fun installedCopy(server: Server, started: Long): Installed? {
        val place = File(directory, server.id)
        val stamp = readMarker(File(place, MARKER)) ?: return null
        if (stamp["identity"] != server.identity) return null
        val entry = File(place, server.entry)
        if (!entry.isFile) return null
        return Installed(server, place, entry, reused = true, millis = millisSince(started), files = server.files)
    }

    private fun install(server: Server, started: Long, progress: ProgressListener?): Installed {
        val place = File(directory, server.id)
        val staging = File(directory, STAGING_PREFIX + server.id)
        try {
            SealedRuntime.ensureDirectory(directory)
            staging.deleteRecursively()
            SealedRuntime.ensureDirectory(staging)
        } catch (failure: IOException) {
            throw LanguageServerFailure(LanguageServerProblem.STORAGE, failure.message ?: "the servers' folder is not writable", failure)
        }
        try {
            val needed = server.bytes + server.bytes / 10
            val free = freeSpace(directory)
            if (free in 0 until needed) {
                throw LanguageServerFailure(
                    LanguageServerProblem.STORAGE,
                    "the ${server.id} server needs ${megabytes(needed)} MB and ${megabytes(free)} MB are free",
                )
            }
            val manifestBytes = try {
                source.open(server.manifest).use { it.readBytes() }
            } catch (absent: IOException) {
                throw LanguageServerFailure(LanguageServerProblem.DAMAGED, "the APK lacks ${server.manifest}", absent)
            }
            if (sha256(manifestBytes) != server.identity) {
                throw LanguageServerFailure(LanguageServerProblem.DAMAGED, "${server.manifest} differs from its identity in $SERVERS")
            }
            val manifest = RuntimeManifest.parse(String(manifestBytes, Charsets.UTF_8))
            if (manifest.size() != server.files) {
                throw LanguageServerFailure(
                    LanguageServerProblem.DAMAGED,
                    "${server.manifest} lists ${manifest.size()} files, and $SERVERS says ${server.files}",
                )
            }
            val archive = try {
                source.open(server.archive)
            } catch (absent: IOException) {
                throw LanguageServerFailure(LanguageServerProblem.DAMAGED, "the APK lacks ${server.archive}", absent)
            }
            val result = try {
                archive.use { input ->
                    PayloadExtractor.extract(input, staging, manifest) { _, index -> progress?.onProgress(index, server.files) }
                }
            } catch (failure: IOException) {
                throw classify(server, failure)
            }
            if (!result.ok()) {
                throw LanguageServerFailure(
                    LanguageServerProblem.DAMAGED,
                    "the ${server.id} server's archive differs from its manifest: " + SealedRuntime.describe(result.problems),
                )
            }
            if (result.files != result.verified) {
                throw LanguageServerFailure(
                    LanguageServerProblem.DAMAGED,
                    "the ${server.id} server's archive holds files its manifest does not list (${result.files - result.verified})",
                )
            }
            if (!File(staging, server.entry).isFile) {
                throw LanguageServerFailure(LanguageServerProblem.DAMAGED, "the ${server.id} server lacks its entry ${server.entry}")
            }
            val millis = millisSince(started)
            try {
                SealedRuntime.write(File(staging, MARKER), marker(server, millis).toByteArray(Charsets.UTF_8))
                replace(place, staging)
            } catch (failure: IOException) {
                throw LanguageServerFailure(LanguageServerProblem.STORAGE, failure.message ?: "the server could not be put in place", failure)
            }
            return Installed(server, place, File(place, server.entry), reused = false, millis = millis, files = result.files)
        } finally {
            staging.deleteRecursively()
        }
    }

    /** Puts [staging] at [place]: the old copy is first moved aside, then removed. */
    private fun replace(place: File, staging: File) {
        var aside: File? = null
        if (place.exists()) {
            aside = File(directory, TRASH_PREFIX + place.name + "-" + System.nanoTime())
            if (!place.renameTo(aside)) throw IOException("the old ${place.name} server could not be moved aside")
        }
        if (!staging.renameTo(place)) {
            aside?.renameTo(place)
            throw IOException("the ${place.name} server could not be renamed into place")
        }
        aside?.deleteRecursively()
    }

    private fun marker(server: Server, millis: Long): String =
        "identity=${server.identity}\nid=${server.id}\nfiles=${server.files}\n" +
            "installedAt=${System.currentTimeMillis()}\ninstallMs=$millis\n"

    private fun millisSince(started: Long): Long = (clock() - started) / 1_000_000L

    companion object {
        /** The servers' description in the APK's assets. */
        const val SERVERS = "lsp/servers.json"

        /** The marker in a server's folder, written last, before the folder is renamed into place. */
        const val MARKER = ".codeforge-server.properties"

        private const val STAGING_PREFIX = ".staging-"
        private const val TRASH_PREFIX = ".old-"
        private val HEX64 = Regex("^[0-9a-f]{64}$")

        /** lsp/servers.json's servers. Throws IllegalArgumentException when it is not the format runtime/language_servers.py writes. */
        internal fun parse(text: String): List<Server> {
            val document = MiniJson.parse(text) as? Map<*, *> ?: throw IllegalArgumentException("not an object")
            require(document["schema"] == 1L) { "schema ${document["schema"]}, not 1" }
            val servers = document["servers"] as? List<*> ?: throw IllegalArgumentException("no servers")
            val parsed = servers.map { item ->
                val server = item as? Map<*, *> ?: throw IllegalArgumentException("a server is not an object")
                val id = string(server, "id")
                require(Regex("^[a-z][a-z0-9-]*$").matches(id)) { "a server's id is not a name: $id" }
                val entry = string(server, "entry")
                require(RuntimeManifest.normalize(entry) == entry) { "server $id: its entry is not a plain relative path" }
                val identity = string(server, "identity")
                require(HEX64.matches(identity)) { "server $id: its identity is not a SHA-256" }
                Server(
                    id = id,
                    languages = strings(server, "languages"),
                    entry = entry,
                    arguments = strings(server, "arguments"),
                    packages = (server["packages"] as? List<*> ?: emptyList<Any>()).map { value ->
                        val pkg = value as? Map<*, *> ?: throw IllegalArgumentException("server $id: a package is not an object")
                        Package(string(pkg, "name"), string(pkg, "version"), string(pkg, "license"))
                    },
                    archive = string(server, "archive"),
                    manifest = string(server, "manifest"),
                    identity = identity,
                    files = (server["files"] as? Long ?: throw IllegalArgumentException("server $id: no file count")).toInt(),
                    bytes = server["bytes"] as? Long ?: throw IllegalArgumentException("server $id: no byte count"),
                )
            }
            require(parsed.map { it.id }.toSet().size == parsed.size) { "a server is named twice" }
            return parsed
        }

        private fun string(map: Map<*, *>, key: String): String =
            (map[key] as? String)?.takeIf { it.isNotEmpty() } ?: throw IllegalArgumentException("no $key")

        private fun strings(map: Map<*, *>, key: String): List<String> =
            (map[key] as? List<*> ?: throw IllegalArgumentException("no $key")).map {
                it as? String ?: throw IllegalArgumentException("$key holds a non-string")
            }

        internal fun readMarker(file: File): Map<String, String>? =
            try {
                if (!file.isFile) {
                    null
                } else {
                    file.readLines(Charsets.UTF_8).filter { it.contains('=') }
                        .associate { it.substringBefore('=') to it.substringAfter('=') }
                }
            } catch (unreadable: IOException) {
                null
            }

        internal fun classify(server: Server, failure: IOException): LanguageServerFailure {
            val message = failure.message ?: failure.javaClass.simpleName
            return when {
                failure is ZipException || failure is EOFException ->
                    LanguageServerFailure(LanguageServerProblem.DAMAGED, "the ${server.id} server's archive is damaged: $message", failure)
                message.contains("ENOSPC") || message.contains("No space left", ignoreCase = true) ->
                    LanguageServerFailure(LanguageServerProblem.STORAGE, "the device ran out of space", failure)
                else -> LanguageServerFailure(LanguageServerProblem.STORAGE, message, failure)
            }
        }

        internal fun sha256(data: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { byte -> "%02x".format(byte) }

        private fun megabytes(bytes: Long): Long = (bytes + 1_048_575L) / 1_048_576L
    }
}
