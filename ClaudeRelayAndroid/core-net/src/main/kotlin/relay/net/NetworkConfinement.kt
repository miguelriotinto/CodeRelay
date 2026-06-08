package relay.net

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import java.util.concurrent.Executors

/**
 * Single-thread confinement dispatcher replicating the Swift `@MainActor`
 * serial isolation used by `RelayConnection` / `SessionController`.
 *
 * All connection state (generation, RTT window, pong continuation, subscriber
 * map) is mutated only while confined to this one thread, so the port can drop
 * the per-field locks the JVM would otherwise need. This is a pure-JVM
 * dispatcher with no Android `Main` dependency, keeping `:core-net` testable
 * without an Android runtime.
 */
object NetworkConfinement {
    val dispatcher: CoroutineDispatcher =
        Executors.newSingleThreadExecutor { r ->
            Thread(r, "relay-net").apply { isDaemon = true }
        }.asCoroutineDispatcher()
}
