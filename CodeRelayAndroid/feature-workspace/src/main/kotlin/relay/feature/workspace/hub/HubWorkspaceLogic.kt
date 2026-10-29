package relay.feature.workspace.hub

import relay.protocol.SessionRef
import relay.session.hub.HubAggregate
import relay.session.hub.ServerSection
import relay.session.hub.ServerSectionStatus

/** One tab in the cross-server strip. Keyed by [ref], never a bare session id (two relays can list the same UUID). */
data class HubTab(
    val ref: SessionRef,
    val number: Int,
    val isSelected: Boolean,
    /** The server's title, only when more than one server is enabled (G8: one server shows no prefix). */
    val serverTitle: String?,
)

/** What a section header's Retry does. */
enum class RetryAction { RECOVER, OPEN_MANAGEMENT }

/** Pure rules for the hub workspace (multi-server spec §8.1), shared by Android and Linux. */
object HubWorkspaceLogic {
    /** Nothing to show: the management screen is the workspace (spec §9, an upgrade with every bookmark disabled). */
    fun shouldPresentManagement(aggregate: HubAggregate): Boolean = aggregate.enabledServers == 0

    /** Tabs number sessions across enabled servers in sidebar order (spec §8.1). */
    fun tabs(sections: List<ServerSection>, activeRef: SessionRef?): List<HubTab> {
        val enabled = sections.filter { it.config.enabled }
        val prefix = enabled.size > 1
        var n = 0
        return enabled.flatMap { section ->
            section.sessions.map { s ->
                n += 1
                val ref = SessionRef(section.id, s.id)
                HubTab(ref, n, ref == activeRef, if (prefix) section.title else null)
            }
        }
    }

    /** A rejected or missing token cannot be retried away; it needs re-pairing in Servers. */
    fun retryAction(section: ServerSection): RetryAction =
        if (section.status is ServerSectionStatus.AuthFailed) RetryAction.OPEN_MANAGEMENT else RetryAction.RECOVER

    /** Some enabled server is on its way up, so an empty workspace should say "Connecting…". */
    fun isConnecting(sections: List<ServerSection>): Boolean = sections.any {
        it.config.enabled && (it.status == ServerSectionStatus.Connecting || it.status == ServerSectionStatus.Reconnecting)
    }
}

/** Status dot colour for a section header. */
enum class HeaderDot { GREEN, ORANGE, RED, GRAY }

/** Pure presentation of a server section's header line (spec §8.1); port of Swift `ServerSectionHeaderModel`. */
data class ServerSectionHeaderModel(
    val title: String,
    val subtitle: String?,
    val dot: HeaderDot,
    val badge: Int,
    val offersRetry: Boolean,
    val isDuplicate: Boolean,
) {
    val accessibilityLabel: String get() = listOfNotNull(title, subtitle).joinToString(", ")

    companion object {
        fun of(section: ServerSection): ServerSectionHeaderModel {
            val (subtitle, dot, retry) = when (val s = section.status) {
                ServerSectionStatus.Live -> Triple(null, HeaderDot.GREEN, false)
                ServerSectionStatus.Connecting -> Triple("connecting…", HeaderDot.ORANGE, false)
                ServerSectionStatus.Reconnecting -> Triple("reconnecting…", HeaderDot.ORANGE, false)
                ServerSectionStatus.Offline -> Triple("offline", HeaderDot.RED, true)
                is ServerSectionStatus.AuthFailed -> Triple(s.message, HeaderDot.ORANGE, true)
                ServerSectionStatus.Disabled -> Triple("disabled", HeaderDot.GRAY, false)
            }
            return ServerSectionHeaderModel(
                title = section.title,
                subtitle = subtitle,
                dot = dot,
                badge = if (section.status.isLive) section.awaitingInput else 0,
                offersRetry = retry,
                isDuplicate = section.isDuplicateInstance,
            )
        }
    }
}
