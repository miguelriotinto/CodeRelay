package relay.protocol

import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * A session the user had in the pane that is no longer there.
 *
 * Lives in `:core-protocol` (not `relay.session.hub`) because the storage
 * modules persist it and `:core-session` depends on them, never the reverse.
 * `relay.session.hub` re-exports it via typealias.
 */
@Serializable
data class LostSession(
    @Serializable(with = UuidSerializer::class) val id: UUID,
    val name: String,
)

/**
 * The sessions a server's pane last showed, scoped to the token that listed
 * them. A DIFF baseline only; it never populates the pane.
 */
@Serializable
data class SessionBaseline(val tokenId: String, val sessions: List<LostSession>)
