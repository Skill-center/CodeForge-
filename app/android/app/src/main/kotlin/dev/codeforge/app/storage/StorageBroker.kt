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
import java.io.FileNotFoundException
import java.io.OutputStream
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
 * Logs name the call, its outcome and its duration: never a URI, a path
 * or a file name.
 */
class StorageBroker(private val activity: Activity) : StorageApi {
    private val resolver: ContentResolver = activity.applicationContext.contentResolver
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

    /** Stops the threads; the engine and its Dart side are going away. */
    fun close() {
        pendingPick = null
        pendingSave = null
        pool.shutdownNow()
        timer.shutdownNow()
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

        fun threads(name: String): ThreadFactory {
            val count = AtomicInteger()
            return ThreadFactory { task ->
                Thread(task, "$name-${count.incrementAndGet()}").apply { isDaemon = true }
            }
        }
    }
}
