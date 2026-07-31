import ArgumentParser
import Foundation
import ClaudeRelayKit

/// Pure presentation for `claude-relay setup`, split out so the output is
/// testable without booting a server or touching launchd.
struct SetupPresenter {

    static func render(
        url: PairingURL,
        expiresAt: Date,
        now: Date,
        host: HostCandidate,
        includeQR: Bool
    ) -> String {
        var out = ""

        let reason: String
        switch host.kind {
        case .bonjour:        reason = "Bonjour — survives DHCP, ATS-safe"
        case .lan:            reason = "LAN address — may change when the DHCP lease renews"
        case .loopback:       reason = "loopback — only reachable from this Mac"
        case .cgnat:          reason = "Tailscale — requires TLS"
        case .publicHostname: reason = "public hostname — requires TLS"
        case .ipv6:           reason = "IPv6 address — requires TLS"
        }
        out += "✓ host: \(host.host)  (\(reason))\n\n"

        if includeQR, let qr = TerminalQRRenderer().render(url.urlString) {
            out += qr
            out += "\n"
        } else {
            out += "  \(url.urlString)\n\n"
        }

        let formattedCode = PairingCode.formatted(url.code)
        out += "  scan in CodeRelay, or enter code:  \(formattedCode)\n"

        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 {
            out += "  this code has expired — run `claude-relay setup` again\n"
        } else {
            let minutes = Int(remaining) / 60
            let seconds = Int(remaining) % 60
            out += String(format: "  expires in %d:%02d\n", minutes, seconds)
        }

        out += "\nOptional: claude-relay hook install    (authoritative Claude Code state)\n"
        return out
    }
}

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Start the service and show a pairing QR code"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Override the host address put in the pairing code")
    var host: String?

    @Flag(name: .customLong("no-qr"), help: "Print the pairing URL and code without drawing a QR")
    var noQR = false

    @Option(name: .long, help: "Label for the token this pairing will mint")
    var label: String?

    func run() async throws {
        let client = AdminClient(port: globals.port)

        // 1. Ensure the service is up — via whichever manager owns it.
        if await !client.isServiceRunning() {
            try await startService()
            // Give the server a moment to bind before minting.
            try await Task.sleep(for: .seconds(1))
            guard await client.isServiceRunning() else {
                print("The service did not come up. Check: claude-relay logs show")
                throw ExitCode.failure
            }
        }

        // 2. Resolve the host that goes in the QR (before minting, so the common
        // "no address found" failure exits without burning a code).
        let candidate: HostCandidate
        if let host {
            // Classify the explicitly-passed host so TLS guard applies.
            let kind = HostAddressProbe.kind(forHost: host)
            candidate = HostCandidate(host: host, kind: kind)
        } else {
            guard let chosen = HostAddressResolver.choose(from: HostAddressProbe.candidates()) else {
                print("Could not determine a host address. Pass --host explicitly.")
                throw ExitCode.failure
            }
            candidate = chosen
        }

        // Validate the host against the same rule the parser applies, still
        // before minting: a typo must not burn a code, because burning enough of
        // them evicts codes that are legitimately pending.
        guard PairingURL.isValidHost(candidate.host) else {
            print("The host '\(candidate.host)' produces an invalid pairing URL. Pass a valid hostname or IP address.")
            throw ExitCode.failure
        }

        // 3. Mint a pairing code.
        let response: PairCreateResponse = try await client.post(
            "/pair/create", body: PairCreateRequest(label: label))

        // 4. Check the TLS guard. MUST use response.tls (the running server's
        // launch-time config), not on-disk config — disk may have been edited
        // without a server restart, so wsPort/tls can differ from the running
        // state. A refused setup strands a live code for up to 5 min, but the
        // code is single-use and unguessable, so the trade-off favors correctness
        // over slot pressure.
        if HostAddressResolver.requiresTLS(candidate) && !response.tls {
            print("""
            The only reachable address (\(candidate.host)) needs TLS, but the server has none configured.
            Apple's ATS blocks plaintext ws:// to this address, so a pairing code would not connect.
            Configure TLS first:
              claude-relay config set tlsCert <path> tlsKey <path>
            """)
            throw ExitCode.failure
        }

        let url = PairingURL(host: candidate.host, port: response.wsPort,
                             useTLS: response.tls, code: response.code)

        if globals.json {
            let formatter = ISO8601DateFormatter()
            print(OutputFormatter.formatJSON(SetupJSON(
                code: response.code, formattedCode: response.formattedCode,
                expiresAt: formatter.string(from: response.expiresAt), host: candidate.host,
                port: response.wsPort, tls: response.tls, url: url.urlString)))
            return
        }

        print(SetupPresenter.render(
            url: url,
            expiresAt: response.expiresAt,
            now: Date(),
            host: candidate,
            includeQR: !noQR
        ))
    }

    /// Starts the service using whichever manager owns it, so `setup` never
    /// installs a second competing launchd agent.
    private func startService() async throws {
        let detector = ServiceManagerDetector.detect()
        switch detector.owner {
        case .homebrew:
            print("Starting via Homebrew services…")
            try runShell(["/bin/sh", "-c", "brew services start clauderelay"])
        case .launchAgent:
            print("Starting the launchd agent…")
            var start = StartCommand()
            start.globals = globals
            try await start.run()
        case .both:
            print(detector.nudge(for: .start) ?? "Two service managers are installed.")
            throw ExitCode.failure
        case .none:
            // If the binary came from Homebrew but no service is installed yet,
            // tell the operator to start the Homebrew service instead of
            // installing a CLI-managed agent that will conflict later.
            if detector.installedViaHomebrew {
                print("""
                    clauderelay was installed via Homebrew.
                    Start the service with:
                      brew services start clauderelay
                    """)
                throw ExitCode.failure
            }
            print("Installing the launchd agent…")
            var load = LoadCommand()
            load.globals = globals
            try await load.run()
        }
    }
}

private struct PairCreateRequest: Encodable {
    let label: String?
}

struct PairCreateResponse: Decodable {
    let code: String
    let formattedCode: String
    let expiresAt: Date
    let wsPort: UInt16
    let tls: Bool
}

private struct SetupJSON: Encodable {
    let code: String
    let formattedCode: String
    let expiresAt: String
    let host: String
    let port: UInt16
    let tls: Bool
    let url: String
}

/// Runs a shell command synchronously, capturing stderr and throwing on failure.
private func runShell(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())

    let pipe = Pipe()
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        throw CLIError.shellCommandFailed(
            command: arguments[0],
            status: Int(process.terminationStatus),
            stderr: errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
