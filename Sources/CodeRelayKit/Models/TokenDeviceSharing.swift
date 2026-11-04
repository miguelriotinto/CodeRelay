import Foundation

/// Detects one relay token in use on more than one device.
///
/// Session ownership is per TOKEN: `session_list` returns every session the
/// token owns, so two devices sharing a token share one session pane and each
/// sees the other's sessions as its own. Nothing about that is a client bug,
/// and nothing on the wire can tell the devices apart — except the device id
/// clients send in `auth_request`. This records those sightings per token so
/// the relay can warn and `claude-relay token list` can flag the token.
///
/// Pure value logic so the server (`TokenStore`) and the CLI share one rule.
public enum TokenDeviceSharing {
    /// A device counts toward "in use on N devices" while it authenticated
    /// within this window. Long enough that a device used weekly still counts,
    /// short enough that re-pairing one device clears the flag on its own.
    public static let window: TimeInterval = 7 * 24 * 3600
    /// Per-token bound on remembered devices; the oldest sighting is evicted.
    public static let maxDevicesPerToken = 16
    /// Same bound the push registration applies to its device id.
    public static let maxDeviceIdLength = 128

    /// Whether `deviceId` is worth recording (non-empty, bounded, and not the
    /// `"unknown"` fallback a platform returns when it refuses an id).
    public static func isRecordable(_ deviceId: String) -> Bool {
        !deviceId.isEmpty && deviceId != "unknown" && deviceId.count <= maxDeviceIdLength
    }

    /// Devices in `devices` seen within `window` of `now`.
    public static func recentCount(_ devices: [String: Date]?, now: Date) -> Int {
        (devices ?? [:]).values.filter { now.timeIntervalSince($0) <= window }.count
    }

    /// Records a sighting of `deviceId` at `now`.
    ///
    /// - Returns: the updated map, and `sharedWith` — the number of OTHER
    ///   devices seen within the window, reported only when this sighting is
    ///   what makes the token shared (the device is new, or its last sighting
    ///   had aged out). Every later reconnect of the same device returns 0, so
    ///   the relay warns once per device joining, not once per connection.
    public static func record(
        _ deviceId: String,
        at now: Date,
        in devices: [String: Date]?
    ) -> (devices: [String: Date], sharedWith: Int) {
        var map = devices ?? [:]
        guard isRecordable(deviceId) else { return (map, 0) }

        let previous = map[deviceId]
        let wasRecent = previous.map { now.timeIntervalSince($0) <= window } ?? false
        let others = map.filter { $0.key != deviceId && now.timeIntervalSince($0.value) <= window }.count

        map[deviceId] = now
        while map.count > maxDevicesPerToken,
              let oldest = map.min(by: { $0.value < $1.value })?.key {
            map.removeValue(forKey: oldest)
        }
        return (map, wasRecent ? 0 : others)
    }
}
