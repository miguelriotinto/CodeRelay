import Foundation
import AsyncHTTPClient
import NIOCore
import ClaudeRelayKit

/// Builds the composite push sender from configuration, creating the shared
/// `HTTPClient` (returned via `out` so `main` can shut it down). Returns nil
/// when no provider is fully configured (caller then leaves push disabled).
enum PushSenderFactory {
    static func make(config: RelayConfig, group: EventLoopGroup,
                     out httpClient: inout HTTPClient?) -> PushSending? {
        var apns: APNsClient?
        var fcm: FCMClient?

        if let keyPath = config.apnsKeyPath, let keyId = config.apnsKeyId,
           let teamId = config.apnsTeamId, let bundleId = config.apnsBundleId {
            do {
                let client = HTTPClient(eventLoopGroupProvider: .shared(group))
                httpClient = client
                let apnsConfig = try APNsConfig(keyPath: keyPath, keyId: keyId, teamId: teamId,
                                                bundleId: bundleId, useSandbox: config.apnsUseSandbox)
                apns = try APNsClient(config: apnsConfig, http: PushHTTP(client: client))
            } catch {
                RelayLogger.log(.error, category: "push",
                    "APNs configuration failed: \(PushHTTP.redact("\(error)"))")
            }
        }

        if let saPath = config.fcmServiceAccountPath, let projectId = config.fcmProjectId {
            do {
                let client = httpClient ?? HTTPClient(eventLoopGroupProvider: .shared(group))
                httpClient = client
                fcm = try FCMClient(serviceAccountPath: saPath, projectId: projectId,
                                    http: PushHTTP(client: client))
            } catch {
                RelayLogger.log(.error, category: "push",
                    "FCM configuration failed: \(PushHTTP.redact("\(error)"))")
            }
        }

        guard apns != nil || fcm != nil else {
            // Nothing usable — don't leak an HTTPClient.
            if let client = httpClient { try? client.syncShutdown(); httpClient = nil }
            return nil
        }
        return CompositePushSender(apns: apns, fcm: fcm)
    }
}
