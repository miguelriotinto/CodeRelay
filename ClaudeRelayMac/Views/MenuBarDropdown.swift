import SwiftUI
import AppKit
import ClaudeRelayClient
import ClaudeRelayKit

struct MenuBarDropdown: View {
    @StateObject private var viewModel = MenuBarViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: connection
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.connectionColor)
                    .frame(width: 8, height: 8)
                Text(viewModel.connectionLabel)
                    .font(.headline)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            menuSeparator

            // Session list
            if viewModel.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.sessions, id: \.id) { session in
                        SessionMenuRow(
                            session: session,
                            activity: viewModel.activityStates[session.id] ?? .active,
                            agentId: viewModel.agentIds[session.id],
                            isActive: session.id == viewModel.activeSessionId,
                            onSelect: { activate(sessionId: session.id) }
                        )
                    }
                }
            }

            menuSeparator

            // Actions
            VStack(alignment: .leading, spacing: 0) {
                MenuButton(label: "Open Window") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                        return
                    }
                }
                MenuButton(label: "New Session") {
                    if let coordinator = ActiveCoordinatorRegistry.shared.coordinator {
                        Task { await coordinator.createNewSession() }
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                        return
                    }
                }
                .disabled(ActiveCoordinatorRegistry.shared.coordinator == nil)
                MenuButton(label: "Attach Session...") {
                    if let coordinator = ActiveCoordinatorRegistry.shared.coordinator {
                        coordinator.showQRScanner = true
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                        return
                    }
                }
                .disabled(ActiveCoordinatorRegistry.shared.coordinator == nil)
                MenuButton(label: "Servers...") {
                    NotificationCenter.default.post(name: .showServerList, object: nil)
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                        return
                    }
                }
                MenuButton(label: "Settings...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }

                menuSeparator

                MenuButton(label: "Quit Code[Relay]") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 280)
    }

    /// Separator inset from both edges so it doesn't touch the popover window border.
    private var menuSeparator: some View {
        Divider()
            .padding(.horizontal, 10)
    }

    private func activate(sessionId: UUID) {
        if let coordinator = ActiveCoordinatorRegistry.shared.coordinator {
            Task { await coordinator.switchToSession(id: sessionId) }
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}

private struct SessionMenuRow: View {
    let session: SessionInfo
    let activity: ActivityState
    let agentId: String?
    let isActive: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 10))
                Text(session.name ?? String(session.id.uuidString.prefix(8)))
                    .foregroundStyle(.primary)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.accentColor.opacity(0.25) : Color.clear)
                    .padding(.horizontal, 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var icon: String {
        switch activity {
        case .agentActive: return "circle.fill"
        case .agentIdle:   return "circle.lefthalf.filled"
        case .idle, .active: return "circle"
        }
    }
    private var iconColor: Color {
        switch activity {
        case .agentActive, .agentIdle:
            return AgentColorPalette.color(for: agentId)
        case .idle, .active: return .secondary
        }
    }
}

private struct MenuButton: View {
    let label: String
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(label)
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovering && isEnabled ? Color.accentColor.opacity(0.25) : Color.clear)
                        .padding(.horizontal, 6)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
