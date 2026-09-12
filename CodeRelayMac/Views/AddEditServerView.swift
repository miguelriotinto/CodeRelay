import SwiftUI
import CodeRelayClient

struct AddEditServerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: AddEditServerViewModel

    let onSave: (ConnectionConfig) -> Void

    init(target: ServerListWindow.AddEditTarget, onSave: @escaping (ConnectionConfig) -> Void) {
        switch target {
        case .add:
            _viewModel = StateObject(wrappedValue: AddEditServerViewModel())
        case .edit(let existing):
            _viewModel = StateObject(wrappedValue: AddEditServerViewModel(existing: existing))
        }
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $viewModel.name)
                    TextField("Host", text: $viewModel.host)
                        .autocorrectionDisabled()
                    TextField("Port", text: $viewModel.port)
                    Toggle("Use TLS (wss://)", isOn: $viewModel.useTLS)
                }
                Section("Authentication") {
                    SecureField("Token", text: $viewModel.token)
                        .textContentType(.password)
                }
                if let error = viewModel.validationError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(viewModel.isEditing ? "Save" : "Add") {
                    if let connection = viewModel.buildConnection() {
                        do {
                            try viewModel.saveToken(for: connection.id)
                            onSave(connection)
                            dismiss()
                        } catch {
                            viewModel.validationError = "Failed to save token: \(error.localizedDescription)"
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 380)
    }
}
