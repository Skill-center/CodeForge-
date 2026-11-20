package dev.codeforge.app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/** One terminal session as the ledger keeps it: how it was, the last time the app knew. */
data class LedgerEntry(
    val id: Long,
    val label: String,
    /** Its shell still ran. */
    val running: Boolean,
    val exitCode: Int? = null,
    val signal: Int? = null,
    /** How it ended other than by its shell's own exit ([TerminalFailure.code]). */
    val failure: String? = null,
)

/**
 * A terminal session that ended with the app's last process (Phase 5 W5):
 * what the next start shows in its place. One that still ran then was
 * [TerminalFailure.SYSTEM]: Android ended the app, and its processes went
 * with it.
 */
data class TerminalTombstone(
    val id: Long,
    val label: String,
    val exitCode: Int?,
    val signal: Int?,
    val failure: TerminalFailure?,
)

/**
 * What the app knew of its terminal sessions, on disk (Phase 5 W5), so that
 * after Android ends the app the next start can say how each one ended.
 * Written whole after every change, through a temporary file, so a crash
 * leaves the old ledger or the new one. A ledger that can't be read counts
 * as empty: tombstones are a courtesy, never a reason not to start.
 *
 * The format is a header line, then one line per session: its id, `1` if it
 * ran, its exit code, its signal and its failure (`-` for none), then its
 * label, with any control character a space. No Android type: the JVM tests
 * drive it on real files.
 */
class SessionLedger(private val file: File) {
    /** The sessions as last written; empty when there is no ledger or it can't be read. */
    fun read(): List<LedgerEntry> {
        val lines = try {
            if (!file.isFile) return emptyList()
            file.readLines(Charsets.UTF_8)
        } catch (unreadable: IOException) {
            return emptyList()
        }
        if (lines.firstOrNull() != HEADER) return emptyList()
        val entries = ArrayList<LedgerEntry>()
        for (line in lines.drop(1)) {
            if (line.isEmpty()) continue
            val parts = line.split('\t', limit = 6)
            if (parts.size != 6) return emptyList()
            val id = parts[0].toLongOrNull() ?: return emptyList()
            if (id <= 0 || (parts[1] != "0" && parts[1] != "1")) return emptyList()
            entries.add(
                LedgerEntry(
                    id = id,
                    label = parts[5],
                    running = parts[1] == "1",
                    exitCode = parts[2].takeUnless { it == NONE }?.toIntOrNull(),
                    signal = parts[3].takeUnless { it == NONE }?.toIntOrNull(),
                    failure = parts[4].takeUnless { it == NONE },
                ),
            )
        }
        return entries
    }

    /** Writes [entries] in place of what was there. */
    fun write(entries: List<LedgerEntry>) {
        val parent = file.absoluteFile.parentFile
        if (!parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) throw IOException("could not create the ledger's folder")
        val temp = File(parent, "${file.name}.part")
        val text = buildString {
            append(HEADER).append('\n')
            for (entry in entries) {
                append(entry.id).append('\t')
                append(if (entry.running) "1" else "0").append('\t')
                append(entry.exitCode?.toString() ?: NONE).append('\t')
                append(entry.signal?.toString() ?: NONE).append('\t')
                append(entry.failure?.takeIf { it.isNotEmpty() && it.none(::unsafe) } ?: NONE).append('\t')
                append(entry.label.map { if (unsafe(it)) ' ' else it }.joinToString("").take(MAX_LABEL)).append('\n')
            }
        }
        temp.writeText(text, Charsets.UTF_8)
        Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    companion object {
        const val HEADER = "codeforge-sessions 1"
        const val MAX_LABEL = 64
        private const val NONE = "-"

        private fun unsafe(c: Char): Boolean = c.code < 0x20 || c.code == 0x7F

        /** What [entries], read after the app's process ended, leave behind. */
        fun tombstonesOf(entries: List<LedgerEntry>): List<TerminalTombstone> = entries.map { entry ->
            if (entry.running) {
                TerminalTombstone(entry.id, entry.label, exitCode = null, signal = null, failure = TerminalFailure.SYSTEM)
            } else {
                TerminalTombstone(
                    entry.id,
                    entry.label,
                    exitCode = entry.exitCode,
                    signal = entry.signal,
                    failure = TerminalFailure.entries.firstOrNull { it.code == entry.failure },
                )
            }
        }
    }
}
