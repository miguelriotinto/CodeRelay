import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Contrast helpers for choosing readable foreground colors over a dynamic fill.
///
/// The session-tab / agent badges compute their background from `agentState`
/// (e.g. idle → yellow, working → agent color, blocked → red). The number drawn
/// on top must stay legible on *whatever* fill that produces — a hardcoded white
/// label washes out on a light fill such as the idle yellow. `contrastingLabel`
/// derives black-or-white from the fill's perceived luminance so the pairing can
/// never drift out of sync when a new state color is introduced.
public extension Color {
    /// Perceived luminance (0…1) of the color *as it renders over black*.
    ///
    /// Alpha is folded in by compositing over black, so a translucent fill like
    /// `.white.opacity(0.15)` (which looks dark grey on the app's black toolbar)
    /// reports a low luminance rather than white's high one. Uses the Rec. 601
    /// luma coefficients. Returns `nil` when the platform can't resolve RGB
    /// components (callers then fall back to a safe default).
    var perceivedLuminance: CGFloat? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if canImport(UIKit)
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #elseif canImport(AppKit)
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        return nil
        #endif
        // Composite over black: a partially transparent fill sits on the black UI.
        let luma = 0.299 * red + 0.587 * green + 0.114 * blue
        return luma * alpha
    }

    /// Black on light fills, white on dark ones — a legible label for this fill.
    ///
    /// The 0.6 threshold sits above mid-grey so only genuinely light fills (the
    /// idle yellow, plain white) flip the label to black; agent orange/teal and
    /// the translucent dim fills keep white. Falls back to white if luminance
    /// can't be resolved (matches the previous always-white behavior).
    var contrastingLabel: Color {
        guard let luminance = perceivedLuminance else { return .white }
        return luminance > 0.6 ? .black : .white
    }
}
