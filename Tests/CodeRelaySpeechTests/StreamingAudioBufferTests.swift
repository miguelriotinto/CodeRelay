import XCTest
@testable import CodeRelaySpeech

final class StreamingAudioBufferTests: XCTestCase {

    func testAppendAndReadLastSecondsWithinCapacity() {
        let buffer = StreamingAudioBuffer(capacitySeconds: 1.0, sampleRate: 16000)
        // 0.5s of samples: 8000 samples at 16kHz
        let samples = Array(repeating: Float(0.5), count: 8000)
        buffer.append(samples)

        let last = buffer.lastSeconds(0.5)
        XCTAssertEqual(last.count, 8000)
        XCTAssertEqual(last.first, 0.5)
        XCTAssertEqual(last.last, 0.5)
    }

    func testLastSecondsReturnsOnlyAvailableAudio() {
        // Request more than was written: return what's there.
        let buffer = StreamingAudioBuffer(capacitySeconds: 5.0, sampleRate: 16000)
        buffer.append(Array(repeating: Float(0.3), count: 4000))  // 0.25s

        let last = buffer.lastSeconds(1.0)
        XCTAssertEqual(last.count, 4000)
    }

    func testOverwritesOldestOnOverflow() {
        let buffer = StreamingAudioBuffer(capacitySeconds: 1.0, sampleRate: 16000)
        // Write 16000 samples of 0.1, then 16000 samples of 0.9.
        // Capacity is 16000, so after second write only 0.9 should remain.
        buffer.append(Array(repeating: Float(0.1), count: 16000))
        buffer.append(Array(repeating: Float(0.9), count: 16000))

        let last = buffer.lastSeconds(1.0)
        XCTAssertEqual(last.count, 16000)
        XCTAssertEqual(last.first, 0.9)
        XCTAssertEqual(last.last, 0.9)
    }

    func testPartialOverwriteKeepsNewest() {
        let buffer = StreamingAudioBuffer(capacitySeconds: 1.0, sampleRate: 16000)
        // 16000 sample capacity.
        buffer.append(Array(repeating: Float(0.1), count: 10000))
        buffer.append(Array(repeating: Float(0.9), count: 10000))

        // Total writes: 20000, capacity 16000, so last 16000 = 6000 of 0.1 + 10000 of 0.9
        let last = buffer.lastSeconds(1.0)
        XCTAssertEqual(last.count, 16000)
        XCTAssertEqual(last[0], 0.1)
        XCTAssertEqual(last[5999], 0.1)
        XCTAssertEqual(last[6000], 0.9)
        XCTAssertEqual(last[15999], 0.9)
    }

    func testAudioSincePosition() {
        let buffer = StreamingAudioBuffer(capacitySeconds: 5.0, sampleRate: 16000)
        let markA = buffer.currentPosition

        buffer.append(Array(repeating: Float(0.2), count: 5000))
        let markB = buffer.currentPosition

        buffer.append(Array(repeating: Float(0.7), count: 5000))

        let since = buffer.audioSince(position: markB)
        XCTAssertEqual(since.count, 5000)
        XCTAssertEqual(since.first, 0.7)

        let sinceA = buffer.audioSince(position: markA)
        XCTAssertEqual(sinceA.count, 10000)
        XCTAssertEqual(sinceA.first, 0.2)
        XCTAssertEqual(sinceA.last, 0.7)
    }

    func testAudioSinceReturnsEmptyWhenPositionLost() {
        // Position older than buffer capacity — return at most capacity, don't crash.
        let buffer = StreamingAudioBuffer(capacitySeconds: 1.0, sampleRate: 16000)
        let stalePosition = buffer.currentPosition

        buffer.append(Array(repeating: Float(0.1), count: 32000))  // overwrites capacity twice

        let since = buffer.audioSince(position: stalePosition)
        XCTAssertLessThanOrEqual(since.count, 16000)
    }

    func testConcurrentAppendsAreSerialized() {
        let buffer = StreamingAudioBuffer(capacitySeconds: 10.0, sampleRate: 16000)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.append", attributes: .concurrent)

        for i in 0..<10 {
            group.enter()
            queue.async {
                let chunk = Array(repeating: Float(i) * 0.1, count: 1000)
                buffer.append(chunk)
                group.leave()
            }
        }

        group.wait()
        let total = buffer.lastSeconds(10.0)
        XCTAssertEqual(total.count, 10 * 1000)
    }
}
