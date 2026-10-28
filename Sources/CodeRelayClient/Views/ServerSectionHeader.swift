import SwiftUI
import CodeRelayKit

/// Pure presentation of a server section's header line (spec §8.1), shared by
/// the macOS sidebar now and the iOS one in Plan 2.
public struct ServerSectionHeaderModel: Equatable {
    public let title: String
    public let subtitle: String?
    public let dotColor: Color
    public let badge: Int
    public let offersRetry: Bool
    public let isDuplicate: Bool

    public init(section: ServerSection) {
        title = section.title
        switch section.status {
        case .live:
            subtitle = nil; dotColor = .green; offersRetry = false
        case .connecting:
            subtitle = "connecting…"; dotColor = .orange; offersRetry = false
        case .reconnecting:
            subtitle = "reconnecting…"; dotColor = .orange; offersRetry = false
        case .offline:
            subtitle = "offline"; dotColor = .red; offersRetry = true
        case .authFailed(let message):
            subtitle = message; dotColor = .orange; offersRetry = true
        case .disabled:
            subtitle = "disabled"; dotColor = .gray; offersRetry = false
        }
        badge = section.status.isLive ? section.awaitingInput : 0
        isDuplicate = section.isDuplicateInstance
    }
}

/// The section header row: name, status dot, subtitle, attention badge,
/// Retry (offline / token rejected), New, collapse chevron.
public struct ServerSectionHeader: View {
    private let model: ServerSectionHeaderModel
    private let isCollapsed: Bool
    private let onToggle: () -> Void
    private let onRetry: () -> Void
    private let onNew: (() -> Void)?

    public init(model: ServerSectionHeaderModel, isCollapsed: Bool,
                onToggle: @escaping () -> Void, onRetry: @escaping () -> Void, onNew: (() -> Void)?) {
        self.model = model
        self.isCollapsed = isCollapsed
        self.onToggle = onToggle
        self.onRetry = onRetry
        self.onNew = onNew
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Circle().fill(model.dotColor).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.title)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .lineLimit(1)
                        if let subtitle = model.subtitle {
                            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if model.isDuplicate {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Another bookmark points at this same relay")
                    }
                    Spacer(minLength: 4)
                    if model.badge > 0 {
                        Text("\(model.badge)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                            .foregroundStyle(.white)
                    }
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.offersRetry {
                Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help("Reconnect")
            } else if let onNew {
                Button(action: onNew) { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("New session on \(model.title)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.title)\(model.subtitle.map { ", \($0)" } ?? "")")
    }
}
