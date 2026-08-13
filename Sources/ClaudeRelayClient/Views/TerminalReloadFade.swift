import SwiftUI
import Combine

/// Fade-through-black for the session-name tap.
///
/// The tap discards the rendered pane and re-renders it from the server's
/// scrollback (`SharedSessionCoordinator.reloadTerminalFromServer`). This drives
/// the cover that hides that swap: fade to black, reload behind the black, fade
/// back once the fresh screen has painted.
///
/// It replaced a translucent white band that swept down the pane over a fixed
/// 1 s. The band was decoration on a timeline unrelated to the reload — it could
/// finish long before the replay landed, or still be mid-sweep after. An opaque
/// cover cannot be decorative: it has to lift on the repaint, which is why the
/// hold below is the reload itself rather than a duration.
///
/// Both apps drive it, so the timings and that rule live in one place.
@MainActor
public enum TerminalReloadFade {
    /// Quick — the user just tapped, so the black needs no easing-in to be
    /// legible as a response.
    public static let fadeOutDuration: TimeInterval = 0.16
    /// Longer than the fade out, so the fresh screen resolves instead of
    /// snapping in.
    public static let fadeInDuration: TimeInterval = 0.22
    /// Ceiling on the black hold. `TerminalViewModel`'s 5 s reload backstop
    /// already guarantees the flag clears (as do `prepareForSwitch` /
    /// `prepareForReplay`), so this is belt as well as braces: a pane stuck
    /// black is the one failure mode the user can't tell from a hung app.
    private static let maxHold = DispatchQueue.SchedulerTimeType.Stride.seconds(8)

    /// Runs the whole gesture: cover, reload, uncover. `cover` is the view's
    /// blackout opacity (0 = terminal visible, 1 = fully covered), animated here
    /// so both apps get identical curves.
    public static func run(
        coordinator: SharedSessionCoordinator,
        id: UUID,
        cover: Binding<Double>
    ) async {
        withAnimation(.easeOut(duration: fadeOutDuration)) { cover.wrappedValue = 1 }
        // Let the black land BEFORE the RIS-prefixed replay repaints underneath,
        // so the swap itself is never on screen.
        try? await Task.sleep(for: .seconds(fadeOutDuration))
        await coordinator.reloadTerminalFromServer(id: id)
        // That call returns when the resume RPC does; the fresh screen paints a
        // moment later, when `replay_complete` flushes the buffered blob.
        if let vm = coordinator.viewModel(for: id) {
            await waitForReloadToLand(vm)
        }
        withAnimation(.easeIn(duration: fadeInDuration)) { cover.wrappedValue = 0 }
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
}
