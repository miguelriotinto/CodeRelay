import SwiftUI
import UIKit
import CodeRelayClient

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isCapturing = false
    @State private var capturedFlags: UIKeyModifierFlags = []
    @State private var capturedKey: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Auto Connect", isOn: $settings.autoConnectEnabled)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Automatically reconnect to the last server on launch.")
                }

                Section {
                    Toggle("Push Notifications", isOn: $settings.pushNotificationsEnabled)
                    if settings.pushNotificationsEnabled {
                        Toggle("Notify When Finished", isOn: $settings.pushNotifyOnFinished)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text(settings.pushNotificationsEnabled
                         ? "Get notified when an agent needs input (blocked). Enable \"Notify When Finished\" to also be alerted when an agent completes."
                         : "Turn on to be notified when an agent is blocked or finishes, even when the app is in the background.")
                }

                Section {
                    Toggle("Haptic Feedback", isOn: $settings.hapticFeedbackEnabled)
                    Picker("Session Names", selection: $settings.sessionNamingTheme) {
                        ForEach(SessionNamingTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    HStack {
                        Text("Terminal Font Size")
                        Spacer()
                        Text("\(Int(settings.terminalFontSize)) pt")
                            .foregroundStyle(.secondary)
                        Stepper("", value: $settings.terminalFontSize, in: 8...16, step: 1)
                            .labelsHidden()
                            .fixedSize()
                    }
                    Picker("Terminal Scrollback", selection: $settings.terminalScrollbackLines) {
                        Text("1,000 lines").tag(1_000)
                        Text("5,000 lines").tag(5_000)
                        Text("10,000 lines").tag(10_000)
                        Text("25,000 lines").tag(25_000)
                    }
                    Toggle(OptimizerStrings.shareScreenToggle, isOn: $settings.shareScreenWithOptimizer)
                } header: {
                    Text("General")
                } footer: {
                    Text(OptimizerStrings.shareScreenFooter)
                }

                Section {
                    Toggle("Optimizer Shortcut", isOn: $settings.recordingShortcutEnabled)
                    if settings.recordingShortcutEnabled {
                        if isCapturing {
                            VStack(spacing: 8) {
                                Text("Press your shortcut...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(capturedFlags.isEmpty && capturedKey.isEmpty
                                     ? "Waiting..."
                                     : capturedFlags.symbolString + capturedKey.uppercased())
                                    .font(.system(.title, design: .rounded, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                                KeyCaptureView(
                                    capturedFlags: $capturedFlags,
                                    capturedKey: $capturedKey,
                                    isCapturing: $isCapturing,
                                    onCommit: { flags, key in
                                        settings.shortcutModifierFlags = flags
                                        settings.recordingShortcutKey = key
                                    }
                                )
                                .frame(width: 0, height: 0)
                                Button("Cancel") {
                                    isCapturing = false
                                }
                                .font(.subheadline)
                            }
                            .padding(.vertical, 4)
                        } else {
                            HStack {
                                Text("Key Combination")
                                Spacer()
                                Text(settings.shortcutDisplayString)
                                    .foregroundStyle(.secondary)
                                    .font(.system(.body, design: .rounded))
                                Button("Set") {
                                    capturedFlags = []
                                    capturedKey = ""
                                    isCapturing = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                } header: {
                    Text("Keyboard Shortcuts")
                } footer: {
                    if settings.recordingShortcutEnabled && !isCapturing {
                        if settings.recordingShortcutKey.isEmpty {
                            Text("Tap Set and press a modifier + letter key combination (e.g. ⌘⌥R).")
                        } else {
                            Text("Press \(settings.shortcutDisplayString) to optimize the prompt when a hardware keyboard is connected.")
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Build", value: buildNumber)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }
}
