package dev.codeforge.app.runtime

import dev.codeforge.runtime.core.HarnessConfig
import dev.codeforge.runtime.core.exec.SealedPayloadInstaller
import dev.codeforge.runtime.sealed.ExecAudit
import dev.codeforge.runtime.sealed.PayloadExtractor
import dev.codeforge.runtime.sealed.SealedInstaller
import dev.codeforge.runtime.sealed.SealedLayout
import dev.codeforge.runtime.sealed.SealedUninstaller
import java.io.ByteArrayInputStream
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
import java.util.Properties
import java.util.zip.ZipException

/** Why the runtime is not usable, or not healthy. Each code travels to Dart. */
enum class RuntimeProblem(val code: String) {
    /** This APK carries no runtime for the device's ABI. */
    NO_PAYLOAD("no_payload"),

    /** A file differs from its manifest, or the payload archive is damaged. */
    CORRUPT("corrupt"),

    /** The payload lacks files its manifest lists. */
    INCOMPLETE("incomplete"),

    /** The device could not store the runtime: no space, or a write failed. */
    STORAGE("storage"),

    /** The APK lacks an executable the payload's exec manifest names. */
    MISSING_EXECUTABLES("missing_executables"),

    /** The audit found executables outside the APK (degraded, not failed). */
    OUTSIDE_APK("outside_apk"),

    /** The audit could not walk the whole prefix (degraded, not failed). */
    AUDIT_INCOMPLETE("audit_incomplete"),

    UNEXPECTED("unexpected"),
}

/** A typed failure of the runtime: what Dart shows, and what the gate checks. */
class RuntimeFailure(
    val problem: RuntimeProblem,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/** Files written so far, and in all, while installing. Called on the worker. */
fun interface ProgressListener {
    fun onProgress(done: Int, total: Int)
}

/** One pass of t1's ExecAudit over the prefix. */
data class AuditResult(
    /** ELF executables outside the APK: 0 is the only healthy count. */
    val outsideApk: Int,
    /** Scripts outside the APK (run through their interpreter, never exec'd). */
    val outsideScripts: Int,
    /** Executables that resolve into the APK's native library directory. */
    val shipped: Int,
    val scanned: Int,
    val truncated: Boolean,
    /** Why the walk could not run at all, or null. */
    val failure: String?,
    val millis: Long,
    /** ExecAudit's own report, for Settings > Runtime and exec-audit.txt. */
    val report: String,
) {
    val clean: Boolean get() = outsideApk == 0 && !truncated && failure == null
}

/** What the runtime occupies on the device. */
data class RuntimeSizes(
    /** The prefix's regular files, each inode once (symlinks not followed). */
    val prefixBytes: Long,
    val prefixFiles: Int,
    /** The native library directory: the executables Android extracted, and the app's own. */
    val nativeLibraryBytes: Long,
    /** The APK itself (with its splits). */
    val apkBytes: Long,
)

/**
 * The sealed runtime on this device (Phase 4 W3; docs/RUNTIME_INTEGRATION.md
 * §3): it installs this APK's payload into the prefix, starts an earlier
 * install again without extracting anything, and audits the prefix.
 *
 * Blocking, and not thread-safe: one worker thread calls it (RuntimeHub). It
 * uses no Android or Flutter type, so the JVM tests drive it whole over a
 * synthetic payload; the device's payload comes through [AssetPayloadSource].
 *
 * It is a thin adapter over t1's kernel, the shape t1 describes for a host
 * that consumes it (SealedPayloadInstaller's class comment): the kernel's
 * SealedInstaller extracts, verifies and links, and this class adds the four
 * things CodeForge needs around it. Progress for each file. An install marker,
 * written only after everything verified, so an unchanged payload is never
 * extracted twice and a failed or half-finished install is never taken for a
 * ready one. Exact removal of what the previous install wrote
 * (SealedUninstaller), so a changed payload leaves nothing stale behind. And a
 * warm start that applies the executables' layout again: Android gives an
 * updated app a new native library directory, and the links follow it.
 *
 * The four invariants hold because the kernel holds them: executables are
 * symlinks into the native library directory (SealedLayout), every file is
 * verified while it is written (PayloadExtractor), dependencies were resolved
 * by version when the payload was built (runtime/pins.json), and the
 * interpreters' environment comes with the commands (Phase 4 W4).
 */
class SealedRuntime(
    private val source: PayloadSource,
    private val config: HarnessConfig,
    private val clock: () -> Long = System::nanoTime,
    private val freeSpace: (File) -> Long = { it.usableSpace },
) {
    /** The payload this APK carries for the device. */
    data class Payload(val abi: String, val identity: String?, val info: String?)

    /** A finished install of this APK's payload. */
    data class Installed(val abi: String, val identity: String, val installedAtMs: Long, val installMs: Long)

    data class WarmStart(val millis: Long, val relinked: Int)

    data class InstallResult(
        val millis: Long,
        val files: Int,
        val verified: Int,
        val bytes: Long,
        val links: Int,
        val executables: Int,
    )

    val prefix: File get() = config.prefix

    /** The harness root (HarnessPaths): the prefix's rootfs sits in it. */
    private val root: File = config.rootfs?.parentFile ?: config.prefix.parentFile
    private val state = File(root, "codeforge")
    private val marker = File(state, "installed.properties")
    private val savedManifest = File(state, "installed-manifest.txt")
    private val savedExec = File(state, "installed-exec.txt")
    private val auditFile = File(state, "exec-audit.txt")

    private var payloadRead = false
    private var payload: Payload? = null

    /** What this APK carries for the device, or null (read once). */
    fun payload(): Payload? {
        if (!payloadRead) {
            payload = source.abi()?.let { abi -> Payload(abi, source.identity(abi), readInfo(abi)) }
            payloadRead = true
        }
        return payload
    }

    /** The finished install of this APK's payload, or null when there is none. */
    fun installed(): Installed? {
        val payload = payload() ?: return null
        // Without an identity no install can be matched, so none is ever warm.
        val identity = payload.identity ?: return null
        val properties = readMarker() ?: return null
        if (properties.getProperty("abi") != payload.abi || properties.getProperty("payload") != identity) {
            return null
        }
        if (!config.prefix.isDirectory) return null
        return Installed(
            payload.abi,
            identity,
            properties.getProperty("installedAt")?.toLongOrNull() ?: 0L,
            properties.getProperty("installMs")?.toLongOrNull() ?: 0L,
        )
    }

    /**
     * A warm start: nothing is extracted. The executables' layout is applied
     * again from the exec manifest, which checks every link and rewrites the
     * ones that point anywhere but this APK's native library directory.
     */
    fun warmStart(): WarmStart {
        val started = clock()
        val payload = payload() ?: throw RuntimeFailure(RuntimeProblem.NO_PAYLOAD, NO_PAYLOAD)
        val exec = readText(SealedPayloadInstaller.execAsset(payload.abi))
        val layout = SealedLayout.apply(config.prefix, config.nativeLibraryDirectory, SealedLayout.parse(exec))
        if (layout.missingTargets.isNotEmpty()) {
            throw RuntimeFailure(RuntimeProblem.MISSING_EXECUTABLES, describe(layout.missingTargets))
        }
        if (layout.errors.isNotEmpty()) {
            throw RuntimeFailure(RuntimeProblem.STORAGE, describe(layout.errors))
        }
        if (layout.linked + layout.alreadyCorrect == 0) {
            throw RuntimeFailure(RuntimeProblem.MISSING_EXECUTABLES, "the exec manifest names no executable")
        }
        return WarmStart(millisSince(started), layout.linked)
    }

    /**
     * Installs this APK's payload: what the previous install wrote is removed,
     * then the payload is extracted, verified file by file, and its
     * executables are linked. The marker is written last, and only when
     * nothing failed; any failure is a [RuntimeFailure] with its problem.
     */
    fun install(listener: ProgressListener?): InstallResult {
        val started = clock()
        val payload = payload() ?: throw RuntimeFailure(RuntimeProblem.NO_PAYLOAD, NO_PAYLOAD)
        val abi = payload.abi
        if (config.nativeLibraryDirectory == null) {
            throw RuntimeFailure(RuntimeProblem.MISSING_EXECUTABLES, "no native library directory")
        }
        try {
            ensureDirectory(state)
            // From here on, the prefix is not a finished install.
            if (marker.exists() && !marker.delete()) {
                throw RuntimeFailure(RuntimeProblem.STORAGE, "the install marker could not be removed")
            }
            removePrevious()
        } catch (failure: IOException) {
            throw RuntimeFailure(RuntimeProblem.STORAGE, failure.message ?: "the runtime folder is not writable", failure)
        }

        val manifest = readBytes(SealedPayloadInstaller.manifestAsset(abi))
        val manifestLines = String(manifest, Charsets.UTF_8).lines()
        val exec = readText(SealedPayloadInstaller.execAsset(abi)).lines()
        val links = readText(SealedPayloadInstaller.linksAsset(abi)).lines()
        val entries = manifestLines.filter { it.isNotBlank() && !it.startsWith("#") }
        val total = entries.size
        checkSpace(entries)

        try {
            // Saved before extracting, so that even a failed install can be
            // removed exactly by the next one.
            write(savedManifest, manifest)
            write(savedExec, exec.joinToString("\n").toByteArray(Charsets.UTF_8))
            ensureDirectory(config.prefix)
        } catch (failure: IOException) {
            throw RuntimeFailure(RuntimeProblem.STORAGE, failure.message ?: "the prefix is not writable", failure)
        }

        val request = SealedInstaller.Request()
            .prefix(config.prefix)
            .nativeLibraryDirectory(config.nativeLibraryDirectory)
            .execManifest(exec)
            .linkManifest(links)
            .progress(PayloadExtractor.Listener { _, index -> listener?.onProgress(index, total) })
        val result = try {
            source.open(SealedPayloadInstaller.userlandAsset(abi)).use { userland ->
                request.payload(userland).manifest(ByteArrayInputStream(manifest))
                SealedInstaller.install(request)
            }
        } catch (failure: IOException) {
            throw classify(failure)
        }
        if (result.problems.isNotEmpty()) {
            throw RuntimeFailure(classify(result.problems), describe(result.problems))
        }
        if (!result.ok()) {
            throw RuntimeFailure(RuntimeProblem.MISSING_EXECUTABLES, "the payload linked no executable")
        }
        val millis = millisSince(started)
        try {
            writeMarker(abi, payload.identity, millis)
        } catch (failure: IOException) {
            throw RuntimeFailure(RuntimeProblem.STORAGE, "the install marker could not be written", failure)
        }
        return InstallResult(
            millis,
            result.files,
            result.verified,
            result.bytes,
            result.links,
            result.executables + result.alreadySealed,
        )
    }

    /** t1's ExecAudit over the prefix; its report is kept as exec-audit.txt. */
    fun audit(): AuditResult {
        val started = clock()
        val report = ExecAudit.audit(config.prefix, config.nativeLibraryDirectory)
        val text = report.toText()
        try {
            ensureDirectory(state)
            write(auditFile, text.toByteArray(Charsets.UTF_8))
        } catch (ignored: IOException) {
            // Diagnostics never fail the audit.
        }
        return AuditResult(
            outsideApk = report.outsideApk().size,
            outsideScripts = report.outsideScripts().size,
            shipped = report.shippedCount(),
            scanned = report.scanned,
            truncated = report.truncated,
            failure = report.failure,
            millis = millisSince(started),
            report = text,
        )
    }

    /** What the runtime occupies: the prefix, the native libraries and the APK. */
    fun sizes(apkBytes: Long): RuntimeSizes {
        val prefix = uniqueBytes(config.prefix)
        return RuntimeSizes(
            prefixBytes = prefix.first,
            prefixFiles = prefix.second,
            nativeLibraryBytes = uniqueBytes(config.nativeLibraryDirectory).first,
            apkBytes = apkBytes,
        )
    }

    private fun removePrevious() {
        if (!savedManifest.isFile && !savedExec.isFile) return
        // Exactly what the last install wrote: its executables' links and its
        // files (each only while it still has the size it was written with),
        // never a directory, never the user's files.
        SealedUninstaller.remove(config.prefix, readLines(savedExec), readLines(savedManifest))
        savedManifest.delete()
        savedExec.delete()
    }

    private fun checkSpace(entries: List<String>) {
        var needed = 0L
        for (line in entries) {
            needed += line.split('\t').getOrNull(1)?.trim()?.toLongOrNull() ?: 0L
        }
        // A tenth more for the file system's own overhead.
        needed += needed / 10
        val free = freeSpace(root)
        if (free in 0 until needed) {
            throw RuntimeFailure(
                RuntimeProblem.STORAGE,
                "the runtime needs ${megabytes(needed)} MB and ${megabytes(free)} MB are free",
            )
        }
    }

    private fun readInfo(abi: String): String? =
        try {
            source.open("runtime-info-$abi.json").use { String(it.readBytes(), Charsets.UTF_8) }
        } catch (absent: IOException) {
            null
        }

    private fun readBytes(name: String): ByteArray =
        try {
            source.open(name).use { it.readBytes() }
        } catch (absent: IOException) {
            throw RuntimeFailure(RuntimeProblem.INCOMPLETE, "the APK lacks $name", absent)
        }

    private fun readText(name: String): String = String(readBytes(name), Charsets.UTF_8)

    private fun readMarker(): Properties? {
        if (!marker.isFile) return null
        return try {
            Properties().apply { marker.inputStream().use { load(it) } }
        } catch (unreadable: IOException) {
            null
        }
    }

    private fun writeMarker(abi: String, identity: String?, installMs: Long) {
        val properties = Properties()
        properties.setProperty("abi", abi)
        properties.setProperty("payload", identity ?: "")
        properties.setProperty("installedAt", System.currentTimeMillis().toString())
        properties.setProperty("installMs", installMs.toString())
        val text = StringBuilder()
        for (key in listOf("abi", "payload", "installedAt", "installMs")) {
            text.append(key).append('=').append(properties.getProperty(key)).append('\n')
        }
        write(marker, text.toString().toByteArray(Charsets.UTF_8))
    }

    private fun millisSince(started: Long): Long = (clock() - started) / 1_000_000L

    companion object {
        private const val NO_PAYLOAD = "this app carries no runtime for this device"

        /** Lines of a file, or none when it is absent or unreadable. */
        internal fun readLines(file: File): List<String> =
            try {
                if (file.isFile) file.readLines(Charsets.UTF_8) else emptyList()
            } catch (unreadable: IOException) {
                emptyList()
            }

        /** Writes [data] to [file] through a temporary file and a rename. */
        internal fun write(file: File, data: ByteArray) {
            val temporary = File(file.parentFile, file.name + ".part")
            temporary.writeBytes(data)
            if (!temporary.renameTo(file)) {
                file.delete()
                if (!temporary.renameTo(file)) throw IOException("cannot write ${file.name}")
            }
        }

        internal fun ensureDirectory(directory: File) {
            if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) {
                throw IOException("cannot create ${directory.name}")
            }
        }

        /** The problem of an install whose kernel reported problems (its strings). */
        internal fun classify(problems: List<String>): RuntimeProblem = when {
            problems.any { problem ->
                CORRUPT_PREFIXES.any { problem.startsWith(it) } || problem.startsWith("link ")
            } -> RuntimeProblem.CORRUPT
            problems.any { it.startsWith("manifest lists ") } -> RuntimeProblem.INCOMPLETE
            problems.any { MISSING_TARGET.matches(it) } -> RuntimeProblem.MISSING_EXECUTABLES
            else -> RuntimeProblem.STORAGE
        }

        /** The failure of an install whose kernel threw. */
        internal fun classify(failure: IOException): RuntimeFailure {
            val message = failure.message ?: failure.javaClass.simpleName
            return when {
                failure is ZipException || failure is EOFException ->
                    RuntimeFailure(RuntimeProblem.CORRUPT, "the payload archive is damaged: $message", failure)
                message.contains("ENOSPC") || message.contains("No space left", ignoreCase = true) ->
                    RuntimeFailure(RuntimeProblem.STORAGE, "the device ran out of space", failure)
                else -> RuntimeFailure(RuntimeProblem.STORAGE, message, failure)
            }
        }

        /** The first problem, and how many more there are. */
        internal fun describe(problems: List<String>): String =
            problems.first() + if (problems.size > 1) " (and ${problems.size - 1} more)" else ""

        /** Regular files below [directory], each inode once; symlinks are not followed. */
        internal fun uniqueBytes(directory: File?): Pair<Long, Int> {
            if (directory == null || !directory.isDirectory) return 0L to 0
            val seen = HashSet<Any>()
            var bytes = 0L
            var files = 0
            Files.walkFileTree(directory.toPath(), object : SimpleFileVisitor<Path>() {
                override fun visitFile(file: Path, attributes: BasicFileAttributes): FileVisitResult {
                    if (attributes.isRegularFile) {
                        val key = attributes.fileKey()
                        if (key == null || seen.add(key)) {
                            bytes += attributes.size()
                            files++
                        }
                    }
                    return FileVisitResult.CONTINUE
                }

                override fun visitFileFailed(file: Path, failure: IOException): FileVisitResult =
                    FileVisitResult.CONTINUE
            })
            return bytes to files
        }

        private fun megabytes(bytes: Long): Long = bytes / (1024L * 1024L)

        private val CORRUPT_PREFIXES = listOf(
            "digest differs: ",
            "size differs: ",
            "unsafe payload path: ",
            "payload path escapes the prefix: ",
            "bad link line: ",
            "unsafe link line: ",
        )

        /** SealedLayout's missing target: `libfoo.so (for bin/foo)`. */
        private val MISSING_TARGET = Regex("""^\S+\.so \(for .+\)$""")
    }
}
