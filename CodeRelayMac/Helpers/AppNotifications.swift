import Foundation

/// App-wide notifications posted by the menu bar and deep-link handlers and
/// observed by `MainWindow`.
extension Notification.Name {
    static let showServerList = Notification.Name("com.coderelay.mac.showServerList")
    static let connectToServer = Notification.Name("com.coderelay.mac.connectToServer")
}
