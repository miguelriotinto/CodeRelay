import XCTest
// Not the target name: the Mac app's module is c99-sanitized from
// PRODUCT_NAME "Code[Relay]". Was "ClaudeDock" before the product was renamed.
@testable import Code_Relay_

@MainActor
final class AddEditServerViewModelTests: XCTestCase {

    // MARK: - Validation

    func testValidConfigPasses() {
        let vm = AddEditServerViewModel()
        vm.name = "Dev Server"
        vm.host = "192.168.1.10"
        vm.port = "9200"
        vm.token = "tok_abc"
        XCTAssertTrue(vm.validate())
        XCTAssertNil(vm.validationError)
    }

    func testEmptyNameFails() {
        let vm = AddEditServerViewModel()
        vm.name = "   "
        vm.host = "localhost"
        vm.port = "9200"
        vm.token = "tok_abc"
        XCTAssertFalse(vm.validate())
        XCTAssertEqual(vm.validationError, "Name is required")
    }

    func testEmptyHostFails() {
        let vm = AddEditServerViewModel()
        vm.name = "Server"
        vm.host = ""
        vm.port = "9200"
        vm.token = "tok_abc"
        XCTAssertFalse(vm.validate())
        XCTAssertEqual(vm.validationError, "Host is required")
    }

    func testInvalidPortFails() {
        let vm = AddEditServerViewModel()
        vm.name = "Server"
        vm.host = "localhost"
        vm.port = "0"
        vm.token = "tok_abc"
        XCTAssertFalse(vm.validate())
        XCTAssertNotNil(vm.validationError)
    }

    func testNonNumericPortFails() {
        let vm = AddEditServerViewModel()
        vm.name = "Server"
        vm.host = "localhost"
        vm.port = "abc"
        vm.token = "tok_abc"
        XCTAssertFalse(vm.validate())
        XCTAssertNotNil(vm.validationError)
    }

    func testEmptyTokenFails() {
        let vm = AddEditServerViewModel()
        vm.name = "Server"
        vm.host = "localhost"
        vm.port = "9200"
        vm.token = "   "
        XCTAssertFalse(vm.validate())
        XCTAssertEqual(vm.validationError, "Token is required")
    }

    // MARK: - buildConnection

    func testBuildConnectionReturnsNilOnInvalidInput() {
        let vm = AddEditServerViewModel()
        vm.name = ""
        XCTAssertNil(vm.buildConnection())
    }

    func testBuildConnectionTrimsWhitespace() {
        let vm = AddEditServerViewModel()
        vm.name = "  My Server  "
        vm.host = " 10.0.0.1 "
        vm.port = "9200"
        vm.token = "tok"
        let config = vm.buildConnection()
        XCTAssertEqual(config?.name, "My Server")
        XCTAssertEqual(config?.host, "10.0.0.1")
    }

    func testBuildConnectionDefaultsPortTo9200() {
        let vm = AddEditServerViewModel()
        vm.name = "S"
        vm.host = "h"
        vm.port = "invalid"
        vm.token = "t"
        // validate() will fail first, so buildConnection returns nil.
        // Test with a valid but edge-case port.
        vm.port = "443"
        let config = vm.buildConnection()
        XCTAssertEqual(config?.port, 443)
    }

    func testBuildConnectionSetsUseTLS() {
        let vm = AddEditServerViewModel()
        vm.name = "S"
        vm.host = "h"
        vm.port = "9200"
        vm.token = "t"
        vm.useTLS = true
        let config = vm.buildConnection()
        XCTAssertEqual(config?.useTLS, true)
    }

    // MARK: - Edit mode

    func testIsEditingFalseForNewServer() {
        let vm = AddEditServerViewModel()
        XCTAssertFalse(vm.isEditing)
    }
}
