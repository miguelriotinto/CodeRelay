package relay.protocol

import java.util.UUID

/**
 * One session on one server (multi-server spec §5.1). [serverId] is the
 * BOOKMARK id — stable, local, survives a host rename — never the relay's
 * instance id, which only routes deep links and flags duplicates.
 */
data class SessionRef(val serverId: UUID, val sessionId: UUID)
