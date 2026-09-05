import Foundation
#if canImport(os)
import os
#endif

// MARK: - RelayLogLevel

/// Severity of a `RelayLogger` entry.
///
/// The case names mirror `OSLogType` so every call site reads
/// `RelayLogger.log(.error, …)` on both platforms; the mapping to the
/// unified-logging type happens once, in `RelayLogger`, and only on Darwin.
public enum RelayLogLevel: String, Sendable {
    case debug, info, error, fault

    #if canImport(os)
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info:  return .info
        case .error: return .error
        case .fault: return .fault
        }
    }
    #endif
}

// MARK: - RelayLogger

/// Structured logging facade for the ClaudeRelay server.
///
/// Categories:
///  - `connection` : WebSocket connect / disconnect events
///  - `websocket`  : WebSocket frame-level handling
///  - `session`    : Session state transitions and lifecycle
///  - `activity`   : Coding-agent activity monitoring
///  - `auth`       : Authentication attempts (NEVER log tokens)
///  - `tokens`     : Token store CRUD
///  - `admin`      : Admin API requests
///  - `server`     : Server lifecycle (start, stop)
///
/// Sinks: stderr and the in-memory `LogStore` everywhere, plus `os.Logger` on
/// Darwin. On Linux stderr is the system sink — a systemd user service's
/// stderr is captured by journald, so `journalctl --user -u claude-relay` is
/// the `log stream` equivalent and no second backend is needed.
///
/// Security: This logger must NEVER emit tokens, secrets, or raw terminal I/O.
public enum RelayLogger {
    private static let subsystem = "com.coderemote.relay"
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// In-memory log store queryable via the admin `/logs` endpoint.
    public private(set) static var store = LogStore()

    /// Log to the platform logger (Darwin), stderr, and the in-memory LogStore.
    public static func log(
        _ level: RelayLogLevel = .info,
        category: String,
        _ message: String
    ) {
        #if canImport(os)
        let logger = Logger(subsystem: subsystem, category: category)
        logger.log(level: level.osLogType, "\(message, privacy: .public)")
        #endif

        let levelString = level.rawValue
        let timestamp = timestampFormatter.string(from: Date())
        fputs("[\(timestamp)] [\(levelString.uppercased())] [\(category)] \(message)\n", stderr)

        store.append(level: levelString, category: category, message: message)
    }
}
