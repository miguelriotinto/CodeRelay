package relay.app

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.SessionDeepLink
import java.util.UUID

class DeepLinkRoutingTest {
    @Test fun launchIntentRoutesSessionLinksToTheHub() { // Review Focus 1
        val sid = UUID.randomUUID(); val iid = UUID.randomUUID()
        assertEquals(
            DeepLinkRouting.Route.Session(SessionDeepLink(sid, iid)),
            DeepLinkRouting.route("coderelay://session/$sid?server=$iid"),
            "the server hint survives into the hub so a push opens the right relay",
        )
        assertTrue(DeepLinkRouting.route("coderelay://pair?host=h&port=9200&tls=0&code=ABCDEFGH") is DeepLinkRouting.Route.Pair)
        assertEquals(DeepLinkRouting.Route.None, DeepLinkRouting.route(null))
        assertEquals(DeepLinkRouting.Route.None, DeepLinkRouting.route("https://example.com"))
    }

    @Test fun aRecreatedActivityDoesNotReplayItsLaunchLink() {
        // Rotation / the fold's display switch hand the original launch intent
        // back; replaying it pulled the user back to the notified session and
        // could re-enable a server they had since disabled.
        assertTrue(DeepLinkRouting.shouldHandleLaunchIntent(restoredFromState = false, launchedFromHistory = false))
        assertEquals(false, DeepLinkRouting.shouldHandleLaunchIntent(restoredFromState = true, launchedFromHistory = false))
        assertEquals(false, DeepLinkRouting.shouldHandleLaunchIntent(restoredFromState = false, launchedFromHistory = true))
    }
}
