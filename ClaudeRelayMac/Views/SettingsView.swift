import SwiftUI
import Combine
import ClaudeRelayClient
import ClaudeRelaySpeech

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            TabView {
                GeneralSettingsTab()
                    .tabItem { Label("General", systemImage: "gear") }

                SpeechSettingsTab()
                    .tabItem { Label("Speech", systemImage: "mic") }

                AboutSettingsTab()
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
        }
        .frame(width: 560, height: 520)
        .background(.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings Section Helpers

private struct SettingsSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.top, 12)
    }
}

private struct SettingsSectionFooter: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }
}

private struct SettingsRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsGroupRow<Content: View>: View {
    var showDivider: Bool = true
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if showDivider {
                Divider().padding(.leading, 12)
            }
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @StateObject private var settings = AppSettings.shared
    @State private var isCapturing = false
    @State private var capturedModifiers: NSEvent.ModifierFlags = []
    @State private var capturedKey: String = ""
    @State private var windowObserver: AnyCancellable?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: "Appearance")
                SettingsGroup {
                    SettingsGroupRow {
                        Text("Session naming theme")
                        Spacer()
                        Picker("", selection: $settings.sessionNamingTheme) {
                            ForEach(SessionNamingTheme.allCases) { theme in
                                Text(theme.displayName).tag(theme)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsGroupRow {
                        Text("Terminal font size")
                        Spacer()
                        Text("\(Int(settings.terminalFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Stepper("", value: $settings.terminalFontSize, in: 8...16, step: 1)
                            .labelsHidden()
                            .fixedSize()
                    }
                    SettingsGroupRow(showDivider: false) {
                        Text("Terminal scrollback")
                        Spacer()
                        Picker("", selection: $settings.terminalScrollbackLines) {
                            Text("1,000 lines").tag(1_000)
                            Text("5,000 lines").tag(5_000)
                            Text("10,000 lines").tag(10_000)
                            Text("25,000 lines").tag(25_000)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                SettingsSectionHeader(title: "Recording Shortcut")
                SettingsGroup {
                    SettingsGroupRow {
                        Text("Enable shortcut")
                        Spacer()
                        Toggle("", isOn: $settings.recordingShortcutEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    if settings.recordingShortcutEnabled {
                        SettingsGroupRow(showDivider: false) {
                            Text("Key Combination")
                            Spacer()
                            if isCapturing {
                                Text(capturedDisplayString)
                                    .font(.system(.body, design: .rounded))
                                    .foregroundStyle(.primary)
                                Button("Set") {
                                    settings.shortcutModifierFlags = capturedModifiers
                                    settings.recordingShortcutKey = capturedKey
                                    isCapturing = false
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(capturedKey.isEmpty)
                                Button("Cancel") {
                                    isCapturing = false
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                Text(savedDisplayString)
                                    .font(.system(.body, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Button("Change") {
                                    NSLog("[KeyCapture] Change button tapped")
                                    capturedModifiers = []
                                    capturedKey = ""
                                    isCapturing = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                if settings.recordingShortcutEnabled {
                    SettingsSectionFooter(text: isCapturing
                        ? "Press a modifier + letter combination (e.g. ⌘⌥R), then click Set."
                        : settings.recordingShortcutKey.isEmpty
                            ? "Click Change to assign a shortcut."
                            : "Press \(settings.shortcutDisplayString) to toggle speech recording.")
                }

                SettingsSectionHeader(title: "Notifications")
                SettingsGroup {
                    SettingsGroupRow(showDivider: settings.pushNotificationsEnabled) {
                        Text("Push notifications")
                        Spacer()
                        Toggle("", isOn: $settings.pushNotificationsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    if settings.pushNotificationsEnabled {
                        SettingsGroupRow(showDivider: false) {
                            Text("Notify when finished")
                            Spacer()
                            Toggle("", isOn: $settings.pushNotifyOnFinished)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                }
                SettingsSectionFooter(text: "Get notified when an agent is blocked or (optionally) finishes, even when Code[Relay] is in the background.")

                SettingsSectionHeader(title: "Launch")
                SettingsGroup {
                    SettingsGroupRow {
                        Text("Auto connect on launch")
                        Spacer()
                        Toggle("", isOn: $settings.autoConnectEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsGroupRow {
                        Text("Show window on launch")
                        Spacer()
                        Toggle("", isOn: $settings.showWindowOnLaunch)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsGroupRow(showDivider: false) {
                        Text("Launch at login")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { settings.launchAtLoginEnabled },
                            set: { newValue in
                                do {
                                    try LaunchAtLogin.setEnabled(newValue)
                                    settings.launchAtLoginEnabled = newValue
                                } catch {
                                    NSLog("[Mac] LaunchAtLogin toggle failed: \(error)")
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
                SettingsSectionFooter(text: "Automatically reconnect to the last server on launch.")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(.black)
        .onChange(of: isCapturing) { _, capturing in
            if capturing {
                installKeyMonitor()
            } else {
                removeKeyMonitor()
            }
        }
        .onAppear {
            windowObserver = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
                .sink { _ in
                    if isCapturing {
                        NSLog("[KeyCapture] window resigned key — cancelling capture")
                        isCapturing = false
                    }
                }
        }
        .onDisappear {
            removeKeyMonitor()
            isCapturing = false
            windowObserver?.cancel()
            windowObserver = nil
        }
    }

    private func installKeyMonitor() {
        KeyCaptureInterceptor.shared.begin { mods, key in
            DispatchQueue.main.async {
                if !key.isEmpty {
                    // keyDown — freeze the full combo (modifiers + letter).
                    capturedModifiers = mods
                    capturedKey = key
                } else if capturedKey.isEmpty {
                    // flagsChanged with no letter yet — track live modifier state
                    // so the user sees what they're pressing.
                    capturedModifiers = mods
                }
                // If capturedKey is set, ignore further flagsChanged (don't erase
                // the frozen combo when the user releases modifier keys).
            }
        }
    }

    private func removeKeyMonitor() {
        KeyCaptureInterceptor.shared.end()
    }

    private var savedDisplayString: String {
        settings.recordingShortcutKey.isEmpty ? "None" : settings.shortcutDisplayString
    }

    private var capturedDisplayString: String {
        let mods = capturedModifiers.intersection([.command, .option, .shift, .control]).symbolString
        if capturedKey.isEmpty {
            return mods.isEmpty ? "Press keys..." : mods + "..."
        }
        return mods + capturedKey.uppercased()
    }
}

// MARK: - Speech

private struct SpeechSettingsTab: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = SpeechModelStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: "Models")
                SettingsGroup {
                    if store.modelsReady {
                        SettingsGroupRow {
                            Label("Models downloaded", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                        }
                        SettingsGroupRow(showDivider: false) {
                            Button("Delete Models") {
                                store.deleteModels()
                            }
                            Spacer()
                        }
                    } else {
                        SettingsGroupRow(showDivider: false) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Speech models need to be downloaded before first use (~1 GB).")
                                    .foregroundStyle(.secondary)
                                Button(store.downloadProgress == nil ? "Download Models" : "Downloading...") {
                                    Task { try? await store.downloadAllModels() }
                                }
                                .disabled(store.downloadProgress != nil)
                                if let progress = store.downloadProgress {
                                    ProgressView(value: progress)
                                }
                            }
                            Spacer()
                        }
                    }
                }

                SettingsSectionHeader(title: "Speech to Text")
                SettingsGroup {
                    SettingsGroupRow {
                        Text("Smart cleanup (local LLM)")
                        Spacer()
                        Toggle("", isOn: $settings.smartCleanupEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsGroupRow(showDivider: false) {
                        Text("Prompt enhancement (Bedrock Haiku)")
                        Spacer()
                        Toggle("", isOn: $settings.promptEnhancementEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                SettingsSectionFooter(text: speechFooterText)

                SettingsSectionHeader(title: "Continuous Listening")
                SettingsGroup {
                    SettingsGroupRow(showDivider: settings.continuousListeningEnabled) {
                        Text("Enable continuous listening")
                        Spacer()
                        Toggle("", isOn: $settings.continuousListeningEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    if settings.continuousListeningEnabled {
                        SettingsGroupRow(showDivider: false) {
                            Text("Wake word")
                            Spacer()
                            Text(settings.wakeWord.capitalized)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                SettingsSectionFooter(text: settings.continuousListeningEnabled
                    ? "Say the wake word to start a new utterance. "
                    + "On-device AI detects when you've finished speaking. Audio stays on-device."
                    : "When enabled, the mic stays open and transcribes utterances "
                    + "starting with the wake word.")

                if settings.promptEnhancementEnabled {
                    SettingsSectionHeader(title: "AWS Bedrock")
                    SettingsGroup {
                        SettingsGroupRow {
                            Text("Bearer Token")
                            Spacer()
                            SecureField("", text: $settings.bedrockBearerToken)
                                .textContentType(.password)
                                .frame(maxWidth: 250)
                        }
                        SettingsGroupRow(showDivider: false) {
                            Text("Region")
                            Spacer()
                            TextField("", text: $settings.bedrockRegion)
                                .frame(maxWidth: 250)
                        }
                    }
                    SettingsSectionFooter(
                        text: "Prompt Enhancement uses Claude Haiku on AWS Bedrock. "
                            + "Paste your bearer token to enable cloud-based prompt rewriting."
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(.black)
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
}

// MARK: - About

private struct AboutSettingsTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: "Code[Relay]")
                SettingsGroup {
                    SettingsGroupRow {
                        Text("Version")
                        Spacer()
                        Text(appVersion).foregroundStyle(.secondary)
                    }
                    SettingsGroupRow(showDivider: false) {
                        Text("Build")
                        Spacer()
                        Text(buildNumber).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(.black)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }
}
