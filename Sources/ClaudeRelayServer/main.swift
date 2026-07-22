import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import ClaudeRelayKit
import Foundation

// Ensure config directory exists
do {
    try ConfigManager.ensureDirectory()
} catch {
    fputs("FATAL: Cannot create config directory: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
}

let config: RelayConfig
do {
    config = try ConfigManager.load()
} catch {
    fputs("FATAL: Cannot load config: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

let tokenStore = TokenStore(directory: RelayConfig.configDirectory)
let sessionManager = SessionManager(config: config, tokenStore: tokenStore)
// Always constructed so devices can register even when push delivery is off;
// enabling push later then doesn't require every device to reconnect.
let pushStore = PushRegistrationStore(directory: RelayConfig.configDirectory)

// Shared rate limiter for both the admin HTTP surface and the WebSocket
// auth surface. A brute-force scanner that hits either path is throttled
// by the same bucket. 10 failures / 60 s is generous for humans typing
// tokens but cheap enough to stall credential-stuffing tools.
let rateLimiter = RateLimiter(maxAttempts: 10, windowSeconds: 60)

// Every 30 minutes, evict observers older than 1 hour. Prevents unbounded
// growth if a channel dies without its ChannelInboundHandler running cleanup.
let observerPurgeTask = Task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30 * 60))
        guard !Task.isCancelled else { return }
        await sessionManager.purgeStaleObservers(olderThan: 60 * 60)
    }
}

let wsServer = WebSocketServer(
    group: group, config: config,
    sessionManager: sessionManager, tokenStore: tokenStore,
    rateLimiter: rateLimiter,
    pushStore: pushStore
)
let adminServer = AdminHTTPServer(
    group: group, port: config.adminPort,
    sessionManager: sessionManager, tokenStore: tokenStore,
    rateLimiter: rateLimiter
)

do {
    try await wsServer.start()
} catch {
    fputs("FATAL: WebSocket server failed to start on port \(config.wsPort): \(error.localizedDescription)\n", stderr)
    RelayLogger.log(.fault, category: "server",
        "WebSocket bind failed on port \(config.wsPort): \(error.localizedDescription)")
    try? await group.shutdownGracefully()
    Foundation.exit(1)
}

do {
    try await adminServer.start()
} catch {
    fputs("FATAL: Admin server failed to start on port \(config.adminPort): \(error.localizedDescription)\n", stderr)
    RelayLogger.log(.fault, category: "server",
        "Admin bind failed on port \(config.adminPort): \(error.localizedDescription)")
    try? await wsServer.stop()
    try? await group.shutdownGracefully()
    Foundation.exit(1)
}

let wsHost = config.bindAll ? "0.0.0.0" : "127.0.0.1"
RelayLogger.log(category: "server", "Server started — WebSocket: \(wsHost):\(config.wsPort), Admin: 127.0.0.1:\(config.adminPort)")
print("ClaudeRelay server running")
print("  WebSocket: \(wsHost):\(config.wsPort)")
print("  Admin API: 127.0.0.1:\(config.adminPort)")

// Auto-reap child processes (PTY shells) to prevent zombies.
signal(SIGCHLD, SIG_IGN)

// Wait for SIGINT/SIGTERM using async-safe signal handling.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    sigintSource.setEventHandler {
        sigintSource.cancel()
        sigtermSource.cancel()
        continuation.resume()
    }
    sigtermSource.setEventHandler {
        sigintSource.cancel()
        sigtermSource.cancel()
        continuation.resume()
    }
    sigintSource.resume()
    sigtermSource.resume()
}

RelayLogger.log(category: "server", "Shutdown signal received")
print("\nShutting down...")

observerPurgeTask.cancel()

// Race the graceful-shutdown path against a 10s timer. If the normal
// teardown stalls (e.g. a stuck PTY terminate), fall through to the forced
// exit path so launchd can restart us rather than leaving a zombie server.
let shutdownSucceeded: Bool = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
        await sessionManager.shutdown()
        await tokenStore.flushIfDirty()
        return true
    }
    group.addTask {
        try? await Task.sleep(for: .seconds(10))
        return false
    }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
}

if !shutdownSucceeded {
    RelayLogger.log(.error, category: "server",
        "Shutdown timed out after 10s — forcing exit")
    print("Shutdown timed out, forcing exit.")
}

// Stop the servers no matter what — if shutdown timed out we still want
// to close sockets so the next launch can bind the ports. Log any
// teardown failures but never re-raise — the process is exiting.
do {
    try await wsServer.stop()
} catch {
    RelayLogger.log(.info, category: "server",
        "wsServer.stop() failed: \(error.localizedDescription)")
}
do {
    try await adminServer.stop()
} catch {
    RelayLogger.log(.info, category: "server",
        "adminServer.stop() failed: \(error.localizedDescription)")
}
do {
    try await group.shutdownGracefully()
} catch {
    RelayLogger.log(.info, category: "server",
        "eventLoopGroup.shutdownGracefully() failed: \(error.localizedDescription)")
}
