/// A small box that transfers a non-`Sendable` value across a `Task` boundary.
/// ONLY safe when the receiving task accesses `value` on the originating
/// `EventLoop` (e.g., via `ctx.eventLoop.execute`).
///
/// Misuse (accessing `value` from any other thread) is a data race and
/// undefined behavior. See the SwiftNIO concurrency guide for context on
/// why `ChannelHandlerContext` cannot be made `Sendable`.
struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
