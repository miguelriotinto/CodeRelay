import XCTest
// Module is c99-sanitized from PRODUCT_NAME "Code[Relay]" — see project.yml.
@testable import Code_Relay_

@MainActor
final class SessionNavigationTests: XCTestCase {

    // MARK: - nextIndex

    func testNextIndexWrapsAround() {
        XCTAssertEqual(SessionCoordinator.nextIndex(current: 2, count: 3), 0)
    }

    func testNextIndexAdvances() {
        XCTAssertEqual(SessionCoordinator.nextIndex(current: 0, count: 3), 1)
        XCTAssertEqual(SessionCoordinator.nextIndex(current: 1, count: 3), 2)
    }

    func testNextIndexReturnsNilForSingleSession() {
        XCTAssertNil(SessionCoordinator.nextIndex(current: 0, count: 1))
    }

    func testNextIndexReturnsNilForEmpty() {
        XCTAssertNil(SessionCoordinator.nextIndex(current: 0, count: 0))
    }

    // MARK: - previousIndex

    func testPreviousIndexWrapsAround() {
        XCTAssertEqual(SessionCoordinator.previousIndex(current: 0, count: 3), 2)
    }

    func testPreviousIndexDecrements() {
        XCTAssertEqual(SessionCoordinator.previousIndex(current: 2, count: 3), 1)
        XCTAssertEqual(SessionCoordinator.previousIndex(current: 1, count: 3), 0)
    }

    func testPreviousIndexReturnsNilForSingleSession() {
        XCTAssertNil(SessionCoordinator.previousIndex(current: 0, count: 1))
    }

    func testPreviousIndexReturnsNilForEmpty() {
        XCTAssertNil(SessionCoordinator.previousIndex(current: 0, count: 0))
    }

    // MARK: - Round-trip

    func testNextThenPreviousReturnsToOriginal() {
        let count = 5
        for start in 0..<count {
            guard let next = SessionCoordinator.nextIndex(current: start, count: count),
                  let back = SessionCoordinator.previousIndex(current: next, count: count) else {
                XCTFail("Should have valid indices for count=\(count)")
                return
            }
            XCTAssertEqual(back, start)
        }
    }
}
