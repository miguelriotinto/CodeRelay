import SwiftUI
import UIKit
import UserNotifications
import ClaudeRelayClient
import ClaudeRelaySpeech

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

@main
struct ClaudeRelayApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate

    /// Platform-scoped server bookmark storage. The legacy key migrates
    /// existing users from the old `com.coderemote.*` prefix transparently.
    static let savedConnections = SavedConnectionStore(
        key: "com.clauderelay.ios.savedConnections",
        legacyKeys: ["com.coderemote.savedConnections"]
    )

    @State private var showSplash = true
    @State private var pendingSessionId: UUID?
    @State private var preloadTask: Task<Void, Never>?

    var body: some Scene {
        WindowGroup {
            ZStack {
                ServerListView(pendingSessionId: $pendingSessionId)

                if showSplash {
                    SplashScreenView {
                        showSplash = false
                    }
                    .transition(.identity)
                }
            }
            .task {
                let task = Task { await preloadSpeechModels() }
                preloadTask = task
                await task.value
            }
            .onDisappear {
                preloadTask?.cancel()
                preloadTask = nil
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
            .onReceive(PushTokenBridge.shared.$pendingDeepLink.compactMap { $0 }) { url in
                handleDeepLink(url)
                PushTokenBridge.shared.pendingDeepLink = nil
            }
            .task {
                // Request notification permission once the UI is up, if the
                // user hasn't disabled push in settings.
                if AppSettings.shared.pushNotificationsEnabled {
                    pushDelegate.requestAndRegister()
                }
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "clauderelay",
              url.host == "session",
              let uuidString = url.pathComponents.dropFirst().first,
              let sessionId = UUID(uuidString: uuidString) else {
            return
        }
        pendingSessionId = sessionId
    }

    @MainActor
    private func preloadSpeechModels() async {
        let store = SpeechModelStore.shared

        if !store.modelsReady {
            try? await store.downloadAllModels()
        }

        guard store.modelsReady else { return }

        let transcriber = WhisperTranscriber.shared
        if !transcriber.isLoaded {
            try? await transcriber.loadModel()
        }

        let cleaner = TextCleaner.shared
        if !cleaner.isLoaded {
            cleaner.modelPath = store.llmModelPath
            try? cleaner.loadModel(from: store.llmModelPath)
        }
    }
}
