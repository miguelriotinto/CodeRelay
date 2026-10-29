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
            // Every row is laid out in every state, hidden when it has nothing
            // to say, so the sheet keeps ONE size from the first phase to Ready
            // (it used to grow and shrink by a row as states changed).
            Text(presentation.detail ?? "0 KB")
                .font(Self.bytesFont)
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: presentation.detail)
                .opacity(presentation.detail == nil ? 0 : 1)
                .accessibilityLabel("\(presentation.detail ?? "") loaded")
                .accessibilityHidden(presentation.detail == nil)
            Text(presentation.status)
                .font(Self.statusFont)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.25), value: presentation.status)
            Text(presentation.subtitle ?? " ")
                .font(.footnote).foregroundStyle(.tertiary).lineLimit(1)
                .accessibilityHidden(presentation.subtitle == nil)
            let showsCancel = presentation.allowsCancel && onCancel != nil
            Button("Cancel", role: .cancel) { onCancel?() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 4)
                .opacity(showsCancel ? 1 : 0)
                .disabled(!showsCancel)
                .accessibilityHidden(!showsCancel)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Shared geometry for the loading sheet.
public enum SessionLoadingSheetLayout {
    /// The sheet's width on macOS and on iPad-class (regular-width) displays.
    public static let fixedWidth: CGFloat = 340
    /// First guess for the iOS detent before the content has been measured.
    static let initialHeight: CGFloat = 300
}

public extension View {
    /// Hosts `SessionLoadingSheet` at one constant size. The height is the
    /// content's natural height — never a guessed constant, which clipped the
    /// spinner and the reconnect Cancel button (a third of the screen on iOS,
    /// 220 pt on macOS) — and it is the same in every state because the sheet
    /// reserves all of its rows. The width is `fixedWidth` on macOS and on
    /// form-sheet idioms (iPad, the open Duo), whose `.fitted` sizing reads the
    /// ideal width; a compact iPhone sheet spans the screen. On iOS the
    /// measured height becomes the sheet's only detent.
    func sessionLoadingSheetContainer() -> some View {
        modifier(SessionLoadingSheetContainer())
    }
}

struct SessionLoadingSheetContainer: ViewModifier {
    @State private var height: CGFloat = SessionLoadingSheetLayout.initialHeight

    func body(content: Content) -> some View {
        #if os(iOS)
        sized(content
            .frame(idealWidth: SessionLoadingSheetLayout.fixedWidth, maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                if measured > 0 { height = measured.rounded(.up) }
            }
            .presentationDetents([.height(height)]))
        #else
        content
            .frame(width: SessionLoadingSheetLayout.fixedWidth)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private func sized(_ view: some View) -> some View {
        if #available(iOS 18.0, *) {
            view.presentationSizing(.fitted)
        } else {
            view
        }
    }
    #endif
}
