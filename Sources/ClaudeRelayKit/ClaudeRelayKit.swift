/// ClaudeRelayKit provides shared types and utilities for the ClaudeRelay system.
public enum ClaudeRelayKit {
    public static let version = "0.3.21"

    /// Current wire-protocol version. Bump when messages change in breaking ways.
    public static let protocolVersion = 1

    /// Oldest protocol version this build can communicate with.
    /// Keep at 0 until a breaking wire-protocol change forces older clients out.
    public static let minProtocolVersion = 0
}

// NOTE: A `ProtocolFeature` enum existed here at one point to document per-
// feature minimum protocol versions. It was never consulted at a call site
// (all features shipped at v1), so it was removed to keep `ClaudeRelayKit`
// focused. Re-introduce only when a second protocol version actually ships.
