import Foundation

/// Which launchd manager owns the relay service.
enum ServiceOwner: Equatable {
    case homebrew
    case launchAgent
    case both
    case none
}

enum ServiceVerb: String {
    case start, stop, restart, load, unload
}

/// Works out which launchd manager owns the service so the CLI never drives the
/// wrong label.
///
/// Two managers exist and they are mutually exclusive in practice:
///
/// | Manager             | Label / plist                  |
/// | ------------------- | ------------------------------ |
/// | `brew services`     | `homebrew.mxcl.clauderelay`    |
/// | `claude-relay load` | `com.claude.relay`             |
///
/// Every service command used to hardcode `com.claude.relay`, so on a Homebrew
/// install — the documented path — `start`/`stop`/`restart`/`unload` failed with
/// a raw `launchctl failed:` error against a label that was never loaded.
/// `status`/`health` were unaffected because they talk to the admin HTTP API.
struct ServiceManagerDetector {

    static let homebrewPlistName = "homebrew.mxcl.clauderelay.plist"
    static let launchAgentPlistName = "com.claude.relay.plist"

    private let homebrewPlistExists: Bool
    private let launchAgentPlistExists: Bool
    private let binaryPath: String

    init(homebrewPlistExists: Bool, launchAgentPlistExists: Bool, binaryPath: String) {
        self.homebrewPlistExists = homebrewPlistExists
        self.launchAgentPlistExists = launchAgentPlistExists
        self.binaryPath = binaryPath
    }

    /// Reads the real filesystem. Injected values are used by tests.
    static func detect() -> ServiceManagerDetector {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let fm = FileManager.default
        return ServiceManagerDetector(
            homebrewPlistExists: fm.fileExists(
                atPath: launchAgents.appendingPathComponent(homebrewPlistName).path),
            launchAgentPlistExists: fm.fileExists(
                atPath: launchAgents.appendingPathComponent(launchAgentPlistName).path),
            binaryPath: CommandLine.arguments.first ?? ""
        )
    }

    var owner: ServiceOwner {
        switch (homebrewPlistExists, launchAgentPlistExists) {
        case (true, true):   return .both
        case (true, false):  return .homebrew
        case (false, true):  return .launchAgent
        case (false, false): return .none
        }
    }

    /// True when this CLI binary lives under a Homebrew prefix — used to nudge
    /// about the *installer* on a machine with no service installed yet.
    var installedViaHomebrew: Bool {
        binaryPath.hasPrefix("/opt/homebrew/") || binaryPath.hasPrefix("/usr/local/")
    }

    func startCommand() -> String? { command(for: .start) }
    func stopCommand() -> String? { command(for: .stop) }
    func restartCommand() -> String? { command(for: .restart) }

    private func command(for verb: ServiceVerb) -> String? {
        switch owner {
        case .homebrew, .both: return "brew services \(verb.rawValue) clauderelay"
        case .launchAgent:     return "claude-relay \(verb.rawValue)"
        case .none:            return nil
        }
    }

    /// A message to print instead of driving the wrong manager, or nil when the
    /// command is the right one for this host.
    ///
    /// Deliberately a *nudge*: we print the correct command rather than shelling
    /// out to Homebrew on the user's behalf. A command documented as driving
    /// launchctl silently invoking brew would be surprising, and the nudge
    /// teaches the right tool for next time.
    func nudge(for verb: ServiceVerb) -> String? {
        switch owner {
        case .both:
            // In the .both state, `unload` must be able to proceed — it is the
            // remedy for the duplicate-manager situation, not a hazard. For
            // start/stop/restart, we still warn because driving the wrong label
            // is wrong.
            if verb == .unload {
                return nil  // Let it proceed to remove the CLI-installed manager.
            }
            return """
            Two service managers are installed for clauderelay:
              • \(Self.homebrewPlistName) (Homebrew)
              • \(Self.launchAgentPlistName) (claude-relay load)
            Both will try to bind the WebSocket port. Remove one before continuing:
              brew services stop clauderelay     # keep the CLI-managed agent
              claude-relay unload                # keep the Homebrew-managed one
            """

        case .homebrew:
            if verb == .load {
                return """
                clauderelay is managed by Homebrew services.
                Running `load` would install a second launchd agent competing for the same port.
                Use this instead:
                  brew services start clauderelay
                Pass --force to install the CLI-managed agent anyway.
                """
            }
            if verb == .unload {
                return """
                clauderelay is managed by Homebrew services; `unload` only removes a
                CLI-installed agent, and there isn't one. To stop the running service:
                  brew services stop clauderelay
                """
            }
            return """
            clauderelay is managed by Homebrew services. Use:
              brew services \(verb.rawValue) clauderelay
            """

        case .launchAgent:
            return nil

        case .none:
            switch verb {
            case .load:
                return nil
            case .unload:
                return "No service is installed — nothing to unload."
            case .start, .stop, .restart:
                let installer = installedViaHomebrew
                    ? "  brew services start clauderelay"
                    : "  claude-relay setup"
                return """
                No service is installed yet, so there is nothing to \(verb.rawValue).
                Install and start it with:
                \(installer)
                """
            }
        }
    }
}
