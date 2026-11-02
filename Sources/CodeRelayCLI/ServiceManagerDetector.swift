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
/// | Manager             | Label / plist                                          |
/// | ------------------- | ------------------------------------------------------ |
/// | `brew services`     | `sh.brew.coderelay` (before the rename: `sh.brew.clauderelay`, `homebrew.mxcl.clauderelay`) |
/// | `claude-relay load` | `com.claude.relay`                                     |
///
/// Every service command used to hardcode `com.claude.relay`, so on a Homebrew
/// install — the documented path — `start`/`stop`/`restart`/`unload` failed with
/// a raw `launchctl failed:` error against a label that was never loaded.
/// `status`/`health` were unaffected because they talk to the admin HTTP API.
struct ServiceManagerDetector {

    // The formula was renamed clauderelay → coderelay, and Homebrew renamed its
    // label prefix from homebrew.mxcl. to sh.brew. A Mac that has not upgraded
    // since still runs the service under an old label, so all are recognised.
    static let homebrewPlistNames = [
        "sh.brew.coderelay.plist",            // current
        "sh.brew.clauderelay.plist",          // before the formula rename
        "homebrew.mxcl.clauderelay.plist"     // legacy label prefix
    ]
    static let formulaName = "coderelay"
    static let launchAgentPlistName = "com.claude.relay.plist"

    private let homebrewPlistExists: Bool
    private let homebrewPlistName: String?  // which specific Homebrew plist was found
    private let launchAgentPlistExists: Bool
    private let binaryPath: String

    init(homebrewPlistExists: Bool, homebrewPlistName: String? = nil, launchAgentPlistExists: Bool, binaryPath: String) {
        self.homebrewPlistExists = homebrewPlistExists
        self.homebrewPlistName = homebrewPlistName
        self.launchAgentPlistExists = launchAgentPlistExists
        self.binaryPath = binaryPath
    }

    /// Reads the real filesystem. Injected values are used by tests.
    static func detect() -> ServiceManagerDetector {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let fm = FileManager.default

        // Check for either Homebrew plist name
        var foundHomebrewPlist: String? = nil
        for plistName in homebrewPlistNames {
            if fm.fileExists(atPath: launchAgents.appendingPathComponent(plistName).path) {
                foundHomebrewPlist = plistName
                break
            }
        }

        return ServiceManagerDetector(
            homebrewPlistExists: foundHomebrewPlist != nil,
            homebrewPlistName: foundHomebrewPlist,
            launchAgentPlistExists: fm.fileExists(
                atPath: launchAgents.appendingPathComponent(launchAgentPlistName).path),
            binaryPath: CommandLine.arguments.first ?? ""
        )
    }

    /// The formula `brew services` must be given: the one whose plist was found
    /// (an unmigrated install answers only to its old name), else the current one.
    var formula: String {
        guard let plist = homebrewPlistName else { return Self.formulaName }
        return plist
            .replacingOccurrences(of: ".plist", with: "")
            .replacingOccurrences(of: "sh.brew.", with: "")
            .replacingOccurrences(of: "homebrew.mxcl.", with: "")
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
        case .homebrew, .both: return "brew services \(verb.rawValue) \(formula)"
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
        // Prefer the actual found Homebrew plist name, or the current one as default
        let brewPlist = homebrewPlistName ?? Self.homebrewPlistNames[0]

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
            Two service managers are installed for \(formula):
              • \(brewPlist) (Homebrew)
              • \(Self.launchAgentPlistName) (claude-relay load)
            Both will try to bind the WebSocket port. Remove one before continuing:
              brew services stop \(formula)     # keep the CLI-managed agent
              claude-relay unload                # keep the Homebrew-managed one
            """

        case .homebrew:
            if verb == .load {
                return """
                \(formula) is managed by Homebrew services.
                Running `load` would install a second launchd agent competing for the same port.
                Use this instead:
                  brew services start \(formula)
                Pass --force to install the CLI-managed agent anyway.
                """
            }
            if verb == .unload {
                return """
                \(formula) is managed by Homebrew services; `unload` only removes a
                CLI-installed agent, and there isn't one. To stop the running service:
                  brew services stop \(formula)
                """
            }
            return """
            \(formula) is managed by Homebrew services. Use:
              brew services \(verb.rawValue) \(formula)
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
                    ? "  brew services start \(formula)"
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
