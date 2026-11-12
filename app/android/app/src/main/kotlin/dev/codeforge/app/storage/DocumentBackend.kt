package dev.codeforge.app.storage

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

/** One document as a provider lists it. */
data class DocumentRow(
    val id: String,
    val name: String,
    val isDirectory: Boolean,
    val size: Long?,
    val modifiedMs: Long?,
    /** DocumentsContract.Document.FLAG_* as the provider reports them ([DocFlags]). */
    val flags: Int,
) {
    fun has(flag: Int): Boolean = flags and flag != 0
}

/**
 * What the broker needs from a documents provider, for one granted tree.
 * StorageBroker.kt implements it over ContentResolver and DocumentsContract
 * ([ResolverBackend]); the JVM tests over an in-memory provider with the
 * quirks of Android's own (FakeProvider).
 */
interface DocumentBackend {
    /** The granted folder's document id. */
    val rootId: String

    /** The document, or null when it is gone. */
    fun query(id: String): DocumentRow?

    /** The folder's children, at most [limit]; null when the folder is gone. */
    fun children(id: String, limit: Int): List<DocumentRow>?

    /** Creates a document named [name] in [parentId]; its id. */
    fun create(parentId: String, name: String, directory: Boolean): String

    /** Renames the document; its id afterwards (path-based ids change). */
    fun rename(id: String, name: String): String

    /** Moves the document; its id afterwards. */
    fun move(id: String, fromParentId: String, toParentId: String): String

    /** Deletes a file, or a folder with everything in it. */
    fun delete(id: String)

    fun openRead(id: String): InputStream

    /** Opens a file for writing from its first byte, dropping the rest ("wt"). */
    fun openWrite(id: String): OutputStream
}

/**
 * DocumentsContract.Document's flags (Android's values, checked against the
 * platform's constants in DocumentOpsTest), and the subset Dart gets.
 */
object DocFlags {
    const val SUPPORTS_WRITE = 1 shl 1
    const val SUPPORTS_DELETE = 1 shl 2
    const val DIR_SUPPORTS_CREATE = 1 shl 3
    const val SUPPORTS_RENAME = 1 shl 6
    const val SUPPORTS_COPY = 1 shl 7
    const val SUPPORTS_MOVE = 1 shl 8
    const val VIRTUAL_DOCUMENT = 1 shl 9

    /** EntryMessage.flags: 1 write (a file) or create inside (a folder), 2 delete, 4 rename, 8 move. */
    fun forDart(row: DocumentRow): Long {
        var flags = 0L
        if (row.has(if (row.isDirectory) DIR_SUPPORTS_CREATE else SUPPORTS_WRITE)) flags = flags or 1L
        if (row.has(SUPPORTS_DELETE)) flags = flags or 2L
        if (row.has(SUPPORTS_RENAME)) flags = flags or 4L
        if (row.has(SUPPORTS_MOVE)) flags = flags or 8L
        return flags
    }
}

/**
 * Paths to document ids, filled by listings and resolutions (Phase 3 W2).
 * Least recently used ids go first. Shared by the broker's threads. A
 * change outside the app needs no clearing (Phase 3 W5): DocumentOps uses
 * a remembered id only after a query shows the same name there.
 */
class DocumentIdCache(private val capacity: Int = 20_000) {
    private val ids = object : LinkedHashMap<String, String>(256, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?): Boolean =
            size > capacity
    }

    @Synchronized
    fun get(path: String): String? = ids[path]

    @Synchronized
    fun put(path: String, id: String) {
        ids[path] = id
    }

    /** Forgets [path] and everything under it. */
    @Synchronized
    fun forget(path: String) {
        if (path.isEmpty()) {
            ids.clear()
            return
        }
        val prefix = "$path/"
        ids.keys.removeAll { it == path || it.startsWith(prefix) }
    }

    @get:Synchronized
    val size: Int
        get() = ids.size
}

/** Streams with limits (docs/SECURITY.md §4.1, S3). */
object Streams {
    const val BUFFER_BYTES = 64 * 1024

    /**
     * All of [input], or [StorageProblem.TOO_LARGE] as soon as it gives more
     * than [cap] bytes, whatever size the provider claimed: an endless
     * stream stops one buffer past the cap.
     */
    fun readCapped(input: InputStream, cap: Int, cancel: Cancellation): ByteArray {
        val out = ByteArrayOutputStream(minOf(cap.coerceAtLeast(0), BUFFER_BYTES))
        val buffer = ByteArray(BUFFER_BYTES)
        var total = 0L
        while (true) {
            cancel.check()
            val n = input.read(buffer)
            if (n < 0) {
                break
            }
            total += n
            if (total > cap) {
                throw StorageException(StorageProblem.TOO_LARGE, "The file holds more than $cap bytes.")
            }
            out.write(buffer, 0, n)
        }
        return out.toByteArray()
    }

    /** Writes [bytes] in buffer-sized pieces, checking the time between them. */
    fun writeAll(output: OutputStream, bytes: ByteArray, cancel: Cancellation) {
        var offset = 0
        while (offset < bytes.size) {
            cancel.check()
            val n = minOf(BUFFER_BYTES, bytes.size - offset)
            output.write(bytes, offset, n)
            offset += n
        }
        output.flush()
    }

    /** Copies [input] to [output]; the bytes copied. */
    fun copy(input: InputStream, output: OutputStream, cancel: Cancellation): Long {
        val buffer = ByteArray(BUFFER_BYTES)
        var total = 0L
        while (true) {
            cancel.check()
            val n = input.read(buffer)
            if (n < 0) {
                break
            }
            output.write(buffer, 0, n)
            total += n
        }
        output.flush()
        return total
    }

    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
