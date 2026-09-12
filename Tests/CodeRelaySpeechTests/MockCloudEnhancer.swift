import Foundation
@testable import CodeRelaySpeech

/// Test double for cloud prompt enhancement. Returns pre-programmed results
/// or throws a pre-programmed error.
final class MockCloudEnhancer: CloudEnhancing, @unchecked Sendable {
    var resultToReturn: String = "enhanced text"
    var errorToThrow: Error?
    var callCount = 0
    var lastToken: String?
    var lastRegion: String?

    func enhance(_ text: String, bearerToken: String, region: String) async throws -> String {
        callCount += 1
        lastToken = bearerToken
        lastRegion = region
        if let err = errorToThrow { throw err }
        return resultToReturn
    }
}
