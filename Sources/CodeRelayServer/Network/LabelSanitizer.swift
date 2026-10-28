import Foundation

/// The one rule for operator- or device-supplied labels that reach the log,
/// `TokenStore` or another client: trim, strip control characters and
/// newlines (a `\n` could forge a log line, an ESC could corrupt a terminal),
/// cap at 60 unicode scalars. Used for pairing labels (`handlePairRequest`,
/// `handlePairCreate`) and the `serverName` config key.
enum LabelSanitizer {
    static let maxScalars = 60

    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.controlCharacters.union(.newlines).inverted
        let stripped = trimmed.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(stripped).prefix(maxScalars))
    }
}
