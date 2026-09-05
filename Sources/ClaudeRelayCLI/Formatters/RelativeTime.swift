import Foundation

/// "5 min. ago" — the abbreviated relative-time style `session list` prints.
///
/// Apple platforms use Foundation's `RelativeDateTimeFormatter`, which
/// swift-corelibs-foundation does not ship. This is a deliberate English-only
/// stand-in for Linux whose output matches that formatter's `.abbreviated`
/// style unit for unit, so `session list` reads the same on both servers and
/// the CLI tests can assert one expected string.
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
    /// largest unit with a non-zero count, truncated.
    static func portableAbbreviated(seconds: TimeInterval) -> String {
        let magnitude = abs(seconds)
        let (count, unit): (Int, String)
        switch magnitude {
        case ..<60:            (count, unit) = (Int(magnitude), "sec.")
        case ..<3600:          (count, unit) = (Int(magnitude / 60), "min.")
        case ..<86_400:        (count, unit) = (Int(magnitude / 3600), "hr.")
        case ..<604_800:       (count, unit) = (Int(magnitude / 86_400), "day")
        case ..<2_629_800:     (count, unit) = (Int(magnitude / 604_800), "wk.")
        case ..<31_557_600:    (count, unit) = (Int(magnitude / 2_629_800), "mo.")
        default:               (count, unit) = (Int(magnitude / 31_557_600), "yr.")
        }
        // "day" is the one unit the abbreviated style spells out and pluralises.
        let noun = unit == "day" ? (count == 1 ? "day" : "days") : unit
        return seconds >= 0 ? "\(count) \(noun) ago" : "in \(count) \(noun)"
    }
}
