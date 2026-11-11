package dev.codeforge.app.storage

import java.io.FileNotFoundException
import java.io.IOException

/**
 * Why a storage call failed. [code] travels to Dart as the FlutterError's
 * code, where lib/services/files/native/pigeon_storage_broker.dart maps it
 * to a FileProblem.
 */
enum class StorageProblem(val code: String) {
    INVALID_PATH("invalid_path"),
    NOT_FOUND("not_found"),
    EXISTS("exists"),
    WRONG_TYPE("wrong_type"),

    /** The file is not what the caller read: saving would lose that. */
    CHANGED("changed"),
    TOO_LARGE("too_large"),

    /** No grant for the folder, or the provider refused it. */
    ACCESS_LOST("access_lost"),

    /** The granted folder itself is gone. */
    MISSING("missing"),

    /** A document outside the granted folder (Android's own check). */
    OUTSIDE("outside"),
    TIMEOUT("timeout"),
    BUSY("busy"),
    UNSUPPORTED("unsupported"),

    /** The provider gave a new item another name than the one asked for. */
    NAME_CHANGED("name_changed"),

    /** Several entries of one folder share the name. */
    AMBIGUOUS("ambiguous"),
    IO("io"),
}

/**
 * A storage call's failure. The message is for developers and never holds
 * a URI (docs/SECURITY.md §4.1, S5); Dart words what the user reads.
 */
class StorageException(
    val problem: StorageProblem,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

object StorageErrors {
    /**
     * What a provider's exception means. Android's DocumentsContract
     * rethrows what the provider threw: SecurityException for a missing
     * grant or a document outside the tree, FileNotFoundException for a
     * missing document, IllegalStateException when a file system step
     * failed. Their messages can name files, so none is passed on.
     */
    fun classify(error: Throwable): StorageException = when (error) {
        is StorageException -> error
        is SecurityException ->
            if (error.message?.contains("descendant") == true) {
                StorageException(StorageProblem.OUTSIDE, "The provider refused a document outside the folder.", error)
            } else {
                StorageException(StorageProblem.ACCESS_LOST, "The provider refused access to the folder.", error)
            }
        is FileNotFoundException -> StorageException(StorageProblem.NOT_FOUND, "The document is not there.", error)
        is UnsupportedOperationException ->
            StorageException(StorageProblem.UNSUPPORTED, "The provider does not support that.", error)
        is IOException -> StorageException(StorageProblem.IO, "The provider failed (${error.javaClass.simpleName}).", error)
        else -> StorageException(StorageProblem.IO, "The provider refused (${error.javaClass.simpleName}).", error)
    }
}

/** Throws [StorageProblem.TIMEOUT] once the call's time is up. */
fun interface Cancellation {
    fun check()

    companion object {
        val NONE = Cancellation {}
    }
}
