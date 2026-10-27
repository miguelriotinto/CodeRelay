import SwiftUI

/// The veil over the terminal pane while a session is on its way to the
/// screen: spinner, phase, byte counter, session name. Shared by the iOS and
/// macOS apps; the Kotlin clients have `SessionLoadingOverlay` in
/// `feature-workspace` with the same shape.
///
/// It appears only once the wait has lasted `showDelay`, so a LAN connection
/// that paints in 100 ms never flashes it, and it fades out when the phase
/// returns to `nil` — which the coordinator does on the first visible frame.
/// It never intercepts touches: the pane underneath is black and inert while
/// loading, and the sidebar and tabs around it must keep working.
public struct SessionLoadingOverlay: View {
    public let phase: SessionLoadPhase?
    public let sessionName: String?

    /// Waits this long before showing anything. Below it the user would read a
    /// flash, not feedback.
    public static let showDelay: Duration = .milliseconds(300)
    static let fadeIn: Double = 0.15
    static let fadeOut: Double = 0.2

    @State private var visible = false
    /// The last non-nil phase, kept so the text doesn't blank mid-fade-out.
    @State private var shown: SessionLoadPhase?

    public init(phase: SessionLoadPhase?, sessionName: String?) {
        self.phase = phase
        self.sessionName = sessionName
    }

    public var body: some View {
        ZStack {
            if visible, let shown = shown ?? phase {
                content(for: shown)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: visible ? Self.fadeIn : Self.fadeOut), value: visible)
        .allowsHitTesting(false)
        .task(id: phase != nil) {
            guard phase != nil else {
                visible = false
                return
            }
            try? await Task.sleep(for: Self.showDelay)
            if !Task.isCancelled, phase != nil { visible = true }
        }
        .onChange(of: phase) { _, newValue in
            if let newValue { shown = newValue }
        }
        .onAppear { if let phase { shown = phase } }
    }

    private func content(for phase: SessionLoadPhase) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(phase.label)
                    .font(.headline)
                    .foregroundStyle(.white)
                if let detail = phase.detail {
                    Text(detail)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .contentTransition(.numericText())
                }
                if let sessionName, !sessionName.isEmpty {
                    Text(sessionName)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(24)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
