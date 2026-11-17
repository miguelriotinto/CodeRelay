import SwiftUI

/// Port defaults for the add-server and pairing forms — the Swift side of
/// Android's `ServerFormLogic.portForTLSChange`, so every client treats the
/// "Use TLS" toggle the same way.
public enum ServerFormLogic {
    /// The relay's default plaintext WebSocket port (`wsPort`).
    public static let defaultPlaintextPort = "9200"
    /// The TLS default: `wss://` behind a reverse proxy on standard HTTPS.
    public static let defaultTLSPort = "443"

    /// The port to show after the "Use TLS" toggle flips. Only the well-known
    /// defaults swap, so a deliberate custom port is never clobbered:
    /// TLS on with the plaintext default (or a blank field) gives 443, TLS off
    /// with 443 gives 9200, anything else is returned unchanged.
    public static func portForTLSChange(_ port: String, useTLS: Bool) -> String {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if useTLS {
            return trimmed.isEmpty || trimmed == defaultPlaintextPort ? defaultTLSPort : port
        }
        return trimmed == defaultTLSPort ? defaultPlaintextPort : port
    }
}

/// A form with a port field and a "Use TLS" toggle.
@MainActor
public protocol TLSPortForm: AnyObject {
    var port: String { get set }
    var useTLS: Bool { get set }
}

extension TLSPortForm {
    /// Bind the "Use TLS" toggle to this, not to `useTLS` directly: a user flip
    /// swaps the default port, while code that sets `useTLS` (loading a saved
    /// server, prefilling from a pairing QR) keeps the port it was given.
    public var useTLSToggle: Binding<Bool> {
        Binding(get: { self.useTLS }, set: { on in
            self.port = ServerFormLogic.portForTLSChange(self.port, useTLS: on)
            self.useTLS = on
        })
    }
}
