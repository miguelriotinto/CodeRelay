import Foundation
import CodeRelayKit

// Deep-link routing lives in its own file so the hub's class body stays within
// the lint budget; it is the one piece of the hub that reads several concerns
// at once (bookmarks, slots, sections, pending selection).
extension ServerHub {
    // MARK: - Deep links (spec §10)

    public enum DeepLinkOutcome: Equatable {
        case selected(SessionRef)
        case enabledAndSelected(SessionRef)
        case attachingRemote(serverId: UUID)
        case notFound(serverName: String?)
    }

    /// Routing precedence: instance id → unique session across live sections →
    /// single enabled server's cross-device attach → not found. A link that
    /// arrives before `start()` finished waits for it.
    public func handleDeepLink(_ link: SessionDeepLink) async -> DeepLinkOutcome {
        // A link that arrives before the first `start()` has finished — cold
        // launch included — waits for it; afterwards (even with no slot built,
        // e.g. every bookmark token-less) it routes immediately.
        if !startCompleted {
            await withCheckedContinuation { startGate.append($0) }
        }
        // 1. The relay named itself. An enabled bookmark wins over a disabled
        //    twin of the same relay (§12) — never a second socket to one relay.
        if let instanceId = link.serverInstanceId,
           let config = bookmarks.first(where: { $0.instanceId == instanceId && $0.enabled })
                     ?? bookmarks.first(where: { $0.instanceId == instanceId }) {
            let ref = SessionRef(serverId: config.id, sessionId: link.sessionId)
            if !config.enabled {
                guard setEnabled(config.id, true) else {
                    return .notFound(serverName: config.displayName ?? config.name)
                }
                notice = "Enabled \(config.displayName ?? config.name) to open this session"
                selectionGeneration &+= 1
                selectionsInFlight += 1
                defer { selectionsInFlight -= 1 }
                // D9 even here: the current server is detached before the new
                // one's pending selection can attach.
                if let previous = activeRef, previous.serverId != config.id, let from = slots[previous.serverId] {
                    await detachBounded(from)
                }
                activeRef = ref
                pendingRef = ref
                stateStore.saveActiveRef(ref)
                publish()
                return .enabledAndSelected(ref)
            }
            await select(ref)
            return .selected(ref)
        }
        // 2. Exactly one live section lists the session.
        let hits = sections.filter { $0.status.isLive && $0.sessions.contains(where: { $0.id == link.sessionId }) }
        if hits.count == 1 {
            let ref = SessionRef(serverId: hits[0].id, sessionId: link.sessionId)
            await select(ref)
            return .selected(ref)
        }
        // 3. One enabled server: the pre-hub cross-device attach.
        let enabled = bookmarks.filter(\.enabled)
        if enabled.count == 1, let slot = slots[enabled[0].id] {
            selectionGeneration &+= 1
            let generation = selectionGeneration
            selectionsInFlight += 1
            defer { selectionsInFlight -= 1 }
            pendingRef = nil
            if let previous = activeRef, previous.serverId != enabled[0].id, let from = slots[previous.serverId] {
                await detachBounded(from)
                guard generation == selectionGeneration else { return .attachingRemote(serverId: enabled[0].id) }
            }
            await slot.attachRemoteSession(id: link.sessionId, serverName: nil)
            guard generation == selectionGeneration else { return .attachingRemote(serverId: enabled[0].id) }
            mirror(slot, serverId: enabled[0].id)
            publish()
            return .attachingRemote(serverId: enabled[0].id)
        }
        // 4. Nothing to route to.
        notice = "Session not found on any enabled server"
        return .notFound(serverName: nil)
    }
}
