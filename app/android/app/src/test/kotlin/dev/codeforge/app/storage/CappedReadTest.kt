package dev.codeforge.app.storage

import java.io.ByteArrayInputStream
import java.io.InputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * A hostile or broken provider (docs/SECURITY.md §4.1, S3): reads stop one
 * buffer past their cap whatever size was listed, and when the call's time
 * is up.
 */
class CappedReadTest {
    private class CountingEndless : InputStream() {
        var given = 0L

        override fun read(): Int {
            given += 1
            return 'x'.code
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            b.fill('x'.code.toByte(), off, off + len)
            given += len
            return len
        }
    }

    private fun tooLarge(block: () -> Unit) {
        try {
            block()
            fail("expected TOO_LARGE")
        } catch (error: StorageException) {
            assertEquals(StorageProblem.TOO_LARGE, error.problem)
        }
    }

    @Test
    fun anEndlessStreamStopsJustPastTheCap() {
        val endless = CountingEndless()
        tooLarge { Streams.readCapped(endless, 1_000_000, Cancellation.NONE) }
        assertTrue(endless.given <= 1_000_000 + Streams.BUFFER_BYTES)
    }

    @Test
    fun exactlyTheCapIsRead() {
        val bytes = ByteArray(300_000) { it.toByte() }
        assertArrayEquals(bytes, Streams.readCapped(ByteArrayInputStream(bytes), bytes.size, Cancellation.NONE))
        tooLarge { Streams.readCapped(ByteArrayInputStream(bytes), bytes.size - 1, Cancellation.NONE) }
    }

    @Test
    fun aListedSizeThatLiesDoesNotLiftTheCap() {
        val provider = FakeProvider()
        provider.file("liar.txt", ByteArray(5_000))
        provider.listedSize = 10
        val ops = DocumentOps(provider, DocumentIdCache(), Cancellation.NONE)
        tooLarge { ops.read("liar.txt", 4_096) }
        provider.endless = true
        tooLarge { ops.read("liar.txt", 4_096) }
    }

    @Test
    fun aReadStopsWhenTheTimeIsUp() {
        var checks = 0
        val cancel = Cancellation {
            checks += 1
            if (checks > 3) throw StorageException(StorageProblem.TIMEOUT, "time is up")
        }
        try {
            Streams.readCapped(CountingEndless(), Int.MAX_VALUE, cancel)
            fail("expected TIMEOUT")
        } catch (error: StorageException) {
            assertEquals(StorageProblem.TIMEOUT, error.problem)
        }
    }
}
