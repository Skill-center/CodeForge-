package dev.codeforge.app.runtime

import java.io.ByteArrayInputStream
import java.io.InputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * LSP's base protocol as Kotlin reads it from a server (Phase 6 W3, gate G3):
 * whole messages however the bytes arrive, and anything else refused with
 * its reason, so that Dart never sees part of a message.
 */
class LspFramingTest {
    private fun reader(bytes: ByteArray, chunk: Int = Int.MAX_VALUE): LspFrameReader =
        LspFrameReader(Chunked(bytes, chunk))

    private fun refusal(bytes: ByteArray): String =
        assertThrows(LspFramingException::class.java) { reader(bytes).read() }.reason

    private fun ascii(text: String): ByteArray = text.toByteArray(Charsets.US_ASCII)

    @Test
    fun aFrameIsReadBackWhole() {
        val message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"text\":\"héllo – ✓\"}}"
        val frame = LspFrames.frame(message)
        val body = message.toByteArray(Charsets.UTF_8)
        assertTrue("Content-Length counts bytes", String(frame, Charsets.UTF_8).startsWith("Content-Length: ${body.size}\r\n\r\n"))
        val reader = reader(frame)
        assertEquals(message, reader.read())
        assertNull("the stream ended between messages", reader.read())
    }

    @Test
    fun severalMessagesInOneReadComeOutOneByOne() {
        val reader = reader(LspFrames.frame("{\"a\":1}") + LspFrames.frame("{\"b\":2}") + LspFrames.frame("{\"c\":3}"))
        assertEquals("{\"a\":1}", reader.read())
        assertEquals("{\"b\":2}", reader.read())
        assertEquals("{\"c\":3}", reader.read())
        assertNull(reader.read())
    }

    @Test
    fun aMessageArrivingAByteAtATimeComesOutWhole() {
        // A four-byte character split across reads, too.
        val message = "{\"emoji\":\"\uD83D\uDE00\",\"x\":\"${"y".repeat(5000)}\"}"
        val reader = reader(LspFrames.frame(message) + LspFrames.frame("{}"), chunk = 1)
        assertEquals(message, reader.read())
        assertEquals("{}", reader.read())
        assertNull(reader.read())
    }

    @Test
    fun otherHeadersAreAllowedAndTheNameIsCaseInsensitive() {
        val body = "{\"ok\":true}"
        val frame = ascii("content-type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: ${body.length}\r\n\r\n$body")
        assertEquals(body, reader(frame).read())
    }

    @Test
    fun theStreamEndingInsideAMessageIsTruncated() {
        assertEquals("truncated", refusal(ascii("Content-Len")))
        assertEquals("truncated", refusal(ascii("Content-Length: 10\r\n\r\n{\"a\":")))
    }

    @Test
    fun aHeaderPartWithoutAValidLengthIsBad() {
        assertEquals("bad_header", refusal(ascii("Content-Type: x\r\n\r\n{}")))
        assertEquals("bad_header", refusal(ascii("Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}")))
        assertEquals("bad_header", refusal(ascii("Content-Length: two\r\n\r\n{}")))
        assertEquals("bad_header", refusal(ascii("Content-Length: -2\r\n\r\n{}")))
        assertEquals("bad_header", refusal(ascii("\r\n{}")))
    }

    @Test
    fun aServerPrintingTextIsBad() {
        assertEquals("bad_header", refusal(ascii("Starting the server...\n")))
        assertEquals("bad_header", refusal(ascii("no colon here\r\n\r\n")))
        assertEquals("bad_header", refusal("Content-Length: 2\r\nX-Name: é\r\n\r\n{}".toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun aHeaderPartTooLongIsBad() {
        assertEquals("bad_header", refusal(ascii("X-Long: ${"a".repeat(LspFrames.MAX_HEADER_LINE + 1)}\r\n")))
        val many = (0..LspFrames.MAX_HEADERS).joinToString("") { "X-$it: y\r\n" }
        assertEquals("bad_header", refusal(ascii(many + "Content-Length: 2\r\n\r\n{}")))
    }

    @Test
    fun aMessageOverTheCapIsRefusedBeforeItIsRead() {
        assertEquals("too_large", refusal(ascii("Content-Length: ${LspFrames.MAX_MESSAGE_BYTES + 1}\r\n\r\n")))
        assertEquals("too_large", refusal(ascii("Content-Length: 9999999999\r\n\r\n")))
    }

    @Test
    fun aBodyThatIsNotUtf8IsRefused() {
        val frame = ascii("Content-Length: 4\r\n\r\n") + byteArrayOf(0x7b, 0xff.toByte(), 0xfe.toByte(), 0x7d)
        assertEquals("bad_utf8", refusal(frame))
    }

    @Test
    fun anEmptyStreamHasNoMessage() {
        assertNull(reader(ByteArray(0)).read())
    }

    /** Hands out at most [chunk] bytes per read, as a pipe may. */
    private class Chunked(private val data: ByteArray, private val chunk: Int) : InputStream() {
        private val inner = ByteArrayInputStream(data)

        override fun read(): Int = inner.read()

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
            inner.read(buffer, offset, minOf(length, chunk))
    }
}
