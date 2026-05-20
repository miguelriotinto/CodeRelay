import os
import Foundation

// MARK: - RelayLogger

/// Structured logging facade for the ClaudeRelay server.
///
/// Categories:
///  - `connection` : WebSocket connect / disconnect events
///  - `session`    : Session state transitions and lifecycle
///  - `auth`       : Authentication attempts (NEVER log tokens)
///  - `admin`      : Admin API requests
///  - `server`     : Server lifecycle (start, stop)
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

    /// Log to os.Logger, stderr, and the in-memory LogStore.
    public static func log(
        _ level: OSLogType = .info,
        category: String,
        _ message: String
    ) {
        let logger = Logger(subsystem: subsystem, category: category)
        logger.log(level: level, "\(message, privacy: .public)")

        let levelString: String
        switch level {
        case .debug: levelString = "debug"
        case .error: levelString = "error"
        case .fault: levelString = "fault"
        default: levelString = "info"
        }

        let timestamp = timestampFormatter.string(from: Date())
        fputs("[\(timestamp)] [\(levelString.uppercased())] [\(category)] \(message)\n", stderr)

        store.append(level: levelString, category: category, message: message)
    }
}
