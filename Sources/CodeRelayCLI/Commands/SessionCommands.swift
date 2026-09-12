import ArgumentParser
import Foundation

struct SessionGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Manage sessions",
        subcommands: [
            SessionListCommand.self,
            SessionInspectCommand.self,
            SessionTerminateCommand.self
        ]
    )
}

// MARK: - List

struct SessionListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List active sessions"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let sessions: [CLISessionInfo] = try await client.get("/sessions")

            if globals.json {
                print(OutputFormatter.formatJSON(sessions))
            } else {
                if sessions.isEmpty {
                    if !globals.quiet {
                        print("No active sessions.")
                    }
                } else {
                    let headers = ["ID", "STATE", "TOKEN", "SIZE", "CREATED"]
                    let rows = sessions.map { s -> [String] in
                        [String(s.id.uuidString.prefix(8)).lowercased(),
                         s.state,
                         String(s.tokenId.prefix(8)),
                         "\(s.cols)x\(s.rows)",
                         s.createdAtFormatted]
                    }
                    print(OutputFormatter.formatTable(headers: headers, rows: rows))
                }
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - Inspect

struct SessionInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Show details for a session"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Session ID to inspect")
    var id: String

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let session: CLISessionInfo = try await client.get("/sessions/\(id)")

            if globals.json {
                print(OutputFormatter.formatJSON(session))
            } else {
                print("ID:        \(session.id)")
                print("State:     \(session.state)")
                print("Token:     \(session.tokenId)")
                print("Size:      \(session.cols)x\(session.rows)")
                print("Created:   \(session.createdAtFormatted)")
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - Terminate

struct SessionTerminateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminate",
        abstract: "Terminate a session"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Session ID to terminate")
    var id: String

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            try await client.delete("/sessions/\(id)")
            if !globals.quiet {
                print("Session \(id) terminated.")
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

struct CLISessionInfo: Codable {
    let id: UUID
    let state: String
    let tokenId: String
    let createdAt: Date
    let cols: UInt16
    let rows: UInt16

    var createdAtFormatted: String {
        RelativeTime.abbreviated(from: createdAt)
    }
}
