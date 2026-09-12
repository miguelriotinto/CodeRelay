import XCTest
@testable import CodeRelaySpeech

final class StreamingAudioSourceInterruptionTests: XCTestCase {

    func testInterruptionEventEnumCases() {
        let a = StreamingAudioSource.InterruptionEvent.began
        let b = StreamingAudioSource.InterruptionEvent.ended(shouldResume: true)
        let c = StreamingAudioSource.InterruptionEvent.ended(shouldResume: false)
        XCTAssertNotEqual(String(describing: a), String(describing: b))
        XCTAssertNotEqual(String(describing: b), String(describing: c))
    }
}
