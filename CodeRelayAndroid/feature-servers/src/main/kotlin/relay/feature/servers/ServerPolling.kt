package relay.feature.servers

import relay.protocol.ConnectionConfig
import relay.session.hub.ServerSection

/** Management-screen rules (multi-server spec §8.1, §11), shared by Android and Linux. */
object ServerPolling {
    /**
     * Only DISABLED bookmarks are probed (D11): an enabled one is live in the
     * hub, whose connection is its status — probing it too would open a second
     * socket to the same relay.
     */
    fun targets(list: List<ConnectionConfig>): List<ConnectionConfig> = list.filter { !it.enabled }

    /**
     * After an edit, only a server that is not live gets a fresh coordinator (a
     * pasted token reaches the relay only that way); rebuilding a live one would
     * detach its session for nothing.
     */
    fun shouldRebuild(section: ServerSection): Boolean = !section.status.isLive
}
