import ArgumentParser
import Foundation
import ClaudeRelayKit

/// Prints the nudge and returns true when the caller should stop.
/// `--quiet` suppresses the text but still blocks the wrong action.
///
/// The nudge goes to stderr because every caller follows a `true` with
/// `throw ExitCode.failure` — it is a refusal, and stdout may be carrying JSON.
private func nudgeBlocks(_ platform: any ServicePlatform, _ verb: ServiceVerb,
                         force: Bool = false, quiet: Bool) -> Bool {
    guard let nudge = platform.nudge(for: verb, force: force) else { return false }
    if !quiet { CLIOutput.error(nudge) }
    return true
}

// MARK: - Load

struct LoadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "load",
        abstract: "Install and start the service"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: .long, help: "Install the CLI-managed agent even if another manager owns the service")
    var force = false

    func run() async throws {
        let platform = ServicePlatforms.current
        if nudgeBlocks(platform, .load, force: force, quiet: globals.quiet) { throw ExitCode.failure }

        // Update config.json if ports were specified on the command line.
        try updateConfigIfNeeded()

        // Find server binary
        let serverBinary = platform.findServerBinary()

        let installLines = try platform.load(serverBinary: serverBinary)

        let config = try ConfigManager.load()
        if !globals.quiet {
            let wsHost = config.bindAll ? "0.0.0.0" : "127.0.0.1"
            print("Service installed and started.")
            print("  WebSocket: \(wsHost):\(config.wsPort)")
            print("  Admin API: 127.0.0.1:\(config.adminPort)")
            for line in installLines { print(line) }
            if config.bindAll && (config.tlsCert?.isEmpty ?? true) {
                print("")
                print("  WARNING: bindAll=true without TLS — tokens travel in the clear on the network.")
                print("           Configure tlsCert/tlsKey or reset with: claude-relay config set bindAll false")
            }
        }
    }

    /// If the user passed --ws-port, --admin-port, --bind-all, or
    /// --no-bind-all, update config.json so the server picks up the new
    /// values on startup.
    private func updateConfigIfNeeded() throws {
        let wsPortProvided = globals.wsPort != nil
        let adminPortProvided = ProcessInfo.processInfo.arguments.contains("--admin-port")
            || ProcessInfo.processInfo.arguments.contains("-p")
        let bindAllProvided = ProcessInfo.processInfo.arguments.contains("--bind-all")
            || ProcessInfo.processInfo.arguments.contains("--no-bind-all")

        guard wsPortProvided || adminPortProvided || bindAllProvided else { return }

        try ConfigManager.ensureDirectory()
        var config = (try? ConfigManager.load()) ?? .default

        if let ws = globals.wsPort {
            config.wsPort = ws
        }
        if adminPortProvided {
            config.adminPort = globals.adminPort
        }
        if bindAllProvided {
            config.bindAll = globals.bindAll
        }

        try ConfigManager.save(config)
    }
}

// MARK: - Unload

struct UnloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unload",
        abstract: "Stop and uninstall the service"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let platform = ServicePlatforms.current
        if nudgeBlocks(platform, .unload, quiet: globals.quiet) { throw ExitCode.failure }

        let notes = try platform.unload()

        if !globals.quiet {
            print("Service stopped and uninstalled.")
            for line in notes { print(line) }
        }
    }
}

// MARK: - Start

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the service"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let platform = ServicePlatforms.current
        if nudgeBlocks(platform, .start, quiet: globals.quiet) { throw ExitCode.failure }
        try platform.start()
        if !globals.quiet {
            print("Service started.")
        }
    }
}

// MARK: - Stop

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the service"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let platform = ServicePlatforms.current
        if nudgeBlocks(platform, .stop, quiet: globals.quiet) { throw ExitCode.failure }
        try platform.stop()
        if !globals.quiet {
            print("Service stopped.")
        }
    }
}

// MARK: - Restart

struct RestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart the service"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let platform = ServicePlatforms.current
        if nudgeBlocks(platform, .restart, quiet: globals.quiet) { throw ExitCode.failure }
        try platform.restart()
        if !globals.quiet {
            print("Service restarted.")
        }
    }
}

// MARK: - Status

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show service status"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let response: StatusResponse = try await client.get("/status")

            let platform = ServicePlatforms.current
            if globals.json {
                print(OutputFormatter.formatJSON(response, merging: "manager", value: platform.managerJSON))
            } else {
                print(OutputFormatter.formatStatus(
                    running: response.running,
                    version: response.version,
                    pid: response.pid,
                    uptime: response.uptime,
                    sessions: response.sessions
                ))
                if !globals.quiet {
                    print("  Managed by: \(platform.managerDescription)")
                }
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            if globals.json {
                print(#"{"running": false, "error": "Service is not running"}"#)
            } else {
                print("Service is not running.")
            }
            throw ExitCode.failure
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Health

struct HealthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Check if the service is reachable"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)
        let running = await client.isServiceRunning()

        if globals.json {
            print(#"{"healthy": \#(running)}"#)
        } else {
            print(running ? "OK" : "Unreachable")
        }

        if !running {
            throw ExitCode.failure
        }
    }
}

struct StatusResponse: Codable {
    let status: String
    let version: String?
    let pid: Int?
    let uptimeSeconds: Int?
    let sessionCount: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case version
        case pid
        case uptimeSeconds = "uptime_seconds"
        case sessionCount = "session_count"
    }

    var running: Bool { status == "running" }
    var uptime: Int? { uptimeSeconds }
    var sessions: Int { sessionCount ?? 0 }
}

enum CLIError: Error, LocalizedError {
    case launchctlFailed(String)
    case serviceManagerFailed(tool: String, message: String)
    case shellCommandFailed(command: String, status: Int, stderr: String)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let msg):
            return "launchctl failed: \(msg)"
        case .serviceManagerFailed(let tool, let msg):
            return "\(tool) failed: \(msg)"
        case .shellCommandFailed(let cmd, let status, let stderr):
            let name = (cmd as NSString).lastPathComponent
            return "\(name) failed (exit \(status)): \(stderr)"
        }
    }
}

// MARK: - AdminClientError Equatable

extension AdminClientError: Equatable {
    public static func == (lhs: AdminClientError, rhs: AdminClientError) -> Bool {
        switch (lhs, rhs) {
        case (.serviceNotRunning, .serviceNotRunning):
            return true
        default:
            return false
        }
    }
}
