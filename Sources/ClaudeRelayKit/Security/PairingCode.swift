import Foundation
import Security

/// A short, human-transcribable one-time pairing code.
///
/// Alphabet is Crockford Base32 — the 10 digits plus 22 uppercase letters,
/// excluding `I`, `L`, `O` and `U`. That removes every `0`/`O` and `1`/`I`/`L`
/// confusion when a user reads a code off a screen and types it on a phone.
/// `U` is excluded by the same standard (it keeps accidental profanity out of
/// generated codes).
///
/// 8 characters over a 32-symbol alphabet is 40 bits of entropy. Combined with
/// the server's per-IP rate limit and a 5-minute TTL, that is far out of reach
/// of online guessing.
public enum PairingCode {

    public static let length = 8

    public static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Characters a user might type instead of the canonical symbol.
    private static let confusables: [Character: Character] = [
        "I": "1", "L": "1", "O": "0", "U": "V"
    ]

    /// Generates a fresh code using the system CSPRNG.
    ///
    /// Rejection-samples raw bytes so every symbol is equally likely: 256 is
    /// not a multiple of 32, so a bare `byte % 32` would bias the first 8
    /// symbols. (256 happens to be divisible by 32, but the rejection guard is
    /// kept so the alphabet can change size without silently introducing bias.)
    public static func generate() -> String {
        var out = ""
        out.reserveCapacity(length)
        let count = alphabet.count
        let limit = (256 / count) * count
        while out.count < length {
            var byte: UInt8 = 0
            let status = withUnsafeMutablePointer(to: &byte) {
                SecRandomCopyBytes(kSecRandomDefault, 1, $0)
            }
            precondition(status == errSecSuccess, "Failed to generate random bytes")
            guard Int(byte) < limit else { continue }
            out.append(alphabet[Int(byte) % count])
        }
        return out
    }

    /// Canonicalizes user input, or returns nil if it cannot be a valid code.
    /// Strips hyphens and whitespace, uppercases, and folds confusable letters.
    public static func normalize(_ input: String) -> String? {
        var out = ""
        out.reserveCapacity(length)
        for raw in input.uppercased() {
            if raw == "-" || raw.isWhitespace { continue }
            let ch = confusables[raw] ?? raw
            guard alphabet.contains(ch) else { return nil }
            out.append(ch)
        }
        return out.count == length ? out : nil
    }

    /// Renders a code for display, grouped in fours: `K7QP-2M4X`.
    /// The hyphen is presentation only; `normalize` strips it.
    public static func formatted(_ code: String) -> String {
        guard code.count == length else { return code }
        let mid = code.index(code.startIndex, offsetBy: length / 2)
        return "\(code[code.startIndex..<mid])-\(code[mid...])"
    }
}
