package dev.codeforge.app.search

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.regex.Pattern
import java.util.regex.PatternSyntaxException

/**
 * A query as a matcher for one line at a time (Phase 4 W6), for [TextScan].
 * Java's regular expressions stand in for ripgrep's: the same for the usual
 * patterns, while Java also takes look-around and back-references, which
 * ripgrep refuses. Matching ignores case unless the query asks for it (both
 * ways, never ripgrep's smart case). A whole word is one with no letter,
 * digit, mark or connector next to it, as ripgrep's `-w` reads it.
 */
class LineMatcher private constructor(private val pattern: Pattern) {
    /** The matches in [line], or null when there is none. */
    fun find(line: String): LineMatches? {
        val matcher = pattern.matcher(line)
        var kept: IntArray? = null
        var stored = 0
        var count = 0
        while (matcher.find()) {
            if (kept == null) kept = IntArray(8)
            if (stored < SearchCollector.RANGES_MAX * 2) {
                if (stored + 2 > kept.size) kept = kept.copyOf(kept.size * 2)
                kept[stored] = matcher.start()
                kept[stored + 1] = matcher.end()
                stored += 2
            }
            count += 1
        }
        return kept?.let { LineMatches(it.copyOf(stored), count) }
    }

    companion object {
        private const val WORD = "[\\p{L}\\p{M}\\p{N}\\p{Pc}]"

        /** Throws IllegalArgumentException with a message for the user when the pattern does not compile. */
        fun of(query: SearchQuery): LineMatcher {
            if (query.text.isEmpty()) throw IllegalArgumentException("Type something to search for.")
            var source = if (query.regex) query.text else Pattern.quote(query.text)
            if (query.wholeWord) source = "(?<!$WORD)(?:$source)(?!$WORD)"
            var flags = 0
            if (!query.caseSensitive) flags = flags or Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE
            return try {
                LineMatcher(Pattern.compile(source, flags))
            } catch (bad: PatternSyntaxException) {
                throw IllegalArgumentException("Not a valid regular expression: ${bad.description}")
            }
        }
    }
}

/** A line's matches: the first ones' start and end offsets in pairs, and how many there are in all. */
class LineMatches(val ranges: IntArray, val count: Int)

/**
 * The editor's rule for what is text (lib/core/files/text_codec.dart,
 * `decodeText`), for [TextScan]: a UTF-16 or UTF-32 byte-order mark, a NUL
 * byte or malformed UTF-8 means the editor would not open the file, so it is
 * not searched. A UTF-8 byte-order mark is taken off.
 */
object TextRule {
    sealed class Decoded {
        class Text(val text: String) : Decoded()
        object Binary : Decoded()
        object NotText : Decoded()
    }

    fun decode(bytes: ByteArray): Decoded {
        if (startsWith(bytes, 0xFF, 0xFE) || startsWith(bytes, 0xFE, 0xFF)) return Decoded.NotText
        val start = if (startsWith(bytes, 0xEF, 0xBB, 0xBF)) 3 else 0
        for (i in start until bytes.size) {
            if (bytes[i] == 0.toByte()) return Decoded.Binary
        }
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            Decoded.Text(decoder.decode(ByteBuffer.wrap(bytes, start, bytes.size - start)).toString())
        } catch (malformed: CharacterCodingException) {
            Decoded.NotText
        }
    }

    private fun startsWith(bytes: ByteArray, vararg prefix: Int): Boolean =
        bytes.size >= prefix.size && prefix.indices.all { bytes[it] == prefix[it].toByte() }
}
