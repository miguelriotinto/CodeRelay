import SwiftUI
import Combine

/// The session-name tap and the blackout timings shared by both apps.
///
/// The tap discards the rendered pane and re-renders it from the server's
/// scrollback (`SharedSessionCoordinator.reloadTerminalFromServer`). The
/// coordinator publishes `sessionLoadPhase = .attaching` first, which raises
/// the loading sheet (`SessionLoadingSheetModel`) and the black cover over the
/// terminal; the replay hooks clear it on the first visible frame, so the
/// cover lifts on the repaint, never on a timer.
///
/// It replaced a translucent white band that swept down the pane over a fixed
/// 1 s — decoration on a timeline unrelated to the reload. An opaque cover
/// cannot be decorative: it has to lift on the repaint.
@MainActor
public enum TerminalReloadFade {
    /// Quick — the user just acted, so the black needs no easing-in to be
    /// legible as a response.
    public static let coverOutDuration: TimeInterval = 0.16
    /// Longer than the fade out, so the fresh screen resolves instead of
    /// snapping in.
    public static let coverInDuration: TimeInterval = 0.22
    /// Ceiling on the black hold. `TerminalViewModel`'s 5 s reload backstop
    /// already guarantees the flag clears (as do `prepareForSwitch` /
    /// `prepareForReplay`), so this is belt as well as braces: a pane stuck
    /// black is the one failure mode the user can't tell from a hung app.
    private static let maxHold = DispatchQueue.SchedulerTimeType.Stride.seconds(8)

    /// The session-name tap: reload the pane from the server's scrollback. The
    /// coordinator publishes `.attaching` first, which raises the loading sheet
    /// and the blackout; the replay hooks clear it on the first visible frame.
    /// Returns once the fresh screen has landed (or the backstop fired).
    public static func reload(coordinator: SharedSessionCoordinator, id: UUID) async {
        await coordinator.reloadTerminalFromServer(id: id)
        // That call returns when the resume RPC does; the fresh screen paints a
        // moment later, when `replay_complete` flushes the buffered blob.
        if let vm = coordinator.viewModel(for: id) {
            await waitForReloadToLand(vm)
        }
    }

    /// Returns once `vm` is no longer mid-reload, or after `maxHold` — Combine's
    /// `timeout` finishes the sequence, which ends the loop without a value.
    ///
    /// A reload the coordinator dropped (recovery in flight, or a re-tap over a
    /// replay that hasn't landed) leaves the flag already false, so this returns
    /// immediately and the cover just blinks.
    private static func waitForReloadToLand(_ vm: TerminalViewModel) async {
        guard vm.isReloadingFromServer else { return }
        let landed = vm.$isReloadingFromServer
            .filter { !$0 }
            .timeout(maxHold, scheduler: DispatchQueue.main)
            .values
        for await _ in landed { return }
    }
}

public extension View {
    /// Paints the reload blackout over this view at `opacity`. Purely visual, so
    /// it never intercepts input meant for the terminal underneath.
    func terminalReloadCover(_ opacity: Double) -> some View {
        overlay(Color.black.opacity(opacity).allowsHitTesting(false))
    }

    /// The blackout that follows the loading sheet: black while `covered`, with
    /// the shared curves (quick to black, slower back) so both apps match.
    func terminalLoadingCover(_ covered: Bool) -> some View {
        terminalReloadCover(covered ? 1 : 0)
            .animation(.easeInOut(duration: covered ? TerminalReloadFade.coverOutDuration
                                                    : TerminalReloadFade.coverInDuration),
                       value: covered)
    }
}
