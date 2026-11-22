import Foundation

/// Which APNs environment this build's push token belongs to, reported to the
/// relay with the registration (`PushRegistration.sandbox`). APNs refuses a
/// token sent to the wrong endpoint with `BadDeviceToken`, and the relay reads
/// that as a dead token — so it has to know, per device, where to send.
public enum APNsEnvironment {
    /// `true` = sandbox, `false` = production, `nil` = unknown (the relay then
    /// uses its configured default).
    ///
    /// Read from the build's own provisioning profile, which is where the
    /// entitlement's value comes from: an Xcode development build embeds a
    /// profile granting `development`; a Mac App Store or Developer ID build
    /// embeds one granting `production`. App Store and TestFlight **iOS** builds
    /// carry no profile at all (Apple strips it) and always use production.
    public static func isSandbox(bundle: Bundle = .main) -> Bool? {
        let root = bundle.bundleURL
        for path in ["embedded.mobileprovision", "Contents/embedded.provisionprofile"] {
            if let data = try? Data(contentsOf: root.appendingPathComponent(path)) {
                return isSandbox(profile: data)
            }
        }
        #if os(iOS) && targetEnvironment(simulator)
        return true
        #elseif os(iOS)
        return false
        #else
        return nil
        #endif
    }

    /// The `aps-environment` a provisioning profile grants (iOS key or the
    /// macOS `com.apple.developer.` one): `development` → `true`,
    /// `production` → `false`, absent or unreadable → `nil`. The profile is a
    /// CMS-signed envelope around a plain XML plist, so the plist is sliced out
    /// and parsed directly — no `security cms` needed.
    static func isSandbox(profile: Data) -> Bool? {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = (entitlements["aps-environment"] ?? entitlements["com.apple.developer.aps-environment"]) as? String
        else { return nil }
        switch value {
        case "development": return true
        case "production": return false
        default: return nil
        }
    }
}
