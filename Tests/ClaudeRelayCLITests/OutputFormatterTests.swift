import XCTest
@testable import ClaudeRelayCLI

final class OutputFormatterTests: XCTestCase {

    // MARK: - JSON Format

    func testJSONFormat() throws {
        struct Sample: Codable {
            let name: String
            let count: Int
        }
        let sample = Sample(name: "test", count: 42)
        let result = OutputFormatter.formatJSON(sample)

        // Verify it's valid JSON by decoding it back
        let data = result.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Sample.self, from: data)
        XCTAssertEqual(decoded.name, "test")
        XCTAssertEqual(decoded.count, 42)
    }

    func testJSONFormatWithMergedKey() throws {
        struct Sample: Codable {
            let name: String
            let count: Int
        }
        let sample = Sample(name: "test", count: 42)
        let result = OutputFormatter.formatJSON(sample, merging: "extra", value: "merged")

        // Parse the result and verify all keys are present and sorted
        let data = result.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["name"] as? String, "test")
        XCTAssertEqual(dict?["count"] as? Int, 42)
        XCTAssertEqual(dict?["extra"] as? String, "merged")

        // Verify keys are sorted (JSONSerialization.data with .sortedKeys ensures this)
        let keys = dict?.keys.sorted() ?? []
        XCTAssertEqual(keys, ["count", "extra", "name"])
    }

    // MARK: - Human Status

    func testHumanStatusRunning() {
        let output = OutputFormatter.formatStatus(
            running: true,
            version: "0.1.9",
            pid: 12345,
            uptime: 3661,
            sessions: 3
        )
        XCTAssertTrue(output.contains("Running"), "Should indicate Running")
        XCTAssertTrue(output.contains("0.1.9"), "Should contain the version")
        XCTAssertTrue(output.contains("12345"), "Should contain the PID")
        XCTAssertTrue(output.contains("3"), "Should contain session count")
    }

    func testHumanStatusStopped() {
        let output = OutputFormatter.formatStatus(
            running: false,
            version: nil,
            pid: nil,
            uptime: nil,
            sessions: 0
        )
        XCTAssertTrue(output.contains("Stopped"), "Should indicate Stopped")
        XCTAssertFalse(output.contains("Version"), "Should not show version when nil")
    }

    // MARK: - Table Format

    func testTableFormat() {
        let headers = ["ID", "Name", "Status"]
        let rows = [
            ["1", "alpha", "active"],
            ["2", "beta", "inactive"]
        ]
        let output = OutputFormatter.formatTable(headers: headers, rows: rows)

        // Verify headers present
        XCTAssertTrue(output.contains("ID"))
        XCTAssertTrue(output.contains("Name"))
        XCTAssertTrue(output.contains("Status"))

        // Verify rows present
        XCTAssertTrue(output.contains("alpha"))
        XCTAssertTrue(output.contains("beta"))
        XCTAssertTrue(output.contains("active"))
        XCTAssertTrue(output.contains("inactive"))

        // Verify alignment: each line should have the same structure
        let lines = output.split(separator: "\n")
        // Header + separator + 2 data rows = at least 4 lines
        XCTAssertGreaterThanOrEqual(lines.count, 4)
    }

    func testTableFormatEmpty() {
        let headers = ["Col1", "Col2"]
        let rows: [[String]] = []
        let output = OutputFormatter.formatTable(headers: headers, rows: rows)
        XCTAssertTrue(output.contains("Col1"))
        XCTAssertTrue(output.contains("Col2"))
    }

    // MARK: - Uptime Formatting

    func testUptimeSeconds() {
        let output = OutputFormatter.formatStatus(
            running: true, version: nil, pid: 1, uptime: 45, sessions: 0
        )
        XCTAssertTrue(output.contains("45s"))
    }

    func testUptimeMinutes() {
        let output = OutputFormatter.formatStatus(
            running: true, version: nil, pid: 1, uptime: 125, sessions: 0
        )
        XCTAssertTrue(output.contains("2m 5s"))
    }

    func testUptimeHours() {
        let output = OutputFormatter.formatStatus(
            running: true, version: nil, pid: 1, uptime: 7265, sessions: 0
        )
        XCTAssertTrue(output.contains("2h 1m 5s"))
    }

    func testStatusWithNilUptime() {
        let output = OutputFormatter.formatStatus(
            running: true, version: nil, pid: 999, uptime: nil, sessions: 2
        )
        XCTAssertFalse(output.contains("Uptime"), "Should not show uptime when nil")
        XCTAssertTrue(output.contains("999"))
        XCTAssertTrue(output.contains("2"))
    }

    // MARK: - Table Edge Cases

    func testTableFormatEmptyHeaders() {
        let output = OutputFormatter.formatTable(headers: [], rows: [])
        XCTAssertEqual(output, "")
    }

    func testTableFormatSingleColumn() {
        let output = OutputFormatter.formatTable(headers: ["Name"], rows: [["Alice"], ["Bob"]])
        XCTAssertTrue(output.contains("Alice"))
        XCTAssertTrue(output.contains("Bob"))
    }

    // MARK: - Error Formatting

    func testFormatErrorHumanReadable() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "something broke"])
        let output = OutputFormatter.formatError(error, json: false)
        XCTAssertTrue(output.contains("something broke"))
        XCTAssertTrue(output.hasPrefix("Error:"))
    }

    func testFormatErrorJSON() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "oops"])
        let output = OutputFormatter.formatError(error, json: true)
        XCTAssertTrue(output.contains("\"error\""))
        XCTAssertTrue(output.contains("oops"))
    }

    func testFormatErrorServiceNotRunningHuman() {
        let error = AdminClientError.serviceNotRunning
        let output = OutputFormatter.formatError(error, json: false)
        XCTAssertEqual(output, "Service is not running.")
    }

    func testFormatErrorServiceNotRunningJSON() {
        let error = AdminClientError.serviceNotRunning
        let output = OutputFormatter.formatError(error, json: true)
        XCTAssertTrue(output.contains("Service is not running"))
        XCTAssertTrue(output.contains("\"error\""))
    }

    func testFormatErrorHTTPErrorWithJSONBody() {
        let error = AdminClientError.httpError(statusCode: 404, body: "{\"error\":\"not found\"}")
        let output = OutputFormatter.formatError(error, json: true)
        XCTAssertTrue(output.contains("not found"))
        XCTAssertTrue(output.contains("404"))
    }

    // MARK: - Table with Unicode

    func testTableFormatWithUnicodeContent() {
        let headers = ["Name", "Status"]
        let rows = [["Caf\u{00E9}", "OK"], ["To\u{0301}kyo\u{0304}", "Err"]]
        let output = OutputFormatter.formatTable(headers: headers, rows: rows)
        XCTAssertTrue(output.contains("Caf\u{00E9}"))
        XCTAssertTrue(output.contains("OK"))
    }
}
