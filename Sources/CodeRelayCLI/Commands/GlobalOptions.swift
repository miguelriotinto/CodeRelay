import ArgumentParser

public struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Output in JSON format")
    var json = false

    @Flag(name: .long, help: "Suppress non-essential output")
    var quiet = false

    @Option(name: [.long, .customShort("p")], help: "Admin API port")
    var adminPort: UInt16 = 9100

    @Option(name: .long, help: "WebSocket port")
    var wsPort: UInt16?

    @Flag(
        name: .customLong("bind-all"),
        inversion: .prefixedNo,
        help: ArgumentHelp(
            "Bind the WebSocket server on 0.0.0.0 (default; network-reachable).",
            discussion: "Pass --no-bind-all to restrict to 127.0.0.1 (localhost only)."
        )
    )
    var bindAll: Bool = true

    /// Backward-compatible alias: commands that used `globals.port` now use this.
    var port: UInt16 { adminPort }

    public init() {}
}
