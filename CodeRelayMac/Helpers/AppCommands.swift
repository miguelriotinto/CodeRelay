import SwiftUI

/// FocusedValue key so menu bar commands can access the active SessionCoordinator.
struct SessionCoordinatorKey: FocusedValueKey {
    typealias Value = SessionCoordinator
}

extension FocusedValues {
    var sessionCoordinator: SessionCoordinator? {
        get { self[SessionCoordinatorKey.self] }
        set { self[SessionCoordinatorKey.self] = newValue }
    }
}

struct ServerHubKey: FocusedValueKey {
    typealias Value = MacServerHub
}

extension FocusedValues {
    var serverHub: MacServerHub? {
        get { self[ServerHubKey.self] }
        set { self[ServerHubKey.self] = newValue }
    }
}

struct SidebarVisibilityKey: FocusedValueKey {
    typealias Value = Binding<NavigationSplitViewVisibility>
}

extension FocusedValues {
    var sidebarVisibility: Binding<NavigationSplitViewVisibility>? {
        get { self[SidebarVisibilityKey.self] }
        set { self[SidebarVisibilityKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.sessionCoordinator) var coordinator: SessionCoordinator?
    @FocusedValue(\.serverHub) var hub: MacServerHub?
    @FocusedValue(\.sidebarVisibility) var sidebarVisibility: Binding<NavigationSplitViewVisibility>?

    var body: some Commands {
        // Replace the default New item in the File menu.
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                // On the active server, else the first live one.
                guard let hub,
                      let serverId = hub.activeRef?.serverId ?? hub.sections.first(where: { $0.status.isLive })?.id
                else { return }
                Task { await hub.createSession(on: serverId) }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(hub?.sections.contains(where: { $0.status.isLive }) != true)
        }

        // Add a Session menu between View and Window.
        CommandMenu("Session") {
            Button("Detach Current") {
                guard let coordinator, let id = coordinator.activeSessionId else { return }
                Task { await coordinator.detachSession(id: id) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(coordinator?.activeSessionId == nil)

            Button("Terminate Current") {
                guard let coordinator, let id = coordinator.activeSessionId else { return }
                Task { await coordinator.terminateSession(id: id) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(coordinator?.activeSessionId == nil)

            Divider()

            Button("Next Session") {
                guard let hub else { return }
                Task { await hub.selectNext() }
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Session") {
                guard let hub else { return }
                Task { await hub.selectPrevious() }
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button("Session \(index)") {
                    guard let hub else { return }
                    let refs = hub.orderedRefs
                    guard index - 1 < refs.count else { return }
                    Task { await hub.select(refs[index - 1]) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }

            Divider()

            Button("Scan QR Code...") {
                coordinator?.showQRScanner = true
            }
            .keyboardShortcut("q", modifiers: [.command, .shift])
            .disabled(coordinator == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                guard let binding = sidebarVisibility else { return }
                switch binding.wrappedValue {
                case .all:
                    binding.wrappedValue = .detailOnly
                default:
                    binding.wrappedValue = .all
                }
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
