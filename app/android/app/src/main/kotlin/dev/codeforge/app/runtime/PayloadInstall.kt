package dev.codeforge.app.runtime

import dev.codeforge.runtime.sealed.PayloadExtractor
import dev.codeforge.runtime.sealed.RuntimeManifest
import dev.codeforge.runtime.sealed.SealedLayout
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files

/**
 * t1's `SealedInstaller.install`, step for step, from a manifest the host has
 * already read (Phase 4 W5).
 *
 * The kernel's own entry point reads the manifest stream with
 * `InputStream.readAllBytes()` (`RuntimeManifest.read(InputStream)`). Android
 * has that method only from API 33, and D8 does not backport it, so every
 * install through the kernel's entry point ended in NoSuchMethodError on
 * Android 8.0 to 12L (API 26 to 32): a part of minSdk 26 that no gate ran
 * before W5's API 26 to 28 legs. Vendored files are never edited (AGENTS.md
 * §4), so the host makes the kernel's public calls in the kernel's order
 * itself:
 *  1. the manifest, parsed by `RuntimeManifest.parse` (what
 *     `RuntimeManifest.read(InputStream)` does with the stream's bytes);
 *  2. the archive, extracted and verified file by file by `PayloadExtractor`;
 *  3. the data links, each side checked by `RuntimeManifest.normalize` and
 *     created as the kernel creates them;
 *  4. the executables, linked into the native library directory by
 *     `SealedLayout`.
 *
 * Step 3's parsing and creation are the kernel's package-private
 * `parseLinks` and `createLink`, restated: the same trimming and splitting,
 * the same problems, word for word. `PayloadInstallTest` installs the same
 * payloads through both entry points on the JVM (where the kernel's works)
 * and compares the prefixes, counts and problems; CI's API floor check
 * (app/tool/ci/check_api_floor.py) fails the build if the app calls the
 * kernel's entry point again.
 */
internal object PayloadInstall {
    /** What `SealedInstaller.Result` holds. */
    class Outcome(
        val files: Int,
        val verified: Int,
        val bytes: Long,
        val links: Int,
        val executables: Int,
        val alreadySealed: Int,
        val problems: List<String>,
    ) {
        /** As `SealedInstaller.Result.ok`: problem-free, and something linked. */
        fun ok(): Boolean = problems.isEmpty() && executables + alreadySealed > 0
    }

    /**
     * Installs [payload] (the userland zip, consumed) into [prefix]: [manifest]
     * holds its `sha256<TAB>size<TAB>path` lines (null: nothing is verified, as
     * with the kernel's null stream), [execManifest] its `path<TAB>library`
     * lines and [linkManifest] its `path<TAB>target` lines.
     *
     * @throws IOException when the prefix or the archive cannot be read at all;
     *   per-file failures are [Outcome.problems], as in the kernel.
     */
    @Throws(IOException::class)
    fun install(
        prefix: File,
        nativeLibraryDirectory: File?,
        payload: InputStream,
        manifest: ByteArray?,
        execManifest: List<String>?,
        linkManifest: List<String>?,
        progress: PayloadExtractor.Listener?,
    ): Outcome {
        val problems = ArrayList<String>()

        val parsed = if (manifest == null) {
            RuntimeManifest.empty()
        } else {
            RuntimeManifest.parse(String(manifest, Charsets.UTF_8))
        }
        val extracted = PayloadExtractor.extract(payload, prefix, parsed, progress)
        problems.addAll(extracted.problems)

        var links = 0
        for (link in parseLinks(linkManifest, problems)) {
            try {
                createLink(prefix, link[0], link[1])
                links++
            } catch (failed: Exception) {
                problems.add("link " + link[0] + ": " + failed.message)
            }
        }

        val sealed = SealedLayout.apply(prefix, nativeLibraryDirectory, SealedLayout.parse(join(execManifest)))
        problems.addAll(sealed.errors)
        problems.addAll(sealed.missingTargets)

        return Outcome(
            files = extracted.files,
            verified = extracted.verified,
            bytes = extracted.bytes,
            links = links,
            executables = sealed.linked,
            alreadySealed = sealed.alreadyCorrect,
            problems = problems,
        )
    }

    /**
     * `SealedInstaller.parseLinks`: `path<TAB>target` lines, both
     * prefix-relative and both safe. Java's `String.trim` (every character up
     * to a space), not Kotlin's (Unicode whitespace), so a line trims alike.
     */
    private fun parseLinks(lines: List<String>?, problems: MutableList<String>): List<Array<String>> {
        val links = ArrayList<Array<String>>()
        if (lines == null) return links
        for (raw in lines) {
            val line = raw.trim { it <= ' ' }
            if (line.isEmpty() || line.startsWith("#")) continue
            val pieces = line.split(WHITESPACE)
            if (pieces.size != 2) {
                problems.add("bad link line: $line")
                continue
            }
            val path = RuntimeManifest.normalize(pieces[0])
            val target = RuntimeManifest.normalize(pieces[1])
            if (path == null || target == null) {
                problems.add("unsafe link line: $line")
                continue
            }
            links.add(arrayOf(path, target))
        }
        return links
    }

    /** `SealedInstaller.createLink`: a data link; targets are prefix-relative by construction. */
    @Throws(IOException::class)
    private fun createLink(prefix: File, path: String, target: String) {
        val link = File(prefix, path)
        val parent = link.parentFile
        if (parent != null && !parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) {
            throw IOException("cannot create $parent")
        }
        Files.deleteIfExists(link.toPath())
        Files.createSymbolicLink(link.toPath(), File(prefix, target).toPath())
    }

    /** `SealedInstaller.join`: the lines, each ended by a newline. */
    private fun join(lines: List<String>?): String {
        if (lines == null) return ""
        val text = StringBuilder()
        for (line in lines) text.append(line).append('\n')
        return text.toString()
    }

    /** Java's `"\\s+"`: a trimmed line splits the same in both languages. */
    private val WHITESPACE = Regex("\\s+")
}
