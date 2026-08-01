import SwiftUI
import ClaudeRelayClient
import ClaudeRelayKit

extension PairingURL: @retroactive Identifiable {
    public var id: String { urlString }
}

struct PairWithHostSheet: View {
    @StateObject private var viewModel = PairingViewModel()
    @Environment(\.dismiss) private var dismiss
    var onPaired: (ConnectionConfig) -> Void
    var prefill: PairingURL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with a host").font(.headline)
            Form {
                TextField("Host", text: $viewModel.host)
                    .autocorrectionDisabled()
                TextField("Port", text: $viewModel.port)
                Toggle("Use TLS (wss://)", isOn: $viewModel.useTLS)
                TextField("Code (K7QP-2M4X)", text: $viewModel.code)
            }
            .formStyle(.grouped)
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Pair") {
                    Task {
                        if let c = await viewModel.pair() {
                            onPaired(c)
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.isValid || viewModel.isPairing)
            }
        }
        .padding(20)
        .frame(width: 480, height: 320)
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
