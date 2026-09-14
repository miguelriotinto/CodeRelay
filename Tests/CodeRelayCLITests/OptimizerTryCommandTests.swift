import XCTest
@testable import CodeRelayCLI

final class OptimizerTryCommandTests: XCTestCase {
    func testRenderOk() {
        let response = OptimizerTryResponse(status: "ok", prompt: "Run tests and fix failures.", message: nil)
        let (text, isFailure) = OptimizerTryCommand.render(response)
        XCTAssertEqual(text, "Run tests and fix failures.")
        XCTAssertFalse(isFailure)
    }

    func testRenderPassthrough() {
        let response = OptimizerTryResponse(status: "passthrough", prompt: nil, message: nil)
        let (text, isFailure) = OptimizerTryCommand.render(response)
        XCTAssertEqual(text, "passthrough — the model left the draft as it was")
        XCTAssertFalse(isFailure)
    }

    func testRenderFailed() {
        let response = OptimizerTryResponse(status: "failed", prompt: nil, message: "Model refused the request")
        let (text, isFailure) = OptimizerTryCommand.render(response)
        XCTAssertEqual(text, "failed: Model refused the request")
        XCTAssertTrue(isFailure)
    }
}
