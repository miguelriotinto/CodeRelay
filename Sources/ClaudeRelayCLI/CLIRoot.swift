import ArgumentParser
import ClaudeRelayKit

@main
struct ClaudeRelay: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "claude-relay",
        abstract: "Manage the ClaudeRelay service",
        version: ClaudeRelayKit.version,
        subcommands: [
            SetupCommand.self,
            LoadCommand.self,
            UnloadCommand.self,
            StartCommand.self,
            StopCommand.self,
            RestartCommand.self,
            StatusCommand.self,
            HealthCommand.self,
            TokenGroup.self,
            SessionGroup.self,
            ConfigGroup.self,
            LogGroup.self,
            HookGroup.self
        ]
    )
}
