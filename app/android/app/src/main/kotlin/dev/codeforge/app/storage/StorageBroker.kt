package dev.codeforge.app.storage

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Intent
import android.content.UriPermission
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import dev.codeforge.app.runtime.RuntimeHubs
import java.io.File
import java.io.FileNotFoundException
import java.io.OutputStream
import java.nio.file.Files
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * The storage broker (Phase 3 W2, docs/ARCHITECTURE.md §3,
 * docs/SECURITY.md §4.1): the only code that touches `content://`. Dart
 * reaches it through the Pigeon API in pigeons/storage_api.dart.
 *
 * **Grants.** The folder picker (`ACTION_OPEN_DOCUMENT_TREE`, starting at
 * `EXTRA_INITIAL_URI` when Dart names a place), then
 * `takePersistableUriPermission` for reading and writing. Every call
 * checks that its tree URI is among the grants the app keeps; the app asks
 * for no storage permission.
 *
 * **Threads.** Every call runs on a small pool of background threads, never
 * on Android's main thread, and answers on the main thread, as Flutter's
 * messenger expects. Each call has a time limit: when it passes, the call's
 * CancellationSignal is cancelled (queries and file opens stop) and Dart
 * gets `timeout` at once; a provider call that can't be cancelled keeps
 * its thread until it returns, and the pool has others. A full queue
 * answers `busy`.
 *
 * **Saving a copy.** `saveDocument` (Phase 3 W4) shows the create-document
 * picker (`ACTION_CREATE_DOCUMENT`) and writes the bytes Dart sent to the
 * file the user makes there. The app keeps no grant to it: that file is the
 * user's, written once.
 *
 * **Watching.** `watch` (Phase 3 W5) keeps a folder's children query open,
 * so its provider tells the app when the folder changes ([FolderWatches]);
 * the notices reach Dart through [StorageEvents].
 *
 * **Run copies and imports.** `syncCopy` (Phase 5 W4, ADR-0013) brings a
 * folder's copy in `<filesDir>/copies/<id>` up to date for a run
 * ([FolderCopy]), reading four files at a time; `copyChanges` and
 * `exportCopy` list and write back what runs made there. `importTree`
 * copies a whole folder into a new project's folder through a hidden
 * staging folder. One copy of a folder at a time; `cancelCopy` stops one.
 *
 * Logs name the call, its outcome and its duration: never a URI, a path
 * or a file name.
 */
class StorageBroker(private val activity: Activity, private val events: StorageEvents) : StorageApi {
    private val resolver: ContentResolver = activity.applicationContext.contentResolver
    private val watches = FolderWatches(resolver) { id -> events.folderChanged(id) {} }
    private val main = Handler(Looper.getMainLooper())
    private val pool = ThreadPoolExecutor(
        THREADS,
        THREADS,
        30,
        TimeUnit.SECONDS,
        LinkedBlockingQueue(QUEUE),
        threads("codeforge-storage"),
    ).apply { allowCoreThreadTimeOut(true) }
    private val timer = ScheduledThreadPoolExecutor(1, threads("codeforge-storage-timer")).apply {
        removeOnCancelPolicy = true
    }
    private val caches = ConcurrentHashMap<String, DocumentIdCache>()
    private val files: File = activity.applicationContext.filesDir
    private val copies = File(files, RuntimeHubs.COPIES)

    /** Copies and imports running, by copy id: their calls, so [cancelCopy] can stop them. */
    private val copying = ConcurrentHashMap<String, Call>()
    private val copyLocks = ConcurrentHashMap<String, Any>()
    private var pendingPick: ((Result<TreeMessage?>) -> Unit)? = null
    private var pendingSave: PendingSave? = null

    override fun pickTree(initialUri: String?, callback: (Result<TreeMessage?>) -> Unit) {
        if (pendingPick != null || pendingSave != null) {
            callback(Result.failure(FlutterError(StorageProblem.BUSY.code, "The folder picker is already open.", null)))
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
            val start = initialUri?.let(Uri::parse)
            if (start?.scheme == ContentResolver.SCHEME_CONTENT) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, start)
            }
        }
        pendingPick = callback
        try {
            activity.startActivityForResult(intent, REQUEST_PICK_TREE)
        } catch (error: ActivityNotFoundException) {
            pendingPick = null
            callback(Result.failure(FlutterError(StorageProblem.UNSUPPORTED.code, "No folder picker on this device.", null)))
        }
    }

    override fun saveDocument(
        suggestedName: String,
        mimeType: String,
        bytes: ByteArray,
        initialUri: String?,
        callback: (Result<String?>) -> Unit,
    ) {
        if (pendingPick != null || pendingSave != null) {
            callback(Result.failure(FlutterError(StorageProblem.BUSY.code, "A picker is already open.", null)))
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, suggestedName)
            val start = initialUri?.let(Uri::parse)
            if (start?.scheme == ContentResolver.SCHEME_CONTENT) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, start)
            }
        }
        pendingSave = PendingSave(bytes, callback)
        try {
            activity.startActivityForResult(intent, REQUEST_SAVE_DOCUMENT)
        } catch (error: ActivityNotFoundException) {
            pendingSave = null
            callback(Result.failure(FlutterError(StorageProblem.UNSUPPORTED.code, "No file picker on this device.", null)))
        }
    }

    /** A picker's answer, from MainActivity; false when the request was not the broker's. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_SAVE_DOCUMENT) {
            onSaveResult(resultCode, data)
            return true
        }
        if (requestCode != REQUEST_PICK_TREE) {
            return false
        }
        // Null after a process death: the Dart side that asked is gone too.
        val callback = pendingPick ?: return true
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || data == null || uri == null) {
            callback(Result.success(null))
            return true
        }
        val writable = data.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0
        submit("pickTree", QUICK_MS, callback) { call ->
            keepGrant(uri, writable)
            treeMessage(uri, call)
        }
        return true
    }

    private fun onSaveResult(resultCode: Int, data: Intent?) {
        // Null after a process death: the Dart side that asked is gone too.
        val pending = pendingSave ?: return
        pendingSave = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.callback(Result.success(null))
            return
        }
        submit("saveDocument", TRANSFER_MS, pending.callback) { call ->
            call.check()
            openForWrite(uri).use { it.write(pending.bytes) }
            call.check()
            displayName(uri, call)
        }
    }

    /**
     * Opens [uri] to write it from the start. "wt" also truncates, in case
     * the picker handed back a file that was already there; a provider that
     * refuses that mode gets "w".
     */
    private fun openForWrite(uri: Uri): OutputStream {
        val stream = try {
            resolver.openOutputStream(uri, "wt")
        } catch (error: IllegalArgumentException) {
            resolver.openOutputStream(uri, "w")
        } catch (error: FileNotFoundException) {
            resolver.openOutputStream(uri, "w")
        }
        return stream ?: throw StorageException(StorageProblem.IO, "The storage gave nothing to write to.")
    }

    /** The document's name as its provider shows it; '' when it does not say. */
    private fun displayName(uri: Uri, call: Call): String =
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null, call.signal)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else null
        } ?: ""

    override fun checkTree(treeUri: String, callback: (Result<TreeMessage>) -> Unit) =
        submit("checkTree", QUICK_MS, callback) { call -> treeMessage(parseTree(treeUri), call) }

    override fun listGrants(callback: (Result<List<GrantMessage>>) -> Unit) =
        submit("listGrants", QUICK_MS, callback) {
            treeGrants().map { grant ->
                GrantMessage(
                    treeUri = grant.uri.toString(),
                    read = grant.isReadPermission,
                    write = grant.isWritePermission,
                    persistedAtMs = grant.persistedTime,
                )
            }
        }

    override fun releaseGrant(treeUri: String, callback: (Result<Unit>) -> Unit) =
        submit("releaseGrant", QUICK_MS, callback) {
            val uri = parseTree(treeUri)
            caches.remove(treeUri)
            val grant = grantFor(uri)
            if (grant != null) {
                var flags = 0
                if (grant.isReadPermission) flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
                if (grant.isWritePermission) flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                resolver.releasePersistableUriPermission(uri, flags)
            }
            Log.i(TAG, "grants kept: ${treeGrants().size}")
        }

    override fun list(treeUri: String, path: String, callback: (Result<List<EntryMessage>>) -> Unit) =
        submit("list", LIST_MS, callback) { call -> ops(treeUri, call).list(path).map(::entry) }

    override fun stat(treeUri: String, path: String, callback: (Result<EntryMessage>) -> Unit) =
        submit("stat", QUICK_MS, callback) { call -> entry(ops(treeUri, call).stat(path)) }

    override fun read(treeUri: String, path: String, maxBytes: Long, callback: (Result<ReadMessage>) -> Unit) =
        submit("read", TRANSFER_MS, callback) { call ->
            val cap = maxBytes.coerceIn(0L, DocumentOps.READ_CEILING.toLong()).toInt()
            val (row, bytes) = ops(treeUri, call).read(path, cap)
            ReadMessage(entry = entry(row), bytes = bytes)
        }

    override fun write(request: WriteRequest, callback: (Result<EntryMessage>) -> Unit) =
        submit("write", TRANSFER_MS, callback) { call ->
            val expect = if (
                request.expectSize != null || request.expectModifiedMs != null || request.expectSha256 != null
            ) {
                DocumentOps.Expectation(request.expectSize, request.expectModifiedMs, request.expectSha256)
            } else {
                null
            }
            entry(ops(request.treeUri, call, write = true).write(request.path, request.bytes, request.createNew, expect))
        }

    override fun create(
        treeUri: String,
        parentPath: String,
        name: String,
        directory: Boolean,
        callback: (Result<EntryMessage>) -> Unit,
    ) = submit("create", CHANGE_MS, callback) { call ->
        entry(ops(treeUri, call, write = true).create(parentPath, name, directory))
    }

    override fun rename(treeUri: String, path: String, newName: String, callback: (Result<EntryMessage>) -> Unit) =
        submit("rename", CHANGE_MS, callback) { call -> entry(ops(treeUri, call, write = true).rename(path, newName)) }

    override fun move(treeUri: String, path: String, newParentPath: String, callback: (Result<EntryMessage>) -> Unit) =
        submit("move", COPY_MS, callback) { call -> entry(ops(treeUri, call, write = true).move(path, newParentPath)) }

    override fun copy(
        treeUri: String,
        path: String,
        newParentPath: String,
        newName: String,
        callback: (Result<EntryMessage>) -> Unit,
    ) = submit("copy", COPY_MS, callback) { call ->
        entry(ops(treeUri, call, write = true).copy(path, newParentPath, newName))
    }

    override fun delete(treeUri: String, path: String, callback: (Result<Unit>) -> Unit) =
        submit("delete", CHANGE_MS, callback) { call -> ops(treeUri, call, write = true).delete(path) }

    override fun watch(treeUri: String, path: String, watchId: Long, callback: (Result<Boolean>) -> Unit) =
        submit("watch", QUICK_MS, callback) { call ->
            val folder = ops(treeUri, call).stat(path)
            if (!folder.isDirectory) {
                throw StorageException(StorageProblem.WRONG_TYPE, "That is a file, not a folder.")
            }
            watches.start(watchId, parseTree(treeUri), folder.id, call.signal)
        }

    override fun unwatch(watchId: Long, callback: (Result<Unit>) -> Unit) {
        watches.stop(watchId)
        callback(Result.success(Unit))
    }

    override fun syncCopy(treeUri: String, copyId: String, callback: (Result<CopySummaryMessage>) -> Unit) =
        submit("syncCopy", SYNC_MS, callback) { call ->
            val id = copyIdOf(copyId)
            val ops = ops(treeUri, call)
            copying(id, call) {
                FolderCopy(
                    source = SafCopySource(ops),
                    target = File(copies, id),
                    manifestFile = manifestOf(id),
                    staging = File(copies, "$STAGING/$id"),
                    parallelism = READERS,
                    stopped = { call.signal.isCanceled },
                    progress = { count, bytes -> post { events.copyProgress(id, count.toLong(), bytes) {} } },
                ).sync().also { Log.i(TAG, "copy: ${it.copied} copied, ${it.unchanged} unchanged, ${it.removed} removed in ${it.elapsedMs} ms") }
                    .toMessage()
            }
        }

    override fun cancelCopy(copyId: String, callback: (Result<Unit>) -> Unit) {
        copying[copyId]?.signal?.cancel()
        callback(Result.success(Unit))
    }

    override fun copyChanges(copyId: String, callback: (Result<CopyChangesMessage>) -> Unit) =
        submit("copyChanges", LIST_MS, callback) {
            val id = copyIdOf(copyId)
            val changes = copyOf(id, FolderCopy.NO_SOURCE).changes()
            CopyChangesMessage(
                changes = changes.changes.map { CopyChangeMessage(path = it.path, created = it.created, size = it.size) },
                more = changes.more.toLong(),
                unexportable = changes.unexportable.toLong(),
                skippedFolders = changes.skippedFolders.toLong(),
            )
        }

    override fun exportCopy(
        treeUri: String,
        copyId: String,
        paths: List<String>,
        callback: (Result<ExportResultMessage>) -> Unit,
    ) = submit("exportCopy", COPY_MS, callback) { call ->
        val id = copyIdOf(copyId)
        val ops = ops(treeUri, call, write = true)
        val result = synchronized(copyLocks.getOrPut(id) { Any() }) {
            copyOf(id, SafCopySource(ops)).export(paths) { path, bytes ->
                ops.write(path, bytes, createNew = false, expect = null)
            }
        }
        ExportResultMessage(
            exported = result.exported.toLong(),
            failures = result.failures.map { ExportFailureMessage(path = it.path, problem = it.problem.code, message = it.message) },
        )
    }

    override fun deleteCopy(copyId: String, callback: (Result<Unit>) -> Unit) =
        submit("deleteCopy", COPY_MS, callback) {
            val id = copyIdOf(copyId)
            synchronized(copyLocks.getOrPut(id) { Any() }) {
                FolderCopy.deleteTree(File(copies, id).toPath())
                FolderCopy.deleteTree(File(copies, "$STAGING/$id").toPath())
                Files.deleteIfExists(manifestOf(id).toPath())
            }
        }

    override fun importTree(treeUri: String, folderName: String, callback: (Result<CopySummaryMessage>) -> Unit) =
        submit("importTree", IMPORT_MS, callback) { call ->
            StoragePaths.requireName(folderName)
            if (folderName.startsWith(".")) {
                throw StorageException(StorageProblem.INVALID_PATH, "A project's name can't start with a dot.")
            }
            val ops = ops(treeUri, call)
            val projects = File(files, RuntimeHubs.PROJECTS)
            if (!projects.isDirectory && !projects.mkdirs() && !projects.isDirectory) {
                throw StorageException(StorageProblem.IO, "The projects' folder could not be made.")
            }
            fun taken() = projects.list()?.any { it.equals(folderName, ignoreCase = true) } == true
            if (taken()) throw StorageException(StorageProblem.EXISTS, "A project of that name is there.")
            val token = java.lang.Long.toHexString(System.nanoTime())
            // Hidden while it fills: the app's project list leaves dot names out.
            val staging = File(projects, ".import-$token")
            val parts = File(copies, "$STAGING/import-$token")
            try {
                copying(IMPORT, call) {
                    val summary = FolderCopy(
                        source = SafCopySource(ops),
                        target = staging,
                        manifestFile = null,
                        staging = parts,
                        limits = CopyLimits.IMPORT,
                        skipped = emptySet(),
                        parallelism = READERS,
                        stopped = { call.signal.isCanceled },
                        progress = { count, bytes -> post { events.copyProgress(IMPORT, count.toLong(), bytes) {} } },
                    ).sync()
                    if (summary.stopped) throw StorageException(StorageProblem.TIMEOUT, "The import was stopped.")
                    if (taken()) throw StorageException(StorageProblem.EXISTS, "A project of that name is there.")
                    try {
                        Files.move(staging.toPath(), File(projects, folderName).toPath())
                    } catch (clash: java.nio.file.FileAlreadyExistsException) {
                        throw StorageException(StorageProblem.EXISTS, "A project of that name is there.")
                    }
                    Log.i(TAG, "import: ${summary.copied} files in ${summary.elapsedMs} ms")
                    summary.toMessage()
                }
            } finally {
                FolderCopy.deleteTree(staging.toPath())
                FolderCopy.deleteTree(parts.toPath())
            }
        }

    /** Stops the threads and the watches; the engine and its Dart side are going away. */
    fun close() {
        pendingPick = null
        pendingSave = null
        watches.close()
        pool.shutdownNow()
        timer.shutdownNow()
    }

    /**
     * Operations on [treeUri] for a search's walk (Phase 4 W6, SearchHost),
     * which runs on its own threads and stops through [signal] and [cancel]:
     * the same grant check as every call here.
     */
    fun searchOps(treeUri: String, signal: CancellationSignal, cancel: Cancellation): DocumentOps {
        val uri = parseTree(treeUri)
        grantFor(uri) ?: throw StorageException(StorageProblem.ACCESS_LOST, "The app keeps no grant for that folder.")
        return DocumentOps(ResolverBackend(resolver, uri, signal), cacheFor(uri), cancel)
    }

    private fun ops(treeUri: String, call: Call, write: Boolean = false): DocumentOps {
        val uri = parseTree(treeUri)
        val grant = grantFor(uri)
            ?: throw StorageException(StorageProblem.ACCESS_LOST, "The app keeps no grant for that folder.")
        if (write && !grant.isWritePermission) {
            throw StorageException(StorageProblem.UNSUPPORTED, "The folder was granted for reading only.")
        }
        return DocumentOps(ResolverBackend(resolver, uri, call.signal), cacheFor(uri), call)
    }

    private fun treeMessage(uri: Uri, call: Call): TreeMessage {
        fun status(status: String) = TreeMessage(treeUri = uri.toString(), name = "", status = status, writable = false)
        val grant = grantFor(uri) ?: return status("accessLost")
        return try {
            val root = DocumentOps(ResolverBackend(resolver, uri, call.signal), cacheFor(uri), call).root()
            TreeMessage(
                treeUri = uri.toString(),
                name = root.name,
                status = "available",
                writable = grant.isWritePermission && root.has(DocFlags.DIR_SUPPORTS_CREATE),
            )
        } catch (error: Exception) {
            when (StorageErrors.classify(error).problem) {
                StorageProblem.MISSING, StorageProblem.NOT_FOUND -> status("missing")
                StorageProblem.ACCESS_LOST -> status("accessLost")
                else -> throw error
            }
        }
    }

    private fun keepGrant(uri: Uri, writable: Boolean) {
        val read = Intent.FLAG_GRANT_READ_URI_PERMISSION
        val write = Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        if (writable) {
            try {
                resolver.takePersistableUriPermission(uri, read or write)
            } catch (error: SecurityException) {
                resolver.takePersistableUriPermission(uri, read)
            }
        } else {
            resolver.takePersistableUriPermission(uri, read)
        }
        // Android caps how many grants an app keeps; W3 releases a folder's
        // grant when it leaves the recents.
        Log.i(TAG, "grants kept: ${treeGrants().size}")
    }

    private fun parseTree(treeUri: String): Uri {
        val uri = Uri.parse(treeUri)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT || !DocumentsContract.isTreeUri(uri)) {
            throw StorageException(StorageProblem.INVALID_PATH, "That is not a folder grant.")
        }
        return uri
    }

    private fun treeGrants(): List<UriPermission> =
        resolver.persistedUriPermissions.filter { DocumentsContract.isTreeUri(it.uri) }

    private fun grantFor(uri: Uri): UriPermission? =
        resolver.persistedUriPermissions.firstOrNull { it.uri == uri && it.isReadPermission }

    private fun cacheFor(uri: Uri): DocumentIdCache = caches.getOrPut(uri.toString()) { DocumentIdCache() }

    /** [copyId] when it is a copy's id ([FolderCopy.isCopyId]); INVALID_PATH otherwise. */
    private fun copyIdOf(copyId: String): String {
        if (!FolderCopy.isCopyId(copyId)) throw StorageException(StorageProblem.INVALID_PATH, "That is not a copy's id.")
        return copyId
    }

    private fun manifestOf(id: String) = File(copies, "$MANIFESTS/$id.tsv")

    private fun copyOf(id: String, source: CopySource) = FolderCopy(
        source = source,
        target = File(copies, id),
        manifestFile = manifestOf(id),
        staging = File(copies, "$STAGING/$id"),
    )

    /** Runs [work] as copy [id]: one at a time for a copy, and stoppable through [cancelCopy]. */
    private fun <T> copying(id: String, call: Call, work: () -> T): T =
        synchronized(copyLocks.getOrPut(id) { Any() }) {
            copying[id] = call
            try {
                work()
            } finally {
                copying.remove(id, call)
            }
        }

    private fun post(task: () -> Unit) {
        main.post { task() }
    }

    private fun entry(row: DocumentRow) = EntryMessage(
        name = row.name,
        isDirectory = row.isDirectory,
        size = row.size,
        modifiedMs = row.modifiedMs,
        flags = DocFlags.forDart(row),
    )

    /** Runs [work] off the main thread within [limitMs], and answers on the main thread exactly once. */
    private fun <T> submit(op: String, limitMs: Long, callback: (Result<T>) -> Unit, work: (Call) -> T) {
        val call = Call()
        val started = SystemClock.elapsedRealtime()
        val finish = { result: Result<T> ->
            if (call.finish()) {
                val outcome = result.exceptionOrNull()?.let { (it as? FlutterError)?.code ?: "error" } ?: "ok"
                val count = (result.getOrNull() as? List<*>)?.let { " (${it.size})" } ?: ""
                Log.i(TAG, "$op: $outcome$count in ${SystemClock.elapsedRealtime() - started} ms")
                main.post { callback(result) }
            }
        }
        val deadline = try {
            timer.schedule(
                Runnable {
                    call.signal.cancel()
                    finish(Result.failure(FlutterError(StorageProblem.TIMEOUT.code, "$op took longer than $limitMs ms.", null)))
                },
                limitMs,
                TimeUnit.MILLISECONDS,
            )
        } catch (error: RejectedExecutionException) {
            finish(Result.failure(FlutterError(StorageProblem.BUSY.code, "The broker is closed.", null)))
            return
        }
        try {
            pool.execute {
                try {
                    finish(Result.success(work(call)))
                } catch (error: Throwable) {
                    val failure = StorageErrors.classify(error)
                    finish(Result.failure(FlutterError(failure.problem.code, failure.message, null)))
                } finally {
                    deadline.cancel(false)
                }
            }
        } catch (error: RejectedExecutionException) {
            deadline.cancel(false)
            finish(Result.failure(FlutterError(StorageProblem.BUSY.code, "Too many storage calls at once.", null)))
        }
    }

    /** A save waiting for the create-document picker: what to write, and who asked. */
    private class PendingSave(val bytes: ByteArray, val callback: (Result<String?>) -> Unit)

    /** One call: its cancellation, and whether it has answered. */
    private class Call : Cancellation {
        val signal = CancellationSignal()
        private val answered = AtomicBoolean(false)

        fun finish(): Boolean = answered.compareAndSet(false, true)

        override fun check() {
            if (signal.isCanceled) {
                throw StorageException(StorageProblem.TIMEOUT, "The call took too long.")
            }
        }
    }

    private companion object {
        const val TAG = "CodeForgeStorage"
        const val REQUEST_PICK_TREE = 0x5AF0
        const val REQUEST_SAVE_DOCUMENT = 0x5AF1
        const val THREADS = 4
        const val QUEUE = 64

        // Time limits per call. Dart waits 5 s longer
        // (lib/services/files/native/pigeon_storage_broker.dart).
        const val QUICK_MS = 10_000L
        const val LIST_MS = 20_000L
        const val TRANSFER_MS = 30_000L
        const val CHANGE_MS = 20_000L
        const val COPY_MS = 120_000L

        /** A folder's run copy: the first of a large folder takes minutes (ADR-0013). */
        const val SYNC_MS = 15 * 60_000L

        /** Importing a folder as a project: everything, once. */
        const val IMPORT_MS = 60 * 60_000L

        /** Files a copy reads at once through its provider, as the search's scan does. */
        const val READERS = 4

        /** Beside the copies, in the copies' folder: their manifests, and files on their way in. */
        const val MANIFESTS = ".manifests"
        const val STAGING = ".staging"

        /** The copy id an import's progress and cancel use. */
        const val IMPORT = "import"

        fun threads(name: String): ThreadFactory {
            val count = AtomicInteger()
            return ThreadFactory { task ->
                Thread(task, "$name-${count.incrementAndGet()}").apply { isDaemon = true }
            }
        }
    }
}

private fun CopySummary.toMessage() = CopySummaryMessage(
    files = files.toLong(),
    bytes = bytes,
    copied = copied.toLong(),
    bytesCopied = bytesCopied,
    unchanged = unchanged.toLong(),
    removed = removed.toLong(),
    leftOutLarge = leftOutLarge.toLong(),
    leftOutFull = leftOutFull.toLong(),
    leftOutVirtual = leftOutVirtual.toLong(),
    leftOutDeep = leftOutDeep.toLong(),
    skipped = skipped.toLong(),
    unreadable = unreadable.toLong(),
    capped = capped,
    stopped = stopped,
    elapsedMs = elapsedMs,
)
