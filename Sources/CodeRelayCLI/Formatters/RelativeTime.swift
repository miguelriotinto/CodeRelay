import Foundation

/// "5m ago" — the abbreviated relative-time style `session list` prints.
///
/// Apple platforms use Foundation's `RelativeDateTimeFormatter`, which
/// swift-corelibs-foundation does not ship. This is a deliberate English-only
/// stand-in for Linux whose output matches that formatter's `.abbreviated`
/// style unit for unit, so `session list` reads the same on both servers and
/// the CLI tests can assert one expected string.
///
/// Note `.abbreviated` is the single-letter style ("5m ago"), NOT `.short`
/// ("5 min. ago") — they are different `unitsStyle` cases and it is easy to
/// write the wrong one. `RelativeTimeTests` asserts the exact strings and runs
/// on both platforms, so a mismatch fails macOS CI rather than shipping a
/// server whose `session list` reads differently from the other one.
enum RelativeTime {
    static func abbreviated(from date: Date, relativeTo now: Date = Date()) -> String {
        #if canImport(Darwin)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
        #else
        return portableAbbreviated(seconds: now.timeIntervalSince(date))
        #endif
    }

    /// Positive `seconds` is the past ("… ago"), negative the future ("in …").
    /// Unit thresholds and rounding follow `RelativeDateTimeFormatter`: the
    /// largest unit with a non-zero count, truncated. The suffix is joined to
    /// the number without a space, as the abbreviated style does ("5m ago").
    static func portableAbbreviated(seconds: TimeInterval) -> String {
        let magnitude = abs(seconds)
        let (count, unit): (Int, String)
        switch magnitude {
        case ..<60:            (count, unit) = (Int(magnitude), "s")
        case ..<3600:          (count, unit) = (Int(magnitude / 60), "m")
        case ..<86_400:        (count, unit) = (Int(magnitude / 3600), "h")
        case ..<604_800:       (count, unit) = (Int(magnitude / 86_400), "d")
        case ..<2_629_800:     (count, unit) = (Int(magnitude / 604_800), "w")
        case ..<31_557_600:    (count, unit) = (Int(magnitude / 2_629_800), "mo")
        default:               (count, unit) = (Int(magnitude / 31_557_600), "y")
        }
        return seconds >= 0 ? "\(count)\(unit) ago" : "in \(count)\(unit)"
    }
}
