import DictationCore
import Foundation

/// Builds the agent with tools for the engine chosen in the settings: Claude Code, or Codex
/// with the same allowed tools. When the chosen command line is missing, the other one is used.
enum AgentFactory {
    static func make(_ settings: DictationSettings, tools: [String], builtinTools: [String] = [], model: ClaudeModel = .sonnet,
                     effort: ClaudeEffort = .low, timeout: TimeInterval, usesSpare: Bool = false,
                     mcpConfig: String? = nil) async -> (any ToolAgent)? {
        if DemoMode.isOn { return DemoAgent() }
        let claudePath = ClaudeCLI.locate(custom: settings.ai.claudePath)
        let codexPath = CodexCLI.locate(custom: settings.ai.codexPath)
        func claude() -> (any ToolAgent)? {
            guard let claudePath else { return nil }
            var agent = ClaudeAgent(path: claudePath, model: model, effort: effort, tools: tools, timeout: timeout)
            agent.builtinTools = builtinTools
            agent.usesSpare = usesSpare
            agent.mcpConfig = mcpConfig
            agent.serverScope = .user
            return agent
        }
        func codex() async -> (any ToolAgent)? {
            guard let codexPath else { return nil }
            let servers = await CodexAgent.servers(path: codexPath)
            var agent = CodexAgent(path: codexPath, model: settings.assistant.planner.codexModel, effort: effort, tools: tools,
                                   servers: servers.names, timeout: timeout)
            agent.localServers = servers.local
            return agent
        }
        // The app's own MCP servers can only be handed to Claude Code.
        if mcpConfig != nil { return claude() }
        switch settings.assistant.agentEngine {
        case .codex:
            if let agent = await codex() { return agent }
            return claude()
        default:
            if let agent = claude() { return agent }
            return await codex()
        }
    }
}
