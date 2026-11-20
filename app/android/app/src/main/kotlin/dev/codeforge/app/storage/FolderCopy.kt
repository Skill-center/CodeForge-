package dev.codeforge.app.storage

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.concurrent.Callable
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicInteger

/** One entry of a folder being copied; [path] is relative to its top, '/'-separated. */
class CopyEntry(
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    /** Bytes, when the folder says. */
    val size: Long?,
    /** Milliseconds since the epoch, when the folder says. */
    val modifiedMs: Long?,
    /** A virtual document (a Google Doc and the like): it has no bytes. */
    val virtual: Boolean = false,
    internal val handle: Any? = null,
)

/** The folder a copy reads. */
interface CopySource {
    /** The entries of [folder], or of the top when it is null. Throws when they can't be listed. */
    fun entries(folder: CopyEntry?): List<CopyEntry>

    /** [file] opened for reading; the caller closes it. */
    fun open(file: CopyEntry): InputStream
}

/**
 * A folder from shared storage, through the storage broker's operations on
 * its grant: the entries the explorer lists, so a copy holds what the editor
 * shows (names the provider repeats or that are not valid are left out).
 */
class SafCopySource(private val ops: DocumentOps) : CopySource {
    override fun entries(folder: CopyEntry?): List<CopyEntry> {
        val row = (folder?.handle as? DocumentRow) ?: ops.root()
        return ops.entries(row, folder?.path ?: "").map { child ->
            CopyEntry(
                name = child.name,
                path = if (folder == null) child.name else "${folder.path}/${child.name}",
                isDirectory = child.isDirectory,
                size = child.size,
                modifiedMs = child.modifiedMs,
                virtual = !child.isDirectory && child.has(DocFlags.VIRTUAL_DOCUMENT),
                handle = child,
            )
        }
    }

    override fun open(file: CopyEntry): InputStream = ops.openRead(file.handle as DocumentRow)
}

/** What a copy takes at most (ADR-0013: set from Phase 5 W4's measurements). */
data class CopyLimits(
    val maxFiles: Int = DEFAULT_MAX_FILES,
    val maxBytes: Long = DEFAULT_MAX_BYTES,
    val maxFileBytes: Long = DEFAULT_MAX_FILE_BYTES,
    val maxDepth: Int = DEFAULT_MAX_DEPTH,
) {
    companion object {
        const val DEFAULT_MAX_FILES = 10_000
        const val DEFAULT_MAX_BYTES = 512L * 1024 * 1024
        const val DEFAULT_MAX_FILE_BYTES = 64L * 1024 * 1024
        const val DEFAULT_MAX_DEPTH = 64

        /** Importing a folder as a project is done once, on request: it takes more. */
        val IMPORT = CopyLimits(maxFiles = 100_000, maxBytes = 4L * 1024 * 1024 * 1024)
    }
}

/** How a copy went, and what it left out. */
data class CopySummary(
    /** Files in the copy from the folder, once it is done. */
    val files: Int,
    /** Their bytes. */
    val bytes: Long,
    /** Files copied this time: new in the folder, changed there, or changed in the copy. */
    val copied: Int,
    val bytesCopied: Long,
    /** Files the copy already had as the folder has them. */
    val unchanged: Int,
    /** Files gone from the folder, removed from the copy. */
    val removed: Int,
    /** Files over [CopyLimits.maxFileBytes]. */
    val leftOutLarge: Int,
    /** Files left out because the copy was full ([CopyLimits.maxFiles] or [CopyLimits.maxBytes]). */
    val leftOutFull: Int,
    /** Virtual documents: they have no bytes. */
    val leftOutVirtual: Int,
    /** Folders deeper than [CopyLimits.maxDepth]. */
    val leftOutDeep: Int,
    /** Entries left out by name wherever they are (`.git` in a run's copy). */
    val skipped: Int,
    /** Files and folders that could not be read; a file's earlier copy stays. */
    val unreadable: Int,
    /** The copy filled up and stopped walking: more may have been left out than it counted. */
    val capped: Boolean,
    val stopped: Boolean,
    val elapsedMs: Long,
)

/**
 * What a run's copy holds from its folder: for each file, the folder's size
 * and time when it was copied, and the copy's own size and time right after.
 * A file whose folder stamp is the same and whose copy is untouched is not
 * copied again; one whose copy differs was changed by a run.
 */
class CopyManifest private constructor(private val entries: LinkedHashMap<String, Entry>) {
    data class Entry(val sourceSize: Long, val sourceModifiedMs: Long?, val copySize: Long, val copyModifiedMs: Long)

    operator fun get(path: String): Entry? = entries[path]

    fun put(path: String, entry: Entry) {
        entries[path] = entry
    }

    fun remove(path: String) {
        entries.remove(path)
    }

    val paths: List<String> get() = entries.keys.toList()

    val size: Int get() = entries.size

    /** Writes it to [file] through a temporary file, so a crash leaves the old one or the new one. */
    fun write(file: File) {
        val parent = file.absoluteFile.parentFile
        if (!parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) throw IOException("could not create the manifest's folder")
        val temp = File(parent, "${file.name}.tmp")
        temp.bufferedWriter(Charsets.UTF_8).use { out ->
            out.write(HEADER)
            out.write("\n")
            for ((path, entry) in entries) {
                out.write("$path\t${entry.sourceSize}\t${entry.sourceModifiedMs ?: "-"}\t${entry.copySize}\t${entry.copyModifiedMs}\n")
            }
        }
        Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    companion object {
        const val HEADER = "codeforge-copy 1"

        fun empty() = CopyManifest(LinkedHashMap())

        /**
         * The manifest in [file]; an empty one when there is none, or when it
         * can't be read or parsed, so everything is copied again.
         */
        fun read(file: File): CopyManifest {
            val lines = try {
                file.readLines(Charsets.UTF_8)
            } catch (missing: IOException) {
                return empty()
            }
            if (lines.firstOrNull() != HEADER) return empty()
            val entries = LinkedHashMap<String, Entry>()
            for (line in lines.drop(1)) {
                if (line.isEmpty()) continue
                val parts = line.split('\t')
                if (parts.size != 5 || !validPath(parts[0])) return empty()
                val sourceSize = parts[1].toLongOrNull() ?: return empty()
                val sourceModified = if (parts[2] == "-") null else parts[2].toLongOrNull() ?: return empty()
                val copySize = parts[3].toLongOrNull() ?: return empty()
                val copyModified = parts[4].toLongOrNull() ?: return empty()
                entries[parts[0]] = Entry(sourceSize, sourceModified, copySize, copyModified)
            }
            return CopyManifest(entries)
        }

        private fun validPath(path: String): Boolean = try {
            StoragePaths.parse(path).isNotEmpty()
        } catch (bad: StorageException) {
            false
        }
    }
}

/** A file a run created or changed in its copy. */
data class CopyChange(val path: String, val created: Boolean, val size: Long)

/** The files only the copy has, or has otherwise than the folder, at most a limit of them. */
data class CopyChanges(
    val changes: List<CopyChange>,
    /** Changed files beyond the limit. */
    val more: Int,
    /** Files whose names a documents provider can't take. */
    val unexportable: Int,
    /** Dependency and cache folders ([FolderCopy.NOT_LISTED]) that were not looked into. */
    val skippedFolders: Int,
)

/** One file export could not write, and why. */
data class ExportFailure(val path: String, val problem: StorageProblem, val message: String)

data class ExportResult(val exported: Int, val failures: List<ExportFailure>)

/**
 * A folder's copy in the app's storage (Phase 5 W4, ADR-0013): a run in a
 * folder from shared storage happens in its copy, since the runtime's
 * programs need real paths and a documents provider has none.
 *
 * - **One way and incremental:** [sync] copies the files that are new or
 *   changed in the folder (size or time), and those a run changed in the
 *   copy, so a run starts from the folder as it is; files gone from the
 *   folder go from the copy. Files only the copy has (a run's output,
 *   `node_modules` from an install) stay until the user exports them or the
 *   copy is deleted. A folder that can't be listed keeps its files.
 * - **Left out:** names in [skipped] wherever they are (`.git` for a run),
 *   virtual documents, files over [CopyLimits.maxFileBytes], folders deeper
 *   than [CopyLimits.maxDepth], and whatever comes once the copy is full
 *   ([CopyLimits.maxFiles], [CopyLimits.maxBytes]); the summary counts each.
 *   A file left out loses its earlier copy.
 * - **Reads ahead** on [parallelism] threads, as the search's scan does
 *   (each file is an open the provider answers); files move into place on
 *   the walking thread, in the walk's order, from [staging].
 * - **Never follows a link** the copy holds: a run can make any, and the
 *   copy must not write through one, so links in the way are replaced.
 * - **Stops** when [stopped] says so, between files and inside a file; what
 *   was copied by then is kept and recorded.
 *
 * [changes] lists what only the copy has, or has otherwise; [export] writes
 * the files the user picks back to the folder. No Android type: the JVM
 * tests drive it over the storage tests' provider and real files.
 */
class FolderCopy(
    private val source: CopySource,
    /** The copy's top folder, created when missing. */
    private val target: File,
    /** The copy's manifest; null for a copy made once (an import). */
    private val manifestFile: File?,
    /** Files are written here, then moved into place: the same volume as [target], outside it. */
    private val staging: File,
    private val limits: CopyLimits = CopyLimits(),
    private val skipped: Set<String> = RUN_SKIPPED,
    private val parallelism: Int = 1,
    private val stopped: () -> Boolean = { false },
    /** Told how far the copy is: files and bytes in place, at most every [PROGRESS_MS]. */
    private val progress: (files: Int, bytes: Long) -> Unit = { _, _ -> },
) {
    private class Stopped : Exception()

    private class TooLarge : Exception()

    /** A file being read: into its temporary file, on a reader thread or this one. */
    private class Pending(
        val entry: CopyEntry,
        val temp: File,
        val future: Future<Long>?,
        val done: Result<Long>?,
    )

    private class Walk(val manifest: CopyManifest) {
        var files = 0
        var bytes = 0L
        var copied = 0
        var bytesCopied = 0L
        var unchanged = 0
        var removed = 0
        var leftOutLarge = 0
        var leftOutFull = 0
        var leftOutVirtual = 0
        var leftOutDeep = 0
        var skipped = 0
        var unreadable = 0
        var capped = false

        /** Files the folder has that the copy keeps. */
        val kept = HashSet<String>()

        /** Files the folder has that the copy left out. */
        val leftOut = HashSet<String>()

        /** Folders the folder has, and folders that could not be listed. */
        val folders = HashSet<String>()
        val unlisted = ArrayList<String>()
        var lastProgress = 0L
    }

    private val temps = AtomicInteger()

    /** Brings the copy up to date with the folder. Throws what listing the folder's top throws. */
    fun sync(): CopySummary {
        val started = System.nanoTime()
        val walk = Walk(manifestFile?.let(CopyManifest::read) ?: CopyManifest.empty())
        realDirectory(target.toPath())
        realDirectory(staging.toPath())
        val threads = parallelism.coerceIn(1, MAX_PARALLELISM)
        val pool = if (threads > 1) {
            val count = AtomicInteger()
            Executors.newFixedThreadPool(threads) { task ->
                Thread(task, "codeforge-copy-${count.incrementAndGet()}").apply { isDaemon = true }
            }
        } else {
            null
        }
        val inFlight = ArrayDeque<Pending>()
        var completed = false
        try {
            walk(walk, pool, inFlight)
            while (inFlight.isNotEmpty() && !stopped()) finish(walk, inFlight.removeFirst())
            if (!stopped()) removeGone(walk)
            completed = true
        } finally {
            for (pending in inFlight) pending.future?.cancel(true)
            pool?.shutdownNow()
            for (pending in inFlight) pending.temp.delete()
            staging.listFiles()?.forEach { it.delete() }
            // What was copied is recorded even when the copy stopped or failed.
            if (manifestFile != null) {
                try {
                    walk.manifest.write(manifestFile)
                } catch (failure: IOException) {
                    if (completed) throw failure
                }
            }
        }
        return CopySummary(
            files = walk.files,
            bytes = walk.bytes,
            copied = walk.copied,
            bytesCopied = walk.bytesCopied,
            unchanged = walk.unchanged,
            removed = walk.removed,
            leftOutLarge = walk.leftOutLarge,
            leftOutFull = walk.leftOutFull,
            leftOutVirtual = walk.leftOutVirtual,
            leftOutDeep = walk.leftOutDeep,
            skipped = walk.skipped,
            unreadable = walk.unreadable,
            capped = walk.capped,
            stopped = stopped(),
            elapsedMs = (System.nanoTime() - started) / 1_000_000L,
        )
    }

    private fun walk(walk: Walk, pool: ExecutorService?, inFlight: ArrayDeque<Pending>) {
        val pending = ArrayDeque<Pair<CopyEntry?, Int>>()
        pending.add(null to 0)
        while (pending.isNotEmpty()) {
            if (stopped()) return
            val (folder, depth) = pending.removeFirst()
            if (walk.capped && folder != null) {
                // Full: what was not walked keeps what it has.
                walk.unlisted.add(folder.path)
                continue
            }
            val entries = try {
                source.entries(folder)
            } catch (failure: Exception) {
                if (folder == null) throw failure
                walk.unreadable += 1
                walk.unlisted.add(folder.path)
                continue
            }
            for (entry in entries.sortedBy { it.name }) {
                if (stopped()) return
                if (entry.name in skipped) {
                    walk.skipped += 1
                    continue
                }
                if (entry.isDirectory) {
                    if (depth + 1 >= limits.maxDepth) {
                        walk.leftOutDeep += 1
                        walk.unlisted.add(entry.path)
                        continue
                    }
                    walk.folders.add(entry.path)
                    realDirectory(local(entry.path))
                    pending.add(entry to depth + 1)
                    continue
                }
                take(walk, entry, pool, inFlight)
            }
        }
    }

    /** Decides what happens to one of the folder's files, and starts reading it when it must be copied. */
    private fun take(walk: Walk, entry: CopyEntry, pool: ExecutorService?, inFlight: ArrayDeque<Pending>) {
        if (entry.virtual) {
            walk.leftOutVirtual += 1
            walk.leftOut.add(entry.path)
            return
        }
        val listed = entry.size
        if (listed != null && listed > limits.maxFileBytes) {
            walk.leftOutLarge += 1
            walk.leftOut.add(entry.path)
            return
        }
        val taken = walk.files + inFlight.size
        if (taken >= limits.maxFiles || (listed != null && walk.bytes + listed > limits.maxBytes)) {
            walk.leftOutFull += 1
            walk.leftOut.add(entry.path)
            walk.capped = true
            return
        }
        val previous = walk.manifest[entry.path]
        if (previous != null && unchanged(entry, previous, local(entry.path))) {
            walk.kept.add(entry.path)
            walk.files += 1
            walk.bytes += previous.copySize
            walk.unchanged += 1
            return
        }
        val temp = File(staging, "copy-${temps.incrementAndGet()}.part")
        if (pool == null) {
            finish(walk, Pending(entry, temp, null, runCatching { read(entry, temp) }))
            return
        }
        inFlight.add(Pending(entry, temp, pool.submit(Callable { read(entry, temp) }), null))
        // Enough read ahead to keep every reader busy, no more.
        while (inFlight.size >= MAX_IN_FLIGHT && !stopped()) finish(walk, inFlight.removeFirst())
    }

    /** The folder's file is as it was copied, and its copy as it was written. */
    private fun unchanged(entry: CopyEntry, previous: CopyManifest.Entry, copy: Path): Boolean {
        val modified = entry.modifiedMs ?: return false
        if (previous.sourceModifiedMs != modified) return false
        if (entry.size != null && entry.size != previous.sourceSize) return false
        return stampOf(copy) == previous.copySize to previous.copyModifiedMs
    }

    /** Reads [entry] into [temp]: on any thread, touching nothing shared. The bytes read. */
    private fun read(entry: CopyEntry, temp: File): Long {
        source.open(entry).use { input ->
            Files.newOutputStream(temp.toPath()).use { output ->
                val buffer = ByteArray(BUFFER_BYTES)
                var total = 0L
                while (true) {
                    if (stopped()) throw Stopped()
                    val n = input.read(buffer)
                    if (n < 0) break
                    total += n
                    if (total > limits.maxFileBytes) throw TooLarge()
                    output.write(buffer, 0, n)
                }
                return total
            }
        }
    }

    /** One read done: its file moves into place and is recorded, or its outcome is counted. On the walking thread. */
    private fun finish(walk: Walk, pending: Pending) {
        val entry = pending.entry
        val outcome = pending.done ?: try {
            Result.success(pending.future!!.get())
        } catch (failure: ExecutionException) {
            Result.failure(failure.cause ?: failure)
        } catch (failure: CancellationException) {
            Result.failure(Stopped())
        }
        val written = outcome.getOrElse { failure ->
            pending.temp.delete()
            when (failure) {
                is Stopped -> Unit
                is TooLarge -> {
                    walk.leftOutLarge += 1
                    walk.leftOut.add(entry.path)
                }
                else -> {
                    // The earlier copy, if any, stays: the folder still has the file.
                    walk.unreadable += 1
                    if (walk.manifest[entry.path] != null) walk.kept.add(entry.path)
                }
            }
            return
        }
        val destination = local(entry.path)
        realParents(destination)
        if (Files.isDirectory(destination, LinkOption.NOFOLLOW_LINKS)) deleteTree(destination)
        Files.move(pending.temp.toPath(), destination, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        val stamp = stampOf(destination) ?: (written to 0L)
        walk.manifest.put(entry.path, CopyManifest.Entry(entry.size ?: written, entry.modifiedMs, stamp.first, stamp.second))
        walk.kept.add(entry.path)
        walk.files += 1
        walk.bytes += written
        walk.copied += 1
        walk.bytesCopied += written
        val now = System.nanoTime()
        if (now - walk.lastProgress >= PROGRESS_MS * 1_000_000L) {
            walk.lastProgress = now
            progress(walk.files, walk.bytes)
        }
    }

    /** Files the copy had from the folder that it no longer has, or no longer takes, go. */
    private fun removeGone(walk: Walk) {
        val emptied = HashSet<String>()
        for (path in walk.manifest.paths) {
            if (path in walk.kept) continue
            if (walk.unlisted.any { StoragePaths.isWithin(path, it) }) continue
            walk.manifest.remove(path)
            val copy = local(path)
            if (Files.isDirectory(copy, LinkOption.NOFOLLOW_LINKS)) continue
            val deleted = try {
                Files.deleteIfExists(copy)
            } catch (failure: IOException) {
                // A file now stands where one of its folders was: nothing to delete.
                false
            }
            if (deleted && path !in walk.leftOut) walk.removed += 1
            var parent = path.substringBeforeLast('/', "")
            while (parent.isNotEmpty() && parent !in walk.folders && emptied.add(parent)) {
                parent = parent.substringBeforeLast('/', "")
            }
        }
        // Folders the folder no longer has, deepest first, once they are empty.
        for (folder in emptied.sortedByDescending { it.length }) {
            val copy = local(folder)
            if (!Files.isDirectory(copy, LinkOption.NOFOLLOW_LINKS)) continue
            val empty = Files.newDirectoryStream(copy).use { !it.iterator().hasNext() }
            if (empty) Files.delete(copy)
        }
    }

    /**
     * What only the copy has, or has otherwise than when it was copied or
     * exported: the files runs created or changed, in name order, at most
     * [limit]. [NOT_LISTED] folders and links are not looked into.
     */
    fun changes(limit: Int = MAX_CHANGES): CopyChanges {
        val manifest = manifestFile?.let(CopyManifest::read) ?: CopyManifest.empty()
        val found = ArrayList<CopyChange>()
        var more = 0
        var unexportable = 0
        var skippedFolders = 0
        val top = target.toPath()
        if (!Files.isDirectory(top, LinkOption.NOFOLLOW_LINKS)) return CopyChanges(found, 0, 0, 0)
        val pending = ArrayDeque<Pair<Path, String>>()
        pending.add(top to "")
        while (pending.isNotEmpty()) {
            val (folder, relative) = pending.removeFirst()
            val children = try {
                Files.newDirectoryStream(folder).use { stream -> stream.toList() }.sortedBy { it.fileName.toString() }
            } catch (failure: IOException) {
                continue
            }
            for (child in children) {
                val name = child.fileName.toString()
                val path = if (relative.isEmpty()) name else "$relative/$name"
                if (Files.isSymbolicLink(child)) continue
                if (Files.isDirectory(child, LinkOption.NOFOLLOW_LINKS)) {
                    if (name in NOT_LISTED || name in skipped) {
                        skippedFolders += 1
                    } else {
                        pending.add(child to path)
                    }
                    continue
                }
                if (!Files.isRegularFile(child, LinkOption.NOFOLLOW_LINKS)) continue
                val stamp = stampOf(child) ?: continue
                val previous = manifest[path]
                if (previous != null && stamp == previous.copySize to previous.copyModifiedMs) continue
                if (!exportable(path)) {
                    unexportable += 1
                    continue
                }
                if (found.size >= limit) {
                    more += 1
                    continue
                }
                found.add(CopyChange(path, created = previous == null, size = stamp.first))
            }
        }
        return CopyChanges(found.sortedBy { it.path }, more, unexportable, skippedFolders)
    }

    /**
     * Writes the copy's files at [paths] to the folder through [write], one by
     * one, and records them as the folder now has them. A file that can't be
     * written is reported; the others still go.
     */
    fun export(paths: List<String>, write: (path: String, bytes: ByteArray) -> DocumentRow): ExportResult {
        val manifest = manifestFile?.let(CopyManifest::read) ?: CopyManifest.empty()
        var exported = 0
        val failures = ArrayList<ExportFailure>()
        try {
            for (path in paths.distinct().take(MAX_EXPORT)) {
                if (stopped()) break
                try {
                    val names = StoragePaths.parse(path)
                    if (names.isEmpty() || names.any { it in skipped }) {
                        throw StorageException(StorageProblem.INVALID_PATH, "That file is not exported.")
                    }
                    val file = existingFile(names)
                    val size = Files.size(file)
                    if (size > DocumentOps.READ_CEILING) {
                        throw StorageException(StorageProblem.TOO_LARGE, "The file holds $size bytes.")
                    }
                    val bytes = Files.readAllBytes(file)
                    val row = write(path, bytes)
                    val stamp = stampOf(file) ?: (bytes.size.toLong() to 0L)
                    manifest.put(path, CopyManifest.Entry(row.size ?: bytes.size.toLong(), row.modifiedMs, stamp.first, stamp.second))
                    exported += 1
                } catch (failure: Exception) {
                    val classified = StorageErrors.classify(failure)
                    failures.add(ExportFailure(path, classified.problem, classified.message ?: classified.problem.code))
                }
            }
        } finally {
            if (manifestFile != null && exported > 0) manifest.write(manifestFile)
        }
        return ExportResult(exported, failures)
    }

    // ------------------------------------------------------------------ files

    private fun local(path: String): Path {
        val names = StoragePaths.parse(path)
        var at = target.toPath()
        for (name in names) at = at.resolve(name)
        return at
    }

    /** A copy's file at [names], reached without following a link; NOT_FOUND otherwise. */
    private fun existingFile(names: List<String>): Path {
        var at = target.toPath()
        for ((index, name) in names.withIndex()) {
            at = at.resolve(name)
            if (Files.isSymbolicLink(at)) throw StorageException(StorageProblem.NOT_FOUND, "A link is in the way.")
            val last = index == names.size - 1
            val present = if (last) Files.isRegularFile(at, LinkOption.NOFOLLOW_LINKS) else Files.isDirectory(at, LinkOption.NOFOLLOW_LINKS)
            if (!present) throw StorageException(StorageProblem.NOT_FOUND, "The copy has no such file.")
        }
        return at
    }

    /** Makes [folder] a real folder: a link or a file in its place goes. */
    private fun realDirectory(folder: Path) {
        if (Files.isSymbolicLink(folder)) {
            Files.delete(folder)
        } else if (Files.exists(folder, LinkOption.NOFOLLOW_LINKS) && !Files.isDirectory(folder, LinkOption.NOFOLLOW_LINKS)) {
            Files.delete(folder)
        }
        if (!Files.isDirectory(folder, LinkOption.NOFOLLOW_LINKS)) Files.createDirectories(folder)
    }

    /** Every folder between the copy's top and [file] made real, top first. */
    private fun realParents(file: Path) {
        val top = target.toPath()
        val relative = top.relativize(file)
        var at = top
        for (index in 0 until relative.nameCount - 1) {
            at = at.resolve(relative.getName(index))
            realDirectory(at)
        }
    }

    private fun exportable(path: String): Boolean = try {
        StoragePaths.parse(path).isNotEmpty()
    } catch (bad: StorageException) {
        false
    }

    companion object {
        /** Left out of a run's copy wherever they are: git's files (ADR-0013), as search leaves them out. */
        val RUN_SKIPPED = setOf(".git")

        /** Folders installs and tools fill: not listed among a run's files (they stay in the copy). */
        val NOT_LISTED = setOf("node_modules", "__pycache__", ".venv", "venv", ".pytest_cache", ".mypy_cache", ".git")

        /** Threads a copy may read with. */
        const val MAX_PARALLELISM = 8

        /** Reads waiting at most, ahead of the one moving into place. */
        const val MAX_IN_FLIGHT = 16

        const val MAX_CHANGES = 500
        const val MAX_EXPORT = 1_000
        const val BUFFER_BYTES = 64 * 1024
        const val PROGRESS_MS = 250L

        /** A file's size and time, without following a link; null when it is not a regular file. */
        fun stampOf(file: Path): Pair<Long, Long>? = try {
            if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) {
                null
            } else {
                Files.size(file) to Files.getLastModifiedTime(file, LinkOption.NOFOLLOW_LINKS).toMillis()
            }
        } catch (failure: IOException) {
            null
        }

        /** Deletes [path] and everything under it, never following a link. */
        fun deleteTree(path: Path) {
            if (Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
                val children = Files.newDirectoryStream(path).use { it.toList() }
                for (child in children) deleteTree(child)
            }
            Files.deleteIfExists(path)
        }

        /** For [changes] and [export], which read only the copy. */
        val NO_SOURCE = object : CopySource {
            override fun entries(folder: CopyEntry?): List<CopyEntry> = throw IllegalStateException("no folder to read")

            override fun open(file: CopyEntry): InputStream = throw IllegalStateException("no folder to read")
        }

        /** A copy's id: a folder workspace's id (`folder-<hex>`), never a path. */
        fun isCopyId(id: String): Boolean = COPY_ID.matches(id)

        private val COPY_ID = Regex("[a-z0-9][a-z0-9-]{0,63}")
    }
}
