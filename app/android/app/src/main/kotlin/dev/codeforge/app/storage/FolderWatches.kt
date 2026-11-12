package dev.codeforge.app.storage

import android.content.ContentResolver
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.DocumentsContract
import android.util.Log

/**
 * Change notices for folders in granted trees (Phase 3 W5,
 * docs/EDITOR_ARCHITECTURE.md §6).
 *
 * A documents provider tells whoever holds one of its cursors when the
 * rows behind it change. Android's file-system provider watches a folder
 * with inotify for as long as a cursor over its children is open
 * (FileSystemProvider.DirectoryCursor), so a watch here is such a query
 * kept open, with an observer on its cursor: the way Android's own file
 * manager keeps a folder current. Notices for one watch gather for
 * [GATHER_MS] before Dart hears of them, and Dart gathers them again
 * across folders. A provider that sends nothing costs one open cursor:
 * Dart still compares open files with their stamps every few seconds.
 *
 * Logs count watches; they never name a folder.
 */
class FolderWatches(
    private val resolver: ContentResolver,
    /** Tells Dart that a watch's folder changed; called on the main thread. */
    private val notify: (Long) -> Unit,
) {
    private val thread = HandlerThread("codeforge-storage-watch").apply { start() }
    private val handler = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private val watches = HashMap<Long, Watch>()
    private var closed = false

    /**
     * Opens the children query of the folder [folderId] in [treeUri] and
     * watches it as [id], replacing an older watch with that id. False when
     * the provider gave no cursor. Runs on a broker thread: the query may
     * take a while.
     */
    fun start(id: Long, treeUri: Uri, folderId: String, signal: CancellationSignal): Boolean {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, folderId)
        val cursor = resolver.query(uri, PROJECTION, null, null, null, signal) ?: return false
        val watch = Watch(id, cursor)
        cursor.registerContentObserver(watch)
        var accepted = false
        var previous: Watch? = null
        synchronized(this) {
            if (!closed) {
                accepted = true
                previous = watches.put(id, watch)
            }
        }
        if (!accepted) {
            watch.close()
            return false
        }
        previous?.close()
        Log.i(TAG, "watches: ${count()}")
        return true
    }

    /** Stops [id]'s notices and closes its query; an unknown id is ignored. */
    fun stop(id: Long) {
        val watch = synchronized(this) { watches.remove(id) } ?: return
        // Closing a cursor is a call into the provider: not on the main thread.
        handler.post { watch.close() }
    }

    /** Stops every watch: the engine and its Dart side are going away. */
    fun close() {
        val all = synchronized(this) {
            closed = true
            val open = watches.values.toList()
            watches.clear()
            open
        }
        handler.post {
            all.forEach { it.close() }
            thread.quitSafely()
        }
    }

    private fun count(): Int = synchronized(this) { watches.size }

    private fun isCurrent(watch: Watch): Boolean = synchronized(this) { watches[watch.id] === watch }

    /** One folder's open query and the observer on it. */
    private inner class Watch(val id: Long, private val cursor: Cursor) : ContentObserver(handler) {
        /** A notice is on its way to Dart, and later ones join it. Only [handler]'s thread touches it. */
        private var pending = false

        override fun deliverSelfNotifications(): Boolean = true

        override fun onChange(selfChange: Boolean) {
            if (pending) {
                return
            }
            pending = true
            handler.postDelayed(
                {
                    pending = false
                    if (isCurrent(this)) {
                        main.post { notify(id) }
                    }
                },
                GATHER_MS,
            )
        }

        fun close() {
            try {
                cursor.unregisterContentObserver(this)
            } catch (error: IllegalStateException) {
                // Never registered, or already gone with the cursor.
            }
            cursor.close()
        }
    }

    private companion object {
        const val TAG = "CodeForgeStorage"

        /** How long one folder's notices gather before Dart hears of them. */
        const val GATHER_MS = 100L

        val PROJECTION = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
    }
}
