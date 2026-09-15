# Settings Page + Prompt Improvement Toggle — Design Spec

> **Superseded (2026-09-14):** on-device voice transcription was removed from the iOS and macOS apps by `docs/superpowers/specs/2026-09-13-server-prompt-optimizer-design.md`. Kept for history only.

**Date:** 2026-04-10
**Status:** Approved

## Overview

Add a settings page accessible from the server list, with a "Speech to Text" section containing a "Prompt Improvement" toggle. When ON, the on-device LLM rewrites transcriptions into clear Claude Code prompts. When OFF, the LLM does filler-word cleanup (current behavior).

## Decisions

| Aspect | Decision |
|--------|----------|
| Storage | `UserDefaults` via `AppSettings` ObservableObject |
| UI entry point | Gear icon, top-left of ServerListView toolbar |
| Presentation | Sheet from ServerListView |
| Sections | "Speech to Text" (prompt improvement toggle), "About" (version/build) |
| Default | Prompt Improvement OFF (filler cleanup) |
| LLM behavior | Same model, different system prompt based on toggle |

## Architecture

### New Files

| File | Responsibility |
|------|---------------|
| `ClaudeRelayApp/Models/AppSettings.swift` | UserDefaults-backed settings store |
| `ClaudeRelayApp/Views/SettingsView.swift` | Settings page UI |

### Modified Files

| File | Change |
|------|--------|
| `ClaudeRelayApp/Views/ServerListView.swift` | Add gear icon toolbar button, sheet, inject AppSettings |
| `ClaudeRelayApp/Speech/TextCleaner.swift` | Add `promptImprovement` parameter to select system prompt |
| `ClaudeRelayApp/Speech/OnDeviceSpeechEngine.swift` | Pass prompt improvement flag through pipeline |
| `ClaudeRelayApp/Views/ActiveTerminalView.swift` | Read AppSettings to pass flag to engine |
| `ClaudeRelayApp/ClaudeRelayApp.swift` | Inject AppSettings as environmentObject |

## AppSettings

```swift
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("promptImprovementEnabled") var promptImprovementEnabled = false
}
```

Using `@AppStorage` for automatic UserDefaults persistence and SwiftUI binding.

## TextCleaner Changes

Add a second system prompt and a parameter to `clean()`:

```swift
static let fillerCleanupSystemPrompt = """
    You are a transcription cleanup engine. ...current prompt...
    """

static let promptImprovementSystemPrompt = """
    You are a prompt optimization engine. Your ONLY job is to rewrite speech-to-text \
    input into a clear, effective instruction for Claude Code (an AI coding assistant).

    Rules:
    - Rewrite as a direct, specific instruction
    - Remove filler words and hedging
    - Make the intent explicit and actionable
    - Preserve all technical details (file names, function names, error messages)
    - Keep it concise — one clear instruction, not a paragraph
    - Do NOT add information the speaker didn't mention
    - Do NOT add commentary, explanation, or preamble
    - Output ONLY the rewritten prompt, nothing else
    """

func clean(_ text: String, promptImprovement: Bool = false) async throws -> String
```

The `TextCleaning` protocol also gains the parameter (with default `false` so mocks don't break):

```swift
protocol TextCleaning: Sendable {
    func clean(_ text: String, promptImprovement: Bool) async throws -> String
}
```

The `promptImprovement` flag selects which system prompt to use. The user prompt and sanitization logic remain the same.

## OnDeviceSpeechEngine Changes

`stopAndProcess()` gains a `promptImprovement` parameter:

```swift
func stopAndProcess(promptImprovement: Bool = false) async -> String?
```

Passes it through to `cleaner.clean(rawText, promptImprovement: promptImprovement)`.

## UI

### ServerListView

Add a leading toolbar item with a gear icon that presents SettingsView as a sheet:

```swift
ToolbarItem(placement: .navigationBarLeading) {
    Button {
        showSettings = true
    } label: {
        Image(systemName: "gear")
    }
}
```

### SettingsView

```
NavigationStack
  Form
    Section("Speech to Text")
      Toggle("Prompt Improvement", isOn: $settings.promptImprovementEnabled)
      // Footer: "When enabled, transcribed speech is rewritten as a clear,
      //          effective Claude Code prompt. When disabled, filler words
      //          are removed and punctuation is fixed."

    Section("About")
      LabeledContent("Version", value: appVersion)
      LabeledContent("Build", value: buildNumber)
```

### ActiveTerminalView MicButton

Reads `AppSettings.shared.promptImprovementEnabled` and passes it to `engine.stopAndProcess(promptImprovement:)`.

## Testing

| Test | Verifies |
|------|----------|
| `TextCleanerStaticTests` | New test: `buildCleanupPrompt` with `promptImprovement: true` uses different system prompt |
| `AppSettings` | No unit test needed — trivial UserDefaults wrapper |
