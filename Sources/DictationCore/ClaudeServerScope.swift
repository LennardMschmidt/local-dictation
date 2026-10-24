import Foundation

/// The MCP servers a Claude Code call loads. Without a scope Claude Code starts every server,
/// plugin and skill of the user's setup and puts all their tool definitions into each prompt,
/// also those the call may not use; with one it gets only the servers whose tools it may call.
public struct ClaudeServerScope: Sendable {
    /// Claude Code's configuration, `~/.claude.json`.
    public var config: URL
    /// Where the file with the chosen servers is written.
    public var directory: URL

    public init(config: URL, directory: URL) {
        self.config = config
        self.directory = directory
    }

    /// The user's Claude Code configuration, with the chosen servers next to the app's settings.
    public static var user: ClaudeServerScope {
        ClaudeServerScope(config: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json"),
                          directory: AppPaths.supportDirectory)
    }

    /// The entries of `mcpServers` in Claude Code's configuration whose tools are among `tools`:
    /// the user's servers and those of the project `directory`, which win on equal names.
    public static func servers(for tools: [String], config: Data, directory: String) -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: config) as? [String: Any] else { return [:] }
        var all = root["mcpServers"] as? [String: Any] ?? [:]
        if let project = (root["projects"] as? [String: Any])?[directory] as? [String: Any],
           let servers = project["mcpServers"] as? [String: Any] {
            all.merge(servers) { _, project in project }
        }
        return all.filter { name, _ in
            let prefix = MCPServer(name: name, target: "", status: "").toolPrefix
            return tools.contains { $0 == prefix || $0.hasPrefix(prefix + "__") }
        }
    }

    /// Whether `tools` include a claude.ai connector. Those come with the Claude login and cannot
    /// be chosen one by one: either all of them load or none.
    public static func usesClaudeAI(_ tools: [String]) -> Bool {
        tools.contains { $0.hasPrefix("mcp__claude_ai_") }
    }

    /// Writes the servers for `tools` into a file only the user can read and returns its path,
    /// or nil when Claude Code's configuration cannot be read. The file is named after the
    /// servers, so a started process keeps its servers when the choice changes, and it is only
    /// written when its content changes.
    public func file(for tools: [String]) -> String? {
        guard let data = try? Data(contentsOf: config) else { return nil }
        let servers = Self.servers(for: tools, config: data, directory: FileManager.default.currentDirectoryPath)
        guard let json = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys]) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let names = servers.keys.sorted().map { String($0.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }) }
        let url = directory.appendingPathComponent("claude-mcp-\(names.isEmpty ? "none" : names.joined(separator: "+")).json")
        if (try? Data(contentsOf: url)) != json {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: json, attributes: [.posixPermissions: 0o600]) else { return nil }
        }
        return url.path
    }
}
