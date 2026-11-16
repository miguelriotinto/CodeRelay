import SwiftUI
import UIKit
import CodeRelayClient

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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
