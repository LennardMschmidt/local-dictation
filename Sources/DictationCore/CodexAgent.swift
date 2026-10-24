import Foundation

/// An agent with tools: Claude Code or Codex, given the same allowed tools in Claude Code's
/// naming ("mcp__awork__awork_query", "mcp__polarion-api", "Skill").
public protocol ToolAgent: Sendable {
    /// Runs `prompt` and returns the answer as text.
    func run(_ prompt: String) async throws -> String
    /// Like `run`, and also the tools the agent called, when it reports them.
    func runWithTools(_ prompt: String) async throws -> (answer: String, tools: [String])
    /// Runs `prompt` and returns JSON text that follows `schema`.
    func structured(_ prompt: String, schema: [String: Any], kind: String) async throws -> String
    /// How the prompt tells this agent to follow the skill `name`.
    func useSkill(_ name: String) -> String
}

public extension ToolAgent {
    func runWithTools(_ prompt: String) async throws -> (answer: String, tools: [String]) {
        (try await run(prompt), [])
    }
}

extension ToolAgent {
    public func structured(_ prompt: String, schema: [String: Any]) async throws -> String {
        try await structured(prompt, schema: schema, kind: "structured")
    }
}

extension ClaudeAgent: ToolAgent {
    public func useSkill(_ name: String) -> String {
        "the \(name) skill (load it with the Skill tool and follow it)"
    }
}

/// Codex with MCP tools: `codex exec` in a read-only sandbox, without a session. Its MCP servers
/// come from the user's Codex configuration; for each call only the allowed tools stay on
/// (`enabled_tools`) and every other server is switched off.
public struct CodexAgent: ToolAgent {
    public let path: String
    public let model: String
    public let effort: ClaudeEffort
    public let tools: [String]
    /// The switched-on MCP servers Codex knows, by name, with whether they run as a local
    /// command (stdio).
    public let servers: [String]
    public var localServers: Set<String> = []
    let runner: CommandRunner
    let timeout: TimeInterval

    public init(path: String, model: String = "", effort: ClaudeEffort = .low, tools: [String], servers: [String],
                runner: CommandRunner = ProcessRunner(), timeout: TimeInterval = 300) {
        self.path = path
        self.model = model
        self.effort = effort
        self.tools = tools
        self.servers = servers
        self.runner = runner
        self.timeout = timeout
    }

    /// The switched-on MCP servers Codex knows (`codex mcp list --json`), and which of them are
    /// local commands.
    public static func servers(path: String, runner: CommandRunner = ProcessRunner()) async -> (names: [String], local: Set<String>) {
        guard let data = try? await runner.run(path, arguments: ["mcp", "list", "--json"], timeout: 30),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return ([], []) }
        let on = list.filter { ($0["enabled"] as? Bool) != false }
        let local = on.filter { (($0["transport"] as? [String: Any])?["type"] as? String) == "stdio" }.compactMap { $0["name"] as? String }
        return (on.compactMap { $0["name"] as? String }, Set(local))
    }

    /// Other names the same server has in other setups: the Polarion REST server is
    /// `polarion-openapi` here and `polarion-mcp` in other setups.
    static let aliases: [String: [String]] = [
        "polarion-openapi": ["polarion-mcp", "polarion-rest"],
        "polarion-api": ["polarion_api"],
    ]

    static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// The allowed tools per Codex server; nil as value allows the whole server.
    func allowed() -> [String: [String]?] {
        var result: [String: [String]?] = [:]
        for tool in tools where tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            let logical = parts[0]
            let candidates = [logical] + (Self.aliases[logical] ?? [])
            guard let server = servers.first(where: { server in candidates.contains { Self.normalized($0) == Self.normalized(server) } })
            else { continue }
            if parts.count > 1 {
                let existing = result[server] ?? []
                if let existing { result[server] = existing + [parts[1]] }
            } else {
                result[server] = .some(nil)
            }
        }
        return result
    }

    func configArguments() -> [String] {
        let allowed = allowed()
        var arguments: [String] = []
        for server in servers {
            if let entry = allowed[server] {
                if let names = entry {
                    let list = names.map { "\"\($0)\"" }.joined(separator: ",")
                    arguments += ["-c", "mcp_servers.\(server).enabled_tools=[\(list)]"]
                }
            } else {
                // A server from an app or plugin has no entry in config.toml; switching it off
                // alone leaves an entry without a command, which Codex rejects, so local ones get
                // a harmless command as well.
                if localServers.contains(server) { arguments += ["-c", "mcp_servers.\(server).command=\"/usr/bin/true\""] }
                arguments += ["-c", "mcp_servers.\(server).enabled=false"]
            }
        }
        return arguments
    }

    public func useSkill(_ name: String) -> String {
        let candidates = ["~/.codex/skills", "~/.agents/skills", "~/.claude/skills"].map { NSString(string: "\($0)/\(name)/SKILL.md").expandingTildeInPath }
        let file = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
        return "the \(name) skill (read its instructions in \(file) and the files it points to, and follow them)"
    }

    public func run(_ prompt: String) async throws -> String {
        try await call(prompt, schema: nil)
    }

    public func structured(_ prompt: String, schema: [String: Any], kind: String) async throws -> String {
        try await call(prompt, schema: schema)
    }

    private func call(_ prompt: String, schema: [String: Any]?) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDictation-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let answerFile = folder.appendingPathComponent("answer.txt")
        // No computer use, no app connectors, no web search: only the MCP tools given.
        var arguments = ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-rules", "--sandbox", "read-only", "--color", "never",
                         "--disable", "computer_use", "--disable", "apps", "-c", "web_search=\"disabled\"",
                         "-c", "model_reasoning_effort=\"\(effort == .max ? "xhigh" : effort.rawValue)\"", "-o", answerFile.path]
        if !model.isEmpty { arguments += ["-m", model] }
        if let schema {
            let schemaFile = folder.appendingPathComponent("schema.json")
            try JSONSerialization.data(withJSONObject: CodexCLI.strict(schema), options: [.sortedKeys]).write(to: schemaFile)
            arguments += ["--output-schema", schemaFile.path]
        }
        arguments += configArguments()
        _ = try await runner.run(path, arguments: arguments + [prompt], timeout: timeout)
        guard let data = try? Data(contentsOf: answerFile) else { throw ClaudeCLI.Failure.unreadable }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeCLI.Failure.unreadable }
        return text
    }
}
