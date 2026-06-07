import XCTest
import NIO
import NIOCore
import NIOEmbedded
@testable import ClaudeRelayServer

/// Verifies the half-open-connection reaper. Regression for the fd leak where
/// clients that vanished without a TCP FIN (mobile app-kill, NAT/CGNAT
/// eviction) left sockets in `ESTABLISHED` forever until the server hit
/// `EMFILE` ("Too many open files").
final class IdleConnectionReaperTests: XCTestCase {

    /// A read-idle `IdleStateEvent` must close the channel so the existing
    /// `channelInactive` cleanup path runs and the fd is released.
    func testReadIdleEventClosesChannel() throws {
        let channel = EmbeddedChannel(handler: IdleConnectionReaper())
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9999)).wait()
        XCTAssertTrue(channel.isActive)

        channel.pipeline.fireUserInboundEventTriggered(IdleStateHandler.IdleStateEvent.read)

        XCTAssertFalse(channel.isActive, "Read-idle event should close the channel")
        _ = try? channel.finish()
    }

    /// Non-read idle events (write/all) and unrelated user events must pass
    /// through untouched — we only reap on inbound silence.
    func testNonReadIdleEventDoesNotClose() throws {
        let channel = EmbeddedChannel(handler: IdleConnectionReaper())
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9999)).wait()
        XCTAssertTrue(channel.isActive)

        channel.pipeline.fireUserInboundEventTriggered(IdleStateHandler.IdleStateEvent.write)
        channel.pipeline.fireUserInboundEventTriggered(IdleStateHandler.IdleStateEvent.all)

        XCTAssertTrue(channel.isActive, "Only read-idle should close the connection")
        _ = try? channel.finish()
    }
}
