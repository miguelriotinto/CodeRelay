import XCTest
import Foundation
@testable import CodeRelayKit

/// Base class shared by the three protocol test suites. Provides a single
/// sorted-keys encoder, a standard decoder, and a JSON-object helper.
///
/// The suites are split by message direction to keep each file well under
/// SwiftLint's `file_length` / `type_body_length` thresholds and to make the
/// responsibility of each easy to infer from the filename.
class ProtocolTestCase: XCTestCase {

    let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    let decoder = JSONDecoder()

    func jsonObject(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }
}
