import SwiftUI
import SwiftTerm
import AppKit
import os.log
import ClaudeRelayClient

/// Diagnostic logger for the idle-no-echo bug. Filter Console.app on
/// subsystem com.claude.relay.client and category EchoDiag.
private let echoDiag = Logger(subsystem: "com.claude.relay.client",
                              category: "EchoDiag")

/// Wraps a SwiftTerm TerminalView and intercepts Cmd+V to handle image paste.
final class PasteAwareTerminalView: TerminalView {

    /// Callback when an image was found on the pasteboard and handled.
    var onImagePaste: ((Data) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.png, .tiff, .fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.png, .tiff, .fileURL])
    }

    override func paste(_ sender: Any) {
        // If the clipboard holds an image, handle it specially.
        if let pngData = ImagePasteHandler.extractFromPasteboard() {
            onImagePaste?(pngData)
            return
        }
        // Otherwise, fall through to SwiftTerm's default text paste.
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.availableType(from: [.png, .tiff, .fileURL]) != nil {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        // Direct image data first.
        if let pngData = ImagePasteHandler.extractFromPasteboard(pasteboard) {
            onImagePaste?(pngData)
            return true
        }

        // File URLs: look for image extensions.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let pngData = ImagePasteHandler.convertFileToPNG(at: url) {
                    onImagePaste?(pngData)
                    return true
                }
            }
        }
        return false
    }
}

/// Holds a PasteAwareTerminalView alongside its SwiftTerm delegate (coordinator)
/// so the delegate's strong reference outlives any single SwiftUI render.
final class CachedTerminal {
    let view: PasteAwareTerminalView
    let delegate: TerminalCoordinator

    init(view: PasteAwareTerminalView, delegate: TerminalCoordinator) {
        self.view = view
        self.delegate = delegate
    }
}

/// A SwiftUI-hosted container that reuses cached terminal views across session
/// switches. The active session's terminal is shown; others are hidden subviews
/// preserving their SwiftTerm scrollback for instant swap-back.
struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var coordinator: SessionCoordinator
    var fontSize: CGFloat

    /// Tracks the last session id that received keyboard focus so we only
    /// fire `makeFirstResponder` on actual session switches. `updateNSView`
    /// is called on many SwiftUI triggers (size change, coordinator publish,
    /// tab switch); refocusing on each one wastes work and can steal focus
    /// from modals. Also owns the force-redraw observer so its lifetime
    /// matches the host view, not any single SwiftUI render.
    final class Coordinator {
        var lastFocusedId: UUID?
        var redrawObserver: Any?

        deinit {
            if let obs = redrawObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let host = NSView(frame: .zero)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        installRedrawObserver(host: host, context: context)
        return host
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let obs = coordinator.redrawObserver {
            NotificationCenter.default.removeObserver(obs)
            coordinator.redrawObserver = nil
        }
    }

    /// Resolves the rare glyph-overlap artifact that a window resize fixes
    /// today. A resize works because it runs SwiftTerm's `processSizeChange`
    /// → `updateFullScreen()` + `needsDisplay`, a *full* repaint of every
    /// cell — the overlap is stale pixels left by the reused, previously-hidden
    /// terminal view (feeds while hidden only mark changed lines dirty, so
    /// showing the view repaints just those, leaving the prior session's glyphs
    /// underneath). This re-syncs the scroller geometry via the public
    /// `changeScrollback(_:)` (re-applying the CURRENT value is a no-op to the
    /// buffer) and forces a full repaint — the resize fix without resizing.
    ///
    /// Posted on `.terminalForceRedraw`: automatically when a session's replay
    /// completes (the switch-garble auto-fix) and manually from the session-name
    /// button (the refresh feature).
    private func installRedrawObserver(host: NSView, context: Context) {
        if let existing = context.coordinator.redrawObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        context.coordinator.redrawObserver = NotificationCenter.default.addObserver(
            forName: .terminalForceRedraw, object: nil, queue: .main
        ) { [weak host] _ in
            guard let terminal = host?.subviews.first(where: { !$0.isHidden }) as? PasteAwareTerminalView else { return }
            let currentScrollback = terminal.getTerminal().options.scrollback
            terminal.changeScrollback(currentScrollback)
            terminal.getTerminal().updateFullScreen()
            terminal.needsDisplay = true
        }
    }

    func updateNSView(_ host: NSView, context: Context) {
        guard let activeId = coordinator.activeSessionId,
              let viewModel = coordinator.viewModel(for: activeId) else {
            // No active session — hide everything.
            for subview in host.subviews { subview.isHidden = true }
            return
        }

        let cached = cachedOrMake(for: activeId, viewModel: viewModel, host: host)

        // Add to view hierarchy once; subsequent swaps just toggle visibility.
        if cached.view.superview !== host {
            host.addSubview(cached.view)
            cached.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                cached.view.topAnchor.constraint(equalTo: host.topAnchor),
                cached.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                cached.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                cached.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            ])
        }

        // Toggle visibility instead of removing to preserve SwiftTerm's scrollback and parse state
        for subview in host.subviews {
            subview.isHidden = (subview !== cached.view)
        }

        let newFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if cached.view.font != newFont {
            cached.view.font = newFont
        }

        cached.delegate.viewModel = viewModel
        echoDiag.info("updateNSView wiring session=\(activeId.uuidString.prefix(8), privacy: .public)")
        viewModel.onTerminalOutput = { [weak view = cached.view] data in
            guard let view else { return }
            view.feed(byteArray: Array(data)[...])
        }
        // Order matters: terminalReady() flushes pending buffer through the newly-wired callback
        viewModel.terminalReady()

        if context.coordinator.lastFocusedId != activeId {
            context.coordinator.lastFocusedId = activeId
            DispatchQueue.main.async { [weak view = cached.view] in
                view?.window?.makeFirstResponder(view)
            }
        }
    }

    // MARK: - Cache Lookup

    private func cachedOrMake(
        for sessionId: UUID,
        viewModel: TerminalViewModel,
        host: NSView
    ) -> CachedTerminal {
        if let existing = coordinator.cachedTerminalView(for: sessionId) as? CachedTerminal {
            return existing
        }
        let delegate = TerminalCoordinator(viewModel: viewModel)
        let terminal = PasteAwareTerminalView(frame: host.bounds)
        terminal.terminalDelegate = delegate
        terminal.onImagePaste = { [weak viewModel] data in
            viewModel?.sendPasteImage(data)
        }
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        terminal.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminal.installColors(TerminalPalette.colors)

        let cached = CachedTerminal(view: terminal, delegate: delegate)
        coordinator.registerLiveTerminal(for: sessionId, view: cached)
        return cached
    }
}

// MARK: - SwiftTerm Delegate

/// Handles callbacks from SwiftTerm. Kept outside the representable so its
/// lifetime matches the cached terminal view, not the SwiftUI render cycle.
final class TerminalCoordinator: NSObject, TerminalViewDelegate {
    weak var viewModel: TerminalViewModel?

    init(viewModel: TerminalViewModel) {
        self.viewModel = viewModel
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        Task { @MainActor [weak self] in
            self?.viewModel?.sendInput(bytes)
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        let cols = UInt16(newCols)
        let rows = UInt16(newRows)
        Task { @MainActor [weak self] in
            self?.viewModel?.sendResize(cols: cols, rows: rows)
            self?.viewModel?.terminalReady()
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.viewModel?.terminalTitle = title
            self?.viewModel?.onTitleChanged?(title)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
