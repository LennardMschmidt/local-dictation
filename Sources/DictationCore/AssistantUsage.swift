import Foundation

/// One assistant request that ran: its steps, the tools Claude Code called and what was opened.
/// Kept in `assistant-usage.jsonl` for the Insights page; the request text is not stored.
public struct AssistantUsage: Codable, Equatable, Sendable {
    public var date: Date
    /// Step types as the planner names them: "agent", "open_url", "awork_task", …
    public var steps: [String]
    /// Tool names in the order Claude Code called them ("mcp__servicedesk__sd_search", "WebSearch").
    public var tools: [String]
    /// What a quick open started: an app ("Spotify") or a site ("github.com").
    public var opened: [String]
    public var seconds: Double

    public init(date: Date = Date(), steps: [String], tools: [String] = [], opened: [String] = [], seconds: Double = 0) {
        self.date = date
        self.steps = steps
        self.tools = tools
        self.opened = opened
        self.seconds = seconds
    }

    public static var file: URL { AppPaths.supportDirectory.appendingPathComponent("assistant-usage.jsonl") }

    public static func append(_ usage: AssistantUsage, to file: URL = file) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(usage) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: file)
        }
    }

    public static func load(from file: URL = file) -> [AssistantUsage] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(AssistantUsage.self, from: Data($0.utf8)) }
    }

    /// The server a tool belongs to, as the MCP page names it: "mcp__servicedesk__sd_search" is
    /// "servicedesk", "mcp__claude_ai_Microsoft_365__outlook_calendar_search" is "Microsoft 365";
    /// WebSearch and WebFetch are "Web"; other built-in tools nil.
    public static func server(of tool: String) -> String? {
        if tool == "WebSearch" || tool == "WebFetch" { return "Web" }
        guard tool.hasPrefix("mcp__") else { return nil }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        guard var name = parts.first, !name.isEmpty else { return nil }
        if name.hasPrefix("claude_ai_") { name = String(name.dropFirst("claude_ai_".count)) }
        return name.replacingOccurrences(of: "_", with: " ")
    }
}

/// Totals over the usage log for the Insights page.
public struct AssistantStats: Sendable {
    public struct Count: Sendable, Equatable {
        public let name: String
        public let count: Int
    }

    public let requests: Int
    /// Calls to MCP servers and the web, without other built-in tools.
    public let toolCalls: Int
    public let quickOpens: Int
    public let averageSeconds: Double
    /// Calls per server, most first.
    public let servers: [Count]
    /// What was opened, most first.
    public let opened: [Count]
    /// Requests per kind: questions, quick opens, awork, plain answers.
    public let kinds: [Count]
    public let since: Date?

    public init(_ log: [AssistantUsage]) {
        requests = log.count
        let serverNames = log.flatMap(\.tools).compactMap(AssistantUsage.server(of:))
        toolCalls = serverNames.count
        quickOpens = log.reduce(0) { $0 + $1.opened.count }
        averageSeconds = log.isEmpty ? 0 : log.reduce(0) { $0 + $1.seconds } / Double(log.count)
        servers = Self.ranked(serverNames)
        opened = Self.ranked(log.flatMap(\.opened))
        kinds = Self.ranked(log.map { Self.kind(of: $0.steps) })
        since = log.map(\.date).min()
    }

    /// The kind a request counts as, by its main step.
    static func kind(of steps: [String]) -> String {
        if steps.contains("agent") { return "Questions" }
        if steps.contains(where: { $0.hasPrefix("awork") }) { return "awork changes" }
        if steps.contains(where: { $0.hasPrefix("open") }) { return "Quick opens" }
        return "Direct answers"
    }

    static func ranked(_ names: [String]) -> [Count] {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return counts.map { Count(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
}
