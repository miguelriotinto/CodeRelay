import SwiftUI

/// The "magic wand" prompt-optimizer button shared by the iOS and macOS apps
/// (spec §7.1 / §7.2). All state lives on `SharedSessionCoordinator`; this
/// view only renders it and forwards taps.
///
/// Layout, left to right: an optional toast chip (`optimizerNotice`), an
/// optional `Optimized · Undo` chip (`optimizerUndo`), then the wand itself.
/// Hosts drop it exactly where the mic button used to be.
public struct WandButton: View {
    @ObservedObject private var coordinator: SharedSessionCoordinator
    private let shareScreen: Bool
    private let size: CGFloat
    private let fill: Color
    private let onTap: (() -> Void)?

    /// - Parameters:
    ///   - shareScreen: the device's "Share terminal screen with the optimizer"
    ///     setting, forwarded as the RPC's `shareScreen`.
    ///   - size: diameter of the circular button (44 on iOS, 26 on macOS).
    ///   - fill: circle colour behind the glyph.
    ///   - onTap: platform hook run before the optimize starts (iOS haptics).
    public init(
        coordinator: SharedSessionCoordinator,
        shareScreen: Bool,
        size: CGFloat = 44,
        fill: Color = Color.gray.opacity(0.5),
        onTap: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.shareScreen = shareScreen
        self.size = size
        self.fill = fill
        self.onTap = onTap
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let notice = coordinator.optimizerNotice {
                chip {
                    Text(notice)
                        .lineLimit(2)
                        .onTapGesture { coordinator.dismissOptimizerNotice() }
                }
                .transition(.opacity)
            }
            if coordinator.optimizerUndo != nil {
                chip {
                    HStack(spacing: 4) {
                        Text(OptimizerStrings.optimized)
                        Text("·").foregroundStyle(.secondary)
                        Button(OptimizerStrings.undo) {
                            Task { await coordinator.undoOptimize() }
                        }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .disabled(!coordinator.isWandEnabled)
                    }
                }
                .transition(.opacity)
            }
            wand
        }
        .animation(.easeInOut(duration: 0.15), value: coordinator.optimizerNotice)
        .animation(.easeInOut(duration: 0.15), value: coordinator.optimizerUndo)
        .onReceive(NotificationCenter.default.publisher(for: .optimizePromptShortcut)) { _ in
            trigger()
        }
    }

    private var wand: some View {
        Button(action: trigger) {
            ZStack {
                Circle().fill(fill)
                if coordinator.optimizerState == .optimizing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: size * 0.38, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .opacity(coordinator.isOptimizerAvailable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!coordinator.isWandEnabled)
        .help(coordinator.wandHint ?? OptimizerStrings.wandLabel)
        .accessibilityLabel(OptimizerStrings.wandLabel)
        .accessibilityHint(coordinator.wandHint ?? "")
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: max(11, size * 0.28)))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }

    private func trigger() {
        guard coordinator.isWandEnabled else { return }
        onTap?()
        Task { await coordinator.optimizePrompt(shareScreen: shareScreen) }
    }
}
