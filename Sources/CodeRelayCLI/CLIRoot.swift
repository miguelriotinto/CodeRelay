import ArgumentParser
import CodeRelayKit

@main
struct CodeRelay: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "claude-relay",
        abstract: "Manage the CodeRelay service",
        version: CodeRelayKit.version,
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
            HookGroup.self,
            OptimizerGroup.self
        ]
    )
}
