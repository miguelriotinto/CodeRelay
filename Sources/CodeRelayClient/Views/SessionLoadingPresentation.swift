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

    public init(loadPhase: SessionLoadPhase?,
                isRecovering: Bool,
                recoveryPhase: SharedSessionCoordinator.RecoveryPhase,
                sessionName: String?,
                serverName: String?) {
        isActive = loadPhase != nil || isRecovering
        title = isRecovering ? "Reconnecting" : "Loading session"
        // The replay phase is the more specific status once it starts, even mid-recovery.
        status = loadPhase?.label ?? (isRecovering ? recoveryPhase.label : "")
        detail = isActive ? (loadPhase?.detail ?? SessionLoadPhase.formatBytes(0)) : nil
        let parts = [sessionName, serverName].compactMap { $0 }.filter { !$0.isEmpty }
        subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        allowsCancel = isRecovering
    }
}

/// Presents the sheet the instant something loads, holds it at least
/// `minimumVisible` so an instant switch still reads as a response rather
/// than a flicker, and dismisses it when nothing is loading any more. The
/// terminal blackout follows `isPresented` so sheet and black lift together.
@MainActor
public final class SessionLoadingSheetModel: ObservableObject {
    public static let minimumVisible: Duration = .milliseconds(600)

    @Published public private(set) var isPresented = false
    /// The last active presentation, kept while the sheet animates down.
    @Published public private(set) var shown: SessionLoadingPresentation?

    private var active = false
    private var holdElapsed = true
    private var holdTask: Task<Void, Never>?
    private let sleep: @MainActor (Duration) async -> Void

    public init(sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    public func update(_ presentation: SessionLoadingPresentation) {
        active = presentation.isActive
        if presentation.isActive { shown = presentation }
        if active, !isPresented {
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
        settle()
    }

    private func settle() {
        if isPresented, !active, holdElapsed { isPresented = false }
    }
}
