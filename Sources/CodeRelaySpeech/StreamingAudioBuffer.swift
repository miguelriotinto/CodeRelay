import Foundation
import os

/// Thread-safe ring buffer for streaming 16 kHz mono audio.
///
/// Fixed capacity — oldest samples are overwritten on overflow. Appends
/// are safe from the audio thread; reads return independent copies so
/// async consumers (Whisper, Smart-Turn) can process without a lock.
public final class StreamingAudioBuffer: @unchecked Sendable {

    private var storage: [Float]
    private let capacity: Int
    private let sampleRate: Double

    /// Monotonic sample-count since buffer creation. Callers mark
    /// positions to extract slices later via `audioSince(position:)`.
    private var writeCount: Int = 0

    private let lock = OSAllocatedUnfairLock()

    public init(capacitySeconds: TimeInterval, sampleRate: Double) {
        precondition(sampleRate > 0, "StreamingAudioBuffer sampleRate must be > 0")
        precondition(capacitySeconds > 0, "StreamingAudioBuffer capacitySeconds must be > 0")
        let cap = Int(capacitySeconds * sampleRate)
        precondition(cap > 0, "StreamingAudioBuffer capacity must be > 0")
        self.capacity = cap
        self.sampleRate = sampleRate
        self.storage = Array(repeating: 0, count: cap)
    }

    /// Current monotonic write position. Use as a marker before
    /// calling `audioSince(position:)` to extract an utterance.
    public var currentPosition: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeCount
    }

    /// Append samples from the audio thread. Wraps around on overflow.
    public func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            storage[writeCount % capacity] = sample
            writeCount += 1
        }
    }

    /// Read the most recent `duration` seconds of audio. If fewer samples are
    /// available, returns what's there. Returns an independent copy.
    public func lastSeconds(_ duration: TimeInterval) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let wanted = min(Int(duration * sampleRate), writeCount, capacity)
        if wanted == 0 { return [] }

        let startAbsolute = writeCount - wanted
        return extractSlice(fromAbsolute: startAbsolute, count: wanted)
    }

    /// Read audio written since the given position. If that position has
    /// been overwritten (older than capacity), returns the oldest available
    /// samples up to capacity.
    public func audioSince(position: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let oldestAvailable = max(0, writeCount - capacity)
        let startAbsolute = max(position, oldestAvailable)
        let count = writeCount - startAbsolute
        if count <= 0 { return [] }

        return extractSlice(fromAbsolute: startAbsolute, count: count)
    }

    /// Must be called with the lock held.
    private func extractSlice(fromAbsolute start: Int, count: Int) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(storage[(start + i) % capacity])
        }
        return out
    }
}
