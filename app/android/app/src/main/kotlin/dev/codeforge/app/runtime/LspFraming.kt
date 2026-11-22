package dev.codeforge.app.runtime

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * Why a language server's output is not LSP's base protocol (Phase 6 W3): the
 * host ends the server as broken, and Dart restarts it. [reason] is one of
 * bad_header, too_large, truncated or bad_utf8.
 */
class LspFramingException(val reason: String, message: String) : IOException(message)

/**
 * LSP's base protocol (Phase 6 W3; docs/LSP_ARCHITECTURE.md §1), CodeForge's
 * own: each message is a header part, ASCII lines each ended by CR LF, one of
 * them Content-Length, then an empty line, then exactly that many bytes of
 * UTF-8 JSON. Kotlin parses the frames from bytes, so Dart only ever sees
 * whole messages.
 */
object LspFrames {
    /** The largest message either side may send. */
    const val MAX_MESSAGE_BYTES = 16 * 1024 * 1024

    /** The longest header line. */
    const val MAX_HEADER_LINE = 8 * 1024

    /** The most header lines one message may have. */
    const val MAX_HEADERS = 16

    /** [message] as one frame: its header, then its UTF-8 bytes. */
    fun frame(message: String): ByteArray {
        val body = message.toByteArray(Charsets.UTF_8)
        return "Content-Length: ${body.size}\r\n\r\n".toByteArray(Charsets.US_ASCII) + body
    }
}

/**
 * Reads whole messages from a language server's stdout. A message comes out
 * only once all of it has arrived, however the bytes were split across
 * reads; anything that is not the base protocol is an [LspFramingException].
 * One reader per stream, on one thread.
 */
class LspFrameReader(input: InputStream) {
    private val input: InputStream = if (input is BufferedInputStream) input else BufferedInputStream(input, BUFFER_BYTES)

    private val decoder = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)

    /**
     * The next message, or null when the stream ended between two messages.
     * Throws [LspFramingException] for a bad header, a length over
     * [LspFrames.MAX_MESSAGE_BYTES], a stream that ends inside a message, or
     * a body that is not UTF-8; an IOException when the stream fails.
     */
    fun read(): String? {
        var length = -1L
        var headers = 0
        while (true) {
            val line = readHeaderLine(atStart = headers == 0) ?: return null
            if (line.isEmpty()) {
                if (headers == 0) throw LspFramingException("bad_header", "an empty line where a header belongs")
                break
            }
            headers += 1
            if (headers > LspFrames.MAX_HEADERS) {
                throw LspFramingException("bad_header", "more than ${LspFrames.MAX_HEADERS} header lines")
            }
            val colon = line.indexOf(':')
            if (colon <= 0) throw LspFramingException("bad_header", "a header line without a name: ${line.take(SHOWN)}")
            val name = line.substring(0, colon).trim()
            if (!name.equals("Content-Length", ignoreCase = true)) continue
            if (length >= 0) throw LspFramingException("bad_header", "Content-Length given twice")
            val value = line.substring(colon + 1).trim()
            if (value.isEmpty() || value.length > MAX_LENGTH_DIGITS || !value.all { it in '0'..'9' }) {
                throw LspFramingException("bad_header", "Content-Length is not a number: ${value.take(SHOWN)}")
            }
            length = value.toLong()
            if (length > LspFrames.MAX_MESSAGE_BYTES) {
                throw LspFramingException("too_large", "a message of $length bytes, over ${LspFrames.MAX_MESSAGE_BYTES}")
            }
        }
        if (length < 0) throw LspFramingException("bad_header", "a message without Content-Length")
        val body = ByteArray(length.toInt())
        var read = 0
        while (read < body.size) {
            val count = input.read(body, read, body.size - read)
            if (count < 0) throw LspFramingException("truncated", "the stream ended $read bytes into a message of ${body.size}")
            read += count
        }
        return try {
            decoder.decode(ByteBuffer.wrap(body)).toString()
        } catch (malformed: CharacterCodingException) {
            throw LspFramingException("bad_utf8", "a message of ${body.size} bytes that is not UTF-8")
        }
    }

    /**
     * One header line without its CR LF; null when the stream ends before the
     * first byte of a message ([atStart]). Header lines are printable ASCII.
     */
    private fun readHeaderLine(atStart: Boolean): String? {
        val bytes = ByteArrayOutputStream()
        while (true) {
            val next = input.read()
            if (next < 0) {
                if (atStart && bytes.size() == 0) return null
                throw LspFramingException("truncated", "the stream ended inside a message's header")
            }
            when {
                next == CR -> {
                    if (input.read() != LF) throw LspFramingException("bad_header", "a header line not ended by CR LF")
                    return bytes.toString("US-ASCII")
                }
                next == LF -> throw LspFramingException("bad_header", "a header line not ended by CR LF")
                next < 0x20 && next != TAB || next > 0x7e ->
                    throw LspFramingException("bad_header", "a header byte that is not printable ASCII: $next")
                else -> bytes.write(next)
            }
            if (bytes.size() > LspFrames.MAX_HEADER_LINE) {
                throw LspFramingException("bad_header", "a header line over ${LspFrames.MAX_HEADER_LINE} bytes")
            }
        }
    }

    private companion object {
        const val BUFFER_BYTES = 64 * 1024
        const val CR = '\r'.code
        const val LF = '\n'.code
        const val TAB = '\t'.code
        const val SHOWN = 80
        const val MAX_LENGTH_DIGITS = 10
    }
}
