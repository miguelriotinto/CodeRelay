import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

struct PairWithHostSheet: View {
    @StateObject private var viewModel = PairingViewModel()
    @Environment(\.dismiss) private var dismiss
    var onPaired: (ConnectionConfig) -> Void

    /// Prefill from a scanned or deep-linked URL (scanner path).
    var prefill: PairingURL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("silverwing.local", text: $viewModel.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $viewModel.port).keyboardType(.numberPad)
                    Toggle("Use TLS (wss://)", isOn: $viewModel.useTLS)
                }
                Section("Pairing code") {
                    TextField("K7QP-2M4X", text: $viewModel.code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Pair with a host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        Task {
                            if let config = await viewModel.pair() {
                                onPaired(config); dismiss()
                            }
                        }
                    }
                    .disabled(!viewModel.isValid || viewModel.isPairing)
                }
            }
            .onAppear {
                if let prefill {
                    viewModel.host = prefill.host
                    viewModel.port = String(prefill.port)
                    viewModel.useTLS = prefill.useTLS
                    viewModel.code = PairingCode.formatted(prefill.code)
                }
            }
        }
    }
}
