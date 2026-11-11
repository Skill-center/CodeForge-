package dev.codeforge.app.storage

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.io.InputStream
import java.io.OutputStream
import java.util.Locale

/**
 * An in-memory documents provider with the quirks of Android's own
 * (FileSystemProvider and ExternalStorageProvider in AOSP), for the
 * broker's JVM tests:
 *
 * - document ids are paths ("primary:Documents/cf-gate/src/main.js"), so a
 *   rename or a move changes them, and an id is looked up without case on
 *   storage that ignores case, as a File would be;
 * - create and rename make names FAT-safe (`buildValidFatFilename`: '_' for
 *   `"*:<>?\|`, control characters and DEL) and unique (`buildUniqueFile`:
 *   " (1)", " (2)"… before the extension), comparing without case when
 *   [caseInsensitive];
 * - move refuses a name the destination has (IllegalStateException), delete
 *   takes a folder with everything in it, nothing offers FLAG_SUPPORTS_COPY;
 * - files dated before 1971 list no modified time.
 */
class FakeProvider(
    private val caseInsensitive: Boolean = true,
    rootPath: String = "Documents/cf-gate",
) : DocumentBackend {
    class Node(
        var name: String,
        val isDirectory: Boolean,
        var bytes: ByteArray = ByteArray(0),
        var modifiedMs: Long = 0,
        var writable: Boolean = true,
    ) {
        var parent: Node? = null
        val children = mutableListOf<Node>()
    }

    private val volume = Node("", isDirectory = true)
    private var clock = 1_700_000_000_000L

    /** Every provider call, in order: "query", "children", "create", "rename", "move", "delete", "read", "write". */
    val calls = mutableListOf<String>()

    /** Whether documents offer FLAG_SUPPORTS_MOVE. */
    var supportsMove = true

    /** Whether "wt" truncates; false leaves old bytes behind a shorter write, as plain "w" may. */
    var truncates = true

    /** A size every query reports instead of the true one. */
    var listedSize: Long? = null

    /** Reads never end. */
    var endless = false

    val root: Node = mkdirs(rootPath)
    override val rootId: String = idOf(root)

    fun idOf(node: Node): String = "primary:" + pathOf(node)

    fun pathOf(node: Node): String {
        val names = ArrayDeque<String>()
        var current: Node? = node
        while (current != null && current !== volume) {
            names.addFirst(current.name)
            current = current.parent
        }
        return names.joinToString("/")
    }

    /** The node at [path] under the granted folder, exact names; null if none. */
    fun at(path: String): Node? {
        var current = root
        if (path.isEmpty()) return current
        for (name in path.split('/')) {
            current = current.children.firstOrNull { it.name == name } ?: return null
        }
        return current
    }

    fun file(path: String, text: String, modifiedMs: Long = tick()): Node = file(path, text.toByteArray(), modifiedMs)

    fun file(path: String, bytes: ByteArray, modifiedMs: Long = tick()): Node {
        val parentPath = path.substringBeforeLast('/', "")
        val parent = if (parentPath.isEmpty()) root else mkdirs(pathOf(root) + "/" + parentPath)
        val node = Node(path.substringAfterLast('/'), isDirectory = false, bytes = bytes, modifiedMs = modifiedMs)
        attach(parent, node)
        return node
    }

    fun folder(path: String): Node = mkdirs(pathOf(root) + "/" + path)

    /** A child added as-is, for names Android's own provider would never make. */
    fun raw(parent: Node, name: String, directory: Boolean = false): Node =
        Node(name, directory, modifiedMs = tick()).also { attach(parent, it) }

    fun text(path: String): String? = at(path)?.bytes?.toString(Charsets.UTF_8)

    /** Removes the granted folder, as another app deleting it would. */
    fun deleteRoot() {
        root.parent?.children?.remove(root)
        root.parent = null
    }

    override fun query(id: String): DocumentRow? {
        calls += "query"
        return find(id)?.let(::row)
    }

    override fun children(id: String, limit: Int): List<DocumentRow>? {
        calls += "children"
        val node = find(id) ?: return null
        return node.children.take(limit).map(::row)
    }

    override fun create(parentId: String, name: String, directory: Boolean): String {
        calls += "create"
        val parent = find(parentId) ?: throw FileNotFoundException("no parent")
        require(parent.isDirectory) { "Parent document isn't a directory" }
        val node = Node(unique(parent, fatSafe(name), self = null), directory, modifiedMs = tick())
        attach(parent, node)
        return idOf(node)
    }

    override fun rename(id: String, name: String): String {
        calls += "rename"
        val node = find(id) ?: throw FileNotFoundException("no document")
        node.name = unique(node.parent!!, fatSafe(name), self = null)
        return idOf(node)
    }

    override fun move(id: String, fromParentId: String, toParentId: String): String {
        calls += "move"
        val node = find(id) ?: throw FileNotFoundException("no document")
        val target = find(toParentId) ?: throw FileNotFoundException("no target")
        check(target.children.none { same(it.name, node.name) }) { "Already exists" }
        node.parent!!.children.remove(node)
        attach(target, node)
        return idOf(node)
    }

    override fun delete(id: String) {
        calls += "delete"
        val node = find(id) ?: throw FileNotFoundException("no document")
        node.parent!!.children.remove(node)
        node.parent = null
    }

    override fun openRead(id: String): InputStream {
        calls += "read"
        val node = find(id) ?: throw FileNotFoundException("no document")
        if (endless) {
            return object : InputStream() {
                override fun read(): Int = 'x'.code
            }
        }
        return ByteArrayInputStream(node.bytes)
    }

    override fun openWrite(id: String): OutputStream {
        calls += "write"
        val node = find(id) ?: throw FileNotFoundException("no document")
        return object : ByteArrayOutputStream() {
            override fun close() {
                val written = toByteArray()
                node.bytes = if (truncates || written.size >= node.bytes.size) {
                    written
                } else {
                    written + node.bytes.copyOfRange(written.size, node.bytes.size)
                }
                node.modifiedMs = tick()
            }
        }
    }

    private fun row(node: Node): DocumentRow {
        var flags = 0
        if (node.writable) {
            flags = flags or DocFlags.SUPPORTS_DELETE or DocFlags.SUPPORTS_RENAME
            if (supportsMove) flags = flags or DocFlags.SUPPORTS_MOVE
            flags = flags or if (node.isDirectory) DocFlags.DIR_SUPPORTS_CREATE else DocFlags.SUPPORTS_WRITE
        }
        return DocumentRow(
            id = idOf(node),
            name = node.name,
            isDirectory = node.isDirectory,
            size = if (node.isDirectory) 0 else listedSize ?: node.bytes.size.toLong(),
            // Only publish dates reasonably after epoch (FileSystemProvider).
            modifiedMs = node.modifiedMs.takeIf { it > 31_536_000_000L },
            flags = flags,
        )
    }

    /** The node a path-based id names, looked up as a File would be. */
    private fun find(id: String): Node? {
        if (!id.startsWith("primary:")) return null
        var current = volume
        val path = id.removePrefix("primary:")
        if (path.isEmpty()) return current
        for (name in path.split('/')) {
            current = current.children.firstOrNull { same(it.name, name) } ?: return null
        }
        return current
    }

    private fun mkdirs(path: String): Node {
        var current = volume
        for (name in path.split('/').filter { it.isNotEmpty() }) {
            current = current.children.firstOrNull { it.name == name }
                ?: Node(name, isDirectory = true, modifiedMs = tick()).also { attach(current, it) }
        }
        return current
    }

    private fun attach(parent: Node, node: Node) {
        node.parent = parent
        parent.children += node
    }

    private fun same(a: String, b: String): Boolean =
        if (caseInsensitive) a.lowercase(Locale.ROOT) == b.lowercase(Locale.ROOT) else a == b

    private fun unique(parent: Node, name: String, self: Node?): String {
        val dot = name.lastIndexOf('.')
        val base = if (dot >= 0) name.substring(0, dot) else name
        val extension = if (dot >= 0) name.substring(dot) else ""
        var candidate = name
        var n = 0
        while (parent.children.any { it !== self && same(it.name, candidate) }) {
            n += 1
            candidate = "$base ($n)$extension"
        }
        return candidate
    }

    private fun tick(): Long {
        clock += 1_000
        return clock
    }

    companion object {
        /** FileUtils.buildValidFatFilename. */
        fun fatSafe(name: String): String {
            if (name.isEmpty() || name == "." || name == "..") return "(invalid)"
            return buildString {
                for (c in name) {
                    append(if (c.code < 0x20 || c.code == 0x7F || c in "\"*/:<>?\\|") '_' else c)
                }
            }
        }
    }
}
