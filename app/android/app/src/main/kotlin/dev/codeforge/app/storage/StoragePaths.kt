package dev.codeforge.app.storage

/**
 * Paths inside a granted folder, checked on the Kotlin side whatever Dart
 * sent (docs/SECURITY.md §4.1, S1).
 *
 * A path is '' (the granted folder itself) or names joined by '/'. A name
 * is never empty, '.' or '..', holds no '/', NUL or other control
 * character, and takes at most 255 bytes in UTF-8. Dart applies stricter
 * rules first (lib/core/files/workspace_path.dart); these are the ones the
 * broker never does without. Pure Kotlin: JVM-tested (StoragePathsTest).
 */
object StoragePaths {
    const val MAX_NAME_BYTES = 255
    const val MAX_PATH_CHARS = 4096
    const val MAX_DEPTH = 128

    /** Why [name] is not a valid name, or null when it is. */
    fun nameProblem(name: String): String? {
        if (name.isEmpty()) {
            return "A name can't be empty."
        }
        if (name == "." || name == "..") {
            return "A name can't be '.' or '..'."
        }
        for (c in name) {
            if (c == '/') {
                return "A name can't hold '/'."
            }
            if (c.code < 0x20 || c.code == 0x7F) {
                return "A name can't hold control characters."
            }
        }
        if (name.toByteArray(Charsets.UTF_8).size > MAX_NAME_BYTES) {
            return "A name can take at most $MAX_NAME_BYTES bytes."
        }
        return null
    }

    fun isValidName(name: String): Boolean = nameProblem(name) == null

    /** The names in [path], in order; [StorageProblem.INVALID_PATH] otherwise. */
    fun parse(path: String): List<String> {
        if (path.isEmpty()) {
            return emptyList()
        }
        if (path.length > MAX_PATH_CHARS) {
            throw StorageException(StorageProblem.INVALID_PATH, "The path is too long.")
        }
        val names = path.split('/')
        if (names.size > MAX_DEPTH) {
            throw StorageException(StorageProblem.INVALID_PATH, "The path is too deep.")
        }
        for (name in names) {
            nameProblem(name)?.let { throw StorageException(StorageProblem.INVALID_PATH, it) }
        }
        return names
    }

    /** [name] checked as a name; [StorageProblem.INVALID_PATH] otherwise. */
    fun requireName(name: String): String {
        nameProblem(name)?.let { throw StorageException(StorageProblem.INVALID_PATH, it) }
        return name
    }

    fun join(parent: String, name: String): String = if (parent.isEmpty()) name else "$parent/$name"

    fun joinAll(names: List<String>): String = names.joinToString("/")

    /** Whether [path] is [ancestor] or lies inside it. */
    fun isWithin(path: String, ancestor: String): Boolean =
        ancestor.isEmpty() || path == ancestor || path.startsWith("$ancestor/")
}
