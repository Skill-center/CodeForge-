package dev.codeforge.app.storage

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.webkit.MimeTypeMap
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.Locale

/**
 * [DocumentBackend] over Android's ContentResolver for one granted tree.
 * Every document is reached through a tree-based document URI
 * (`buildDocumentUriUsingTree`), so Android's DocumentsProvider checks it
 * against the grant on every call (docs/SECURITY.md §4.1, S2). Queries and
 * file opens carry the call's [signal], which the broker cancels when the
 * call's time is up.
 */
class ResolverBackend(
    private val resolver: ContentResolver,
    private val treeUri: Uri,
    private val signal: CancellationSignal,
) : DocumentBackend {
    override val rootId: String = DocumentsContract.getTreeDocumentId(treeUri)

    private fun uri(id: String): Uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)

    override fun query(id: String): DocumentRow? = guarded {
        try {
            resolver.query(uri(id), PROJECTION, null, null, null, signal)?.use { cursor ->
                if (cursor.moveToFirst()) row(cursor) else null
            }
        } catch (error: IllegalArgumentException) {
            // Android's file-system provider says so for a document whose
            // folder is gone ("Failed to determine if ... is child of ...").
            null
        }
    }

    override fun children(id: String, limit: Int): List<DocumentRow>? = guarded {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, id)
        try {
            resolver.query(uri, PROJECTION, null, null, null, signal)?.use { cursor ->
                val rows = ArrayList<DocumentRow>(minOf(cursor.count.coerceAtLeast(0), limit))
                while (rows.size < limit && cursor.moveToNext()) {
                    signal.throwIfCanceled()
                    rows += row(cursor)
                }
                rows
            }
        } catch (error: IllegalArgumentException) {
            null
        }
    }

    override fun create(parentId: String, name: String, directory: Boolean): String = guarded {
        val mime = if (directory) Document.MIME_TYPE_DIR else mimeTypeFor(name)
        val created = DocumentsContract.createDocument(resolver, uri(parentId), mime, name)
            ?: throw StorageException(StorageProblem.IO, "The provider did not create it.")
        DocumentsContract.getDocumentId(created)
    }

    override fun rename(id: String, name: String): String = guarded {
        val renamed = DocumentsContract.renameDocument(resolver, uri(id), name)
            ?: throw StorageException(StorageProblem.IO, "The provider did not rename it.")
        DocumentsContract.getDocumentId(renamed)
    }

    override fun move(id: String, fromParentId: String, toParentId: String): String = guarded {
        val moved = DocumentsContract.moveDocument(resolver, uri(id), uri(fromParentId), uri(toParentId))
            ?: throw StorageException(StorageProblem.IO, "The provider did not move it.")
        DocumentsContract.getDocumentId(moved)
    }

    override fun delete(id: String) = guarded {
        if (!DocumentsContract.deleteDocument(resolver, uri(id))) {
            throw StorageException(StorageProblem.IO, "The provider did not delete it.")
        }
    }

    override fun openRead(id: String): InputStream = guarded {
        val descriptor = resolver.openFileDescriptor(uri(id), "r", signal)
            ?: throw StorageException(StorageProblem.IO, "The provider did not open the file.")
        ParcelFileDescriptor.AutoCloseInputStream(descriptor)
    }

    override fun openWrite(id: String): OutputStream = guarded {
        // "wt", not "w": plain "w" can leave old bytes behind a shorter
        // write on some Android versions.
        val descriptor = resolver.openFileDescriptor(uri(id), "wt", signal)
            ?: throw StorageException(StorageProblem.IO, "The provider did not open the file.")
        SyncingOutputStream(descriptor)
    }

    /** Flushes the bytes to the device before closing, where the provider gave a real file. */
    private class SyncingOutputStream(descriptor: ParcelFileDescriptor) :
        ParcelFileDescriptor.AutoCloseOutputStream(descriptor) {
        override fun close() {
            try {
                fd.sync()
            } catch (_: IOException) {
                // A pipe from a provider that streams: nothing to sync here.
            }
            super.close()
        }
    }

    private companion object {
        val PROJECTION = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
        )

        fun row(cursor: Cursor): DocumentRow {
            fun long(index: Int): Long? = if (cursor.isNull(index)) null else cursor.getLong(index)
            return DocumentRow(
                id = cursor.getString(0) ?: "",
                name = cursor.getString(1) ?: "",
                isDirectory = cursor.getString(2) == Document.MIME_TYPE_DIR,
                size = long(3),
                modifiedMs = long(4),
                flags = if (cursor.isNull(5)) 0 else cursor.getInt(5),
            )
        }

        /**
         * The type a new file is created with. Android's file-system provider
         * keeps the name exactly when the type is the one its extension maps
         * to, or the generic binary type; any other type gets an extension
         * added ("Makefile" as text/plain becomes "Makefile.txt").
         */
        fun mimeTypeFor(name: String): String {
            val dot = name.lastIndexOf('.')
            val extension = if (dot >= 0) name.substring(dot + 1).lowercase(Locale.ROOT) else ""
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                ?: "application/octet-stream"
        }

        /** The call's time ran out while Android was working: the call's own answer. */
        inline fun <T> guarded(work: () -> T): T = try {
            work()
        } catch (error: OperationCanceledException) {
            throw StorageException(StorageProblem.TIMEOUT, "The provider took too long.", error)
        }
    }
}
