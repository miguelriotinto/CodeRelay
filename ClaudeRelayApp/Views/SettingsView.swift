import SwiftUI
import UIKit
import ClaudeRelayClient

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showTokenRequired = false
    @State private var isCapturing = false
    @State private var capturedFlags: UIKeyModifierFlags = []
    @State private var capturedKey: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Smart Cleanup", isOn: $settings.smartCleanupEnabled)
                    Toggle("Prompt Enhancement", isOn: $settings.promptEnhancementEnabled)
                    Toggle("Continuous Listening", isOn: $settings.continuousListeningEnabled)

                    if settings.continuousListeningEnabled {
                        HStack {
                            Text("Wake Word")
                            Spacer()
                            Text(settings.wakeWord.capitalized).foregroundStyle(.secondary)
                        }

                        Text("Continuous listening uses on-device AI to detect when you've finished speaking.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Speech to Text")
                } footer: {
                    Text(speechFooterText)
                }

                if settings.promptEnhancementEnabled {
                    Section {
                        SecureField("Bearer Token", text: $settings.bedrockBearerToken)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Region", text: $settings.bedrockRegion)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text("AWS Bedrock")
                    } footer: {
                        Text(
                            "Prompt Enhancement uses Claude Haiku on AWS Bedrock. "
                            + "Paste your bearer token to enable cloud-based prompt rewriting."
                        )
                    }
                }

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

                Section("General") {
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
                }

                Section {
                    Toggle("Recording Shortcut", isOn: $settings.recordingShortcutEnabled)
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
                            Text("Press \(settings.shortcutDisplayString) to toggle speech recording when a hardware keyboard is connected.")
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
                    Button("Done") { handleDone() }
                }
            }
            .alert("Bearer Key is Required", isPresented: $showTokenRequired) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Prompt Enhancement requires an AWS Bedrock bearer token. Please paste your token or disable Prompt Enhancement.")
            }
        }
    }

    private func handleDone() {
        if settings.promptEnhancementEnabled && settings.bedrockBearerToken.trimmingCharacters(in: .whitespaces).isEmpty {
            showTokenRequired = true
        } else {
            dismiss()
        }
    }

    private var speechFooterText: String {
        if settings.promptEnhancementEnabled {
            return "Transcribed speech is sent to Claude Haiku on AWS Bedrock and rewritten as an optimized prompt."
        } else if settings.smartCleanupEnabled {
            return "Filler words are removed and punctuation is fixed locally on-device before pasting into the terminal."
        } else {
            return "Raw transcription is pasted directly into the terminal with no processing."
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }
}
