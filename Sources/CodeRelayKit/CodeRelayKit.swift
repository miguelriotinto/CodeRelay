/// CodeRelayKit provides shared types and utilities for the CodeRelay system.
public enum CodeRelayKit {
    public static let version = "0.3.24"

    /// Current wire-protocol version. Bump when messages change in breaking ways.
    public static let protocolVersion = 2
    /// Capability advertised in `auth_success.capabilities` when the relay has
    /// a usable prompt optimizer (enabled + key readable at startup, spec §8).
    public static let promptOptimizerCapability = "prompt_optimizer"

    /// Oldest protocol version this build can communicate with.
    /// Keep at 0 until a breaking wire-protocol change forces older clients out.
    public static let minProtocolVersion = 0
}

// NOTE: A `ProtocolFeature` enum existed here at one point to document per-
// feature minimum protocol versions. It was never consulted at a call site
// (all features shipped at v1), so it was removed to keep `CodeRelayKit`
// focused. Re-introduce only when a second protocol version actually ships.
