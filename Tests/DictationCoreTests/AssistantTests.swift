import Foundation
import Testing
@testable import DictationCore

private struct PlanCompleter: ChatCompleter {
    let reply: String
    func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String { reply }
}

struct AssistantTests {
    let places = [Place(name: "staging", aliases: ["stage"], url: "https://staging.example.com/polarion"),
                  Place(name: "qa-central", aliases: ["qa central"], url: "https://central.example.com")]

    @Test func simpleOpeningNeedsNoModel() {
        let plan = AssistantPlanner.quickPlan("Öffne mal stage.", places: places)
        #expect(plan?.actions.first?.url == "https://staging.example.com/polarion")
        #expect(AssistantPlanner.quickPlan("open qa central please", places: places)?.actions.first?.url == "https://central.example.com")
        #expect(AssistantPlanner.quickPlan("Öffne staging und leg eine Aufgabe an", places: places) == nil)
        #expect(AssistantPlanner.quickPlan("Wie spät ist es?", places: places) == nil)
    }

    @Test func modelPlansAreRead() async throws {
        let reply = #"{"summary":"Aufgabe in awork anlegen","actions":[{"type":"awork_task","title":"Aufgabe in Fabrikam","url":"","app":"","note":"","projectId":"p1","projectName":"Fabrikam","taskName":"Release Notes prüfen","due":"2026-10-23","prompt":"","answer":""}]}"#
        let plan = try await AssistantPlanner(completer: PlanCompleter(reply: reply)).plan("leg bei fabrikam eine aufgabe an", context: AssistantContext())
        #expect(plan.actions.first?.kind == .aworkTask)
        #expect(plan.actions.first?.isInstant == false)
        #expect(!plan.isOnlyAnswer)
    }

    @Test func contextReachesThePrompt() {
        let prompt = AssistantPlanner.system(context: AssistantContext(places: places, projects: [("p1", "Fabrikam Release", "Fabrikam")],
                                                                       agentTools: ["mcp__polarion-api"]))
        #expect(prompt.contains("staging (also: stage): https://staging.example.com/polarion"))
        #expect(prompt.contains("p1: Fabrikam Release (Fabrikam)"))
        #expect(prompt.contains("polarion-api: Polarion documentation"))
    }

    @Test func agentGetsOnlyTheAllowedTools() {
        let agent = ClaudeAgent(path: "/bin/claude", tools: ["mcp__polarion-api", "mcp__claude_ai_Microsoft_365"])
        let arguments = agent.arguments("Welches Makro?")
        #expect(Array(arguments.drop { $0 != "--tools" }.prefix(2)) == ["--tools", ""])
        #expect(Array(arguments.drop { $0 != "--allowedTools" }.prefix(2)) == ["--allowedTools", "mcp__polarion-api mcp__claude_ai_Microsoft_365"])
    }
}

struct ClaudeServerScopeTests {
    let config = Data("""
    {"mcpServers": {"polarion-api": {"type": "http", "url": "https://rag.example.com/mcp"},
                    "awork": {"type": "http", "url": "https://awork.example.com/mcp"},
                    "servicedesk": {"type": "stdio", "command": "node"},
                    "vercel": {"type": "http", "url": "https://vercel.example.com/mcp"}},
     "projects": {"/work": {"mcpServers": {"local-tool": {"type": "stdio", "command": "tool"}}}}}
    """.utf8)

    func scope() throws -> ClaudeServerScope {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("claude.json")
        try config.write(to: file)
        return ClaudeServerScope(config: file, directory: directory)
    }

    @Test func onlyServersOfTheAllowedToolsAreKept() {
        let tools = ["mcp__polarion-api", "mcp__servicedesk", "mcp__awork__awork_query", "mcp__claude_ai_Microsoft_365"]
        #expect(Set(ClaudeServerScope.servers(for: tools, config: config, directory: "/").keys) == ["polarion-api", "servicedesk", "awork"])
        #expect(ClaudeServerScope.servers(for: ["mcp__awork_extra"], config: config, directory: "/").isEmpty)
        #expect(Set(ClaudeServerScope.servers(for: ["mcp__local-tool"], config: config, directory: "/work").keys) == ["local-tool"])
    }

    @Test func fileHoldsOnlyTheChosenServersAndOnlyTheUserReadsIt() throws {
        let scope = try scope()
        let path = try #require(scope.file(for: ["mcp__servicedesk", "mcp__awork__awork_query"]))
        #expect(path.hasSuffix("claude-mcp-awork+servicedesk.json"))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        #expect(Set((written?["mcpServers"] as? [String: Any] ?? [:]).keys) == ["awork", "servicedesk"])
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func scopedAgentLoadsOnlyItsServers() throws {
        var agent = ClaudeAgent(path: "/bin/claude", tools: ["mcp__servicedesk"])
        agent.builtinTools = ClaudeAgent.webTools
        agent.serverScope = try scope()
        let arguments = agent.arguments("Welche Tickets?")
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(Array(arguments.drop { $0 != "--setting-sources" }.prefix(2)) == ["--setting-sources", ""])
        #expect(arguments.contains("--disable-slash-commands"))
        // Without the user's settings the built-in tools need their own permission.
        #expect(Array(arguments.drop { $0 != "--allowedTools" }.prefix(2)) == ["--allowedTools", "mcp__servicedesk WebSearch WebFetch"])
    }

    @Test func claudeAIConnectorsNeedTheLooseConfigAndSkillsTheSettings() throws {
        var agent = ClaudeAgent(path: "/bin/claude", tools: ["mcp__servicedesk", "mcp__claude_ai_Microsoft_365"])
        agent.serverScope = try scope()
        #expect(!agent.arguments("Termine?").contains("--strict-mcp-config"))

        var skill = ClaudeAgent(path: "/bin/claude", tools: ["mcp__polarion-openapi"])
        skill.builtinTools = ["Skill", "Read"]
        skill.mcpConfig = "/own/polarion.json"
        skill.serverScope = try scope()
        let arguments = skill.arguments("Entwurf")
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(!arguments.contains("--setting-sources"))
        #expect(arguments.filter { $0 == "--mcp-config" }.count == 2)
    }
}

struct AssistantConversationTests {
    @Test func soundsAreNoRequest() {
        #expect(TextProcessing.cleanTranscript("*Clap*") == "")
        #expect(TextProcessing.cleanTranscript("*Lachen* Öffne staging.") == "Öffne staging.")
    }

    @Test func earlierTurnsReachThePrompt() {
        var context = AssistantContext()
        context.conversation = [("Leg bei Fabrikam eine Aufgabe an", "Proposed: Aufgabe in awork anlegen")]
        let prompt = AssistantPlanner.system(context: context)
        #expect(prompt.contains("User: Leg bei Fabrikam eine Aufgabe an"))
        #expect(prompt.contains("Assistant: Proposed: Aufgabe in awork anlegen"))
    }
}

struct MCPServerTests {
    @Test func listIsRead() {
        let output = """
        Checking MCP server health…

        claude.ai Microsoft 365: https://microsoft365.mcp.claude.com/mcp - ✔ Connected
        awork: https://api.awork.com/api/v1/mcp (HTTP) - ✔ Connected
        plugin:context-mode:context-mode: node /x/start.mjs - ✔ Connected
        supabase: https://mcp.supabase.com/mcp (HTTP) - ! Needs authentication
        """
        let servers = MCPServer.parseList(output)
        #expect(servers.map(\.name) == ["claude.ai Microsoft 365", "awork", "plugin:context-mode:context-mode", "supabase"])
        #expect(servers[0].toolPrefix == "mcp__claude_ai_Microsoft_365")
        #expect(servers[1].assistantTools == MCPServer.aworkReadTools)
        #expect(servers[2].toolPrefix == "mcp__plugin_context-mode_context-mode")
        #expect(!servers[3].isConnected)
    }

    @Test func readsCodexServerList() throws {
        let output = """
        [{"name": "polarion_api", "enabled": true, "transport": {"type": "stdio", "command": "node"}, "auth_status": "unsupported"},
         {"name": "supabase", "enabled": true, "transport": {"type": "streamable_http", "url": "https://mcp.supabase.com/mcp"}, "auth_status": "not_logged_in"},
         {"name": "code-review", "enabled": false, "transport": {"type": "stdio", "command": "/bin/sh"}}]
        """
        let servers = MCPServer.parseCodexList(Data(output.utf8))
        #expect(servers.map(\.name) == ["polarion_api", "supabase", "code-review"])
        #expect(servers[0].isConnected && servers[0].assistantTools == ["mcp__polarion_api"])
        #expect(servers[1].target == "https://mcp.supabase.com/mcp" && !servers[1].isConnected)
        #expect(!servers[2].isConnected)
        // The Codex agent switches on exactly the server the toggle allowed.
        let agent = CodexAgent(path: "codex", tools: servers[0].assistantTools, servers: ["polarion_api", "supabase"], timeout: 10)
        #expect(agent.configArguments() == ["-c", "mcp_servers.supabase.enabled=false"])
    }
}

struct MarkdownBlockTests {
    @Test func answerBecomesBlocks() {
        let text = """
        ## Überfällig

        | Fällig | Titel | Projekt |
        |---|---|---|
        | 28.08. | Implementierungsunterstützung für das Release | HAM |
        - erster Punkt
        2. zweiter Punkt
        Ein Satz
        geht weiter.
        """
        let blocks = MarkdownBlock.parse(text)
        #expect(blocks.first == .heading("Überfällig"))
        #expect(blocks[1] == .table(header: ["Fällig", "Titel", "Projekt"],
                                    rows: [["28.08.", "Implementierungsunterstützung für das Release", "HAM"]], titleColumn: 1, keyColumn: nil))
        #expect(blocks[2] == .bullet("erster Punkt"))
        #expect(blocks[3] == .numbered(2, "zweiter Punkt"))
        #expect(blocks[4] == .paragraph("Ein Satz geht weiter."))
    }
}

struct AworkChangeTests {
    @Test func onlyWritingCallsOnAworkPaths() {
        #expect(AworkCall(method: "post", path: "timeentries", body: "{}", description: "").isAllowed)
        #expect(!AworkCall(method: "GET", path: "tasks", body: "", description: "").isAllowed)
        #expect(!AworkCall(method: "POST", path: "https://evil.example/x", body: "", description: "").isAllowed)
        #expect(!AworkCall(method: "DELETE", path: "/", body: "", description: "").isAllowed)
    }

    @Test func resolvedCallsBecomeSteps() {
        let step = AssistantAction.aworkCall(AworkCall(method: "post", path: "tasks/1/changestatus", body: #"{"statusId":"2"}"#,
                                                        description: "„Release Notes“ auf Erledigt setzen"))
        #expect(step.kind == .aworkCall)
        #expect(step.method == "POST")
        #expect(step.title == "„Release Notes“ auf Erledigt setzen")
    }

    @Test func plannerStepsWithoutCallFieldsAreRead() throws {
        let json = #"{"type":"awork_change","title":"2 h eintragen","url":"","app":"","note":"","projectId":"","projectName":"","taskName":"","due":"","prompt":"2 h heute","answer":""}"#
        let action = try JSONDecoder().decode(AssistantAction.self, from: Data(json.utf8))
        #expect(action.kind == .aworkChange)
        #expect(action.method.isEmpty)
    }
}

struct PolarionBacklogTests {
    @Test func draftsAreRead() throws {
        let json = #"{"questions":[],"drafts":[{"type":"bug","title":"Links zeigen falsche Revision","descriptionHtml":"<p>x</p>","implements":-1,"source":"Nina prüft den Fehler"}]}"#
        let result = try JSONDecoder().decode(PolarionBacklog.DraftResult.self, from: Data(json.utf8))
        #expect(result.drafts.first?.type == "bug")
        #expect(result.drafts.first?.implements == -1)
    }

    @Test func draftingMayOnlyRead() {
        let shared = PolarionBacklog.Connection.claudeCode
        #expect(!shared.readTools.contains { $0.contains("post") || $0.contains("patch") || $0.contains("delete") })
        #expect(shared.writeTools.allSatisfy { $0.contains("post") || $0.contains("get") })
        #expect(shared.readTools.contains("mcp__polarion-openapi__getProjects"))
        #expect(PolarionBacklog.Connection(server: "https://polarion.example.com", serverName: "polarion-openapi")
            .link(project: "MDX", id: "MDX-12")?.absoluteString == "https://polarion.example.com/polarion/#/project/MDX/workitem?id=MDX-12")
        let own = PolarionBacklog.Connection(server: "https://polarion.example.com/", serverName: "ld-polarion", mcpConfig: "/tmp/x.json")
        #expect(own.writeTools.first == "mcp__ld-polarion__postWorkItems")
        #expect(own.host == "polarion.example.com")
    }
}

struct PolarionProjectSearchTests {
    let projects = [PolarionBacklog.Project(id: "MDX_Backlog", name: "MDX Backlog"),
                    PolarionBacklog.Project(id: "WG_Requirements", name: "Woodgrove Requirements"),
                    PolarionBacklog.Project(id: "novaBacklogTemplate", name: "Northwind Backlog Template")]

    @Test func lettersFindTheProject() {
        #expect(PolarionBacklog.search("mdx back", in: projects).first?.id == "MDX_Backlog")
        #expect(PolarionBacklog.search("woodgrove", in: projects).first?.id == "WG_Requirements")
        #expect(PolarionBacklog.search("nvbt", in: projects).first?.id == "novaBacklogTemplate")
        #expect(PolarionBacklog.search("xyz", in: projects).isEmpty)
    }
}

struct ToolListTests {
    @Test func serversAreListedOnceWithWhatTheyAreFor() {
        let list = AssistantPlanner.toolList(["mcp__servicedesk", "mcp__awork__awork_query", "mcp__awork__find_capability", "mcp__other"])
        #expect(list.components(separatedBy: "\n").count == 3)
        #expect(list.contains("servicedesk: Servicedesk tickets"))
        #expect(list.contains("other: MCP server other"))
    }
}

struct CardTableTests {
    @Test func titleColumnByNameAndTicketKeyInFront() {
        let text = """
        | Ticket | Title | Last update |
        |---|---|---|
        | AVA004919 | Rendering Problem | 07.10.2026: you sent the revised widget to the customer |
        """
        #expect(MarkdownBlock.parse(text) == [.table(header: ["Ticket", "Title", "Last update"],
                                                    rows: [["AVA004919", "Rendering Problem", "07.10.2026: you sent the revised widget to the customer"]],
                                                    titleColumn: 1, keyColumn: 0)])
    }

    @Test func fieldValueTableBecomesLines() {
        let text = """
        | Field | Detail |
        |---|---|
        | Status | In Bearbeitung |
        | Queue | Servicedesk |
        """
        #expect(MarkdownBlock.parse(text) == [.fields([["Status", "In Bearbeitung"], ["Queue", "Servicedesk"]])])
    }
}

struct PolarionDescriptionTests {
    @Test func editedTextBecomesHTML() {
        let text = "As a consultant I need the training done.\n\nAcceptance criteria\n• Training shown as completed\n• Account still enabled & usable"
        #expect(PolarionBacklog.html(fromText: text)
                == "<p>As a consultant I need the training done.</p><p><b>Acceptance criteria</b></p><ul><li>Training shown as completed</li><li>Account still enabled &amp; usable</li></ul>")
    }
}
