import DictationCore
import Foundation

/// The connections behind Polarion and awork, as chosen in Settings › Connectors.
///
/// Polarion's own connection starts the same REST MCP server program as Claude Code's
/// `polarion-openapi`, under the name `ld-polarion`, with the server and PAT from the settings.
/// Its definition, PAT included, is written to `polarion-mcp.json` (mode 600, Application
/// Support) and handed to Claude Code with `--mcp-config`, so the PAT is never on a command line.
enum Connectors {
    static let ownServerName = "ld-polarion"
    static var polarionCredentials: URL { AppPaths.supportDirectory.appendingPathComponent("polarion-credentials.json") }
    static var polarionConfig: URL { AppPaths.supportDirectory.appendingPathComponent("polarion-mcp.json") }

    // MARK: Polarion

    static var hasPolarionToken: Bool { polarionToken() != nil }

    static func polarionToken() -> String? {
        guard let data = try? Data(contentsOf: polarionCredentials),
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              let token = values["pat"], !token.isEmpty else { return nil }
        return token
    }

    static func setPolarionToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: polarionCredentials)
            try? FileManager.default.removeItem(at: polarionConfig)
            return
        }
        guard let data = try? JSONEncoder().encode(["pat": trimmed]) else { return }
        CredentialFile.writePrivate(data, to: polarionCredentials)
    }

    /// The connection for drafting and creating backlog items.
    static func polarion(_ settings: ConnectorSettings) throws -> PolarionBacklog.Connection {
        if DemoMode.isOn { return PolarionBacklog.Connection(server: DemoMode.polarionServer, serverName: "polarion-openapi") }
        guard settings.polarionSource == .own else {
            return PolarionBacklog.Connection(server: claudeCodePolarionServer ?? PolarionBacklog.Connection.claudeCode.server,
                                              serverName: "polarion-openapi")
        }
        guard let token = polarionToken() else { throw ConnectorError.missing("Polarion PAT (Settings › Connectors)") }
        let server = settings.polarionServer.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard URL(string: server)?.host != nil else { throw ConnectorError.missing("Polarion server address (Settings › Connectors)") }
        let program = NSString(string: settings.polarionProgram).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: program) else { throw ConnectorError.missing("Polarion MCP program at \(program)") }
        guard let node = nodePath else { throw ConnectorError.missing("Node.js (node)") }
        let config: [String: Any] = ["mcpServers": [ownServerName: [
            "type": "stdio", "command": node, "args": [program],
            "env": ["API_BASE_URL": server + "/polarion/rest/v1", "BEARER_TOKEN": token],
        ]]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        // Views ask for the connection often; the file is only written when it changes.
        if (try? Data(contentsOf: polarionConfig)) != data { CredentialFile.writePrivate(data, to: polarionConfig) }
        return PolarionBacklog.Connection(server: server, serverName: ownServerName, mcpConfig: polarionConfig.path)
    }

    static var nodePath: String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The server Claude Code's `polarion-openapi` points to, from `claude mcp get`; only the
    /// API_BASE_URL line is kept, the rest of the output is dropped.
    nonisolated(unsafe) static var claudeCodePolarionServer: String? = DemoMode.isOn ? DemoMode.polarionServer : nil

    static func detectClaudeCodePolarionServer(claudePath: String) async {
        guard !DemoMode.isOn else { return }
        let output = (try? await ProcessRunner().run(claudePath, arguments: ["mcp", "get", "polarion-openapi"], timeout: 30))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard let line = output.split(separator: "\n").first(where: { $0.contains("API_BASE_URL=") }),
              let value = line.split(separator: "=", maxSplits: 1).last else { return }
        let url = String(value).trimmingCharacters(in: .whitespaces)
        claudeCodePolarionServer = url.components(separatedBy: "/polarion").first
    }

    // MARK: awork

    /// Sets the awork transport: the own API client, or the awork MCP through Claude Code.
    static func applyAwork(_ settings: DictationSettings) async {
        guard !DemoMode.isOn, settings.connectors.aworkViaMCP, let path = ClaudeCLI.locate(custom: settings.ai.claudePath) else {
            await AworkClient.shared.useMCP(nil)
            return
        }
        var agent = ClaudeAgent(path: path, model: .haiku, effort: .low, tools: AworkClient.mcpTools, timeout: 180)
        agent.usesSpare = true
        agent.serverScope = .user
        await AworkClient.shared.useMCP(agent)
    }
}

enum ConnectorError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case .missing(let what): return "Missing: \(what)."
        }
    }
}
