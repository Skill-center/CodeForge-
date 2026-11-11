package dev.codeforge.app.storage

import java.util.Locale
import kotlin.random.Random

/**
 * The broker's operations on one granted folder, over a [DocumentBackend]
 * (docs/SECURITY.md §4.1). Pure Kotlin: JVM-tested against an in-memory
 * provider that behaves like Android's own (DocumentOpsTest).
 *
 * **Scoping (S1, S2).** Every path is parsed by [StoragePaths] and reached
 * from the granted folder's root, name by name, through the provider's own
 * listings. A document id never comes from text; one remembered in the
 * [cache] is used only after a query shows the same name there. The
 * backend reaches documents through tree-based URIs, which Android checks
 * against the grant.
 *
 * **Names.** Android's file-system provider quietly changes names: it
 * replaces characters FAT can't hold with '_' and adds " (1)" when the
 * name is taken, comparing names without case on shared storage. So every
 * new name is checked against its folder first (case ignored), and the
 * name the provider gives back is compared with the one asked for: a new
 * item named otherwise is deleted, a rename is undone, and either is
 * reported ([StorageProblem.NAME_CHANGED]). A rename that changes only the
 * case goes through a temporary name.
 *
 * **Limits (S3).** A listing keeps at most [MAX_LIST] entries and skips
 * names [StoragePaths] refuses, and repeats; a name that repeats can't be
 * reached ([StorageProblem.AMBIGUOUS]). Reads stop one buffer past their
 * cap whatever size the provider claimed. Copies stop at [MAX_COPY_DEPTH]
 * levels and [MAX_COPY_ITEMS] items. [cancel] is checked between steps.
 */
class DocumentOps(
    private val backend: DocumentBackend,
    private val cache: DocumentIdCache,
    private val cancel: Cancellation,
) {
    /** What a write must find before it replaces a file. */
    data class Expectation(val size: Long?, val modifiedMs: Long?, val sha256: String?)

    /** A folder's entries as the broker keeps them. */
    class Listing(val rows: List<DocumentRow>, val repeated: Set<String>) {
        private val byName: Map<String, DocumentRow> = rows.associateBy { it.name }

        /** The entry named exactly [name]; [StorageProblem.AMBIGUOUS] if several are. */
        fun named(name: String): DocumentRow? {
            if (name in repeated) {
                throw StorageException(StorageProblem.AMBIGUOUS, "Several entries share that name.")
            }
            return byName[name]
        }

        /** An entry other than [except] whose name is [name] when case is ignored. */
        fun clash(name: String, except: DocumentRow? = null): DocumentRow? {
            val folded = fold(name)
            return rows.firstOrNull { it.id != except?.id && fold(it.name) == folded }
        }
    }

    /** The granted folder; [StorageProblem.MISSING] when it is gone. */
    fun root(): DocumentRow {
        cancel.check()
        val row = backend.query(backend.rootId)
        if (row == null || !row.isDirectory) {
            throw StorageException(StorageProblem.MISSING, "The granted folder is gone.")
        }
        return row
    }

    fun list(path: String): List<DocumentRow> {
        val names = StoragePaths.parse(path)
        val folder = resolve(path, names)
        if (!folder.isDirectory) {
            throw StorageException(StorageProblem.WRONG_TYPE, "That is a file, not a folder.")
        }
        return children(folder, path).rows
    }

    fun stat(path: String): DocumentRow = resolve(path, StoragePaths.parse(path))

    /**
     * A file's bytes, refused above [maxBytes], and the file as it was
     * right after they were read. A file that changed during the read is
     * read again, twice at most.
     */
    fun read(path: String, maxBytes: Int): Pair<DocumentRow, ByteArray> {
        val names = StoragePaths.parse(path)
        val cap = maxBytes.coerceIn(0, READ_CEILING)
        var row = resolve(path, names)
        var attempt = 0
        while (true) {
            if (row.isDirectory) {
                throw StorageException(StorageProblem.WRONG_TYPE, "That is a folder, not a file.")
            }
            if (row.has(DocFlags.VIRTUAL_DOCUMENT)) {
                throw StorageException(StorageProblem.UNSUPPORTED, "A virtual document has no bytes to read.")
            }
            val listed = row.size
            if (listed != null && listed > cap) {
                throw StorageException(StorageProblem.TOO_LARGE, "The file holds $listed bytes.")
            }
            val bytes = backend.openRead(row.id).use { Streams.readCapped(it, cap, cancel) }
            cancel.check()
            val after = backend.query(row.id)
                ?: throw StorageException(StorageProblem.NOT_FOUND, "The file went away while it was read.")
            val changed = after.modifiedMs != row.modifiedMs ||
                (after.size != null && after.size != bytes.size.toLong())
            if (!changed || attempt >= 2) {
                cache.put(path, after.id)
                return after to bytes
            }
            attempt += 1
            row = after
        }
    }

    /**
     * Writes [bytes] to the file at [path], in place: Android has no way to
     * replace a document by renaming over it. Missing folders above it are
     * created. With [expect], the file must still be what the caller read
     * ([StorageProblem.CHANGED] otherwise). The new stamp is read back, and
     * its size must be the number of bytes written.
     */
    fun write(path: String, bytes: ByteArray, createNew: Boolean, expect: Expectation?): DocumentRow {
        val names = StoragePaths.parse(path)
        if (names.isEmpty()) {
            throw StorageException(StorageProblem.INVALID_PATH, "The folder itself is not a file.")
        }
        val parentNames = names.dropLast(1)
        val parentPath = StoragePaths.joinAll(parentNames)
        val name = names.last()
        val parent = folderCreatingMissing(parentPath, parentNames)
        val listing = children(parent, parentPath)
        val existing = listing.named(name)
        val target = if (existing != null) {
            if (existing.isDirectory) {
                throw StorageException(StorageProblem.WRONG_TYPE, "That is a folder, not a file.")
            }
            if (createNew) {
                throw StorageException(StorageProblem.EXISTS, "Something is already there.")
            }
            if (!existing.has(DocFlags.SUPPORTS_WRITE)) {
                throw StorageException(StorageProblem.UNSUPPORTED, "The provider keeps that file read-only.")
            }
            if (expect != null) {
                requireUnchanged(existing, expect)
            }
            existing
        } else {
            listing.clash(name)?.let {
                throw StorageException(StorageProblem.EXISTS, "An entry whose name differs only in case is there.")
            }
            createChecked(parent, parentPath, name, directory = false)
        }
        cancel.check()
        backend.openWrite(target.id).use { Streams.writeAll(it, bytes, cancel) }
        cancel.check()
        val after = backend.query(target.id)
            ?: throw StorageException(StorageProblem.IO, "The file went away while it was written.")
        val size = after.size
        if (size != null && size != bytes.size.toLong()) {
            throw StorageException(
                StorageProblem.IO,
                "The file holds $size bytes after the write, not ${bytes.size}.",
            )
        }
        cache.put(path, after.id)
        return after
    }

    /** Creates an empty file or a folder named [name] in the folder at [parentPath]. */
    fun create(parentPath: String, name: String, directory: Boolean): DocumentRow {
        StoragePaths.requireName(name)
        val parent = resolve(parentPath, StoragePaths.parse(parentPath))
        if (!parent.isDirectory) {
            throw StorageException(StorageProblem.WRONG_TYPE, "That is a file, not a folder.")
        }
        children(parent, parentPath).clash(name)?.let {
            throw StorageException(StorageProblem.EXISTS, "That name is taken.")
        }
        return createChecked(parent, parentPath, name, directory)
    }

    fun rename(path: String, newName: String): DocumentRow {
        StoragePaths.requireName(newName)
        val names = StoragePaths.parse(path)
        if (names.isEmpty()) {
            throw StorageException(StorageProblem.INVALID_PATH, "The granted folder is not renamed here.")
        }
        val parentNames = names.dropLast(1)
        val parentPath = StoragePaths.joinAll(parentNames)
        val oldName = names.last()
        val parent = resolve(parentPath, parentNames)
        val listing = children(parent, parentPath)
        val doc = listing.named(oldName)
            ?: throw StorageException(StorageProblem.NOT_FOUND, "It is not there.")
        if (newName == oldName) {
            return doc
        }
        if (!doc.has(DocFlags.SUPPORTS_RENAME)) {
            throw StorageException(StorageProblem.UNSUPPORTED, "The provider can't rename that.")
        }
        listing.clash(newName, except = doc)?.let {
            throw StorageException(StorageProblem.EXISTS, "That name is taken.")
        }
        cache.forget(path)
        val renamed = if (fold(newName) == fold(oldName)) {
            // Only the case changes: storage that ignores case would take the
            // new name for the file's own and add " (1)".
            val temporary = renameChecked(doc, temporaryName(listing), undoTo = oldName)
            try {
                renameChecked(temporary, newName, undoTo = oldName)
            } catch (error: Exception) {
                runCatching { backend.rename(temporary.id, oldName) }
                throw error
            }
        } else {
            renameChecked(doc, newName, undoTo = oldName)
        }
        cache.put(StoragePaths.join(parentPath, newName), renamed.id)
        return renamed
    }

    /** Moves the entry at [path] into the folder at [newParentPath], keeping its name. */
    fun move(path: String, newParentPath: String): DocumentRow {
        val names = StoragePaths.parse(path)
        if (names.isEmpty()) {
            throw StorageException(StorageProblem.INVALID_PATH, "The granted folder is not moved here.")
        }
        val targetNames = StoragePaths.parse(newParentPath)
        if (StoragePaths.isWithin(newParentPath, path)) {
            throw StorageException(StorageProblem.INVALID_PATH, "A folder can't move into itself.")
        }
        val parentNames = names.dropLast(1)
        val parentPath = StoragePaths.joinAll(parentNames)
        val name = names.last()
        if (newParentPath == parentPath) {
            return stat(path)
        }
        val parent = resolve(parentPath, parentNames)
        val doc = children(parent, parentPath).named(name)
            ?: throw StorageException(StorageProblem.NOT_FOUND, "It is not there.")
        val target = resolve(newParentPath, targetNames)
        if (!target.isDirectory) {
            throw StorageException(StorageProblem.WRONG_TYPE, "The destination is a file, not a folder.")
        }
        if (!target.has(DocFlags.DIR_SUPPORTS_CREATE)) {
            throw StorageException(StorageProblem.UNSUPPORTED, "The provider can't add to that folder.")
        }
        children(target, newParentPath).clash(name)?.let {
            throw StorageException(StorageProblem.EXISTS, "That name is taken in the destination.")
        }
        cache.forget(path)
        val moved = if (doc.has(DocFlags.SUPPORTS_MOVE)) {
            cancel.check()
            val id = backend.move(doc.id, parent.id, target.id)
            backend.query(id) ?: throw StorageException(StorageProblem.IO, "The moved item could not be found.")
        } else {
            // A provider that can't move: copy, then delete the original.
            if (!doc.has(DocFlags.SUPPORTS_DELETE)) {
                throw StorageException(StorageProblem.UNSUPPORTED, "The provider can't move or delete that.")
            }
            val copy = copyTopLevel(doc, target, newParentPath, name)
            try {
                cancel.check()
                backend.delete(doc.id)
            } catch (error: Exception) {
                throw StorageException(StorageProblem.IO, "Copied, but the original could not be deleted.", error)
            }
            copy
        }
        if (moved.name != name) {
            throw StorageException(StorageProblem.NAME_CHANGED, "The provider named it \"${moved.name}\".")
        }
        cache.put(StoragePaths.join(newParentPath, name), moved.id)
        return moved
    }

    /** Copies the entry at [path] into the folder at [newParentPath] as [newName]. */
    fun copy(path: String, newParentPath: String, newName: String): DocumentRow {
        StoragePaths.requireName(newName)
        val names = StoragePaths.parse(path)
        if (names.isEmpty()) {
            throw StorageException(StorageProblem.INVALID_PATH, "The granted folder is not copied here.")
        }
        if (StoragePaths.isWithin(newParentPath, path)) {
            throw StorageException(StorageProblem.INVALID_PATH, "A folder can't be copied into itself.")
        }
        val source = resolve(path, names)
        val target = resolve(newParentPath, StoragePaths.parse(newParentPath))
        if (!target.isDirectory) {
            throw StorageException(StorageProblem.WRONG_TYPE, "The destination is a file, not a folder.")
        }
        children(target, newParentPath).clash(newName)?.let {
            throw StorageException(StorageProblem.EXISTS, "That name is taken in the destination.")
        }
        return copyTopLevel(source, target, newParentPath, newName)
    }

    /** Deletes the file at [path], or the folder with everything in it. */
    fun delete(path: String) {
        val names = StoragePaths.parse(path)
        if (names.isEmpty()) {
            throw StorageException(StorageProblem.INVALID_PATH, "The granted folder is not deleted here.")
        }
        val doc = resolve(path, names)
        if (!doc.has(DocFlags.SUPPORTS_DELETE)) {
            throw StorageException(StorageProblem.UNSUPPORTED, "The provider can't delete that.")
        }
        cancel.check()
        backend.delete(doc.id)
        cache.forget(path)
    }

    /**
     * The document at [path] ([names] parsed from it): from the cache when
     * a query finds it there under the same name, otherwise walked from
     * the root through each folder's listing.
     */
    private fun resolve(path: String, names: List<String>): DocumentRow {
        if (names.isEmpty()) {
            return root()
        }
        cache.get(path)?.let { id ->
            cancel.check()
            val row = backend.query(id)
            if (row != null && row.name == names.last()) {
                return row
            }
            cache.forget(path)
        }
        var current = root()
        var currentPath = ""
        for (name in names) {
            if (!current.isDirectory) {
                throw StorageException(StorageProblem.NOT_FOUND, "A file stands where a folder should be.")
            }
            current = children(current, currentPath).named(name)
                ?: throw StorageException(StorageProblem.NOT_FOUND, "It is not there.")
            currentPath = StoragePaths.join(currentPath, name)
        }
        return current
    }

    /** The folder at [path], creating the folders that are missing. */
    private fun folderCreatingMissing(path: String, names: List<String>): DocumentRow {
        try {
            val folder = resolve(path, names)
            if (!folder.isDirectory) {
                throw StorageException(StorageProblem.WRONG_TYPE, "A file stands where a folder should be.")
            }
            return folder
        } catch (error: StorageException) {
            if (error.problem != StorageProblem.NOT_FOUND) {
                throw error
            }
        }
        var current = root()
        var currentPath = ""
        for (name in names) {
            val listing = children(current, currentPath)
            val existing = listing.named(name)
            current = when {
                existing == null -> {
                    listing.clash(name)?.let {
                        throw StorageException(StorageProblem.EXISTS, "An entry whose name differs only in case is there.")
                    }
                    createChecked(current, currentPath, name, directory = true)
                }
                existing.isDirectory -> existing
                else -> throw StorageException(StorageProblem.WRONG_TYPE, "A file stands where a folder should be.")
            }
            currentPath = StoragePaths.join(currentPath, name)
        }
        return current
    }

    /** [folder]'s entries, each valid and unique one remembered in the cache. */
    private fun children(folder: DocumentRow, folderPath: String): Listing {
        cancel.check()
        val raw = backend.children(folder.id, MAX_LIST + 1)
            ?: throw StorageException(
                if (folderPath.isEmpty()) StorageProblem.MISSING else StorageProblem.NOT_FOUND,
                "The folder is gone.",
            )
        val kept = LinkedHashMap<String, DocumentRow>()
        val repeated = HashSet<String>()
        for (row in raw.take(MAX_LIST)) {
            if (!StoragePaths.isValidName(row.name)) {
                continue
            }
            if (kept.containsKey(row.name)) {
                repeated += row.name
            } else {
                kept[row.name] = row
            }
        }
        for ((name, row) in kept) {
            if (name !in repeated) {
                cache.put(StoragePaths.join(folderPath, name), row.id)
            }
        }
        return Listing(kept.values.toList(), repeated)
    }

    private fun createChecked(parent: DocumentRow, parentPath: String, name: String, directory: Boolean): DocumentRow {
        if (!parent.has(DocFlags.DIR_SUPPORTS_CREATE)) {
            throw StorageException(StorageProblem.UNSUPPORTED, "The provider can't add to that folder.")
        }
        cancel.check()
        val id = backend.create(parent.id, name, directory)
        val row = backend.query(id)
            ?: throw StorageException(StorageProblem.IO, "The new item could not be found.")
        if (row.name != name || row.isDirectory != directory) {
            runCatching { backend.delete(row.id) }
            throw StorageException(StorageProblem.NAME_CHANGED, "The provider named it \"${row.name}\".")
        }
        cache.put(StoragePaths.join(parentPath, name), row.id)
        return row
    }

    private fun renameChecked(doc: DocumentRow, name: String, undoTo: String): DocumentRow {
        cancel.check()
        val id = backend.rename(doc.id, name)
        val row = backend.query(id)
            ?: throw StorageException(StorageProblem.IO, "The renamed item could not be found.")
        if (row.name != name) {
            runCatching { backend.rename(row.id, undoTo) }
            throw StorageException(StorageProblem.NAME_CHANGED, "The provider named it \"${row.name}\".")
        }
        return row
    }

    /** Copies [source] into [target] as [name]; a failed copy leaves nothing behind. */
    private fun copyTopLevel(source: DocumentRow, target: DocumentRow, targetPath: String, name: String): DocumentRow {
        val budget = intArrayOf(MAX_COPY_ITEMS)
        var created: DocumentRow? = null
        try {
            return copyInto(source, target, targetPath, name, depth = 0, budget) { created = it }
        } catch (error: Exception) {
            created?.let { partial -> runCatching { backend.delete(partial.id) } }
            cache.forget(StoragePaths.join(targetPath, name))
            throw error
        }
    }

    private fun copyInto(
        source: DocumentRow,
        target: DocumentRow,
        targetPath: String,
        name: String,
        depth: Int,
        budget: IntArray,
        onCreated: (DocumentRow) -> Unit = {},
    ): DocumentRow {
        if (depth > MAX_COPY_DEPTH) {
            throw StorageException(StorageProblem.UNSUPPORTED, "Folders nested deeper than $MAX_COPY_DEPTH are not copied.")
        }
        budget[0] -= 1
        if (budget[0] < 0) {
            throw StorageException(StorageProblem.UNSUPPORTED, "More than $MAX_COPY_ITEMS items are not copied at once.")
        }
        cancel.check()
        if (!source.isDirectory) {
            if (source.has(DocFlags.VIRTUAL_DOCUMENT)) {
                throw StorageException(StorageProblem.UNSUPPORTED, "A virtual document has no bytes to copy.")
            }
            val file = createChecked(target, targetPath, name, directory = false)
            onCreated(file)
            backend.openRead(source.id).use { input ->
                backend.openWrite(file.id).use { output -> Streams.copy(input, output, cancel) }
            }
            return backend.query(file.id)
                ?: throw StorageException(StorageProblem.IO, "The copy went away.")
        }
        val folder = createChecked(target, targetPath, name, directory = true)
        onCreated(folder)
        val folderPath = StoragePaths.join(targetPath, name)
        val entries = backend.children(source.id, MAX_LIST + 1)
            ?: throw StorageException(StorageProblem.NOT_FOUND, "The folder went away while it was copied.")
        if (entries.size > MAX_LIST) {
            throw StorageException(StorageProblem.UNSUPPORTED, "Folders of more than $MAX_LIST entries are not copied.")
        }
        for (child in entries) {
            if (!StoragePaths.isValidName(child.name)) {
                throw StorageException(StorageProblem.UNSUPPORTED, "An entry's name can't be copied.")
            }
            copyInto(child, folder, folderPath, child.name, depth + 1, budget)
        }
        return backend.query(folder.id) ?: folder
    }

    private fun temporaryName(listing: Listing): String {
        while (true) {
            val name = ".cf-rename-" + Random.nextLong().toULong().toString(16)
            if (listing.clash(name) == null) {
                return name
            }
        }
    }

    private fun requireUnchanged(existing: DocumentRow, expect: Expectation) {
        val sha256 = expect.sha256
        val unchanged = if (sha256 != null) {
            // The provider gave no time when the file was read: compare the bytes.
            val current = try {
                backend.openRead(existing.id).use { Streams.readCapped(it, READ_CEILING, cancel) }
            } catch (error: StorageException) {
                if (error.problem != StorageProblem.TOO_LARGE) {
                    throw error
                }
                null
            }
            current != null && Streams.sha256Hex(current) == sha256
        } else {
            existing.size == expect.size && existing.modifiedMs == expect.modifiedMs
        }
        if (!unchanged) {
            throw StorageException(StorageProblem.CHANGED, "The file changed since it was read.")
        }
    }

    companion object {
        const val MAX_LIST = 50_000
        const val MAX_COPY_DEPTH = 64
        const val MAX_COPY_ITEMS = 10_000

        /** No read ever takes more, whatever the caller asked for. */
        const val READ_CEILING = 64 * 1024 * 1024

        /** Names compared as shared storage compares them: without case. */
        fun fold(name: String): String = name.lowercase(Locale.ROOT)
    }
}
