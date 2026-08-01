import Foundation
import SwiftUI
import UIKit
import ClaudeRelayClient
import ClaudeRelayKit

@MainActor
final class PairingViewModel: ObservableObject {
    @Published var host: String = ""
    @Published var port: String = "9200"
    @Published var useTLS: Bool = false
    @Published var code: String = ""
    @Published var errorMessage: String?
    @Published var isPairing = false

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && UInt16(port) != nil && PairingCode.normalize(code) != nil
    }

    /// Builds a PairingURL from the fields, redeems it, returns the saved config.
    func pair() async -> ConnectionConfig? {
        errorMessage = nil
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            errorMessage = "Host is required."; return nil
        }
        guard let portNumber = UInt16(port), portNumber >= 1 else {
            errorMessage = "Port must be a number between 1 and 65535."; return nil
        }
        guard let normalized = PairingCode.normalize(code) else {
            errorMessage = "That code is not a valid pairing code."; return nil
        }
        let url = PairingURL(host: trimmedHost, port: portNumber, useTLS: useTLS, code: normalized)
        let controller = PairingController(
            store: ClaudeRelayApp.savedConnections,
            deviceName: UIDevice.current.name,
            platform: "ios")
        isPairing = true
        defer { isPairing = false }
        do {
            return try await controller.pair(url)
        } catch let error as PairingError {
            errorMessage = Self.message(for: error, host: trimmedHost, useTLS: useTLS)
            return nil
        } catch {
            errorMessage = "Pairing failed: \(error.localizedDescription)"
            return nil
        }
    }

    static func message(for error: PairingError, host: String, useTLS: Bool) -> String {
        switch error {
        case .invalidCode:
            return "That code is invalid or has expired. Run `claude-relay setup` again for a fresh code."
        case .rateLimited:
            return "Too many attempts from this device. Wait a minute and try again."
        case .tlsRequired:
            return "\(host) requires a secure connection (wss://). Enable TLS on the server, then pair again."
        case .unreachable:
            return "Could not reach \(host). Check you are on the same network as the Mac."
        case .timedOut:
            return "The server did not respond. Check it is running with `claude-relay status`."
        case .server(let code, let text):
            return "Pairing failed (\(code)): \(text)"
        }
    }
}
