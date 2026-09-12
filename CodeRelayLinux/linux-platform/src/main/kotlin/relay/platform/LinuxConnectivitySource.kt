package relay.platform

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import relay.session.ConnectivitySource
import java.io.File

/**
 * Linux implementation of the `ConnectivitySource` seam that `NetworkObserver`
 * consumes. The Swift original wraps `NWPathMonitor`; Android wraps
 * `ConnectivityManager.registerNetworkCallback`.
 *
 * **Link state, not internet reachability — and that is the correct signal here.**
 * The obvious implementation is an internet check (`nmcli networking
 * connectivity`, or fetching a probe URL), and it would be wrong: a CodeRelay
 * server typically lives on the LAN or on Tailscale, so a machine with no
 * internet route can still reach its relay perfectly. Reporting "offline"
 * because a captive portal is in the way would trigger recovery loops against a
 * connection that was never broken.
 *
 * So this reports whether any non-loopback interface is carrying a link, read
 * from `/sys/class/net/<if>/operstate`. No NetworkManager dependency, no probe
 * traffic, and it works identically under systemd-networkd, iwd, or a
 * hand-configured interface.
 *
 * This is intentionally a coarse signal. It exists only to catch the
 * offline→online **edge** that `NetworkObserver` turns into a recovery trigger;
 * the authority on whether the relay is actually reachable is
 * `RelayConnection`'s own ping/pong death detection, which is unchanged.
 */
class LinuxConnectivitySource(
    scope: CoroutineScope,
    private val pollInterval: Long = DEFAULT_POLL_MILLIS,
    private val netDir: File = File("/sys/class/net"),
) : ConnectivitySource {

    private val _isOnline = MutableStateFlow(readLinkState())
    override val isOnline: StateFlow<Boolean> = _isOnline.asStateFlow()

    private val job: Job = scope.launch {
        while (isActive) {
            delay(pollInterval)
            // MutableStateFlow already conflates equal values, so a redundant
            // `true` never reaches NetworkObserver's edge detector.
            _isOnline.value = readLinkState()
        }
    }

    /** Stops polling. Called on app shutdown. */
    fun stop() = job.cancel()

    /**
     * True when at least one non-loopback interface reports `up`.
     *
     * `unknown` counts as up: virtual interfaces — Tailscale's `tailscale0`,
     * WireGuard, and most TUN devices — report `unknown` rather than `up`
     * because they have no physical carrier to report on. Treating those as
     * offline would mark a Tailscale-only machine permanently disconnected,
     * which is precisely the deployment this client is built for.
     */
    internal fun readLinkState(): Boolean {
        val interfaces = netDir.listFiles() ?: return true // can't tell → assume online
        for (iface in interfaces) {
            if (iface.name == "lo") continue
            val state = runCatching {
                File(iface, "operstate").readText().trim().lowercase()
            }.getOrNull() ?: continue
            if (state == "up" || state == "unknown") return true
        }
        return false
    }

    companion object {
        /**
         * Two seconds. This only needs to notice a returning network promptly
         * enough that recovery feels immediate; reading a handful of tiny sysfs
         * files at this rate is not measurable.
         */
        const val DEFAULT_POLL_MILLIS = 2_000L
    }
}
