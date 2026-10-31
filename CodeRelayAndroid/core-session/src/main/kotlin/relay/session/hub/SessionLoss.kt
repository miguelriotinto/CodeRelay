package relay.session.hub

import relay.protocol.SessionInfo
import java.util.UUID

typealias LostSession = relay.protocol.LostSession
typealias SessionBaseline = relay.protocol.SessionBaseline

enum class SessionLossKind { TAKEN, ENDED }

/**
 * What one coordinator pass lost, already classified. Delivered through
 * `SessionCoordinator.onSessionsLost` to the hub, which aggregates and presents
 * (spec §2). Mirrors Swift `SessionLossReport`.
 */
data class SessionLossReport(val taken: List<LostSession>, val ended: List<LostSession>)

/** Pure classification of sessions that disappeared from this token's list. */
object SessionLossClassifier {
    /** Entries of [before] not present as non-terminal in [owned], order preserved. */
    fun lost(before: List<LostSession>, owned: List<SessionInfo>): List<LostSession> {
        val live = owned.filter { !it.state.isTerminal }.map { it.id }.toSet()
        return before.filter { it.id !in live }
    }

    /**
     * Splits lost sessions using the unscoped list. Taken when still alive under
     * another token; otherwise ended. A null [all] counts every session as taken.
     * Duplicate ids in [all]: the first occurrence wins (matches Swift).
     */
    fun classify(
        lost: List<LostSession>,
        all: List<SessionInfo>?,
        myTokenId: String,
    ): Pair<List<LostSession>, List<LostSession>> {
        if (all == null) return lost to emptyList()
        val byId = LinkedHashMap<UUID, SessionInfo>()
        for (info in all) byId.putIfAbsent(info.id, info)
        val taken = mutableListOf<LostSession>()
        val ended = mutableListOf<LostSession>()
        for (session in lost) {
            val info = byId[session.id]
            if (info != null && !info.state.isTerminal && info.tokenId != myTokenId) taken += session
            else ended += session
        }
        return taken to ended
    }
}

data class SessionLossItem(val serverId: UUID, val serverName: String, val session: LostSession)

object SessionLossCopy {
    fun takenTitle(count: Int): String = if (count == 1) "Session Moved" else "Sessions Moved"

    fun takenBody(items: List<SessionLossItem>): String =
        body(items, "was attached from another device.", "were attached from another device.")

    fun endedBody(items: List<SessionLossItem>): String =
        body(items, "ended while you were away.", "ended while you were away.")

    private fun body(items: List<SessionLossItem>, one: String, many: String): String {
        val multiServer = items.map { it.serverId }.toSet().size > 1
        val names = items.map { if (multiServer) "${it.session.name} (on ${it.serverName})" else it.session.name }
        return when (names.size) {
            0 -> ""
            1 -> "${names[0]} $one"
            2 -> "${names[0]} and ${names[1]} $many"
            else -> {
                val rest = names.size - 2
                "${names[0]}, ${names[1]} and $rest ${if (rest == 1) "other" else "others"} $many"
            }
        }
    }
}
