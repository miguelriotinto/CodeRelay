import NIO
import NIOCore

/// Closes a channel that has gone silent for too long.
///
/// Pairs with NIO's `IdleStateHandler`: when no inbound bytes arrive within
/// the configured read-idle window, `IdleStateHandler` fires a read
/// `IdleStateEvent` and this handler closes the channel.
///
/// **Why this exists.** `RelayMessageHandler.channelInactive` cleans up
/// observers + PTY state, but it only fires when the kernel learns the peer
/// is gone (a TCP FIN/RST). A mobile client that vanishes ungracefully — app
/// killed, network dropped, NAT/CGNAT idle-eviction — sends no FIN, so the
/// socket lingers in `ESTABLISHED` forever and its fd is never released.
/// Over days this leaks file descriptors until the server hits `EMFILE`
/// ("Too many open files") and can no longer accept connections.
///
/// Healthy clients send an application-level ping every 10 s
/// (`RelayConnection.pingInterval`), so a 60 s read-idle window = 6 missed
/// pings before a connection is judged dead. That is comfortably above
/// normal jitter and below any reasonable leak budget. Closing here routes
/// through `channelInactive`, so the existing cleanup path frees the fd.
final class IdleConnectionReaper: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idle = event as? IdleStateHandler.IdleStateEvent, idle == .read {
            let remote = context.remoteAddress?.description ?? "unknown"
            RelayLogger.log(category: "connection",
                "Closing idle connection from \(remote) (no data within read-idle window)")
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }
}
