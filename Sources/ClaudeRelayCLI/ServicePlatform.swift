import Foundation

/// What `setup` should do to get the service running, decided by the platform
/// from which manager (if any) owns it.
enum SetupStartPlan: Equatable {
    /// Drive the existing installation with `claude-relay start`.
    case start(progress: String)
    /// Nothing is installed: run `claude-relay load`.
    case load(progress: String)
    /// Another manager owns it: run this shell command instead.
    case shell(command: String, progress: String)
    /// Refuse, printing this message.
    case fail(message: String)
}

/// The host's service manager — launchd on macOS, `systemd --user` on Linux —
/// behind one interface so `ServiceCommands` and `SetupCommand` contain no
/// platform branches.
///
/// Both implementations share the *nudge* model: before driving the manager,
/// a command asks whether it is the right one for this host, and a non-nil
/// nudge is printed instead of acting. On macOS that guards against two
/// launchd managers binding one port; on Linux it distinguishes a packaged
/// unit from one `load` wrote (`docs/linux-server-spec.md` AD-4).
protocol ServicePlatform {
    /// A message to print instead of proceeding, or nil when `verb` is right
    /// for this host. `force` is `load --force`.
    func nudge(for verb: ServiceVerb, force: Bool) -> String?

    /// Installs and starts the service running `serverBinary`. Returns the
    /// lines `load` prints after its port summary (where the definition went).
    func load(serverBinary: String) throws -> [String]

    /// Stops and uninstalls. Returns lines to print afterwards.
    func unload() throws -> [String]

    func start() throws
    func stop() throws
    func restart() throws

    /// The `Managed by:` line for `status`.
    var managerDescription: String { get }
    /// The `manager` value for `status --json`.
    var managerJSON: String { get }

    func setupStartPlan() -> SetupStartPlan

    /// Where `load` looks for `claude-relay-server` after the CLI's own
    /// directory, and the path it falls back to when none exists.
    var serverBinaryCandidates: [String] { get }
    var serverBinaryFallback: String { get }
}

/// The platform's manager, reading the real filesystem.
enum ServicePlatforms {
    static var current: any ServicePlatform {
        #if os(Linux)
        return SystemdService()
        #else
        return LaunchdService()
        #endif
    }
}

extension ServicePlatform {
    /// Search order: sibling of the CLI binary (covers a package install and a
    /// local build), then the platform's candidates, then its fallback.
    func findServerBinary() -> String {
        let cliPath = CommandLine.arguments[0]
        let cliDir = URL(fileURLWithPath: cliPath).deletingLastPathComponent().path
        let siblingCandidate = cliDir + "/claude-relay-server"
        if FileManager.default.isExecutableFile(atPath: siblingCandidate) {
            return siblingCandidate
        }
        for path in serverBinaryCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return serverBinaryFallback
    }
}

/// Runs a manager binary synchronously, capturing stderr and throwing
/// `CLIError.serviceManagerFailed` on a non-zero exit.
func runServiceManager(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        throw CLIError.serviceManagerFailed(
            tool: (executable as NSString).lastPathComponent,
            message: errorMessage.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
