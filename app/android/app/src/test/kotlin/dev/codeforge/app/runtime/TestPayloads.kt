package dev.codeforge.app.runtime

import dev.codeforge.runtime.core.HarnessConfig
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.security.MessageDigest
import java.util.Random
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * A synthetic sealed payload in the shape runtime/build-sealed-payload.py
 * writes (the userland zip, its manifest, the exec and symlink lists, the
 * identity, runtime-info), for the runtime host's JVM tests.
 */
class TestPayload(
    val abi: String = "x86_64",
    val identity: String? = "0123456789abcdef",
    val files: Map<String, ByteArray> = DEFAULT_FILES,
    val executables: Map<String, String> = DEFAULT_EXECUTABLES,
    val links: Map<String, String> = DEFAULT_LINKS,
    /** Manifest entries the zip does not carry: an incomplete payload. */
    val manifestExtra: Map<String, ByteArray> = emptyMap(),
    /** A file whose manifest digest is not its bytes'. */
    val wrongDigestFor: String? = null,
) {
    val assets: Map<String, ByteArray> = mapOf(
        "userland-$abi.zip" to zip(),
        "sealed-manifest-$abi.txt" to manifest().toByteArray(Charsets.UTF_8),
        "sealed-exec-$abi.txt" to table(EXEC_HEADER, executables).toByteArray(Charsets.UTF_8),
        "sealed-symlinks-$abi.txt" to table(LINKS_HEADER, links).toByteArray(Charsets.UTF_8),
        "runtime-info-$abi.json" to "{\"abi\": \"$abi\", \"bootstrap\": \"test\"}\n".toByteArray(Charsets.UTF_8),
    )

    /** The bytes of every regular file the payload installs. */
    val bytes: Long get() = files.values.sumOf { it.size.toLong() }

    /** This payload as a source; [transform] changes an asset on its way out. */
    fun source(
        abi: String? = this.abi,
        transform: (String, ByteArray) -> ByteArray = { _, data -> data },
    ): PayloadSource = MapPayloadSource(abi, identity, assets.mapValues { (name, data) -> transform(name, data) })

    private fun zip(): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((path, data) in files) {
                zip.putNextEntry(ZipEntry(path))
                zip.write(data)
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    private fun manifest(): String {
        val text = StringBuilder("# sha256\tsize\tprefix-relative path\n")
        for ((path, data) in files + manifestExtra) {
            val digest = if (path == wrongDigestFor) "0".repeat(64) else sha256(data)
            text.append(digest).append('\t').append(data.size).append('\t').append(path).append('\n')
        }
        return text.toString()
    }

    companion object {
        private const val EXEC_HEADER = "# prefix-relative executable path\tJNI library (shipped by the APK)\n"
        private const val LINKS_HEADER = "# prefix-relative link\tprefix-relative target (data, created at install)\n"

        /** ELF's magic, so the audit sees an executable. */
        val ELF: ByteArray = byteArrayOf(0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0)

        /**
         * The first file is 64 KiB that does not compress, so the middle of
         * the archive always falls inside its data.
         */
        val DEFAULT_FILES: Map<String, ByteArray> = linkedMapOf(
            "share/blob.bin" to ByteArray(64 * 1024).also { Random(7).nextBytes(it) },
            "etc/profile" to "export PS1='> '\n".toByteArray(Charsets.UTF_8),
            "lib/libfoo.so.1" to ELF + "foo".toByteArray(Charsets.UTF_8),
        )

        val DEFAULT_EXECUTABLES: Map<String, String> = linkedMapOf(
            "bin/sh" to "libsh.so",
            "bin/tool" to "libtool.so",
        )

        val DEFAULT_LINKS: Map<String, String> = linkedMapOf("lib/libfoo.so" to "lib/libfoo.so.1")

        /** The APK's native library directory: one library per executable. */
        fun writeLibraries(directory: File, executables: Map<String, String> = DEFAULT_EXECUTABLES) {
            directory.mkdirs()
            for (library in executables.values) {
                File(directory, library).writeBytes(ELF + library.toByteArray(Charsets.UTF_8))
            }
        }

        /** The layout t1's HarnessPaths gives a harness root. */
        fun configFor(root: File, nativeLibraries: File): HarnessConfig {
            val rootfs = File(root, "rootfs")
            val prefix = File(rootfs, "data/data/com.termux/files/usr")
            return HarnessConfig.Builder()
                .workspace(File(root, "workspace"))
                .home(File(root, "home"))
                .prefix(prefix)
                .rootfs(rootfs)
                .toolDirectory(File(prefix, "bin"))
                .libraryDirectory(File(prefix, "lib"))
                .nativeLibraryDirectory(nativeLibraries)
                .build()
        }

        /** [data] with the byte at [offset] inverted. */
        fun flip(data: ByteArray, offset: Int): ByteArray =
            data.copyOf().also { it[offset] = (it[offset].toInt() xor 0xff).toByte() }

        fun sha256(data: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

        private fun table(header: String, rows: Map<String, String>): String =
            header + rows.entries.joinToString("") { (path, value) -> "$path\t$value\n" }
    }
}

/** A payload held in memory. */
class MapPayloadSource(
    private val abi: String?,
    private val identity: String?,
    private val files: Map<String, ByteArray>,
) : PayloadSource {
    override fun abi(): String? = abi

    override fun identity(abi: String): String? = identity

    override fun open(name: String): InputStream =
        ByteArrayInputStream(files[name] ?: throw FileNotFoundException(name))
}
