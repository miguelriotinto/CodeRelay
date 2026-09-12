import ArgumentParser
import Foundation

struct LogGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "View service logs",
        subcommands: [
            LogShowCommand.self,
            LogTailCommand.self
        ]
    )
}

// MARK: - Show

struct LogShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show recent log entries"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Number of lines to show")
    var lines: Int = 50

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let response: LogResponse = try await client.get("/logs?lines=\(lines)")

            if globals.json {
                print(OutputFormatter.formatJSON(response))
            } else {
                for entry in response.entries {
                    print(entry)
                }
            }
        } catch let error as AdminClientError where error == .serviceNotRunning {
            print("Service is not running.")
            throw ExitCode.failure
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// MARK: - Tail

struct LogTailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tail",
        abstract: "Follow log output"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        if !globals.quiet {
            print("Following logs (Ctrl+C to stop)...")
        }

        var lastSeenEntry: String?
        var baselineEstablished = false

        while !Task.isCancelled {
            do {
                let response: LogResponse = try await client.get("/logs?lines=50")

                let entries = response.entries
                // First poll establishes baseline — only subsequent polls print new entries
                if !baselineEstablished {
                    baselineEstablished = true
                } else if let lastSeen = lastSeenEntry,
                   let lastIndex = entries.lastIndex(of: lastSeen) {
                    // Print only entries after the last one we saw
                    let newEntries = entries.suffix(from: entries.index(after: lastIndex))
                    for entry in newEntries {
                        if globals.json {
                            print(#"{"log": "\#(entry)"}"#)
                        } else {
                            print(entry)
                        }
                    }
                } else if lastSeenEntry != nil {
                    // Last seen entry not found (log rotated) — print all
                    for entry in entries {
                        if globals.json {
                            print(#"{"log": "\#(entry)"}"#)
                        } else {
                            print(entry)
                        }
                    }
                }
                lastSeenEntry = entries.last ?? lastSeenEntry
            } catch let error as AdminClientError where error == .serviceNotRunning {
                print("Service is not running.")
                throw ExitCode.failure
            } catch {
                print("Error: \(error.localizedDescription)")
                throw ExitCode.failure
            }

            // 2s poll interval balances responsiveness against admin API load
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

struct LogResponse: Codable {
    let entries: [String]
}
