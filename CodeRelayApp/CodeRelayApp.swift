import SwiftUI
import UIKit
import UserNotifications
import CodeRelayClient
import CodeRelayKit

/// App-target conformance to enable `.sheet(item:)` presentation.
extension PairingURL: @retroactive Identifiable {
    public var id: String { urlString }
}

/// Handles APNs registration + notification taps, publishing results to the
/// shared `PushTokenBridge`. Registration-vs-unregister decisions and the wire
/// send live in the coordinator (driven by `PushRegistrationController`).
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Request authorization and, if granted, register for remote notifications.
    /// Safe to call repeatedly.
    @MainActor
    func requestAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                PushTokenBridge.shared.permissionGranted = granted
                if granted { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushTokenBridge.shared.setAPNsToken(deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushTokenBridge.shared.permissionGranted = false }
    }

    /// Notification tapped → route its deep link through the app's handler.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let link = response.notification.request.content.userInfo["deepLink"] as? String,
           let url = URL(string: link) {
            await MainActor.run { PushTokenBridge.shared.pendingDeepLink = url }
        }
    }

    /// Show banners even while the app is foregrounded.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Routes an incoming URL: pairing links open the pairing sheet; session links
/// go to the hub, which queues them until `start()` has finished (spec §10).
@MainActor
struct DeepLinkRouter {
    enum Outcome: Equatable {
        case pairing(PairingURL)
        case session(IOSServerHub.DeepLinkOutcome)
        case ignored
    }

    let hub: IOSServerHub

    func open(_ url: URL) async -> Outcome {
        if url.host == "pair", let pairing = PairingURL(url: url) { return .pairing(pairing) }
        guard let link = SessionDeepLink(url: url) else { return .ignored }
        return .session(await hub.handleDeepLink(link))
    }
}

@main
struct CodeRelayApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate

    /// Platform-scoped server bookmark storage. The legacy key migrates
    /// existing users from the old `com.coderemote.*` prefix transparently.
    static let savedConnections = SavedConnectionStore(
        key: "com.clauderelay.ios.savedConnections",
        legacyKeys: ["com.coderemote.savedConnections"]
    )

    /// The one hub (multi-server spec §8.2): owned here, not by a view that can
    /// be recreated, so a deep link that arrives during launch has a target.
    @StateObject private var hub = IOSServerHubFactory.make()
    @State private var showSplash = true
    @State private var pendingPairing: PairingURL?

    var body: some Scene {
        WindowGroup {
            ZStack {
                WorkspaceView(hub: hub)

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .transition(.identity)
                }
            }
            .onOpenURL { url in
                Task { await route(url) }
            }
            .onReceive(PushTokenBridge.shared.$pendingDeepLink.compactMap { $0 }) { url in
                Task { await route(url) }
                PushTokenBridge.shared.pendingDeepLink = nil
            }
            .task {
                // Request notification permission once the UI is up, if the
                // user hasn't disabled push in settings.
                if AppSettings.shared.pushNotificationsEnabled {
                    pushDelegate.requestAndRegister()
                }
            }
            .sheet(item: $pendingPairing) { pairing in
                PairWithHostSheet(onPaired: { _ in
                    // The paired bookmark is saved enabled; reloading builds its
                    // coordinator (the cap is enforced by the hub).
                    hub.reloadBookmarks()
                }, prefill: pairing)
            }
        }
    }

    private func route(_ url: URL) async {
        switch await DeepLinkRouter(hub: hub).open(url) {
        case .pairing(let pairing): pendingPairing = pairing
        case .session, .ignored: break    // the hub published a notice for .notFound
        }
    }
}
