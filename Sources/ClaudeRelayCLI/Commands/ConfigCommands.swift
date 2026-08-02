import ArgumentParser
import Foundation
import ClaudeRelayKit

struct ConfigGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage configuration",
        subcommands: [
            ConfigShowCommand.self,
            ConfigSetCommand.self,
            ConfigValidateCommand.self
        ]
    )
}

// MARK: - Show

struct ConfigShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show current configuration"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let config: [String: ConfigValue] = try await client.get("/config")

            if globals.json {
                print(OutputFormatter.formatJSON(config))
            } else {
                let headers = ["KEY", "VALUE"]
                let rows = config.sorted(by: { $0.key < $1.key }).map { key, value in
                    [key, value.description]
                }
                print(OutputFormatter.formatTable(headers: headers, rows: rows))
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - Set

struct ConfigSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a configuration value"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Configuration key")
    var key: String

    @Argument(help: "Configuration value")
    var value: String

    func run() async throws {
        // Must match server-side AdminRoutes.applyConfigValue accepted keys
        let validKeys: Set<String> = [
            "wsPort", "adminPort", "detachTimeout", "scrollbackSize",
            "tlsCert", "tlsKey", "logLevel", "maxSessionsPerToken",
            "bindAll",
            "pushEnabled", "pushNotifyOnFinished",
            "apnsKeyPath", "apnsKeyId", "apnsTeamId", "apnsBundleId", "apnsUseSandbox",
            "fcmServiceAccountPath", "fcmProjectId"
        ]
        guard validKeys.contains(key) else {
            FileHandle.standardError.write(Data(
                "Error: unknown config key '\(key)'. Valid keys: \(validKeys.sorted().joined(separator: ", "))\n".utf8))
            throw ExitCode.failure
        }

        let typedValue = ConfigValue.infer(from: value)
        switch (key, typedValue) {
        case ("wsPort", .int(let portValue)), ("adminPort", .int(let portValue)):
            // Shared bound, not a local literal: this is a fast-path copy of the
            // check `AdminRoutes.validatePort` performs, and the two must agree.
            guard RelayConfig.portRange.contains(portValue) else {
                FileHandle.standardError.write(Data(
                    "Error: port must be \(RelayConfig.portRange.lowerBound)..\(RelayConfig.portRange.upperBound)\n".utf8))
                throw ExitCode.failure
            }
        case ("scrollbackSize", .int(let s)):
            guard s >= 1024 else {
                FileHandle.standardError.write(Data("Error: scrollbackSize must be >= 1024\n".utf8))
                throw ExitCode.failure
            }
        case ("logLevel", .string(let lvl)):
            let valid = ["trace", "debug", "info", "warning", "error"]
            guard valid.contains(lvl) else {
                FileHandle.standardError.write(Data("Error: logLevel must be one of \(valid)\n".utf8))
                throw ExitCode.failure
            }
        case ("maxSessionsPerToken", .int(let count)):
            guard count >= 0 else {
                FileHandle.standardError.write(Data("Error: maxSessionsPerToken must be >= 0\n".utf8))
                throw ExitCode.failure
            }
        case ("tlsCert", .string(let path)), ("tlsKey", .string(let path)):
            // Accept empty string (means "disable this TLS field"); otherwise
            // fail fast if the path isn't readable. The server-side
            // `applyConfigValue` runs the same check — this is just for a
            // nicer error message without a round-trip.
            if !path.isEmpty {
                let expanded = NSString(string: path).expandingTildeInPath
                let fm = FileManager.default
                if !fm.fileExists(atPath: expanded) {
                    FileHandle.standardError.write(Data("Error: \(key) path not found: \(path)\n".utf8))
                    throw ExitCode.failure
                }
                if !fm.isReadableFile(atPath: expanded) {
                    FileHandle.standardError.write(Data("Error: \(key) path exists but is not readable: \(path)\n".utf8))
                    throw ExitCode.failure
                }
            }
        default:
            break
        }

        let client = AdminClient(port: globals.port)

        do {
            let body = ["value": typedValue]
            let _: ConfigSetResponse = try await client.put("/config/\(key)", body: body)
            if !globals.quiet {
                print("Set \(key) = \(value)")
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }
}

// MARK: - Validate

struct ConfigValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate current configuration"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let client = AdminClient(port: globals.port)

        do {
            let config: [String: ConfigValue] = try await client.get("/config")

            var errors: [String] = []

            // Ports must parse AND fall in the range `config set` accepts. A
            // value that isn't an integer is an error in its own right rather
            // than silently skipped; `/config` serves a typed `RelayConfig`, so
            // that branch is unreachable today and kept as defence in depth.
            let ws = Self.validatePort(config["wsPort"], name: "wsPort", errors: &errors)
            let admin = Self.validatePort(config["adminPort"], name: "adminPort", errors: &errors)

            if let ws, let admin, ws == admin {
                errors.append("wsPort and adminPort cannot be the same (\(ws))")
            }

            if globals.json {
                let result = ValidationResult(valid: errors.isEmpty, errors: errors)
                print(OutputFormatter.formatJSON(result))
            } else {
                if errors.isEmpty {
                    print("Configuration is valid.")
                } else {
                    print("Configuration errors:")
                    for error in errors {
                        print("  - \(error)")
                    }
                    throw ExitCode.failure
                }
            }
        } catch {
            print(OutputFormatter.formatError(error, json: globals.json))
            throw ExitCode.failure
        }
    }

    /// Range the admin API enforces on writes (`AdminRoutes.validatePort`, on
    /// the `PUT /config` path). Derived from the shared `RelayConfig.portRange`
    /// rather than restated, because a looser bound here would report a port as
    /// valid that `config set` then refuses — which is exactly the drift this
    /// command shipped with. Note the server does *not* re-check the range at
    /// startup: `main.swift` binds whatever `config.json` holds and dies on the
    /// bind error.
    static let minPort = RelayConfig.portRange.lowerBound
    static let maxPort = RelayConfig.portRange.upperBound

    /// Returns the parsed port so the caller can still compare the two for
    /// collision, appending an error when the value is non-numeric or out of
    /// range. Returns nil only when there is no number to compare.
    static func validatePort(_ value: ConfigValue?, name: String, errors: inout [String]) -> Int? {
        guard let value else { return nil }
        guard let port = Int(value.description) else {
            errors.append("\(name): must be an integer, got \"\(value.description)\"")
            return nil
        }
        if port < minPort || port > maxPort {
            errors.append("\(name): must be between \(minPort) and \(maxPort), got \(port)")
        }
        return port
    }
}

enum ConfigValue: Codable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case bool(Bool)

    // Infer type from string so CLI users can pass unquoted values (1024, true, info)
    static func infer(from string: String) -> ConfigValue {
        if let intVal = Int(string) { return .int(intVal) }
        if string == "true" { return .bool(true) }
        if string == "false" { return .bool(false) }
        return .string(string)
    }

    var description: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .bool(let b): return String(b)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .bool(let b): try container.encode(b)
        }
    }
}

struct ConfigSetResponse: Codable {}

struct ValidationResult: Codable {
    let valid: Bool
    let errors: [String]
}
