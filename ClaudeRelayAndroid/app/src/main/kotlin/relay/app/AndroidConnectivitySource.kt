package relay.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import relay.session.ConnectivitySource

/**
 * The Android `ConnectivityManager` glue for [ConnectivitySource], the seam the
 * pure-JVM `:core-session` [relay.session.NetworkObserver] left injected.
 *
 * On iOS the equivalent is `NWPathMonitor` (NetworkMonitor.swift). Here a
 * [ConnectivityManager.NetworkCallback] tracks the set of networks that currently
 * have validated internet capability; [isOnline] is true iff that set is non-empty
 * — the analog of `NWPath.status == .satisfied`.
 *
 * `NetworkObserver.edges(...)` consumes [isOnline] and emits only on the
 * offline→online edge, so transient redundant updates here are harmless (they're
 * collapsed downstream by `distinctUntilChanged`).
 *
 * Call [start] to register the callback and [stop] to unregister it; the host
 * (`MainActivity`) owns that lifecycle. Requires the `ACCESS_NETWORK_STATE`
 * permission (declared in the manifest).
 */
class AndroidConnectivitySource(context: Context) : ConnectivitySource {

    private val connectivityManager =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val _isOnline = MutableStateFlow(false)
    override val isOnline: StateFlow<Boolean> = _isOnline.asStateFlow()

    /** Networks currently providing validated internet, by their [Network] handle. */
    private val validatedNetworks = mutableSetOf<Network>()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            val ok = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            synchronized(validatedNetworks) {
                if (ok) validatedNetworks.add(network) else validatedNetworks.remove(network)
                _isOnline.value = validatedNetworks.isNotEmpty()
            }
        }

        override fun onLost(network: Network) {
            synchronized(validatedNetworks) {
                validatedNetworks.remove(network)
                _isOnline.value = validatedNetworks.isNotEmpty()
            }
        }
    }

    /** Seeds the current state and registers the network callback. Idempotent-safe to call once. */
    fun start() {
        // Seed from the currently-active network so an app launched online doesn't
        // depend on the first capabilities callback to flip isOnline true.
        val active = connectivityManager.activeNetwork
        val caps = active?.let { connectivityManager.getNetworkCapabilities(it) }
        synchronized(validatedNetworks) {
            if (active != null && caps != null &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            ) {
                validatedNetworks.add(active)
            }
            _isOnline.value = validatedNetworks.isNotEmpty()
        }
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        runCatching { connectivityManager.registerNetworkCallback(request, callback) }
    }

    /** Unregisters the network callback. Safe to call even if [start] wasn't called. */
    fun stop() {
        runCatching { connectivityManager.unregisterNetworkCallback(callback) }
    }
}
