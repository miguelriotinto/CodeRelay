import XCTest
@testable import CodeRelaySpeech

final class ProcessedTextTests: XCTestCase {

    func testDeliverableTextReturnsStringForDeliverableCases() {
        XCTAssertEqual(ProcessedText.passthrough("hi").deliverableText, "hi")
        XCTAssertEqual(ProcessedText.cleaned("clean").deliverableText, "clean")
        XCTAssertEqual(ProcessedText.enhanced("enhanced").deliverableText, "enhanced")
    }

    func testDeliverableTextFallsBackToOriginalOnRefusal() {
        XCTAssertEqual(ProcessedText.refused(original: "hi").deliverableText, "hi")
    }

    func testDeliverableTextReturnsNilForEmpty() {
        XCTAssertNil(ProcessedText.empty.deliverableText)
    }

    func testEquatable() {
        XCTAssertEqual(ProcessedText.cleaned("a"), ProcessedText.cleaned("a"))
        XCTAssertNotEqual(ProcessedText.cleaned("a"), ProcessedText.passthrough("a"))
    }
}
