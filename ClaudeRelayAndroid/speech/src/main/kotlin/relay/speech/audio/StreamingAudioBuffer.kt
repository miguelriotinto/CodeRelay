package relay.speech.audio

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Thread-safe ring buffer for streaming 16 kHz mono audio.
 *
 * Faithful port of `Sources/ClaudeRelaySpeech/StreamingAudioBuffer.swift`.
 *
 * Fixed capacity — oldest samples are overwritten on overflow. Appends are safe
 * from the audio thread; reads return independent copies so async consumers
 * (Whisper, Smart-Turn) can process without holding the lock.
 *
 * The Swift original uses `OSAllocatedUnfairLock`; we use [ReentrantLock], which
 * provides equivalent mutual exclusion on the JVM. [writeCount] is a monotonic
 * sample count since buffer creation: callers snapshot [currentPosition] as a
 * marker, then later extract the slice written since that marker via
 * [audioSince].
 *
 * Constructed from `capacitySeconds * sampleRate` (matching Swift) rather than a
 * raw sample count, so callers express capacity in wall-clock terms (e.g. a 30 s
 * ring at 16 kHz). The legacy plan sketch took `capacitySamples` directly; the
 * Swift source of truth derives the sample count from duration, so this port
 * follows the Swift surface.
 */
class StreamingAudioBuffer(
    capacitySeconds: Double,
    private val sampleRate: Double,
) {

    private val capacity: Int
    private val storage: FloatArray
    private val lock = ReentrantLock()

    /**
     * Monotonic sample-count since buffer creation. Guarded by [lock]; never
     * decreases, even after the ring wraps and overwrites the oldest samples.
     */
    private var writeCount: Long = 0L

    init {
        require(sampleRate > 0) { "StreamingAudioBuffer sampleRate must be > 0" }
        require(capacitySeconds > 0) { "StreamingAudioBuffer capacitySeconds must be > 0" }
        val cap = (capacitySeconds * sampleRate).toInt()
        require(cap > 0) { "StreamingAudioBuffer capacity must be > 0" }
        capacity = cap
        storage = FloatArray(cap)
    }

    /**
     * Current monotonic write position. Snapshot this before calling
     * [audioSince] to extract a later utterance.
     */
    val currentPosition: Long
        get() = lock.withLock { writeCount }

    /** Append samples from the audio thread. Wraps around on overflow. */
    fun append(samples: FloatArray) = lock.withLock {
        for (sample in samples) {
            storage[(writeCount % capacity).toInt()] = sample
            writeCount++
        }
    }

    /**
     * Read the most recent [duration] seconds of audio. If fewer samples are
     * available, returns what's there. Returns an independent copy.
     */
    fun lastSeconds(duration: Double): FloatArray = lock.withLock {
        val wanted = minOf((duration * sampleRate).toLong(), writeCount, capacity.toLong())
        if (wanted == 0L) return@withLock FloatArray(0)

        val startAbsolute = writeCount - wanted
        extractSlice(startAbsolute, wanted.toInt())
    }

    /**
     * Read audio written since the given [position]. If that position has been
     * overwritten (older than [capacity]), returns the oldest available samples
     * up to [capacity]. Returns an independent copy.
     */
    fun audioSince(position: Long): FloatArray = lock.withLock {
        val oldestAvailable = maxOf(0L, writeCount - capacity)
        val startAbsolute = maxOf(position, oldestAvailable)
        val count = writeCount - startAbsolute
        if (count <= 0L) return@withLock FloatArray(0)

        extractSlice(startAbsolute, count.toInt())
    }

    /** Must be called with [lock] held. */
    private fun extractSlice(startAbsolute: Long, count: Int): FloatArray =
        FloatArray(count) { i ->
            storage[((startAbsolute + i) % capacity).toInt()]
        }
}
