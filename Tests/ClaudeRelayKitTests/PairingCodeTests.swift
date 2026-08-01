import XCTest
@testable import ClaudeRelayKit

final class PairingCodeTests: XCTestCase {

    func testAlphabetIsCrockfordBase32WithoutAmbiguousLetters() {
        XCTAssertEqual(PairingCode.alphabet.count, 32)
        for banned: Character in ["I", "L", "O", "U"] {
            XCTAssertFalse(PairingCode.alphabet.contains(banned), "\(banned) is ambiguous")
        }
        // Uppercase + digits only.
        for ch in PairingCode.alphabet {
            XCTAssertTrue(ch.isUppercase || ch.isNumber, "unexpected symbol \(ch)")
        }
    }

    func testGenerateProducesCodeOfExpectedLengthFromAlphabet() {
        let code = PairingCode.generate()
        XCTAssertEqual(code.count, PairingCode.length)
        for ch in code {
            XCTAssertTrue(PairingCode.alphabet.contains(ch), "\(ch) not in alphabet")
        }
    }

    func testGenerateIsNotConstant() {
        let codes = Set((0..<50).map { _ in PairingCode.generate() })
        XCTAssertGreaterThan(codes.count, 45, "generation looks non-random")
    }

    func testNormalizeStripsHyphensWhitespaceAndUppercases() {
        XCTAssertEqual(PairingCode.normalize(" k7qp-2m4x "), "K7QP2M4X")
        XCTAssertEqual(PairingCode.normalize("K7QP2M4X"), "K7QP2M4X")
    }

    func testNormalizeMapsVisuallyConfusableInput() {
        // Users type O for 0 and I/L for 1 — accept and fold them.
        XCTAssertEqual(PairingCode.normalize("OI2345L7"), "012345 17".replacingOccurrences(of: " ", with: ""))
    }

    func testNormalizeRejectsWrongLengthOrIllegalCharacters() {
        XCTAssertNil(PairingCode.normalize("K7QP2M4"))      // too short
        XCTAssertNil(PairingCode.normalize("K7QP2M4XX"))    // too long
        XCTAssertNil(PairingCode.normalize("K7QP2M4!"))     // illegal symbol
        XCTAssertNil(PairingCode.normalize(""))
    }

    func testFormattedGroupsInFours() {
        XCTAssertEqual(PairingCode.formatted("K7QP2M4X"), "K7QP-2M4X")
    }

    func testNormalizeRejectsVeryLongInput() {
        // Build a 100k character string of valid alphabet symbols to test the DoS guard.
        // The bound (64) exists because normalize is reachable pre-auth and runs inside
        // an actor, so unbounded input could serialize all other mint/redeem calls.
        let longInput = String(repeating: "K", count: 100_000)
        let start = Date()
        let result = PairingCode.normalize(longInput)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result, "very long input should be rejected")
        XCTAssertLessThan(elapsed, 0.1, "normalize should return fast on oversized input")
    }

    func testNormalizeInputLengthBoundary() {
        // 64 valid characters is still not a valid code (must be exactly 8 after stripping),
        // but it should not be rejected by the input-length guard alone.
        let atCap = String(repeating: "K", count: 64)
        let overCap = String(repeating: "K", count: 65)
        // The at-cap case returns nil via the `out.count == length` check, not the input bound.
        XCTAssertNil(PairingCode.normalize(atCap), "64 chars is not 8 chars, invalid length")
        // The over-cap case returns nil via the input bound — it never scans the string.
        XCTAssertNil(PairingCode.normalize(overCap), "over-cap input rejected by bound")
    }
}
