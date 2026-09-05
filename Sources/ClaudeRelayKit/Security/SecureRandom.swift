import Foundation

/// Cryptographically secure random bytes, from one source on every platform.
///
/// `SystemRandomNumberGenerator` is documented as cryptographically secure and
/// is backed by the platform CSPRNG — `arc4random_buf` on Darwin, `getrandom(2)`
/// on Linux. It replaces `SecRandomCopyBytes`, which is a Security.framework
/// API and does not exist off Apple platforms; keeping a single implementation
/// means the token and pairing-code generators cannot drift between the macOS
/// and Linux servers.
enum SecureRandom {
    /// `count` uniformly random bytes.
    static func bytes(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// One uniformly random byte.
    static func byte() -> UInt8 {
        var generator = SystemRandomNumberGenerator()
        return UInt8.random(in: .min ... .max, using: &generator)
    }
}
