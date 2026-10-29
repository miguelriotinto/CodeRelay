package relay.session.hub

import java.util.UUID

/**
 * One-time move from the single-server build (multi-server spec §9). Only the
 * bookmark the old `lastConnectedServerId` names stays enabled — or the only
 * bookmark, when there is just one — so the upgrade looks exactly like the
 * previous build (G8). The legacy session-name/agent maps move under that
 * bookmark, and are dropped when the last-used id names no bookmark (they
 * belonged to a server that is gone). The flag is set BEFORE the legacy maps
 * move, so a crash in between cannot re-run the migration over the user's
 * later choices.
 */
object HubMigration {
    suspend fun run(
        bookmarks: BookmarkStore,
        lastServerId: String?,
        state: HubStateStore,
        moveLegacyOwnership: (UUID?) -> Unit,
    ): Boolean {
        if (state.isMigrated) return false
        val all = bookmarks.loadAll()
        val last = lastServerId?.takeIf { it.isNotBlank() }?.let { runCatching { UUID.fromString(it) }.getOrNull() }
        val lastExists = last != null && all.any { it.id == last }
        val keep: UUID? = when {
            lastExists -> last
            all.size == 1 -> all[0].id
            else -> null
        }
        bookmarks.saveAll(all.map { it.copy(enabled = it.id == keep) })
        state.markMigrated()
        // A stale last-used id means the maps were that (deleted) server's.
        moveLegacyOwnership(if (last != null && !lastExists) null else keep)
        return true
    }
}
