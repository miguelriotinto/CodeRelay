import SwiftUI

/// Centralized per-agent color mapping used throughout both the iOS and
/// macOS apps.
///
/// To add a new coding agent: add a case here AND register the agent in
/// `CodingAgent.all` (ClaudeRelayKit/Models/CodingAgent.swift). No other
/// file needs to change.
public enum AgentColorPalette {
    public static func color(for agentId: String?) -> Color {
        switch agentId {
        case "claude":       return .orange
        case "codex":        return Color(red: 84/255, green: 132/255, blue: 137/255)
        case "copilot":      return Color(red: 110/255, green: 84/255, blue: 148/255)  // GitHub purple
        case "cursor-agent": return Color(red: 45/255, green: 125/255, blue: 210/255)  // Cursor blue
        case "droid":        return Color(red: 210/255, green: 120/255, blue: 60/255)  // Factory amber
        default:             return Color(red: 84/255, green: 132/255, blue: 137/255)
        }
    }
}
