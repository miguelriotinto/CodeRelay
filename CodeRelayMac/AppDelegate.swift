import AppKit
import SwiftUI
import UserNotifications
import CodeRelayClient

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sleepWakeObserver: SleepWakeObserver?
    private var networkMonitor: NetworkMonitor?
    private var windowObserver: Any?

    /// Request notification authorization and register for remote (APNs)
    /// notifications. Results are published to `PushTokenBridge`.
    func requestAndRegisterPush() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                PushTokenBridge.shared.permissionGranted = granted
                if granted { NSApplication.shared.registerForRemoteNotifications() }
            }
        }
    }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushTokenBridge.shared.setAPNsToken(deviceToken) }
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushTokenBridge.shared.permissionGranted = false }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyCaptureSwizzle.install()
        RecordingShortcutMonitor.shared.start()
        sleepWakeObserver = SleepWakeObserver()
        networkMonitor = NetworkMonitor()

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .black
        }

        Task { @MainActor in
            for window in NSApp.windows where window.canBecomeMain {
                window.titlebarAppearsTransparent = true
                window.backgroundColor = .black
                if !AppSettings.shared.showWindowOnLaunch {
                    window.close()
                }
            }
        }

        if AppSettings.shared.pushNotificationsEnabled {
            requestAndRegisterPush()
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Notification tapped → route its deep link through PushTokenBridge.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let link = response.notification.request.content.userInfo["deepLink"] as? String,
           let url = URL(string: link) {
            await MainActor.run { PushTokenBridge.shared.pendingDeepLink = url }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
