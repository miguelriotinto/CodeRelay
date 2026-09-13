import ArgumentParser
import Foundation

struct OptimizerGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "optimizer",
        abstract: "Exercise the server-side prompt optimizer",
        subcommands: [OptimizerTryCommand.self]
    )
}

struct OptimizerTryRequest: Encodable {
    let draft: String
    let sessionId: String?
    let shareScreen: Bool
}

struct OptimizerTryResponse: Codable {
    let status: String
    let prompt: String?
    let message: String?
}

/// `claude-relay optimizer try "<draft>" [--session <id>] [--no-screen]`
///
/// Runs the relay's optimizer over a draft — with a live session's agent, cwd
/// and screen when `--session` is given — and prints the outcome. Never types
/// into the session; this is the system-prompt tuning loop (spec §5.6).
struct OptimizerTryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "try",
        abstract: "Optimize a draft without touching any session"
    )

    @Argument(help: "The draft text to optimize, as the user would have typed it")
    var draft: String

    @Option(name: .long, help: "Session UUID whose agent, working directory and screen provide context")
    var session: String?

    @Flag(name: .customLong("no-screen"), help: "Do not send the session's screen to the model")
    var noScreen = false

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)
        // Above the 12 s optimizer deadline plus transport, matching the 20 s waiter the spec gives these RPCs.
        client.requestTimeout = 20
        let request = OptimizerTryRequest(draft: draft, sessionId: session, shareScreen: !noScreen)
        do {
            let response: OptimizerTryResponse = try await client.post("/optimizer/try", body: request)
            if globals.json {
                // Exits 0 even when status == "failed", deliberately consistent with `config validate`; scripts inspect the payload.
                print(OutputFormatter.formatJSON(response))
                return
            }
            let (text, isFailure) = Self.render(response)
            print(text)
            if isFailure {
                throw ExitCode.failure
            }
        } catch let error as AdminClientError {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }

    static func render(_ response: OptimizerTryResponse) -> (text: String, isFailure: Bool) {
        switch response.status {
        case "ok":
            return (response.prompt ?? "", false)
        case "passthrough":
            return ("passthrough — the model left the draft as it was", false)
        default:
            return ("failed: \(response.message ?? "unknown error")", true)
        }
    }
}
