package relay.feature.servers

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import relay.protocol.ConnectionConfig
import relay.session.ServerStatus
import relay.session.hub.ServerSection
import relay.session.hub.ServerSectionStatus
import java.util.UUID

class ServerManagementTest {
    @Test fun statusPollerTargetsOnlyDisabledBookmarks() {
        // Enabled servers are live in the hub: their connection IS the status (D11).
        val a = ConnectionConfig(name = "a", host = "a", enabled = true)
        val b = ConnectionConfig(name = "b", host = "b", enabled = false)
        assertEquals(listOf(b.id), ServerPolling.targets(listOf(a, b)).map { it.id })
    }

    @Test fun editingALiveServerDoesNotRebuildItsCoordinator() {
        fun s(st: ServerSectionStatus) =
            ServerSection(ConnectionConfig(name = "a", host = "a"), st, emptyList(), false, emptyList(), 0, false)
        assertFalse(ServerPolling.shouldRebuild(s(ServerSectionStatus.Live)), "a rebuild would detach its session")
        assertTrue(ServerPolling.shouldRebuild(s(ServerSectionStatus.AuthFailed("x"))), "a pasted token needs a fresh coordinator")
        assertTrue(ServerPolling.shouldRebuild(s(ServerSectionStatus.Offline)))
    }

    @Test fun editingPreservesEnabledInstanceAndDisplayName() {
        val existing = ConnectionConfig(
            name = "a", host = "a.local", enabled = false, instanceId = UUID.randomUUID(), displayName = "Studio",
        )
        val built = ServerFormLogic.buildConfig(existing.id, "renamed", "a.local", "9200", false, base = existing)!!
        assertEquals(existing.id, built.id)
        assertEquals("renamed", built.name)
        assertFalse(built.enabled, "renaming a disabled bookmark must not enable it")
        assertEquals(existing.instanceId, built.instanceId)
        assertEquals("Studio", built.displayName)
    }

    @Test fun statusLineUsesTheLiveSectionWhenEnabledAndTheProbeWhenDisabled() {
        fun s(enabled: Boolean, st: ServerSectionStatus) =
            ServerSection(ConnectionConfig(name = "a", host = "a", enabled = enabled), st, emptyList(), false, emptyList(), 0, false)
        assertEquals("Live", statusLine(s(true, ServerSectionStatus.Live), ServerStatus.OFFLINE).first, "the poller never overrides a live hub")
        assertEquals("No token stored for this server", statusLine(s(true, ServerSectionStatus.AuthFailed("No token stored for this server")), null).first)
        assertEquals("disabled · reachable", statusLine(s(false, ServerSectionStatus.Disabled), ServerStatus.LIVE).first)
        assertEquals("disabled · offline", statusLine(s(false, ServerSectionStatus.Disabled), ServerStatus.OFFLINE).first)
    }
}
