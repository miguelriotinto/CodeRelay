import Foundation

/// Aggregates every server's session-loss reports into one batch (spec §2).
///
/// - Dedupes by `(serverId, session.id)` within a batch, across both kinds
///   (the first report wins).
/// - Drops an item announced in the last `suppressionWindow` (120 s), so a late
///   queued `session_stolen` after a wake diff — or the reverse — stays silent.
/// - Outside a hold, flushes `debounce` (1 s) after the LAST report, so two
///   steals in quick succession produce one alert.
/// - `beginHold`/`endHold` nest; while any hold is open nothing flushes, and the
///   outermost `endHold` flushes whatever was collected.
@MainActor
public final class SessionLossCollector {
    public static let debounce: Duration = .seconds(1)
    public static let suppressionWindow: TimeInterval = 120

    private struct Key: Hashable {
        let serverId: UUID
        let sessionId: UUID
    }

    /// Delivered once per batch; at least one of the two arrays is non-empty.
    public var onFlush: ((_ taken: [SessionLossItem], _ ended: [SessionLossItem]) -> Void)?

    private let now: () -> Date
    private let sleep: (Duration) async -> Void
    private var taken: [SessionLossItem] = []
    private var ended: [SessionLossItem] = []
    private var pendingKeys: Set<Key> = []
    private var announced: [Key: Date] = [:]
    private var holdDepth = 0
    /// Bumped by every report and hold change; a debounce that wakes to a
    /// different value was superseded and does nothing. The injected `sleep`
    /// need not honour cancellation, so this — not `Task.cancel` — is the guard.
    private var debounceGeneration: UInt64 = 0

    public init(now: @escaping () -> Date, sleep: @escaping (Duration) async -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public var isHolding: Bool { holdDepth > 0 }

    public func report(_ items: [SessionLossItem], kind: SessionLossKind) {
        let at = now()
        pruneAnnounced(at: at)
        var added = false
        for item in items {
            let key = Key(serverId: item.serverId, sessionId: item.session.id)
            guard !pendingKeys.contains(key), announced[key] == nil else { continue }
            pendingKeys.insert(key)
            switch kind {
            case .taken: taken.append(item)
            case .ended: ended.append(item)
            }
            added = true
        }
        guard added, holdDepth == 0 else { return }
        scheduleDebouncedFlush()
    }

    public func beginHold() {
        holdDepth += 1
        debounceGeneration &+= 1
    }

    public func endHold() {
        guard holdDepth > 0 else { return }
        holdDepth -= 1
        if holdDepth == 0 { flush() }
    }

    private func scheduleDebouncedFlush() {
        debounceGeneration &+= 1
        let generation = debounceGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(Self.debounce)
            guard self.debounceGeneration == generation, self.holdDepth == 0 else { return }
            self.flush()
        }
    }

    private func flush() {
        guard !taken.isEmpty || !ended.isEmpty else { return }
        let at = now()
        for key in pendingKeys { announced[key] = at }
        let batch = (taken, ended)
        taken.removeAll(); ended.removeAll(); pendingKeys.removeAll()
        onFlush?(batch.0, batch.1)
    }

    private func pruneAnnounced(at date: Date) {
        announced = announced.filter { date.timeIntervalSince($0.value) < Self.suppressionWindow }
    }
}

/// The one aggregated "Session Moved" alert the workspace root presents.
public struct SessionLossAlert: Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let message: String

    public init(id: UUID = UUID(), title: String, message: String) {
        self.id = id
        self.title = title
        self.message = message
    }
}

/// Counts a fan-out's slots down to zero; `wait()` returns once every slot has
/// arrived (at once when there were none). The hub races it against the cap
/// through `BoundedWait`, so a slot that never arrives only leaves this waiter
/// parked — nobody is listening by then.
@MainActor
final class FanOutLatch {
    private var remaining: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { remaining = count }

    func arrive() {
        guard remaining > 0 else { return }
        remaining -= 1
        guard remaining == 0 else { return }
        let ready = waiters; waiters.removeAll()
        for w in ready { w.resume() }
    }

    func wait() async {
        guard remaining > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
