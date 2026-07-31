import ArgumentParser
import Foundation

/// Pure merge/removal of the CodeRelay state hook in a Claude Code settings
/// dictionary. Kept separate from file I/O so idempotency and
/// "don't clobber the user's own hooks" are unit-testable.
struct HookSettingsMerger {

    /// Claude Code lifecycle events the hook maps to relay states:
    /// UserPromptSubmit/PreToolUse → working, Notification → blocked, Stop → idle.
    static let events = ["UserPromptSubmit", "PreToolUse", "Notification", "Stop"]

    static func command(hookPath: String, event: String) -> String {
        "\(hookPath) \(event)"
    }

    static func merge(into settings: [String: Any], hookPath: String)
        -> (settings: [String: Any], addedEvents: [String]) {
        var out = settings
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        var added: [String] = []

        for event in events {
            let wanted = command(hookPath: hookPath, event: event)
            var entries = hooks[event] as? [[String: Any]] ?? []

            let alreadyPresent = entries.contains { entry in
                let inner = entry["hooks"] as? [[String: Any]] ?? []
                return inner.contains { ($0["command"] as? String)?.contains(hookPath) == true }
            }
            guard !alreadyPresent else { continue }

            entries.append(["hooks": [["type": "command", "command": wanted]]])
            hooks[event] = entries
            added.append(event)
        }

        out["hooks"] = hooks
        return (out, added)
    }

    static func remove(from settings: [String: Any], hookPath: String)
        -> (settings: [String: Any], removedEvents: [String]) {
        var out = settings
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        var removed: [String] = []

        for event in events {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            let before = entries.count

            entries = entries.compactMap { entry in
                guard var inner = entry["hooks"] as? [[String: Any]] else { return entry }
                inner.removeAll { ($0["command"] as? String)?.contains(hookPath) == true }
                if inner.isEmpty { return nil }
                var copy = entry
                copy["hooks"] = inner
                return copy
            }

            if entries.count != before { removed.append(event) }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }

        out["hooks"] = hooks
        return (out, removed)
    }
}

struct HookGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Manage the Claude Code state hook",
        subcommands: [HookInstallCommand.self, HookUninstallCommand.self]
    )
}

struct HookInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the Claude Code state hook and register it in settings.json"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: .long, help: "Show what would change without writing anything")
    var dryRun = false

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hooksDir = home.appendingPathComponent(".claude-relay/hooks")
        let destination = hooksDir.appendingPathComponent("claude-relay-state-hook.sh")
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        // Written into settings.json with ~ so the file stays portable.
        let displayPath = "~/.claude-relay/hooks/claude-relay-state-hook.sh"

        guard let source = HookInstallCommand.locateBundledScript() else {
            print("Could not find claude-relay-state-hook.sh. Expected it next to the CLI or in the repo's Scripts/hooks/.")
            throw ExitCode.failure
        }

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let (merged, added) = HookSettingsMerger.merge(into: settings, hookPath: displayPath)

        if dryRun {
            print("Would copy:  \(source.path)\n         to: \(destination.path)")
            print(added.isEmpty
                ? "settings.json already registers the hook for all events — no change."
                : "Would register events: \(added.joined(separator: ", "))")
            return
        }

        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        if !added.isEmpty {
            // Back up before touching a file we don't own.
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                let backup = settingsURL.appendingPathExtension("coderelay-backup")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: settingsURL, to: backup)
                if !globals.quiet { print("Backed up settings.json → \(backup.lastPathComponent)") }
            }
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
        }

        if !globals.quiet {
            print("✓ hook installed at \(displayPath)")
            print(added.isEmpty
                ? "✓ settings.json already registered it — nothing to change"
                : "✓ registered events: \(added.joined(separator: ", "))")
            print("\nStart a session through CodeRelay to verify state is reported immediately.")
        }
    }

    /// Looks for the shipped script next to the CLI binary, in the Homebrew
    /// share directory, then in the repo (for a from-source run).
    static func locateBundledScript() -> URL? {
        let fm = FileManager.default
        let cliDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let candidates = [
            cliDir.appendingPathComponent("claude-relay-state-hook.sh"),
            cliDir.appendingPathComponent("../share/clauderelay/claude-relay-state-hook.sh"),
            URL(fileURLWithPath: "/opt/homebrew/share/clauderelay/claude-relay-state-hook.sh"),
            URL(fileURLWithPath: "/usr/local/share/clauderelay/claude-relay-state-hook.sh"),
            URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("Scripts/hooks/claude-relay-state-hook.sh")
        ]
        return candidates.first { fm.fileExists(atPath: $0.standardizedFileURL.path) }?
            .standardizedFileURL
    }
}

struct HookUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the Claude Code state hook registration"
    )

    @OptionGroup var globals: GlobalOptions

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let displayPath = "~/.claude-relay/hooks/claude-relay-state-hook.sh"

        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if !globals.quiet { print("No settings.json found — nothing to remove.") }
            return
        }

        let (updated, removed) = HookSettingsMerger.remove(from: settings, hookPath: displayPath)
        guard !removed.isEmpty else {
            if !globals.quiet { print("The hook was not registered — nothing to remove.") }
            return
        }

        let out = try JSONSerialization.data(
            withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
        if !globals.quiet {
            print("✓ removed hook registration for: \(removed.joined(separator: ", "))")
            print("The script itself is still at \(displayPath) — delete it if you want it gone.")
        }
    }
}
