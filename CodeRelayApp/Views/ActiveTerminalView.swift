import SwiftUI
import CodeRelayClient
import CodeRelayKit
import GameController

/// The session tab strip's rows, pure for tests (spec §8.2: tabs span servers).
enum SessionTabStripModel {
    struct Tab: Equatable {
        let ref: SessionRef
        let number: Int
        let isSelected: Bool
        /// Server name for the spoken label; nil when only one server is enabled (G8).
        let serverTitle: String?
    }

    static func tabs(sections: [ServerSection], activeRef: SessionRef?) -> [Tab] {
        let enabled = sections.filter(\.config.enabled)
        let titled = enabled.count > 1
        var number = 0
        return enabled.flatMap { section in
            section.sessions.map { session in
                number += 1
                let ref = SessionRef(serverId: section.id, sessionId: session.id)
                return Tab(ref: ref, number: number, isSelected: ref == activeRef, serverTitle: titled ? section.title : nil)
            }
        }
    }
}

/// Detail pane: thin toolbar + terminal + optional key bar, hosting the hub's
/// ACTIVE coordinator (multi-server spec §8.2).
struct ActiveTerminalView: View {
    @ObservedObject var hub: IOSServerHub
    @Binding var columnVisibility: NavigationSplitViewVisibility
    /// Drives the blackout under the loading sheet (see `FocusCoordinatorModifiers`).
    @ObservedObject var loading: SessionLoadingSheetModel
    @State private var showKeyBar = true
    @State private var isKeyboardVisible = false
    @State private var hasHardwareKeyboard = GCKeyboard.coalesced != nil
    @State private var showQROverlay = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @ObservedObject private var settings = AppSettings.shared

    private var coordinator: SessionCoordinator? { hub.activeCoordinator }

    /// Keyed host: a cross-server switch swaps the whole SwiftTerm host; within
    /// one server the host is reused so each terminal's scrollback survives.
    static func hostKey(for coordinator: SessionCoordinator?) -> ObjectIdentifier? {
        coordinator.map(ObjectIdentifier.init)
    }

    private var tabs: [SessionTabStripModel.Tab] {
        SessionTabStripModel.tabs(sections: hub.sections, activeRef: hub.activeRef)
    }

    /// Wand + keyboard toggle, floated over the terminal's bottom-trailing corner.
    private func floatingButtons(_ coordinator: SessionCoordinator) -> some View {
        HStack(spacing: 10) {
            WandButton(
                coordinator: coordinator,
                shareScreen: settings.shareScreenWithOptimizer,
                size: 44,
                fill: Color.gray.opacity(0.5),
                onTap: {
                    if settings.hapticFeedbackEnabled {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            )

            Button {
                if settings.hapticFeedbackEnabled {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                if isKeyboardVisible {
                    NotificationCenter.default.post(
                        name: .terminalResignFocus, object: nil
                    )
                } else {
                    NotificationCenter.default.post(
                        name: .terminalRequestFocus, object: nil
                    )
                }
            } label: {
                Image(systemName: isKeyboardVisible
                      ? "keyboard.chevron.compact.down"
                      : "keyboard")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.gray.opacity(0.5))
                    .clipShape(Circle())
            }
            .disabled(hasHardwareKeyboard)
            .opacity(hasHardwareKeyboard ? 0.35 : 1.0)
        }
    }

    /// The top-left button's action; the left-edge swipe calls it too.
    private func toggleSidebar() {
        withAnimation {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    /// A 20 pt strip on the left edge of the empty pane. Over a terminal the
    /// swipe is recognised by `RelayTerminalView` instead: a SwiftUI drag there
    /// loses to the terminal's own UIKit pans and never ends.
    private var edgeSwipeStrip: some View {
        Color.clear
            .frame(width: EdgeSwipeRule.stripWidth)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        if EdgeSwipeRule.shouldOpen(
                            startX: value.startLocation.x,
                            dx: value.translation.width,
                            dy: value.translation.height,
                            listOpen: columnVisibility != .detailOnly
                        ) { toggleSidebar() }
                    }
            )
            .ignoresSafeArea(.container, edges: .horizontal)
            .accessibilityHidden(true)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let coordinator, let id = coordinator.activeSessionId,
               let vm = coordinator.viewModel(for: id) {
                // The floating buttons overlay the TERMINAL only. Overlaying the
                // whole column put them on top of the key bar's trailing keys
                // whenever the bar fit on one line — every wide layout, and the
                // iPhone Duo in either posture.
                ZStack(alignment: .bottomTrailing) {
                    // Single host reused across session switches so each
                    // terminal's SwiftTerm scrollback survives the swap.
                    TerminalHostView(
                        coordinator: coordinator,
                        fontSize: CGFloat(settings.terminalFontSize),
                        isKeyboardVisible: $isKeyboardVisible,
                        onLeftEdgeSwipe: { if columnVisibility == .detailOnly { toggleSidebar() } }
                    )
                    // Black while the loading sheet is up (switch, name-label
                    // refresh, reconnect); covers only the terminal, not the
                    // toolbar or the key bar, so the session name stays visible.
                    .terminalLoadingCover(loading.isPresented)

                    floatingButtons(coordinator)
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                }
                // The container is keyed by the coordinator so a cross-server
                // switch swaps the whole host; within one server it is reused.
                .id(Self.hostKey(for: coordinator))
                // The terminal bleeds under the horizontal safe-area insets —
                // the notch in iPhone landscape, and on iPhone Duo the column
                // along one edge where the system draws the status bar as a
                // frosted pill (and, on the closed display, where the camera
                // sits). Netflix does the same with its artwork. For a terminal
                // the price is explicit and accepted: the few cells under the
                // pill and the camera are unreadable, in exchange for ~8 more
                // columns over the whole height. The top bar does NOT bleed
                // (see below), so no control can land under the camera.
                .ignoresSafeArea(.container, edges: .horizontal)

                if showKeyBar {
                    KeyboardAccessory { data in
                        vm.sendInput(data)
                    }
                    .ignoresSafeArea(.container, edges: .horizontal)
                }
            } else {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "terminal")
                } description: {
                    Text("Swipe from the left edge or create a new session.")
                } actions: {
                    if hub.aggregate.enabledServers == 0 {
                        Button("Servers") { hub.isShowingServerList = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) { edgeSwipeStrip }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 6) {
                ToolbarIconButton(icon: "sidebar.left") { toggleSidebar() }
                .accessibilityLabel("Toggle Sidebar")
                ToolbarIconButton(icon: "server.rack") { hub.isShowingServerList = true }
                    .accessibilityLabel("Servers")
                ToolbarIconButton(icon: "fn", isActive: showKeyBar) { showKeyBar.toggle() }
                    .accessibilityLabel(showKeyBar ? "Hide Key Bar" : "Show Key Bar")

                if let coordinator {
                    ConnectionQualityDot(quality: coordinator.connection.connectionQuality, size: 8)
                }

                if let coordinator, let id = coordinator.activeSessionId,
                   let createdAt = coordinator.createdAt(for: id) {
                    SessionUptimeView(since: createdAt)
                }

                if anyTabNeedsFlash {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let flashOn = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                        sessionTabBar(flashOn: flashOn)
                    }
                } else {
                    sessionTabBar(flashOn: false)
                }

                if coordinator?.activeSessionId != nil {
                    ToolbarIconButton(icon: "qrcode") {
                        showQROverlay = true
                    }
                    .accessibilityLabel("Share Session")
                }

                if let coordinator, let id = coordinator.activeSessionId {
                    Text(coordinator.name(for: id))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: 100)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .layoutPriority(1)
                        // Tap → discard the locally cached terminal text and render
                        // the server's scrollback instead, behind a fade through
                        // black. We deliberately do NOT also post
                        // `.terminalForceRedraw`: a local repaint paints the current
                        // (stale) buffer at once, then the server's copy lands a
                        // round-trip later — two slightly-different paints that read
                        // as a flicker. The server's copy is authoritative alone.
                        // Long-press → rename. The tap gesture is declared first so
                        // it doesn't swallow the long-press.
                        .onTapGesture {
                            if settings.hapticFeedbackEnabled {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            Task { await TerminalReloadFade.reload(coordinator: coordinator, id: id) }
                        }
                        .onLongPressGesture {
                            renameText = coordinator.name(for: id)
                            showRenameAlert = true
                        }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.black)
        }
        .background(.black)
        // Deliberately NO horizontal `ignoresSafeArea` at this level: it would
        // also widen the `safeAreaInset` top bar above, putting the session
        // name and QR button under the Duo's status pill — or under the outer
        // camera when closed. The terminal and key bar opt in individually.
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: hub.activeRef) { _, _ in
            showQROverlay = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            hasHardwareKeyboard = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            hasHardwareKeyboard = GCKeyboard.coalesced != nil
        }
        .alert("Rename Session", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, let coordinator, let id = coordinator.activeSessionId {
                    coordinator.setName(trimmed, for: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .selectAllOnBeginEditing(while: showRenameAlert)
        .overlay {
            if showQROverlay, let coordinator, let id = coordinator.activeSessionId {
                QRCodeOverlay(
                    sessionId: id,
                    sessionName: coordinator.name(for: id),
                    serverInstanceId: hub.sections.first { $0.id == hub.activeRef?.serverId }?.config.instanceId,
                    onDismiss: { showQROverlay = false }
                )
            }
        }
    }

    private var emptyTitle: String {
        if hub.aggregate.enabledServers == 0 { return "No Servers Enabled" }
        if hub.aggregate.liveServers == 0, SessionSidebarView.isConnecting(hub.sections) { return "Connecting…" }
        return "No Active Session"
    }

    /// Whether a tab wants attention — a blocked or waiting (idle) agent via
    /// fine-grained state, or the legacy awaiting-input set when none is reported.
    private func needsAttention(_ tab: SessionTabStripModel.Tab) -> Bool {
        guard let slot = hub.slot(for: tab.ref.serverId) else { return false }
        if let state = slot.agentState(for: tab.ref.sessionId) {
            return state == .blocked || state == .idle
        }
        return slot.sessionsAwaitingInput.contains(tab.ref.sessionId)
    }

    /// True when any tab should be flashing. Gates the flash TimelineView.
    private var anyTabNeedsFlash: Bool {
        tabs.contains(where: needsAttention)
    }

    @ViewBuilder
    private func sessionTabBar(flashOn: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs, id: \.ref) { tab in
                        let slot = hub.slot(for: tab.ref.serverId)
                        Button {
                            if settings.hapticFeedbackEnabled {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            Task { await hub.select(tab.ref) }
                        } label: {
                            SessionTab(
                                number: tab.number,
                                isSelected: tab.isSelected,
                                agentId: slot?.activeAgent(for: tab.ref.sessionId),
                                needsAttention: needsAttention(tab),
                                flashOn: flashOn,
                                agentState: slot?.agentState(for: tab.ref.sessionId)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tab.serverTitle.map { "\($0), session \(tab.number)" } ?? "Session \(tab.number)")
                        .id(tab.ref)
                    }
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TabStripWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(TabStripWidthKey.self) { _ in
                if let ref = hub.activeRef {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(ref, anchor: nil)
                    }
                }
            }
            .onChange(of: hub.activeRef) { _, newRef in
                guard let newRef else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newRef, anchor: nil)
                }
            }
            .onAppear {
                if let ref = hub.activeRef {
                    proxy.scrollTo(ref, anchor: nil)
                }
            }
        }
    }

}

// MARK: - Preference Key for Tab Strip Width

private struct TabStripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Toolbar Icon Button

/// Compact icon button for the status bar toolbar.
private struct ToolbarIconButton: View {
    let icon: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            if AppSettings.shared.hapticFeedbackEnabled {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? .black : SwiftUI.Color.white.opacity(0.7))
                .frame(minWidth: 26, minHeight: 22)
                .background(isActive ? Color.white : Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// Individual session tab. Flash phase is driven by a shared TimelineView clock
/// in the parent, so we don't spin up one Timer.publish per tab.
private struct SessionTab: View {
    let number: Int
    let isSelected: Bool
    let agentId: String?
    let needsAttention: Bool
    /// Shared flash phase passed down from the parent's TimelineView.
    /// Ignored by tabs that don't need attention.
    let flashOn: Bool
    /// Fine-grained agent state (Phase 2). When present it drives the tab color
    /// and flash (parity with the sidebar dot and the Android tab); when nil the
    /// tab falls back to the legacy agent-color + awaiting-input pulse.
    var agentState: AgentDetectedState?

    var body: some View {
        Text("\(number)")
            .font(.system(size: 12, weight: isSelected ? .bold : .semibold, design: .monospaced))
            // Derive the label color from the fill so it stays legible on light
            // backgrounds (e.g. the idle-yellow tab) instead of washing out white.
            .foregroundStyle(tabBackground.contrastingLabel)
            .frame(minWidth: 26, minHeight: 22)
            .background(tabBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selectionBorderColor, lineWidth: isSelected ? 2 : 0)
            )
            .animation(.easeInOut(duration: 0.15), value: flashOn)
    }

    private var selectionBorderColor: SwiftUI.Color { .white }

    private var agentColor: SwiftUI.Color {
        AgentColorPalette.color(for: agentId)
    }

    /// Bright orange for a session waiting on the user (idle), flashing to the
    /// dark below. Motion distinguishes it from Claude's steady amber working fill.
    static let waitingOrange = SwiftUI.Color(red: 1.0, green: 0.584, blue: 0.0)   // #FF9500
    static let waitingFlashDark = SwiftUI.Color(red: 0.102, green: 0.102, blue: 0.102) // #1A1A1A

    private var tabBackground: SwiftUI.Color {
        // When fine-grained agentState is present it drives the color (parity
        // with ActivityDot and the Android tab): blocked=red+flash, working=agent
        // color, waiting(idle)=orange+flash, unknown=gray. Otherwise fall back to the
        // legacy awaiting-input pulse / agent-color fill.
        if let agentState {
            switch agentState {
            case .blocked: return flashOn ? .red : SwiftUI.Color.white.opacity(0.15)
            case .working: return agentColor
            case .idle:    return flashOn ? SessionTab.waitingOrange : SessionTab.waitingFlashDark
            case .unknown: return .gray
            }
        }
        if needsAttention {
            return flashOn ? agentColor : SwiftUI.Color.white.opacity(0.15)
        }
        if agentId != nil { return agentColor }
        return SwiftUI.Color.white.opacity(0.15)
    }
}

// MARK: - Notification for requesting terminal focus

extension Notification.Name {
    static let terminalRequestFocus = Notification.Name("terminalRequestFocus")
    static let terminalResignFocus = Notification.Name("terminalResignFocus")
}

// MARK: - Session Uptime

private struct SessionUptimeView: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatUptime(from: since, to: context.date))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(SwiftUI.Color.white.opacity(0.5))
        }
    }

    private func formatUptime(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if days > 0 {
            return String(format: "%dd %02d:%02d:%02d", days, hours, minutes, seconds)
        }
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
