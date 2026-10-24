@testable import DictationCore
import Foundation
import Testing

struct AssistantUsageTests {
    @Test func serverNames() {
        #expect(AssistantUsage.server(of: "mcp__servicedesk__sd_search") == "servicedesk")
        #expect(AssistantUsage.server(of: "mcp__claude_ai_Microsoft_365__outlook_calendar_search") == "Microsoft 365")
        #expect(AssistantUsage.server(of: "mcp__polarion-api__search_polarion_docs") == "polarion-api")
        #expect(AssistantUsage.server(of: "WebSearch") == "Web")
        #expect(AssistantUsage.server(of: "Read") == nil)
    }

    @Test func totals() {
        let stats = AssistantStats([
            AssistantUsage(steps: ["agent"], tools: ["mcp__servicedesk__sd_queue", "mcp__servicedesk__sd_ticket", "Read"], seconds: 20),
            AssistantUsage(steps: ["agent"], tools: ["WebSearch"], seconds: 30),
            AssistantUsage(steps: ["open_url"], opened: ["Spotify"], seconds: 2),
            AssistantUsage(steps: ["open_app"], opened: ["Spotify"]),
            AssistantUsage(steps: ["awork_call"]),
        ])
        #expect(stats.requests == 5)
        #expect(stats.toolCalls == 3)
        #expect(stats.quickOpens == 2)
        #expect(stats.servers.first == AssistantStats.Count(name: "servicedesk", count: 2))
        #expect(stats.opened == [AssistantStats.Count(name: "Spotify", count: 2)])
        #expect(stats.kinds.first == AssistantStats.Count(name: "Questions", count: 2))
    }

    @Test func appendAndLoad() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        AssistantUsage.append(AssistantUsage(steps: ["agent"], tools: ["WebFetch"]), to: file)
        AssistantUsage.append(AssistantUsage(steps: ["open_url"], opened: ["github.com"]), to: file)
        #expect(AssistantUsage.load(from: file).map(\.steps) == [["agent"], ["open_url"]])
    }
}
