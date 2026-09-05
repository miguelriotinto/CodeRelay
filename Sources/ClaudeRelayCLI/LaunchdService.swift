#if !os(Linux)
import Foundation

/// launchd, driven through `launchctl` and a LaunchAgent plist — the macOS
/// `ServicePlatform`. Ownership questions (Homebrew vs `claude-relay load`)
/// are answered by `ServiceManagerDetector`.
struct LaunchdService: ServicePlatform {

    static let serviceLabel = "com.claude.relay"

    private let detector: ServiceManagerDetector

    init(detector: ServiceManagerDetector = .detect()) {
        self.detector = detector
    }

    private var homeDir: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private var launchAgentsDir: String { "\(homeDir)/Library/LaunchAgents" }
    private var plistPath: String { "\(launchAgentsDir)/\(Self.serviceLabel).plist" }

    func nudge(for verb: ServiceVerb, force: Bool) -> String? {
        if verb == .load, force { return nil }
        return detector.nudge(for: verb)
    }

    func load(serverBinary: String) throws -> [String] {
        let relayDir = "\(homeDir)/.claude-relay"

        // Ensure directories exist
        let fm = FileManager.default
        try fm.createDirectory(atPath: relayDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

        // Get current user environment
        let userName = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        // LaunchAgent plist: runs at user login, auto-restarts on crash
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.serviceLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(serverBinary)</string>
            </array>
            <key>WorkingDirectory</key>
            <string>\(homeDir)</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>HOME</key>
                <string>\(homeDir)</string>
                <key>USER</key>
                <string>\(userName)</string>
                <key>PATH</key>
                <string>\(pathEnv)</string>
            </dict>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(relayDir)/stdout.log</string>
            <key>StandardErrorPath</key>
            <string>\(relayDir)/stderr.log</string>
        </dict>
        </plist>
        """

        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

        // Load via launchctl
        try runLaunchctl(["load", plistPath])
        return ["  Plist:     \(plistPath)"]
    }

    func unload() throws -> [String] {
        try runLaunchctl(["unload", plistPath])

        let fm = FileManager.default
        if fm.fileExists(atPath: plistPath) {
            try fm.removeItem(atPath: plistPath)
        }
        return []
    }

    func start() throws {
        try runLaunchctl(["start", Self.serviceLabel])
    }

    func stop() throws {
        try runLaunchctl(["stop", Self.serviceLabel])
    }

    func restart() throws {
        try runLaunchctl(["stop", Self.serviceLabel])
        try runLaunchctl(["start", Self.serviceLabel])
    }

    var managerDescription: String {
        switch detector.owner {
        case .homebrew:    return "Homebrew services"
        case .launchAgent: return "claude-relay (launchd agent)"
        case .both:        return "WARNING — two managers installed"
        case .none:        return "no launchd agent installed"
        }
    }

    var managerJSON: String {
        switch detector.owner {
        case .homebrew:    return "homebrew"
        case .launchAgent: return "launchAgent"
        case .both:        return "both"
        case .none:        return "none"
        }
    }

    /// `setup` starts the service using whichever manager owns it, so it never
    /// installs a second competing launchd agent.
    func setupStartPlan() -> SetupStartPlan {
        switch detector.owner {
        case .homebrew:
            return .shell(command: "brew services start clauderelay",
                          progress: "Starting via Homebrew services…")
        case .launchAgent:
            return .start(progress: "Starting the launchd agent…")
        case .both:
            return .fail(message: detector.nudge(for: .start) ?? "Two service managers are installed.")
        case .none:
            // If the binary came from Homebrew but no service is installed yet,
            // tell the operator to start the Homebrew service instead of
            // installing a CLI-managed agent that will conflict later.
            if detector.installedViaHomebrew {
                return .fail(message: """
                    clauderelay was installed via Homebrew.
                    Start the service with:
                      brew services start clauderelay
                    """)
            }
            return .load(progress: "Installing the launchd agent…")
        }
    }

    // Search order after the CLI's sibling: Homebrew prefix, standard paths, user home
    var serverBinaryCandidates: [String] {
        [
            "/opt/homebrew/bin/claude-relay-server",
            "/usr/local/bin/claude-relay-server",
            homeDir + "/.claude-relay/bin/claude-relay-server",
        ]
    }

    var serverBinaryFallback: String { "/usr/local/bin/claude-relay-server" }

    private func runLaunchctl(_ arguments: [String]) throws {
        do {
            try runServiceManager("/bin/launchctl", arguments)
        } catch CLIError.serviceManagerFailed(_, let message) {
            throw CLIError.launchctlFailed(message)
        }
    }
}
#endif
