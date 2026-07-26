import SwiftUI
import ClaudeRelayKit

/// Small colored dot visualizing the current `ConnectionQuality`. Used in
/// the status bar on both iOS and macOS.
///
/// Conforms to `Equatable` so SwiftUI can short-circuit redraws inside
/// loops such as `ForEach` and `TimelineView`.
public struct ConnectionQualityDot: View, Equatable {
    public let quality: ConnectionQuality
    public var size: CGFloat

    public init(quality: ConnectionQuality, size: CGFloat = 8) {
        self.quality = quality
        self.size = size
    }

    @State private var blinkOpacity: Double = 1.0

    private var color: Color {
        switch quality {
        case .excellent, .good: return .green
        case .poor, .veryPoor: return .yellow
        case .disconnected: return .red
        }
    }

    // Blink is an attention signal, not a health signal: only a genuinely bad
    // connection pulses. `.good` is the common steady state — blinking it drove
    // a perpetual `repeatForever` animation that pinned Core Animation at 60fps
    // for the whole window lifetime (the status bar is always mounted).
    private static func blinks(_ quality: ConnectionQuality) -> Bool {
        quality == .veryPoor
    }

    private var shouldBlink: Bool {
        Self.blinks(quality)
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .fixedSize()
            .opacity(shouldBlink ? blinkOpacity : 1.0)
            // onAppear for initial state; onChange for transitions during view lifetime
            .onChange(of: quality) { _, newValue in
                let blink = Self.blinks(newValue)
                if blink {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                } else {
                    withAnimation(.default) {
                        blinkOpacity = 1.0
                    }
                }
            }
            .onAppear {
                if shouldBlink {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        blinkOpacity = 0.3
                    }
                }
            }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.quality == rhs.quality && lhs.size == rhs.size
    }
}
