import Foundation

/// Demo mode: the app runs on invented data and reaches no company system. awork, the Polarion
/// backlog, the calendar and the assistant's agent answer from the fixtures below; dictation,
/// speech recognition and the local language model work as always.
///
/// Switched on with the environment variable `DEMO_MODE=1` or the argument `--demo`. The app then
/// keeps its files in "LocalDictation Demo" instead of "LocalDictation", so a demo never reads or
/// changes the settings, history or meetings of normal use.
public enum DemoMode {
    public static let isOn: Bool = {
        let value = (ProcessInfo.processInfo.environment["DEMO_MODE"] ?? "").lowercased()
        return ["1", "true", "yes", "on"].contains(value) || CommandLine.arguments.contains("--demo")
    }()

    /// The invented company the demo user works for, and its mail domain.
    public static let company = "Northwind Consulting"
    public static let ownDomain = "northwind.example"
    public static let userName = "Jonas Weber"

    /// The user's full name: the macOS account's, or the invented one in demo mode.
    public static var fullUserName: String { isOn ? userName : NSFullUserName() }

    /// What `claude mcp list` prints in demo mode.
    public static let mcpList = """
    polarion-api: https://polarion-docs.example.com/mcp (HTTP) - ✔ Connected
    awork: https://api.awork.com/api/v1/mcp (HTTP) - ✔ Connected
    servicedesk: node servicedesk-mcp/build/index.js - ✔ Connected
    claude.ai Microsoft 365: https://microsoft365.mcp.claude.com/mcp - ✔ Connected
    """
    public static let aworkWorkspace = "https://northwind.awork.example"
    public static let polarionServer = "https://polarion.northwind.example"

    /// Customer mail domains and the vault note each one belongs to.
    public static let customerMap = [
        "fabrikam-diagnostics.example": "Fabrikam",
        "litware.example": "Litware",
        "tailspin.example": "Tailspin",
    ]

    /// Waits a little, so demo answers arrive like real ones and the progress states are visible.
    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The next Friday after `date`, as YYYY-MM-DD.
    static func nextFriday(after date: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let next = calendar.nextDate(after: date, matching: DateComponents(weekday: 6), matchingPolicy: .nextTime) ?? date
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: next)
    }
}

// MARK: - awork

/// The awork API as the demo sees it: a handful of projects, people and tasks in memory. Answers
/// the same paths and JSON shapes the real API does, so `AworkClient` reads them unchanged.
public actor DemoAwork {
    public static let shared = DemoAwork()

    struct Project {
        let id, name, key, company: String
    }

    let me = ["id": "u-jonas", "firstName": "Jonas", "lastName": "Weber"]
    let people: [[String: String]] = [
        ["id": "u-jonas", "firstName": "Jonas", "lastName": "Weber"],
        ["id": "u-mia", "firstName": "Mia", "lastName": "Keller"],
        ["id": "u-paul", "firstName": "Paul", "lastName": "Braun"],
        ["id": "u-lea", "firstName": "Lea", "lastName": "Fischer"],
        ["id": "u-sara", "firstName": "Sara", "lastName": "Wolf"],
        ["id": "u-tim", "firstName": "Tim", "lastName": "Hoffmann"],
    ]
    let projects = [
        Project(id: "p-release", name: "[NW] Release 2.4", key: "NWR", company: "Northwind Medical"),
        Project(id: "p-internal", name: "[NW] Interne Aufgaben", key: "NWI", company: "Northwind Consulting GmbH"),
        Project(id: "p-fabrikam", name: "[FB] Fabrikam Validierung", key: "FBV", company: "Fabrikam Diagnostics"),
        Project(id: "p-litware", name: "[LW] Continuous development", key: "LWC", company: "Litware Devices"),
        Project(id: "p-tailspin", name: "[TS] Tailspin Continuous Support", key: "TSCS", company: "Tailspin Optics GmbH"),
    ]
    private var tasks: [String: [(id: String, name: String, identifier: String)]] = [
        "p-release": [("t-1", "Release Notes", "NWR-12"), ("t-2", "Regressionstests", "NWR-13"), ("t-3", "Abnahme beim Kunden", "NWR-14")],
        "p-internal": [("t-4", "Weiterbildung", "NWI-3"), ("t-5", "Template-Pflege", "NWI-7")],
        "p-fabrikam": [("t-6", "Validierungsplan", "FBV-21"), ("t-7", "Risk Suite Update", "FBV-22")],
        "p-litware": [("t-8", "Plugin Updates", "LWC-40"), ("t-9", "Core Update vorbereiten", "LWC-41")],
        "p-tailspin": [("t-10", "Support Q4", "TSCS-8")],
    ]
    private var created = 0

    /// The answer to one API call; `path` is relative to the API root and may carry a query.
    public func answer(method: String, path: String, body: Any?) async throws -> Any? {
        await DemoMode.pause(method == "GET" ? 0.3 : 0.6)
        let route = path.split(separator: "?").first.map(String.init) ?? path
        let page = path.contains("page=") && !path.contains("page=1") ? 2 : 1
        let parts = route.split(separator: "/").map(String.init)
        switch (method.uppercased(), parts.first ?? "") {
        case ("GET", "users") where parts.count == 2 && parts[1] == "me":
            return me
        case ("GET", "users"):
            return page == 1 ? people : []
        case ("GET", "projects") where parts.count == 1:
            return page == 1 ? projects.map { project in
                ["id": project.id, "name": project.name, "projectKey": project.key,
                 "company": ["name": project.company], "projectStatus": ["type": "progress"]] as [String: Any]
            } : []
        case ("GET", "projects") where parts.count == 3 && parts[2] == "projecttasks":
            guard page == 1 else { return [] }
            return (tasks[parts[1]] ?? []).map { ["id": $0.id, "name": $0.name, "taskIdentifier": $0.identifier] }
        case ("POST", "tasks") where parts.count == 1:
            let fields = body as? [String: Any] ?? [:]
            let project = fields["entityId"] as? String ?? "p-internal"
            let key = projects.first { $0.id == project }?.key ?? "NW"
            created += 1
            let task = (id: "demo-\(created)", name: fields["name"] as? String ?? "Task", identifier: "\(key)-\(100 + created)")
            if fields["parentId"] == nil { tasks[project, default: []].append(task) }
            return ["id": task.id, "taskIdentifier": task.identifier]
        default:
            // Assignments, status changes, time entries: accepted and forgotten.
            return method.uppercased() == "GET" ? [] : [String: Any]()
        }
    }
}

// MARK: - Agent

/// Stands in for Claude Code or Codex with their MCP servers: questions get invented answers,
/// the Polarion backlog gets a project list, drafts made from the action items and made-up ids.
public struct DemoAgent: ToolAgent {
    public init() {}

    public func run(_ prompt: String) async throws -> String {
        try await runWithTools(prompt).answer
    }

    public func runWithTools(_ prompt: String) async throws -> (answer: String, tools: [String]) {
        await DemoMode.pause(1.5)
        return Self.answer(to: prompt)
    }

    public func structured(_ prompt: String, schema: [String: Any], kind: String) async throws -> String {
        await DemoMode.pause(1.2)
        let required = Set(schema["required"] as? [String] ?? [])
        let object: [String: Any]
        if required == ["projects"] {
            object = ["projects": Self.polarionProjects.map { ["id": $0.id, "name": $0.name] }]
        } else if required.contains("drafts") {
            object = ["questions": [String](), "drafts": Self.drafts(from: prompt)]
        } else if required.contains("created") {
            object = ["created": Self.created(from: prompt), "problems": [String]()]
        } else if required.contains("calls") {
            object = ["question": "In the demo, awork changes other than new tasks are only shown, not prepared.", "calls": [Any]()]
        } else {
            object = [:]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public func useSkill(_ name: String) -> String { "the \(name) skill" }

    static let polarionProjects = [
        (id: "NW_Backlog", name: "Northwind Backlog"),
        (id: "NW_InfusionPump", name: "Infusion Pump"),
        (id: "FB_Validation", name: "Fabrikam Validation"),
        (id: "LW_Requirements", name: "Litware Requirements"),
    ]

    /// One stakeholder requirement per action item listed under "Action items:" in the prompt.
    static func drafts(from prompt: String) -> [[String: Any]] {
        let items = section(of: prompt, after: "Action items:").compactMap { line -> String? in
            line.hasPrefix("- ") ? String(line.dropFirst(2)) : nil
        }
        return items.map { item in
            ["type": "stakeholderRequirement", "title": item, "implements": -1, "source": item,
             "descriptionHtml": "<p>As a quality manager I need this so the infusion pump file stays complete: \(escape(item))</p>"
                + "<p><b>Acceptance criteria</b></p><ul><li>The result is documented in the project.</li></ul>"]
        }
    }

    /// Made-up ids for the approved drafts, which the prompt lists as JSON.
    static func created(from prompt: String) -> [[String: String]] {
        guard let start = prompt.range(of: "Items as JSON (index = position in the list):\n"),
              let end = prompt.range(of: "\n\nReturn", range: start.upperBound..<prompt.endIndex),
              let list = try? JSONSerialization.jsonObject(with: Data(prompt[start.upperBound..<end.lowerBound].utf8)) as? [[String: Any]]
        else { return [] }
        return list.enumerated().map { index, draft in
            ["title": draft["title"] as? String ?? "Item", "id": "NW-\(231 + index)"]
        }
    }

    private static func section(of text: String, after marker: String) -> [String] {
        guard let range = text.range(of: marker) else { return [] }
        var lines: [String] = []
        for line in text[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            lines.append(line.trimmingCharacters(in: .whitespaces))
        }
        return lines
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A Markdown answer that fits the question, and the tools a real agent would have called.
    static func answer(to prompt: String) -> (answer: String, tools: [String]) {
        let text = prompt.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("ticket", "servicedesk", "support case") {
            return ("""
            Two tickets came in today, both are waiting for you.

            | Ticket | Title | Customer | Status |
            |---|---|---|---|
            | SD-1042 | PDF export cuts off wide tables | Northwind Medical | Waiting for you |
            | SD-1038 | SSO login fails after the update | Fabrikam Diagnostics | Waiting for you |

            - SD-1042 escalates today at 16:00.
            """, ["mcp__servicedesk__sd_queue", "mcp__servicedesk__sd_ticket", "mcp__servicedesk__sd_ticket"])
        }
        if has("awork", "aufgabe", "task", "fällig", "due") {
            return ("""
            Three tasks are due this week.

            | Due | Title | Project | Status |
            |---|---|---|---|
            | Thu | Release Notes | [NW] Release 2.4 | In Progress |
            | Fri | Regressionstests | [NW] Release 2.4 | To Do |
            | Fri | Validierungsplan | [FB] Fabrikam Validierung | To Do |
            """, ["mcp__awork__awork_query"])
        }
        if has("kalender", "calendar", "termin", "meeting", "heute", "today") {
            return ("""
            You have three meetings left today.

            | Time | Title | Place |
            |---|---|---|
            | 10:00 | Release 2.4 Sync | Teams |
            | 13:30 | Fabrikam Weekly | Teams |
            | 16:00 | Risk Suite Review | Room 2 |
            """, ["mcp__claude_ai_Microsoft_365__outlook_calendar_search"])
        }
        if has("polarion", "velocity", "macro", "makro", "livedoc", "work item") {
            return ("""
            The trace table is built by the **reportingMacros** library with `#traceTable($items)`; the columns come from the second parameter.

            - Each column is a field id, such as `status` or `severity`.
            - Links are followed with the role you pass as the third parameter.
            """, ["mcp__polarion-api__search_polarion_api"])
        }
        return ("""
        This is the demo, so the answer is invented. The real app hands the question to Claude Code or Codex, \
        with web search and the tool servers set up there, and shows the answer here.
        """, ["WebSearch"])
    }
}

// MARK: - Planner

/// Plans assistant requests without a model: "create a task …" becomes an awork task in the
/// release project, everything else a question for `DemoAgent`. Opening a place by name is
/// handled before, by `AssistantPlanner.quickPlan`.
public struct DemoPlanner: ChatCompleter {
    public init() {}

    public func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String {
        await DemoMode.pause(0.8)
        let content = messages.last { $0.role == "user" }?.content ?? ""
        let request = content.replacingOccurrences(of: "<request>", with: "").replacingOccurrences(of: "</request>", with: "")
        let plan = Self.plan(request)
        let data = try JSONEncoder().encode(plan)
        return String(decoding: data, as: UTF8.self)
    }

    public static func plan(_ request: String) -> AssistantPlan {
        let lower = request.lowercased()
        let wantsTask = (lower.contains("aufgabe") || lower.contains("task"))
            && ["leg", "anlegen", "create", "erstell", "add", "neue"].contains { lower.contains($0) }
        guard wantsTask else {
            return AssistantPlan(summary: "Ask Claude", actions: [AssistantAction(type: .agent, title: "Ask Claude: \(request)", prompt: request)])
        }
        var name = "Release Notes prüfen"
        if let colon = request.firstIndex(of: ":") {
            let rest = request[request.index(after: colon)...]
            let first = rest.split(whereSeparator: { ",.".contains($0) }).first.map(String.init) ?? ""
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { name = trimmed.prefix(1).uppercased() + trimmed.dropFirst() }
        }
        let due = lower.contains("freitag") || lower.contains("friday") ? DemoMode.nextFriday() : ""
        let title = "„\(name)“ in [NW] Release 2.4" + (due.isEmpty ? "" : ", due \(due)")
        return AssistantPlan(summary: "Create an awork task", actions: [
            AssistantAction(type: .aworkTask, title: title, projectId: "p-release", projectName: "[NW] Release 2.4",
                            taskName: name, due: due),
        ])
    }
}
