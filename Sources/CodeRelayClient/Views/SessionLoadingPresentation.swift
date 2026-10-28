import Foundation

/// What the loading sheet says, derived from the coordinator's two published
/// signals. One rule for the three ways a session reaches the screen — a
/// switch, the session-name refresh, a reconnect — so they look identical.
public struct SessionLoadingPresentation: Equatable {
    public let isActive: Bool
    public let title: String
    public let status: String
    /// Bytes loaded so far, formatted — nil only while nothing is loading.
    /// Reserved from the first phase ("0 KB") so the sheet's layout is stable and
    /// the user sees the counter start moving the moment history streams.
    public let detail: String?
    public let subtitle: String?
    public let allowsCancel: Bool

    /// - Parameter expectsSession: a session is attached or about to be restored.
    ///   The launch/wake handshake publishes connecting / authenticating /
    ///   loadingSessions while NO session is attached; with nothing to restore
    ///   those narrate a server, not a session, and must not raise a modal — the
    ///   old inline overlay never showed them, and a sheet there sat for ~54 s
    ///   against an unreachable host with no Cancel. A switch (`attaching`,
    ///   `loadingHistory`) and recovery (which has Cancel) always show.
    public init(loadPhase: SessionLoadPhase?,
                isRecovering: Bool,
                recoveryPhase: SharedSessionCoordinator.RecoveryPhase,
                expectsSession: Bool = true,
                sessionName: String?,
                serverName: String?) {
        let sessionBound: Bool
        switch loadPhase {
        case .attaching?, .loadingHistory?: sessionBound = true
        case .connecting?, .authenticating?, .loadingSessions?: sessionBound = expectsSession
        case nil: sessionBound = false
        }
        isActive = sessionBound || isRecovering
        title = isRecovering ? "Reconnecting" : "Loading session"
        // The replay phase is the more specific status once it starts, even mid-recovery.
        status = loadPhase?.label ?? (isRecovering ? recoveryPhase.label : "")
        // "0 KB" (not formatBytes(0)'s "<1 KB", which suggests data arrived) until
        // history streams; then the real count.
        let bytes: String? = {
            if case .loadingHistory(let count)? = loadPhase { return SessionLoadPhase.formatBytes(count) }
            return "0 KB"
        }()
        detail = isActive ? bytes : nil
        let parts = [sessionName, serverName].compactMap { $0 }.filter { !$0.isEmpty }
        subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        allowsCancel = isRecovering
    }
}

/// Presents the sheet the instant something loads, holds it at least
/// `minimumVisible` so an instant switch still reads as a response rather
/// than a flicker, and dismisses it when nothing is loading any more. The
/// terminal blackout follows `isPresented` so sheet and black lift together.
///
/// It is also the one enforcer of "the sheet never stays up": when the
/// presentation has not changed for `stallTimeout` (no new phase, no new
/// bytes) the sheet lowers so the pane is usable again, and comes back the
/// moment progress resumes. A replay that never delivers, or an RPC chain
/// parked behind a 20 s optimize, is otherwise indistinguishable from a hang.
@MainActor
public final class SessionLoadingSheetModel: ObservableObject {
    public static let minimumVisible: Duration = .milliseconds(600)
    public static let stallTimeout: Duration = .seconds(15)

    @Published public private(set) var isPresented = false
    /// The last active presentation, kept while the sheet animates down.
    @Published public private(set) var shown: SessionLoadingPresentation?

    private var active = false
    private var holdElapsed = true
    private var holdTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    /// Lowered by the stall timer; the next change re-presents.
    private var stalled = false
    private let sleep: @MainActor (Duration) async -> Void

    public init(sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    public func update(_ presentation: SessionLoadingPresentation) {
        let changed = presentation != shown
        active = presentation.isActive
        if presentation.isActive { shown = presentation }
        if active, changed { stalled = false; armStall() }
        if active, !isPresented, !stalled {
            isPresented = true
            holdElapsed = false
            holdTask?.cancel()
            holdTask = Task { [weak self] in
                guard let self else { return }
                await self.sleep(Self.minimumVisible)
                guard !Task.isCancelled else { return }
                self.holdElapsed = true
                self.settle()
            }
        }
        if !active { stallTask?.cancel(); stallTask = nil; stalled = false }
        settle()
    }

    /// (Re)starts the stall timer: a presentation that stops changing for
    /// `stallTimeout` lowers the sheet until it changes again.
    private func armStall() {
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(Self.stallTimeout)
            guard !Task.isCancelled, self.active else { return }
            self.stalled = true
            self.isPresented = false
        }
    }

    private func settle() {
        if isPresented, !active, holdElapsed { isPresented = false }
    }
}
