package relay.speech.audio

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class StreamingAudioBufferTest {

    // Small, exact capacity: 1 s @ 10 Hz = 10 samples. Keeps wrap-around math easy.
    private fun smallBuffer() = StreamingAudioBuffer(capacitySeconds = 1.0, sampleRate = 10.0)

    @Test
    fun `append advances writePosition by the number of samples`() {
        val buffer = smallBuffer()
        assertEquals(0L, buffer.currentPosition)

        buffer.append(floatArrayOf(1f, 2f, 3f))
        assertEquals(3L, buffer.currentPosition)

        buffer.append(floatArrayOf(4f, 5f))
        assertEquals(5L, buffer.currentPosition)
    }

    @Test
    fun `audioSince returns an independent copy that does not alias the ring`() {
        val buffer = smallBuffer()
        buffer.append(floatArrayOf(1f, 2f, 3f))

        val copy = buffer.audioSince(position = 0L)
        assertArrayEquals(floatArrayOf(1f, 2f, 3f), copy)

        // Mutating the returned copy must not change the buffer's contents.
        copy[0] = 99f
        val fresh = buffer.audioSince(position = 0L)
        assertArrayEquals(floatArrayOf(1f, 2f, 3f), fresh)
    }

    @Test
    fun `lastSeconds returns an independent copy`() {
        val buffer = smallBuffer()
        buffer.append(floatArrayOf(1f, 2f, 3f, 4f))

        val copy = buffer.lastSeconds(duration = 1.0)
        copy[0] = 42f
        val fresh = buffer.lastSeconds(duration = 1.0)

        assertArrayEquals(floatArrayOf(1f, 2f, 3f, 4f), fresh)
    }

    @Test
    fun `ring overwrites oldest beyond capacity but writePosition stays monotonic`() {
        val buffer = smallBuffer() // capacity = 10

        // Write 15 samples into a 10-slot ring: 0..4 get overwritten by 10..14.
        val all = FloatArray(15) { it.toFloat() } // [0,1,...,14]
        buffer.append(all)

        // writeCount is monotonic — it counts every appended sample, not the
        // ring size.
        assertEquals(15L, buffer.currentPosition)

        // The oldest 5 (values 0..4) were overwritten; only the most recent 10
        // (values 5..14) survive.
        val survivors = buffer.audioSince(position = 0L)
        assertArrayEquals(FloatArray(10) { (it + 5).toFloat() }, survivors) // [5,...,14]
    }

    @Test
    fun `audioSince clamps a position older than capacity to the oldest available`() {
        val buffer = smallBuffer() // capacity = 10
        buffer.append(FloatArray(15) { it.toFloat() }) // values 0..14, ring holds 5..14

        // Position 0 is older than what survives; clamp to oldest available (value 5).
        val fromZero = buffer.audioSince(position = 0L)
        assertArrayEquals(FloatArray(10) { (it + 5).toFloat() }, fromZero)

        // A mid-range marker returns only the tail written since that marker.
        val fromTwelve = buffer.audioSince(position = 12L)
        assertArrayEquals(floatArrayOf(12f, 13f, 14f), fromTwelve)
    }

    @Test
    fun `audioSince returns empty when nothing was written since the marker`() {
        val buffer = smallBuffer()
        buffer.append(floatArrayOf(1f, 2f, 3f))

        val marker = buffer.currentPosition // 3
        assertTrue(buffer.audioSince(position = marker).isEmpty())
    }

    @Test
    fun `lastSeconds returns only the most recent window and clamps to available samples`() {
        val buffer = StreamingAudioBuffer(capacitySeconds = 1.0, sampleRate = 10.0) // capacity 10

        buffer.append(floatArrayOf(1f, 2f, 3f))
        // Ask for 1 s (10 samples) but only 3 exist → returns the 3 we have.
        assertArrayEquals(floatArrayOf(1f, 2f, 3f), buffer.lastSeconds(duration = 1.0))

        // Append values 4..23 (FloatArray(20){it+4}); 23 samples total, ring holds last 10.
        buffer.append(FloatArray(20) { (it + 4).toFloat() })
        // Request 0.5 s = 5 samples → the 5 most recent (values 19..23).
        assertArrayEquals(FloatArray(5) { (it + 19).toFloat() }, buffer.lastSeconds(duration = 0.5))
    }

    @Test
    fun `lastSeconds returns empty when no samples have been appended`() {
        val buffer = smallBuffer()
        assertTrue(buffer.lastSeconds(duration = 1.0).isEmpty())
    }

    @Test
    fun `append of an empty array is a no-op`() {
        val buffer = smallBuffer()
        buffer.append(FloatArray(0))
        assertEquals(0L, buffer.currentPosition)
    }

    @Test
    fun `constructor rejects non-positive sampleRate and capacity`() {
        assertThrows(IllegalArgumentException::class.java) {
            StreamingAudioBuffer(capacitySeconds = 1.0, sampleRate = 0.0)
        }
        assertThrows(IllegalArgumentException::class.java) {
            StreamingAudioBuffer(capacitySeconds = 0.0, sampleRate = 16000.0)
        }
        // capacitySeconds * sampleRate truncating to 0 samples is rejected too.
        assertThrows(IllegalArgumentException::class.java) {
            StreamingAudioBuffer(capacitySeconds = 0.00001, sampleRate = 1.0)
        }
    }
}
