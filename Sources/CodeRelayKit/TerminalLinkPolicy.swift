import Foundation

/// Where a terminal link came from.
public enum TerminalLinkSource: Sendable, Equatable {
    /// An OSC 8 hyperlink: the program chose the target, and the text on screen
    /// can be anything.
    case explicit
    /// URL-shaped text detected on screen: what you see is the target.
    case implicit
}

/// What a client does with a link the user activated.
public enum TerminalLinkDecision: Sendable, Equatable {
    /// Open it in the device's browser (or mail app) straight away.
    case open(URL)
    /// Show the full target first (Open / Copy / Cancel): the text on screen
    /// does not say where the link goes.
    case confirm(URL)
    /// Never open it.
    case reject
}

/// The one rule every client applies before opening a link from terminal
/// output. Terminal output is written by whatever runs on the host, so a link
/// in it is untrusted input: only web and mail links open, and our own
/// `coderelay:` deep links (pairing, session switching) can never be fired by
/// text a program printed. Mirrored one-to-one by Kotlin's
/// `relay.protocol.TerminalLinkPolicy`; both are tested against the same
/// vectors (`CodeRelayAndroid/core-protocol/src/test/resources/terminal-link-vectors.json`).
public enum TerminalLinkPolicy {
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]
    /// Longer than any real link a terminal shows, short enough to bound work.
    public static let maxLength = 2048

    /// - Parameters:
    ///   - candidate: the link target (OSC 8 payload, or the detected text).
    ///   - source: explicit (OSC 8) or implicit (detected on screen).
    ///   - visibleText: for an explicit link, the text of the cells that carry
    ///     it. Ignored for implicit links.
    public static func decide(_ candidate: String,
                              source: TerminalLinkSource,
                              visibleText: String? = nil) -> TerminalLinkDecision {
        let link = source == .implicit ? trimImplicit(candidate) : candidate
        guard !link.isEmpty,
              link.utf8.count <= maxLength,
              link.unicodeScalars.allSatisfy({ uriCharacters.contains($0) }),
              let colon = link.firstIndex(of: ":") else { return .reject }

        let scheme = link[..<colon]
        guard isValidScheme(scheme), allowedSchemes.contains(scheme.lowercased()) else { return .reject }

        let rest = link[link.index(after: colon)...]
        var hasUserInfo = false
        if scheme.lowercased() == "mailto" {
            guard rest.contains("@"), !rest.hasPrefix("@") else { return .reject }
        } else {
            guard rest.hasPrefix("//") else { return .reject }
            let afterSlashes = rest.dropFirst(2)
            let authority = afterSlashes.prefix { !"/?#".contains($0) }
            hasUserInfo = authority.contains("@")
            let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
            let host = hostAndPort.hasPrefix("[")
                ? hostAndPort.prefix { $0 != "]" }.dropFirst()
                : hostAndPort.prefix { $0 != ":" }
            guard !host.isEmpty else { return .reject }
        }

        guard let url = URL(string: link) else { return .reject }
        if hasUserInfo { return .confirm(url) }
        if source == .explicit, !visibleTextMatches(visibleText, link: link) { return .confirm(url) }
        return .open(url)
    }

    /// Trailing characters that end a sentence around a URL rather than belong
    /// to it, and closing brackets with no opener inside the URL — `(see
    /// https://x.dev/a)` must not open `https://x.dev/a)`.
    public static func trimImplicit(_ text: String) -> String {
        var s = Substring(text)
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while let last = s.last {
            if ".,;:!?'\"".contains(last) {
                s = s.dropLast()
            } else if let opener = pairs[last],
                      s.filter({ $0 == last }).count > s.filter({ $0 == opener }).count {
                s = s.dropLast()
            } else {
                break
            }
        }
        return String(s)
    }

    /// RFC 3986 unreserved + reserved characters and `%`. Checked here rather
    /// than left to the URL parser: Foundation percent-encodes characters such
    /// as `|` and `{` that `java.net.URI` rejects, and the two policies must
    /// agree. Also excludes whitespace, controls, bidi overrides and non-ASCII.
    private static let uriCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")

    private static func isValidScheme(_ scheme: Substring) -> Bool {
        guard let first = scheme.unicodeScalars.first,
              CharacterSet.letters.contains(first), first.isASCII else { return false }
        return scheme.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+.-".unicodeScalars.contains($0))
        }
    }

    /// The text on screen "is" the link when it shows the whole target, with
    /// or without its scheme (`example.com/a` for `https://example.com/a`).
    private static func visibleTextMatches(_ visible: String?, link: String) -> Bool {
        guard let shown = visible?.trimmingCharacters(in: .whitespaces), !shown.isEmpty else {
            return false
        }
        if shown == link { return true }
        for prefix in ["https://", "http://", "mailto:"] where link.lowercased().hasPrefix(prefix) {
            if shown == String(link.dropFirst(prefix.count)) { return true }
        }
        return false
    }
}
