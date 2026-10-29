package relay.protocol

import java.util.UUID

/** The relay's own identity, sent on `auth_success` / `pair_success` from protocol v3 (multi-server spec §5.2, §6.2). */
data class ServerIdentity(val id: UUID, val name: String) {
    companion object {
        /** Null for a v2 relay (no id) or a malformed id. */
        fun from(serverId: String?, serverName: String?): ServerIdentity? {
            val id = serverId?.let { runCatching { UUID.fromString(it) }.getOrNull() } ?: return null
            return ServerIdentity(id, serverName.orEmpty())
        }
    }
}
