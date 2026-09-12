import Foundation
import CodeRelaySpeech
@testable import CodeRelayApp

final class MockTranscriber: SpeechTranscribing {
    var resultToReturn: String = "hello world"
    var shouldThrow = false
    var transcribeCallCount = 0

    func transcribe(_ audioBuffer: [Float], skipNoSpeechFilter: Bool) async throws -> String {
        transcribeCallCount += 1
        if shouldThrow { throw TranscriberError.emptyTranscription }
        return resultToReturn
    }
}

final class MockCleaner: TextCleaning {
    var resultToReturn: String?
    var shouldThrow = false
    var cleanCallCount = 0

    func clean(_ text: String) async throws -> String {
        cleanCallCount += 1
        if shouldThrow { throw CleanerError.modelNotLoaded }
        return resultToReturn ?? text
    }
}
