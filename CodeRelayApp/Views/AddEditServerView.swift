import SwiftUI
import CodeRelayClient

/// Modal form for adding or editing a server configuration.
/// This screen is configuration only — no connection happens here.
struct AddEditServerView: View {
    @StateObject private var viewModel: AddEditServerViewModel
    @Environment(\.dismiss) private var dismiss

    let onSave: ((ConnectionConfig) -> Void)?
    let onDelete: (() -> Void)?

    init(
        mode: AddEditServerViewModel.Mode,
        onSave: ((ConnectionConfig) -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: AddEditServerViewModel(mode: mode))
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server Name", text: $viewModel.name)
                        .textContentType(.name)
                        .autocorrectionDisabled()

                    TextField("Host", text: $viewModel.host)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("Port", text: $viewModel.port)
                        .keyboardType(.numberPad)

                    SecureField("Auth Token", text: $viewModel.token)

                    Toggle("Use TLS", isOn: $viewModel.useTLS)
                }

                Section {
                    Button {
                        if let config = viewModel.save() {
                            onSave?(config)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Save")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(viewModel.isValid ? Color.red : Color(.systemGray5))
                    .foregroundStyle(viewModel.isValid ? .white : .black)
                    .disabled(!viewModel.isValid)
                }

                if viewModel.isEditing {
                    Section {
                        Button(role: .destructive) {
                            viewModel.showDeleteConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete Server")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(viewModel.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Delete Server", isPresented: $viewModel.showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete \"\(viewModel.serverName)\"? This cannot be undone.")
            }
        }
    }
}

#Preview("Add") {
    AddEditServerView(mode: .add)
}
