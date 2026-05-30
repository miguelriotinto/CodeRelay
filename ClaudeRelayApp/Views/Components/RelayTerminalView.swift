import SwiftUI
import SwiftTerm
import ClaudeRelayClient
import ClaudeRelayKit
import UIKit
import ObjectiveC

// MARK: - TerminalView subclass for hardware keyboard commands

/// Adds explicit UIKeyCommand entries for Cmd+C / Cmd+V / Cmd+X so that
/// copy-paste works reliably when a hardware keyboard is connected.
/// SwiftTerm implements the `copy(_:)` / `paste(_:)` methods but does not
/// register key commands, so the system never dispatches them on iOS.
class RelayTerminalView: TerminalView {
    // UIKit stops firing deleteBackward when text buffer is empty;
    // override hasText to always return true so key-repeat works.
    private static var hasTextOverrideInstalled = false
    private static func installRuntimeOverrides() {
        guard !hasTextOverrideInstalled else { return }
        hasTextOverrideInstalled = true

        // 1. Override hasText → always true so iOS keeps firing deleteBackward on repeat.
        let sel = sel_registerName("hasText")
        let imp = imp_implementationWithBlock({ (_: AnyObject) -> Bool in
            true
        } as @convention(block) (AnyObject) -> Bool)
        // "B16@0:8" = returns Bool, total frame 16, self at 0, _cmd at 8
        class_replaceMethod(RelayTerminalView.self, sel, imp, "B16@0:8")

        // 2. Override deleteBackward to notify inputDelegate even when the internal
        //    text buffer is empty. SwiftTerm's "buffer empty" path sends the backspace
        //    escape code but skips beginTextInputEdit/endTextInputEdit, so iOS's text
        //    system never sees activity and stops key repeat.
        let delSel = sel_registerName("deleteBackward")
        if let origMethod = class_getInstanceMethod(TerminalView.self, delSel) {
            let origImp = method_getImplementation(origMethod)
            typealias DeleteFn = @convention(c) (AnyObject, Selector) -> Void
            let delImp = imp_implementationWithBlock({ (self_: AnyObject) in
                if let textInput = self_ as? UITextInput {
                    textInput.inputDelegate?.textWillChange(textInput)
                }
                let fn = unsafeBitCast(origImp, to: DeleteFn.self)
                fn(self_, delSel)
                if let textInput = self_ as? UITextInput {
                    textInput.inputDelegate?.textDidChange(textInput)
                }
            } as @convention(block) (AnyObject) -> Void)
            // "v16@0:8" = returns void, total frame 16, self at 0, _cmd at 8
            class_replaceMethod(RelayTerminalView.self, delSel, delImp, "v16@0:8")
        }

        // 3. Override canPerformAction to hide Paste when clipboard has no text.
        //    SwiftTerm declares this as `public` (not `open`), so we use the runtime.
        let canSel = #selector(UIResponder.canPerformAction(_:withSender:))
        if let origCanMethod = class_getInstanceMethod(TerminalView.self, canSel) {
            let origCanImp = method_getImplementation(origCanMethod)
            typealias CanFn = @convention(c) (AnyObject, Selector, Selector, AnyObject?) -> Bool
            let canImp = imp_implementationWithBlock({ (self_: AnyObject, action: Selector, sender: AnyObject?) -> Bool in
                if action == #selector(UIResponderStandardEditActions.paste(_:)) {
                    return UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
                }
                let fn = unsafeBitCast(origCanImp, to: CanFn.self)
                return fn(self_, canSel, action, sender)
            } as @convention(block) (AnyObject, Selector, AnyObject?) -> Bool)
            // "B32@0:8:16@24" = returns Bool, self at 0, _cmd at 8, SEL at 16, id at 24
            class_replaceMethod(RelayTerminalView.self, canSel, canImp, "B32@0:8:16@24")
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            Self.installRuntimeOverrides()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(contentsOf: [
            UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copy(_:))),
            UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:))),
            UIKeyCommand(input: "x", modifierFlags: .command, action: #selector(handleCut(_:)))
        ])

        let enabled = UserDefaults.standard.object(forKey: "recordingShortcutEnabled") as? Bool ?? true
        if enabled {
            let key = UserDefaults.standard.string(forKey: "recordingShortcutKey") ?? ""
            if !key.isEmpty {
                let flagsRaw = UserDefaults.standard.integer(forKey: "recordingShortcutFlags")
                let flags: UIKeyModifierFlags = flagsRaw != 0
                    ? UIKeyModifierFlags(rawValue: flagsRaw)
                    : [.command, .alternate]
                let cmd = UIKeyCommand(input: key, modifierFlags: flags,
                                       action: #selector(handleRecordingShortcut))
                cmd.discoverabilityTitle = "Toggle Recording"
                commands.append(cmd)
            }
        }

        return commands
    }

    @objc private func handleRecordingShortcut() {
        NotificationCenter.default.post(name: .toggleSpeechRecording, object: nil)
    }

    var onPasteImage: ((Data) -> Void)?

    override func paste(_ sender: Any?) {
        // Prioritize images — many clipboard sources (Safari, Mail) include both image and URL representations
        if UIPasteboard.general.hasImages,
           let image = UIPasteboard.general.image,
           let pngData = image.pngData() {
            onPasteImage?(pngData)
            return
        }
        // Plain text — let SwiftTerm handle it normally.
        super.paste(sender)
    }

    @objc private func handleCut(_ sender: Any?) {
        // Terminal output isn't editable — cut behaves like copy.
        copy(sender)
    }
}

/// Holds a RelayTerminalView together with the SwiftTerm delegate so its
/// lifetime exceeds any single SwiftUI render cycle. Cached on the coordinator
/// so switching sessions reuses the same UIView (preserving SwiftTerm's
/// internal scrollback) instead of tearing it down.
final class CachedIOSTerminal {
    let view: RelayTerminalView
    let delegate: IOSTerminalCoordinator

    init(view: RelayTerminalView, delegate: IOSTerminalCoordinator) {
        self.view = view
        self.delegate = delegate
    }
}

/// SwiftUI host that shows the coordinator's cached terminal for the active
/// session. Creates a new cached terminal on first use and registers it with
/// the coordinator so subsequent resumes can ask the server to skip the
/// ring-buffer replay.
struct TerminalHostView: UIViewRepresentable {
    @ObservedObject var coordinator: SessionCoordinator
    var fontSize: CGFloat
    @Binding var isKeyboardVisible: Bool

    func makeCoordinator() -> HostCoordinator {
        HostCoordinator(isKeyboardVisible: $isKeyboardVisible)
    }

    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: .zero)
        host.backgroundColor = .black
        context.coordinator.installKeyboardObservers()
        context.coordinator.installFocusObservers { [weak host] in
            (host?.subviews.first { !$0.isHidden }) as? RelayTerminalView
        }
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        guard let activeId = coordinator.activeSessionId,
              let viewModel = coordinator.viewModel(for: activeId) else {
            for subview in host.subviews { subview.isHidden = true }
            return
        }

        let isFirstTimeForSession = coordinator.cachedTerminalView(for: activeId) == nil
        let sessionChanged = context.coordinator.lastFocusedSessionId != activeId
        let cached = cachedOrMake(for: activeId, viewModel: viewModel, host: host)

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

        for subview in host.subviews {
            subview.isHidden = (subview !== cached.view)
        }

        let newFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if cached.view.font != newFont {
            cached.view.font = newFont
        }

        cached.delegate.viewModel = viewModel
        viewModel.onTerminalOutput = { [weak view = cached.view] data in
            guard let view else { return }
            let bytes = ArraySlice([UInt8](data))
            view.feed(byteArray: bytes)

            // Sync UIScrollView after buffer changes that bypass the scrolled delegate.
            // \033[3J (clear scrollback) trims lines and adjusts yDisp without
            // notifying the view, leaving contentOffset/contentSize stale.
            let term = view.getTerminal()
            let rows = term.rows
            if rows > 0 {
                let cellHeight = view.bounds.height / CGFloat(rows)
                let yDisp = CGFloat(term.buffer.yDisp)
                let expectedOffsetY = yDisp * cellHeight
                if view.contentOffset.y - expectedOffsetY > cellHeight * 2 {
                    view.contentSize.height = max(view.bounds.height,
                                                  (yDisp + CGFloat(rows)) * cellHeight)
                    view.contentOffset.y = expectedOffsetY
                }
            }
        }
        // `terminalReady` is itself idempotent, but `updateUIView` fires on every
        // coordinator publish. Only dispatch once per session to avoid the
        // guard + pending-buffer flush loop cost on each update pass. Tracking
        // by session id doubles as the session-switch reset.
        if context.coordinator.readiedSessionId != activeId {
            context.coordinator.readiedSessionId = activeId
            viewModel.terminalReady()
        }

        // Hide the built-in input accessory once per terminal (idempotent, but
        // not needed on every updateUIView).
        if isFirstTimeForSession {
            cached.view.inputAccessoryView?.isHidden = true
            cached.view.inputAccessoryView?.frame.size.height = 0
            cached.view.reloadInputViews()
        }

        // Only focus the terminal when the active session actually changes.
        // updateUIView fires on every @ObservedObject publish (activity updates,
        // connection quality, etc.), and forcing first-responder on each call
        // would override user dismisses — the keyboard would pop back up every
        // time a coordinator property changes.
        if sessionChanged {
            context.coordinator.lastFocusedSessionId = activeId
            _ = cached.view.becomeFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: HostCoordinator) {
        coordinator.removeKeyboardObservers()
        coordinator.removeFocusObservers()
    }

    // MARK: - Cache Lookup

    private func cachedOrMake(
        for sessionId: UUID,
        viewModel: TerminalViewModel,
        host: UIView
    ) -> CachedIOSTerminal {
        if let existing = coordinator.cachedTerminalView(for: sessionId) as? CachedIOSTerminal {
            return existing
        }
        let delegate = IOSTerminalCoordinator(viewModel: viewModel)
        let terminal = RelayTerminalView(frame: host.bounds)
        terminal.terminalDelegate = delegate
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        terminal.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminal.installColors(TerminalPalette.colors)
        terminal.changeScrollback(AppSettings.shared.terminalScrollbackLines)
        terminal.onPasteImage = { [weak viewModel] imageData in
            viewModel?.sendPasteImage(imageData)
        }

        let cached = CachedIOSTerminal(view: terminal, delegate: delegate)
        coordinator.registerLiveTerminal(for: sessionId, view: cached)
        return cached
    }
}

// MARK: - Host Coordinator (keyboard + focus observers)

/// Owns the keyboard-visibility and focus/resign notification observers for
/// the terminal host. These are installed once per host (not per terminal)
/// so switching sessions doesn't register duplicate observers.
final class HostCoordinator: NSObject {
    private var isKeyboardVisible: Binding<Bool>
    private var focusObserver: Any?
    private var resignObserver: Any?
    private var keyboardShowObserver: Any?
    private var keyboardHideObserver: Any?
    /// Tracks which session was most recently focused so we only force-focus
    /// the terminal on actual session switches, not on every coordinator
    /// property publish.
    var lastFocusedSessionId: UUID?

    /// Tracks which session has had its first `terminalReady()` call dispatched.
    /// `updateUIView` fires on every @ObservedObject publish, and while
    /// `terminalReady()` is already internally idempotent, this avoids the
    /// guard dispatch + flush loop cost on each update pass.
    var readiedSessionId: UUID?

    init(isKeyboardVisible: Binding<Bool>) {
        self.isKeyboardVisible = isKeyboardVisible
        super.init()
    }

    func installKeyboardObservers() {
        removeKeyboardObservers()
        keyboardShowObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidShowNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.isKeyboardVisible.wrappedValue = true
        }
        keyboardHideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.isKeyboardVisible.wrappedValue = false
        }
    }

    func removeKeyboardObservers() {
        if let obs = keyboardShowObserver {
            NotificationCenter.default.removeObserver(obs)
            keyboardShowObserver = nil
        }
        if let obs = keyboardHideObserver {
            NotificationCenter.default.removeObserver(obs)
            keyboardHideObserver = nil
        }
    }

    /// Installs focus/resign observers that act on the currently-visible
    /// terminal, resolved lazily via `activeTerminal()` — this avoids dangling
    /// references when session swaps change which terminal is front.
    func installFocusObservers(activeTerminal: @escaping () -> RelayTerminalView?) {
        removeFocusObservers()
        focusObserver = NotificationCenter.default.addObserver(
            forName: .terminalRequestFocus, object: nil, queue: .main
        ) { _ in
            _ = activeTerminal()?.becomeFirstResponder()
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: .terminalResignFocus, object: nil, queue: .main
        ) { _ in
            _ = activeTerminal()?.resignFirstResponder()
        }
    }

    func removeFocusObservers() {
        if let obs = focusObserver {
            NotificationCenter.default.removeObserver(obs)
            focusObserver = nil
        }
        if let obs = resignObserver {
            NotificationCenter.default.removeObserver(obs)
            resignObserver = nil
        }
    }
}

// MARK: - SwiftTerm Delegate

/// One instance per cached terminal. Holds a weak reference to the current
/// view model (which is re-assigned by `updateUIView` as sessions swap in).
final class IOSTerminalCoordinator: NSObject, TerminalViewDelegate {
    weak var viewModel: TerminalViewModel?

    init(viewModel: TerminalViewModel) {
        self.viewModel = viewModel
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        Task { @MainActor [weak self] in
            self?.viewModel?.sendInput(Data(data))
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        Task { @MainActor [weak self] in
            self?.viewModel?.sendResize(cols: UInt16(newCols), rows: UInt16(newRows))
            self?.viewModel?.terminalReady()
        }
    }

    func scrolled(source: TerminalView, position: Double) {}
    func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.viewModel?.terminalTitle = title
            self?.viewModel?.onTitleChanged?(title)
        }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
