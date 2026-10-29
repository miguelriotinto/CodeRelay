package relay.app

import relay.protocol.PairingURL
import relay.protocol.SessionDeepLink

/**
 * Where an incoming `coderelay://` link goes. Pure, so the launch-intent rule
 * is a JVM test: a session link (with its optional `?server=` hint) goes to the
 * hub, a pairing link to the management screen's pairing sheet.
 */
object DeepLinkRouting {
    sealed interface Route {
        data class Session(val link: SessionDeepLink) : Route
        data class Pair(val url: PairingURL) : Route
        data object None : Route
    }

    fun route(uri: String?): Route {
        if (uri == null) return Route.None
        PairingURL.parse(uri)?.let { return Route.Pair(it) }
        SessionDeepLink.parse(uri)?.let { return Route.Session(it) }
        return Route.None
    }
}
