import ArgumentParser
import Foundation

struct TokenGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Manage tokens",
        subcommands: [
            TokenCreateCommand.self,
            TokenListCommand.self,
            TokenDeleteCommand.self,
            TokenRotateCommand.self,
            TokenRenameCommand.self,
            TokenInspectCommand.self
        ]
    )
}

// MARK: - Create

struct TokenCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new token"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: .long, help: "Label for the token")
    var label: String?

    @Option(name: .long, help: "Token expiry in days, or 'never' for non-expiring tokens")
    var expires: String = "never"

    func run() async throws {
        let expiryDays: Int?
        if expires.lowercased() == "never" {
            expiryDays = nil
        } else {
            guard let days = Int(expires), days > 0 else {
                print("Error: --expires must be a positive number of days or 'never'")
                throw ExitCode.validationFailure
            }
            expiryDays = days
        }

        let client = AdminClient(port: globals.port)

        do {
            let body = TokenCreateRequest(label: label, expiryDays: expiryDays)
            let response: TokenCreateResponse = try await client.post("/tokens", body: body)

            if globals.json {
                print(OutputFormatter.formatJSON(response))
            } else {
                print(response.plaintext)
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - List

struct TokenListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all tokens"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let tokens: [TokenInfo] = try await client.get("/tokens")

            if globals.json {
                print(OutputFormatter.formatJSON(tokens))
            } else {
                let headers = ["ID", "LABEL", "PREFIX", "CREATED", "EXPIRES", "LAST USED"]
                let rows = tokens.map { t in
                    [t.id, t.label ?? "-", t.prefix ?? "-", t.createdAt, t.expiresAt ?? "never", t.lastUsedAt ?? "never"]
                }
                print(OutputFormatter.formatTable(headers: headers, rows: rows))
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - Delete

struct TokenDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete one or more tokens"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Token ID(s) to delete")
    var ids: [String]

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            for id in ids {
                try await client.delete("/tokens/\(id)")
                if !globals.quiet {
                    print("Token \(id) deleted.")
                }
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - Rotate

struct TokenRotateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate",
        abstract: "Rotate a token (invalidate old, create new)"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Token ID to rotate")
    var id: String

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let response: TokenCreateResponse = try await client.post("/tokens/\(id)/rotate")

            if globals.json {
                print(OutputFormatter.formatJSON(response))
            } else {
                // Print only the plaintext token so it can be piped
                print(response.plaintext)
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - Rename

struct TokenRenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a token's label"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Token ID to rename")
    var id: String

    @Argument(help: "New label")
    var label: String

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let body = TokenRenameRequest(label: label)
            let token: TokenInfo = try await client.patch("/tokens/\(id)", body: body)

            if globals.json {
                print(OutputFormatter.formatJSON(token))
            } else if !globals.quiet {
                print("Token \(id) renamed to '\(token.label ?? label)'.")
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - Inspect

struct TokenInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Show details for a token"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Token ID to inspect")
    var id: String

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let token: TokenInfo = try await client.get("/tokens/\(id)")

            if globals.json {
                print(OutputFormatter.formatJSON(token))
            } else {
                print("ID:         \(token.id)")
                print("Label:      \(token.label ?? "-")")
                print("Prefix:     \(token.prefix ?? "-")")
                print("Created:    \(token.createdAt)")
                print("Expires:    \(token.expiresAt ?? "never")")
                print("Last Used:  \(token.lastUsedAt ?? "never")")
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

struct TokenCreateRequest: Encodable {
    let label: String?
    let expiryDays: Int?
}

struct TokenRenameRequest: Encodable {
    let label: String
}

struct TokenCreateResponse: Codable {
    let token: String
    let id: String
    let label: String?
    let expiresAt: String?

    /// Convenience alias for the raw token string.
    var plaintext: String { token }
}

struct TokenInfo: Codable {
    let id: String
    let label: String?
    let prefix: String?
    let createdAt: String
    let expiresAt: String?
    let lastUsedAt: String?
}
