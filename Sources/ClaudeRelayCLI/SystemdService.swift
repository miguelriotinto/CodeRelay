#if os(Linux)
import Foundation

/// `systemd --user`, driven through `systemctl` and a user unit — the Linux
/// `ServicePlatform`. See `docs/linux-server-spec.md` AD-4 and §4.
struct SystemdService: ServicePlatform {

    static let unitName = SystemdUnitDetector.unitName

    private let detector: SystemdUnitDetector

    init(detector: SystemdUnitDetector = .detect()) {
        self.detector = detector
    }

    func nudge(for verb: ServiceVerb, force: Bool) -> String? {
        detector.nudge(for: verb)
    }

    /// The unit `load` writes. `serverBinary` is absolute. Also the template the
    /// package ships, with `/usr/bin/claude-relay-server` and no CLI marker.
    static func unitFile(serverBinary: String, marker: String? = SystemdUnitDetector.cliMarker) -> String {
        var header = "# CodeRelay terminal relay server — systemd user unit.\n"
        if let marker { header += marker + "\n" }
        return header + """
        # Starts with your session (like a macOS LaunchAgent) and restarts on
        # failure. For a host that must serve with nobody logged in, run:
        #   loginctl enable-linger
        #
        # Logs: journalctl --user -u \(unitName) -f

        [Unit]
        Description=CodeRelay terminal relay server
        Documentation=https://github.com/miguelriotinto/CodeRelay
        After=default.target

        [Service]
        Type=simple
        ExecStart=\(serverBinary)
        WorkingDirectory=%h
        Restart=always
        RestartSec=5
        # Sessions exec the user's login shell, which builds its own PATH; the
        # service itself needs only the system directories.
        Environment=PATH=/usr/local/bin:/usr/bin:/bin

        [Install]
        WantedBy=default.target

        """
    }

    func load(serverBinary: String) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(fm.homeDirectoryForCurrentUser.path)/.claude-relay",
                               withIntermediateDirectories: true)

        switch detector.owner {
        case .packaged:
            // The package's unit already names the right binary; enabling it is
            // the whole job. Writing a user unit here would shadow the packaged
            // one and silently pin the operator to today's binary path.
            try systemctl(["enable", "--now", Self.unitName])
            return [
                "  Unit:      \(SystemdUnitDetector.packagedUnitPath) (packaged)",
                "  Logs:      journalctl --user -u \(Self.unitName) -f",
            ]

        case .user, .none:
            let unitPath = SystemdUnitDetector.userUnitPath
            try fm.createDirectory(atPath: SystemdUnitDetector.userUnitDirectory,
                                   withIntermediateDirectories: true)
            try Self.unitFile(serverBinary: serverBinary)
                .write(toFile: unitPath, atomically: true, encoding: .utf8)
            try systemctl(["daemon-reload"])
            try systemctl(["enable", "--now", Self.unitName])
            return [
                "  Unit:      \(unitPath)",
                "  Logs:      journalctl --user -u \(Self.unitName) -f",
                "",
                "  The service runs while you are logged in. To keep it running with no",
                "  session open (a headless host), also run: loginctl enable-linger",
            ]
        }
    }

    func unload() throws -> [String] {
        try systemctl(["disable", "--now", Self.unitName])

        switch detector.owner {
        case .user where detector.userUnitWrittenByCLI:
            try FileManager.default.removeItem(atPath: SystemdUnitDetector.userUnitPath)
            try systemctl(["daemon-reload"])
            return []
        case .user:
            return ["Left \(SystemdUnitDetector.userUnitPath) in place — it was not written by claude-relay load."]
        case .packaged:
            return ["The unit file belongs to the package and was left in place: \(SystemdUnitDetector.packagedUnitPath)"]
        case .none:
            return []
        }
    }

    func start() throws {
        try systemctl(["start", Self.unitName])
    }

    func stop() throws {
        try systemctl(["stop", Self.unitName])
    }

    func restart() throws {
        try systemctl(["restart", Self.unitName])
    }

    var managerDescription: String {
        switch detector.owner {
        case .packaged:
            return "systemd user service (packaged unit)"
        case .user:
            return detector.packagedUnitShadowed
                ? "systemd user service (user unit — shadows the packaged one)"
                : "systemd user service (user unit)"
        case .none:
            return "no systemd unit installed"
        }
    }

    var managerJSON: String {
        switch detector.owner {
        case .packaged: return "systemd-package"
        case .user:     return "systemd-user"
        case .none:     return "none"
        }
    }

    func setupStartPlan() -> SetupStartPlan {
        switch detector.owner {
        case .packaged, .user:
            return .start(progress: "Starting the systemd user service…")
        case .none:
            return .load(progress: "Installing the systemd user service…")
        }
    }

    var serverBinaryCandidates: [String] {
        [
            "/usr/bin/claude-relay-server",
            "/usr/local/bin/claude-relay-server",
            FileManager.default.homeDirectoryForCurrentUser.path + "/.claude-relay/bin/claude-relay-server",
        ]
    }

    var serverBinaryFallback: String { "/usr/bin/claude-relay-server" }

    private func systemctl(_ arguments: [String]) throws {
        try runServiceManager("/usr/bin/systemctl", ["--user"] + arguments)
    }
}
#endif
