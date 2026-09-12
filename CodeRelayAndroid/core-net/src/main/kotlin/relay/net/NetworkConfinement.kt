package relay.net

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import java.util.concurrent.Executors

/**
 * Single-thread confinement dispatcher replicating the Swift `@MainActor`
 * serial isolation used by `RelayConnection` / `SessionController`.
 *
 * All connection state (generation, RTT window, pong continuation, transport
 * fields) is mutated only while confined to this one thread, so the port can
 * drop the per-field locks the JVM would otherwise need. The one exception is
 * `RelayConnection`'s subscriber map, which `SessionController` mutates from the
 * caller's thread and the receive loop reads on this dispatcher; it is a
 * `ConcurrentHashMap` rather than confined. This is a pure-JVM dispatcher with
 * no Android `Main` dependency, keeping `:core-net` testable without an Android
 * runtime.
 */
object NetworkConfinement {
    val dispatcher: CoroutineDispatcher =
        Executors.newSingleThreadExecutor { r ->
            Thread(r, "relay-net").apply { isDaemon = true }
        }.asCoroutineDispatcher()
}
