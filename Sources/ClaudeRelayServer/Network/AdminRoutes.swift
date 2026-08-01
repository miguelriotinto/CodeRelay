import Foundation
import NIOCore
import NIOHTTP1
import ClaudeRelayKit
import CPTYShim

/// Routes for the admin HTTP API.
///
/// **Security model:** The admin server binds to `127.0.0.1` only (see `AdminHTTPServer`),
/// so access is restricted to processes running on the same machine. This localhost-only
/// binding is the intentional security boundary — no additional authentication is applied.
enum AdminRoutes {
    /// Process start time in microseconds since the epoch, read from the kernel
    /// (`sysctl` via CPTYShim). Unlike a `static let startTime = Date()`, which is
    /// lazily initialized on first access and would report ~0s uptime on the first
    /// `/status` call, this reflects the actual server boot time regardless of when
    /// the property is first touched. `-1` means the lookup failed.
    private static let processStartMicros: Int64 =
        relay_get_process_start_time(ProcessInfo.processInfo.processIdentifier)

    static func handle(
        method: HTTPMethod,
        uri: String,
        body: ByteBuffer?,
        sessionManager: SessionManager,
        tokenStore: TokenStore,
        pairingStore: PairingCodeStore,
        config: RelayConfig
    ) async -> AdminResponse {
        let parts = uri.split(separator: "?", maxSplits: 1)
        let path = parts.first.map(String.init) ?? uri
        let query: String? = parts.count > 1 ? String(parts[1]) : nil
        let components = path.split(separator: "/").map(String.init)

        switch (method, components.first) {
        case (.GET, "health"):
            return handleHealth(components)
        case (.GET, "status"):
            return await handleStatus(components, sessionManager: sessionManager)
        case (.GET, "sessions"):
            return await handleGetSessions(components, sessionManager: sessionManager)
        case (.DELETE, "sessions"):
            return await handleDeleteSession(components, sessionManager: sessionManager)
        case (.POST, "tokens"):
            return await handlePostTokens(components, body: body, tokenStore: tokenStore)
        case (.GET, "tokens"):
            return await handleGetTokens(components, tokenStore: tokenStore)
        case (.DELETE, "tokens"):
            return await handleDeleteToken(components, tokenStore: tokenStore)
        case (.PATCH, "tokens"):
            return await handlePatchToken(components, body: body, tokenStore: tokenStore)
        case (.GET, "config"):
            return handleGetConfig(components)
        case (.PUT, "config"):
            return handlePutConfig(components, body: body)
        case (.GET, "logs"):
            return handleLogs(components, query: query)
        case (.POST, "hook"):
            return await handleHookState(components, body: body, sessionManager: sessionManager)
        case (.POST, "pair"):
            return await handlePairCreate(components, body: body, pairingStore: pairingStore, config: config)
        default:
            return .error("Not found", status: 404)
        }
    }

    // MARK: - Hook State (F6)

    /// `POST /hook/state` — a local agent lifecycle hook reports authoritative
    /// session state. Body: `{"sessionId": "<uuid>", "state": "working|blocked|idle"}`.
    /// Localhost-only (the admin server binds 127.0.0.1) — same trust boundary
    /// as every other admin route; the hook only knows the sessionId because
    /// the server injected it into the session's own PTY environment.
    private static func handleHookState(
        _ components: [String],
        body: ByteBuffer?,
        sessionManager: SessionManager
    ) async -> AdminResponse {
        guard components == ["hook", "state"] else { return .error("Not found", status: 404) }
        guard let body = body else { return .error("Missing body", status: 400) }
        let bodyData = body.withUnsafeReadableBytes { Data($0) }
        guard let parsed = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let sessionIdStr = parsed["sessionId"] as? String,
              let sessionId = UUID(uuidString: sessionIdStr),
              let stateStr = parsed["state"] as? String else {
            return .error("Invalid body: expected {sessionId, state}", status: 400)
        }
        // Decode tolerantly to the same enum used on the wire; reject unknowns
        // rather than silently coercing to .unknown so a typo in a hook script
        // surfaces instead of masquerading as a real state.
        guard let state = AgentDetectedState(rawValue: stateStr),
              state == .working || state == .blocked || state == .idle else {
            return .error("Invalid state: expected working|blocked|idle", status: 400)
        }
        let applied = await sessionManager.reportHookState(sessionId: sessionId, state: state)
        guard applied else { return .error("Unknown or inactive session", status: 404) }
        return .json(["ok": true])
    }

    // MARK: - Pairing (F11)

    /// `POST /pair/create` — mint a one-time pairing code for a device to
    /// redeem over the WebSocket. Body (optional): `{"label": "<device name>"}`.
    ///
    /// Localhost-only, like every admin route: whoever can reach this port is
    /// already on the machine and could read the token store directly, so the
    /// code adds no privilege. It exists so the *token* never has to be
    /// displayed or transcribed.
    private static func handlePairCreate(
        _ components: [String],
        body: ByteBuffer?,
        pairingStore: PairingCodeStore,
        config: RelayConfig
    ) async -> AdminResponse {
        guard components == ["pair", "create"] else { return .error("Not found", status: 404) }

        var label: String?
        if let body, let data = body.getData(at: body.readerIndex, length: body.readableBytes),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawLabel = json["label"] as? String {
            let trimmed = rawLabel.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                // Apply the same sanitization as deviceName in handlePairRequest:
                // strip control characters and cap at 60 chars.
                let allowedChars = CharacterSet.controlCharacters.union(.newlines).inverted
                let stripped = trimmed.unicodeScalars.filter { allowedChars.contains($0) }
                label = String(String.UnicodeScalarView(stripped).prefix(60))
                if label?.isEmpty == true { label = nil }
            }
        }

        let grant = await pairingStore.mint(label: label)

        let payload: [String: Any] = [
            "code": grant.code,
            "formattedCode": PairingCode.formatted(grant.code),
            "expiresAt": ISO8601DateFormatter().string(from: grant.expiresAt),
            "wsPort": Int(config.wsPort),
            "tls": config.tlsEnabled
        ]
        return .json(payload)
    }

    // MARK: - Health & Status

    private static func handleHealth(_ components: [String]) -> AdminResponse {
        guard components == ["health"] else { return .error("Not found", status: 404) }
        return .json(["status": "ok"])
    }

    private static func handleStatus(
        _ components: [String],
        sessionManager: SessionManager
    ) async -> AdminResponse {
        guard components == ["status"] else { return .error("Not found", status: 404) }
        let sessions = await sessionManager.listSessions()
        // Compute uptime from the kernel-reported process start time. If the
        // lookup failed (-1), report 0 rather than a bogus epoch-based value.
        let uptimeSeconds: Int
        if processStartMicros > 0 {
            let nowSeconds = Date().timeIntervalSince1970
            let startSeconds = Double(processStartMicros) / 1_000_000.0
            uptimeSeconds = max(0, Int(nowSeconds - startSeconds))
        } else {
            uptimeSeconds = 0
        }
        let info: [String: Any] = [
            "status": "running",
            "version": ClaudeRelayKit.version,
            "protocolVersion": ClaudeRelayKit.protocolVersion,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "uptime_seconds": uptimeSeconds,
            "session_count": sessions.count
        ]
        return .json(info)
    }

    // MARK: - Sessions

    private static func handleGetSessions(
        _ components: [String],
        sessionManager: SessionManager
    ) async -> AdminResponse {
        if components == ["sessions"] {
            let sessions = await sessionManager.listSessions()
            return .encodable(sessions)
        }
        if components.count == 2 {
            guard let uuid = UUID(uuidString: components[1]) else {
                return .error("Invalid session ID", status: 400)
            }
            do {
                let info = try await sessionManager.inspectSession(id: uuid)
                return .encodable(info)
            } catch {
                return .error("Session not found", status: 404)
            }
        }
        return .error("Not found", status: 404)
    }

    private static func handleDeleteSession(
        _ components: [String],
        sessionManager: SessionManager
    ) async -> AdminResponse {
        guard components.count == 2 else { return .error("Not found", status: 404) }
        guard let uuid = UUID(uuidString: components[1]) else {
            return .error("Invalid session ID", status: 400)
        }
        do {
            try await sessionManager.terminateSession(id: uuid)
            return .json(["status": "terminated"])
        } catch {
            return .error("Session not found", status: 404)
        }
    }

    // MARK: - Tokens

    private static func handlePostTokens(
        _ components: [String],
        body: ByteBuffer?,
        tokenStore: TokenStore
    ) async -> AdminResponse {
        if components == ["tokens"] {
            return await createToken(body: body, tokenStore: tokenStore)
        }
        if components.count == 3, components[2] == "rotate" {
            return await rotateToken(id: components[1], tokenStore: tokenStore)
        }
        return .error("Not found", status: 404)
    }

    private static func createToken(body: ByteBuffer?, tokenStore: TokenStore) async -> AdminResponse {
        var label: String?
        var expiryDays: Int?
        if let body = body {
            let bodyData = body.withUnsafeReadableBytes { Data($0) }
            if let parsed = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                label = parsed["label"] as? String
                expiryDays = parsed["expiryDays"] as? Int
            }
        }
        do {
            let (plaintext, info) = try await tokenStore.create(label: label, expiryDays: expiryDays)
            var result: [String: Any] = [
                "token": plaintext,
                "id": info.id,
                "label": info.label ?? ""
            ]
            if let expiresAt = info.expiresAt {
                result["expiresAt"] = ISO8601DateFormatter().string(from: expiresAt)
            }
            return .json(result, status: 201)
        } catch {
            return .error("Failed to create token: \(error)", status: 500)
        }
    }

    private static func rotateToken(id: String, tokenStore: TokenStore) async -> AdminResponse {
        do {
            let (plaintext, info) = try await tokenStore.rotate(id: id)
            let result: [String: Any] = [
                "token": plaintext,
                "id": info.id,
                "label": info.label ?? ""
            ]
            return .json(result)
        } catch {
            return .error("Token not found", status: 404)
        }
    }

    private static func handleGetTokens(
        _ components: [String],
        tokenStore: TokenStore
    ) async -> AdminResponse {
        if components == ["tokens"] {
            let tokens = await tokenStore.list()
            return .encodable(tokens)
        }
        if components.count == 2 {
            do {
                let info = try await tokenStore.inspect(id: components[1])
                return .encodable(info)
            } catch {
                return .error("Token not found", status: 404)
            }
        }
        return .error("Not found", status: 404)
    }

    private static func handleDeleteToken(
        _ components: [String],
        tokenStore: TokenStore
    ) async -> AdminResponse {
        guard components.count == 2 else { return .error("Not found", status: 404) }
        do {
            try await tokenStore.delete(id: components[1])
            return .json(["status": "deleted"])
        } catch {
            return .error("Token not found", status: 404)
        }
    }

    private static func handlePatchToken(
        _ components: [String],
        body: ByteBuffer?,
        tokenStore: TokenStore
    ) async -> AdminResponse {
        guard components.count == 2 else { return .error("Not found", status: 404) }
        guard let body = body,
              let parsed = try? JSONSerialization.jsonObject(with: body.withUnsafeReadableBytes { Data($0) }) as? [String: Any],
              let label = parsed["label"] as? String else {
            return .error("Missing label in body", status: 400)
        }
        do {
            let info = try await tokenStore.rename(id: components[1], label: label)
            return .encodable(info)
        } catch {
            return .error("Token not found", status: 404)
        }
    }

    // MARK: - Config

    private static func handleGetConfig(_ components: [String]) -> AdminResponse {
        guard components == ["config"] else { return .error("Not found", status: 404) }
        do {
            let config = try ConfigManager.load()
            return .encodable(config)
        } catch {
            return .error("Failed to load config: \(error)", status: 500)
        }
    }

    private static func handlePutConfig(_ components: [String], body: ByteBuffer?) -> AdminResponse {
        guard components.count == 2 else { return .error("Not found", status: 404) }
        let key = components[1]
        guard let body = body,
              let parsed = try? JSONSerialization.jsonObject(with: body.withUnsafeReadableBytes { Data($0) }) as? [String: Any],
              let value = parsed["value"] else {
            return .error("Missing value in body", status: 400)
        }
        do {
            var config = try ConfigManager.load()
            try applyConfigValue(value, forKey: key, to: &config)
            try ConfigManager.save(config)
            return .encodable(config)
        } catch let error as ConfigError {
            return .error(error.message, status: 400)
        } catch {
            return .error("Failed to update config: \(error)", status: 500)
        }
    }

    static func applyConfigValue(_ value: Any, forKey key: String, to config: inout RelayConfig) throws {
        switch key {
        case "wsPort":
            guard let val = value as? Int else { throw ConfigError(message: "wsPort must be an integer") }
            try validatePort(val, name: "wsPort")
            config.wsPort = UInt16(val)
        case "adminPort":
            guard let val = value as? Int else { throw ConfigError(message: "adminPort must be an integer") }
            try validatePort(val, name: "adminPort")
            config.adminPort = UInt16(val)
        case "detachTimeout":
            guard let val = value as? Int else { throw ConfigError(message: "detachTimeout must be an integer") }
            try validateDetachTimeout(val)
            config.detachTimeout = val
        case "scrollbackSize":
            guard let val = value as? Int else { throw ConfigError(message: "scrollbackSize must be an integer") }
            try validateScrollbackSize(val)
            config.scrollbackSize = val
        case "logLevel":
            guard let val = value as? String else { throw ConfigError(message: "logLevel must be a string") }
            try validateLogLevel(val)
            config.logLevel = val
        case "tlsCert":
            guard let val = value as? String else { throw ConfigError(message: "tlsCert must be a string") }
            try validateTLSPath(val, name: "tlsCert")
            config.tlsCert = val.isEmpty ? nil : val
        case "tlsKey":
            guard let val = value as? String else { throw ConfigError(message: "tlsKey must be a string") }
            try validateTLSPath(val, name: "tlsKey")
            config.tlsKey = val.isEmpty ? nil : val
        case "maxSessionsPerToken":
            guard let val = value as? Int else { throw ConfigError(message: "maxSessionsPerToken must be an integer") }
            guard val >= 0 else { throw ConfigError(message: "maxSessionsPerToken must be >= 0") }
            config.maxSessionsPerToken = val
        case "bindAll":
            guard let val = value as? Bool else { throw ConfigError(message: "bindAll must be a boolean") }
            config.bindAll = val
        case "pushEnabled":
            guard let val = value as? Bool else { throw ConfigError(message: "pushEnabled must be a boolean") }
            config.pushEnabled = val
        case "pushNotifyOnFinished":
            guard let val = value as? Bool else { throw ConfigError(message: "pushNotifyOnFinished must be a boolean") }
            config.pushNotifyOnFinished = val
        case "apnsUseSandbox":
            guard let val = value as? Bool else { throw ConfigError(message: "apnsUseSandbox must be a boolean") }
            config.apnsUseSandbox = val
        case "apnsKeyPath":
            guard let val = value as? String else { throw ConfigError(message: "apnsKeyPath must be a string") }
            try validateReadableFileOrEmpty(val, name: "apnsKeyPath")
            config.apnsKeyPath = val.isEmpty ? nil : val
        case "apnsKeyId":
            guard let val = value as? String else { throw ConfigError(message: "apnsKeyId must be a string") }
            config.apnsKeyId = val.isEmpty ? nil : val
        case "apnsTeamId":
            guard let val = value as? String else { throw ConfigError(message: "apnsTeamId must be a string") }
            config.apnsTeamId = val.isEmpty ? nil : val
        case "apnsBundleId":
            guard let val = value as? String else { throw ConfigError(message: "apnsBundleId must be a string") }
            config.apnsBundleId = val.isEmpty ? nil : val
        case "fcmServiceAccountPath":
            guard let val = value as? String else { throw ConfigError(message: "fcmServiceAccountPath must be a string") }
            try validateReadableFileOrEmpty(val, name: "fcmServiceAccountPath")
            config.fcmServiceAccountPath = val.isEmpty ? nil : val
        case "fcmProjectId":
            guard let val = value as? String else { throw ConfigError(message: "fcmProjectId must be a string") }
            config.fcmProjectId = val.isEmpty ? nil : val
        default:
            throw ConfigError(message: "Unknown config key: \(key)")
        }
    }

    /// Validates that a non-empty path points at a readable regular file
    /// (empty string clears the field). Used for the APNs `.p8` and FCM
    /// service-account JSON credential paths.
    private static func validateReadableFileOrEmpty(_ path: String, name: String) throws {
        guard !path.isEmpty else { return }
        let expanded = NSString(string: path).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: expanded, isDirectory: &isDir), !isDir.boolValue else {
            throw ConfigError(message: "\(name) is not a readable file: \(path)")
        }
        guard fm.isReadableFile(atPath: expanded) else {
            throw ConfigError(message: "\(name) exists but is not readable: \(path)")
        }
    }

    // MARK: - Config Validation

    private static func validatePort(_ port: Int, name: String) throws {
        guard port >= 1024 && port <= 65535 else {
            throw ConfigError(message: "\(name) must be in range 1024-65535, got \(port)")
        }
    }

    private static func validateDetachTimeout(_ timeout: Int) throws {
        guard timeout >= 0 else {
            throw ConfigError(message: "detachTimeout must be >= 0, got \(timeout)")
        }
    }

    private static func validateScrollbackSize(_ size: Int) throws {
        guard size >= 1024 else {
            throw ConfigError(message: "scrollbackSize must be >= 1024 bytes, got \(size)")
        }
    }

    private static func validateLogLevel(_ level: String) throws {
        let validLevels = ["trace", "debug", "info", "warning", "error"]
        guard validLevels.contains(level) else {
            throw ConfigError(message: "logLevel must be one of: \(validLevels.joined(separator: ", ")), got \"\(level)\"")
        }
    }

    /// Accept an empty string (means "disable TLS for this field"); otherwise
    /// verify that the path — with `~` expansion — points at something the
    /// server can actually read. Catches typos before the next restart.
    private static func validateTLSPath(_ path: String, name: String) throws {
        guard !path.isEmpty else { return }
        let expanded = NSString(string: path).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: expanded) else {
            throw ConfigError(message: "\(name) path not found: \(path)")
        }
        guard fm.isReadableFile(atPath: expanded) else {
            throw ConfigError(message: "\(name) path exists but is not readable: \(path)")
        }
    }

    // MARK: - Logs

    private static func handleLogs(_ components: [String], query: String?) -> AdminResponse {
        guard components == ["logs"] else { return .error("Not found", status: 404) }

        var lineCount = 50
        if let query = query {
            for param in query.split(separator: "&") {
                let parts = param.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0] == "lines", let val = Int(parts[1]) {
                    lineCount = min(max(val, 1), 2000)
                }
            }
        }

        let entries = RelayLogger.store.recent(count: lineCount)
        return .json(["entries": entries])
    }
}

private struct ConfigError: Error {
    let message: String
}
