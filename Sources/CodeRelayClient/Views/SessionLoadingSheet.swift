import SwiftUI

/// The bottom sheet shown while a session is on its way to the screen. Hosted
/// by both apps (iOS as a detented sheet, macOS as a window sheet).
public struct SessionLoadingSheet: View {
    public let presentation: SessionLoadingPresentation
    public let onCancel: (() -> Void)?

    /// The byte counter is deliberately the largest text on the sheet: it is
    /// the one line that proves the load is progressing.
    public static let bytesFont: Font = .title2.monospacedDigit().weight(.semibold)
    public static let statusFont: Font = .subheadline

    public init(presentation: SessionLoadingPresentation, onCancel: (() -> Void)? = nil) {
        self.presentation = presentation
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 12) {
            Group {
                if presentation.isReady {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(height: 34)
            .animation(.spring(duration: 0.3), value: presentation.isReady)
            Text(presentation.title).font(.headline)
            if let detail = presentation.detail {
                Text(detail)
                    .font(Self.bytesFont)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.2), value: detail)
                    .accessibilityLabel("\(detail) loaded")
            }
            Text(presentation.status)
                .font(Self.statusFont)
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: presentation.status)
            if let subtitle = presentation.subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.tertiary).lineLimit(1)
            }
            if presentation.allowsCancel, let onCancel {
                Button("Cancel", role: .cancel) { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
