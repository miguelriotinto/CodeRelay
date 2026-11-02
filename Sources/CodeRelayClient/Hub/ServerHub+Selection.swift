import Foundation
import CodeRelayKit

// Selection (spec §7.5) lives in its own file: it is the hub's largest concern
// and the one the D9 invariant (one attachment across all servers) rests on.
extension ServerHub {
    // MARK: - Selection (spec §7.5)

    /// Every row the sidebar shows, in sidebar order (live and cached sections),
    /// for keyboard next/previous across section boundaries.
    public var orderedRefs: [SessionRef] {
        sections.filter(\.config.enabled).flatMap { section in
            section.sessions.map { SessionRef(serverId: section.id, sessionId: $0.id) }
        }
    }

    /// Makes `ref` the one attached session. Same server → the coordinator's own
    /// `switchToSession` (which detaches the previous session itself). Different
    /// server → `detachActive()` on the previous coordinator, bounded, THEN the
    /// attach. Offline or still-building server → remember the choice and (if it
    /// has a coordinator) trigger its recovery. A row whose server has no
    /// coordinator and is not getting one is refused before any state moves.
    public func select(_ ref: SessionRef) async {
        guard let section = sections.first(where: { $0.id == ref.serverId }) else { return }
        let slot = slots[ref.serverId]
        let building = slot == nil && section.config.enabled && !missingToken.contains(ref.serverId) && started
        if slot == nil, !building {
            notice = section.config.enabled
                ? "\(section.title) has no token. Re-pair it in Servers."
                : "Enable \(section.title) in Servers to open its sessions."
            return
        }
        if activeRef == ref, pendingRef == ref { return }
        if activeRef == ref, pendingRef == nil, slot?.activeSessionId == ref.sessionId { return }

        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectionsInFlight += 1
        defer { selectionsInFlight -= 1 }
        let previous = activeRef
        activeRef = ref
        pendingRef = nil
        stateStore.saveActiveRef(ref)
        onTestEvent?("select:\(ref.serverId.uuidString.prefix(4))")

        if let previous, previous.serverId != ref.serverId, let from = slots[previous.serverId] {
            await detachBounded(from)
            guard generation == selectionGeneration else { return }
        }
        guard let to = slots[ref.serverId],
              sections.first(where: { $0.id == ref.serverId })?.status.isLive == true else {
            pendingRef = ref
            slot?.triggerUserRecovery()
            publish()
            return
        }
        await to.switchToSession(id: ref.sessionId)
        guard generation == selectionGeneration else { return }
        mirror(to, serverId: ref.serverId)
        publish()
    }

    /// Every live server's attachable sessions, in sidebar order, fetched
    /// concurrently so a slow relay delays the sheet by its own latency only.
    /// The Attach sheet used to ask the focus server alone, so a second server's
    /// sessions could never be offered. Offline and unbuilt servers are skipped.
    public func attachableSessions() async -> [AttachableGroup] {
        let live = sections.compactMap { section -> (ServerSection, Slot)? in
            guard section.status.isLive, let slot = slots[section.id] else { return nil }
            return (section, slot)
        }
        return await withTaskGroup(of: (Int, AttachableGroup).self) { group in
            for (index, (section, slot)) in live.enumerated() {
                group.addTask { @MainActor in
                    (index, AttachableGroup(serverId: section.id, title: section.title,
                                            sessions: await slot.fetchAttachableSessions()))
                }
            }
            var found: [(Int, AttachableGroup)] = []
            for await entry in group { found.append(entry) }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Attaches `sessionId` — a session another device owns — on `serverId`:
    /// the Attach sheet, the QR scanner and the one-server deep-link fallback.
    /// Detaches any other server first, like every selection path (D9).
    public func attachRemote(on serverId: UUID, sessionId: UUID, serverName: String?) async {
        guard let slot = slots[serverId] else {
            notice = "That server is not connected."
            return
        }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectionsInFlight += 1
        defer { selectionsInFlight -= 1 }
        pendingRef = nil
        if let previous = activeRef, previous.serverId != serverId, let from = slots[previous.serverId] {
            await detachBounded(from)
            guard generation == selectionGeneration else { return }
        }
        await slot.attachRemoteSession(id: sessionId, serverName: serverName)
        guard generation == selectionGeneration else { return }
        mirror(slot, serverId: serverId)
        publish()
    }

    /// New session on `serverId`; detaches on any other server first (§7.5).
    public func createSession(on serverId: UUID) async {
        guard let to = slots[serverId], sections.first(where: { $0.id == serverId })?.status.isLive == true else {
            notice = "That server is not connected."
            return
        }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectionsInFlight += 1
        defer { selectionsInFlight -= 1 }
        pendingRef = nil
        if let previous = activeRef, previous.serverId != serverId, let from = slots[previous.serverId] {
            await detachBounded(from)
            guard generation == selectionGeneration else { return }
        }
        await to.createNewSession()
        guard generation == selectionGeneration else { return }
        mirror(to, serverId: serverId)
        publish()
    }

    /// After an attach the coordinator's `activeSessionId` is the truth (it rolls
    /// back on a failed resume); the hub's ref follows it.
    func mirror(_ slot: Slot, serverId: UUID) {
        let now = slot.activeSessionId.map { SessionRef(serverId: serverId, sessionId: $0) }
        if activeRef != now {
            activeRef = now
            stateStore.saveActiveRef(now)
        }
    }

    public func selectNext() async { await step(by: 1) }
    public func selectPrevious() async { await step(by: -1) }

    func step(by delta: Int) async {
        let refs = orderedRefs
        guard refs.count > 1, let current = activeRef, let index = refs.firstIndex(of: current) else { return }
        let next = (index + delta + refs.count) % refs.count
        await select(refs[next])
    }

    /// Deletes a bookmark: detach if it is active, tear down, forget its token
    /// and its ownership namespace (§7.3, §11).
    public func removeServer(_ serverId: UUID) async {
        if let slot = detachFromHub(serverId) {
            await retire(slot, wasActive: slot.activeSessionId != nil, unregisterPush: true)
        }
        bookmarkStore.delete(id: serverId)
        (tokens as? TokenDeleting)?.deleteTokenIgnoringErrors(for: serverId)
        bookmarks = bookmarkStore.loadAll()
        cachedSessions[serverId] = nil
        missingToken.remove(serverId)
        publish()
    }

    /// Awaits `slot.detachActive()` for at most `detachBudget`. A task group
    /// cannot express this: it waits for every child at scope exit, so a stuck
    /// detach would hold the switch hostage. The straggler is left to finish
    /// on its own; the coordinator's own budget bounds it.
    func detachBounded(_ slot: Slot) async {
        await BoundedWait.run(budget: detachBudget) { await slot.detachActive() }
    }

    /// Called from `slotDidChange` after `publish()`: apply or drop the pending
    /// selection once its server is live. Only ever the CURRENT selection — an
    /// abandoned choice was replaced by the next `select`.
    func applyPendingSelection(for serverId: UUID) {
        guard let wanted = pendingRef, wanted.serverId == serverId, activeRef == wanted,
              let slot = slots[serverId],
              sections.first(where: { $0.id == serverId })?.status.isLive == true else { return }
        pendingRef = nil
        guard slot.activeSessions.contains(where: { $0.id == wanted.sessionId }) else {
            activeRef = nil
            stateStore.saveActiveRef(nil)
            notice = "That session has ended"
            publish()
            return
        }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectionsInFlight += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.selectionsInFlight -= 1 }
            await slot.switchToSession(id: wanted.sessionId)
            guard generation == self.selectionGeneration else { return }
            self.mirror(slot, serverId: serverId)
            self.publish()
        }
    }
}
