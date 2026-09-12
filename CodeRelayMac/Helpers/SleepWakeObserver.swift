import Foundation
import AppKit

final class SleepWakeObserver: @unchecked Sendable {

    static let systemDidWake = Notification.Name("com.coderelay.mac.systemDidWake")

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { _ in
            NSLog("[Mac] System will sleep")
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            NSLog("[Mac] System did wake")
            NotificationCenter.default.post(name: Self.systemDidWake, object: nil)
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
    }
}
