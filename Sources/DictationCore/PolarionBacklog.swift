import Foundation

/// Backlog items for Polarion from a meeting's action items, written by Claude Code with the
/// `polarion-requirements` skill against the server of a `Connection`. Two separate calls: drafting
/// may only read Polarion; creating may only post the drafts the user approved, and verify them.
public enum PolarionBacklog {
    /// The Polarion REST MCP server Claude Code uses and the Polarion server behind it.
    public struct Connection: Equatable, Sendable {
        /// The server's address without a path, such as "https://polarion.example.com".
        public var server: String
        /// The MCP server's name: "polarion-openapi" as configured in Claude Code, or the app's own.
        public var serverName: String
        /// The `--mcp-config` file that defines the app's own server; nil for Claude Code's.
        public var mcpConfig: String?

        public init(server: String, serverName: String, mcpConfig: String? = nil) {
            self.server = server.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            self.serverName = serverName
            self.mcpConfig = mcpConfig
        }

        /// Claude Code's `polarion-openapi`. Its server is read from Claude Code's configuration
        /// (`claude mcp get`), so the address here is empty.
        public static let claudeCode = Connection(server: "", serverName: "polarion-openapi")

        var prefix: String { "mcp__\(serverName)__" }

        /// Reading tools: the hosted docs search and the GET operations of the Polarion REST
        /// server, plus the built-in Skill and Read tools so the skill and its references load.
        public var readTools: [String] {
            ["mcp__polarion-api"] + ["getProject", "getProjects", "getWorkItem", "getWorkItems", "getAllWorkItems",
                                     "getLinkedWorkItems", "getAvailableEnumOptionsForWorkItemType",
                                     "getAvailableEnumOptionsForWorkItem", "getProjectEnumeration", "getGlobalEnumeration",
                                     "getDocument", "getDocumentParts", "getPage"].map { prefix + $0 }
                + ["Skill", "Read", "Grep", "Glob"]
        }

        public var projectsTool: String { prefix + "getProjects" }

        /// Creating: posting work items and links, and reading them back.
        public var writeTools: [String] {
            ["postWorkItems", "postLinkedWorkItems", "getWorkItem", "getLinkedWorkItems",
             "getAvailableEnumOptionsForWorkItemType"].map { prefix + $0 }
        }

        public func link(project: String, id: String) -> URL? {
            URL(string: "\(server)/polarion/#/project/\(project)/workitem?id=\(id)")
        }

        /// The host for the user, "polarion.example.com".
        public var host: String { URL(string: server)?.host ?? server }
    }

    /// What kind of items the drafts should become.
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case automatic, requirement, bug
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .automatic: return "Automatisch"
            case .requirement: return "Stakeholder Requirement"
            case .bug: return "Bug"
            }
        }
        var instruction: String {
            switch self {
            case .automatic: return "Choose the item kinds by the skill's Step 3 ladder."
            case .requirement: return "Write stakeholder requirements, and the specifications the ladder asks for."
            case .bug: return "Write bugs/defects (Step 3a)."
            }
        }
    }

    public struct Draft: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID { UUID(uuidString: key) ?? UUID() }
        /// A stable key for the list, set by the app.
        public var key: String = UUID().uuidString
        /// The work item type id, verified as creatable in the project.
        public var type: String
        public var title: String
        public var descriptionHtml: String
        /// The index of the draft this one implements, -1 for none.
        public var implements: Int
        /// The action item it came from.
        public var source: String

        enum CodingKeys: String, CodingKey { case type, title, descriptionHtml, implements, source }

        public init(type: String, title: String, descriptionHtml: String, implements: Int = -1, source: String = "") {
            self.type = type
            self.title = title
            self.descriptionHtml = descriptionHtml
            self.implements = implements
            self.source = source
        }
    }

    public struct DraftResult: Codable, Equatable, Sendable {
        /// Need-level facts that are missing; the drafts wait for the answers.
        public var questions: [String]
        public var drafts: [Draft]
    }

    public struct Created: Codable, Equatable, Sendable {
        public struct Item: Codable, Equatable, Sendable {
            public var title: String
            public var id: String
        }
        public var created: [Item]
        public var problems: [String]
    }

    /// A description edited as text back into HTML for Polarion: paragraphs separated by empty
    /// lines, lines starting with "• " or "- " as a list, and a short line of its own without a
    /// full stop (such as "Acceptance criteria") in bold. Only used when the user changed the text;
    /// an untouched draft keeps Claude's HTML.
    public static func html(fromText text: String) -> String {
        func escape(_ line: String) -> String {
            line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = ""
        var items: [String] = []
        func flushList() {
            if !items.isEmpty { html += "<ul>" + items.map { "<li>\(escape($0))</li>" }.joined() + "</ul>" }
            items = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("• ") || line.hasPrefix("- ") {
                items.append(String(line.dropFirst(2)))
                continue
            }
            flushList()
            guard !line.isEmpty else { continue }
            let heading = line.count <= 40 && !".:!?".contains(line.last ?? ".")
            html += heading ? "<p><b>\(escape(line))</b></p>" : "<p>\(escape(line))</p>"
        }
        flushList()
        return html
    }

    public struct Project: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    static let projectsSchema: [String: Any] = [
        "type": "object",
        "properties": ["projects": ["type": "array", "items": [
            "type": "object", "properties": ["id": ["type": "string"], "name": ["type": "string"]],
            "required": ["id", "name"], "additionalProperties": false,
        ]]],
        "required": ["projects"], "additionalProperties": false,
    ]

    /// Every project on the connection's server the user can see, read with getProjects.
    public static func projects(agent: any ToolAgent, connection: Connection = .claudeCode) async throws -> [Project] {
        struct List: Codable { var projects: [Project] }
        let reply = try await agent.structured("""
        List every Polarion project on \(connection.server) with the tool \(connection.prefix)getProjects. Read all pages (page size 100) until no more come. Return each project's id and name, nothing else.
        """, schema: projectsSchema)
        return try JSONDecoder().decode(List.self, from: Data(reply.utf8)).projects
    }

    /// Projects matching `query` best first: every word of the query must appear in the id or
    /// name, in that order of letters ("mdx bl" finds "MDX_Backlog"); exact starts rank higher.
    public static func search(_ query: String, in projects: [Project]) -> [Project] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return projects }
        func score(_ project: Project) -> Int? {
            let text = (project.id + " " + project.name).lowercased()
            var total = 0
            for word in words {
                if text.hasPrefix(word) { total += 30 }
                else if text.contains(word) { total += 20 }
                else if isSubsequence(word, of: text) { total += 5 }
                else { return nil }
            }
            return total - project.id.count / 10
        }
        return projects.compactMap { project in score(project).map { (project, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func isSubsequence(_ word: String, of text: String) -> Bool {
        var index = text.startIndex
        for character in word {
            guard let found = text[index...].firstIndex(of: character) else { return false }
            index = text.index(after: found)
        }
        return true
    }

    static let draftSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "questions": ["type": "array", "items": ["type": "string"]],
            "drafts": ["type": "array", "items": [
                "type": "object",
                "properties": ["type": ["type": "string"], "title": ["type": "string"], "descriptionHtml": ["type": "string"],
                               "implements": ["type": "integer"], "source": ["type": "string"]],
                "required": ["type", "title", "descriptionHtml", "implements", "source"], "additionalProperties": false,
            ]],
        ],
        "required": ["questions", "drafts"], "additionalProperties": false,
    ]

    static let createdSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "created": ["type": "array", "items": [
                "type": "object", "properties": ["title": ["type": "string"], "id": ["type": "string"]],
                "required": ["title", "id"], "additionalProperties": false,
            ]],
            "problems": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["created", "problems"], "additionalProperties": false,
    ]

    /// Drafts backlog items from `items`, with the meeting's notes as source material. Nothing
    /// is written; missing need-level facts come back as questions.
    public static func draft(items: [String], project: String, kind: Kind, meetingTitle: String, meetingDate: Date,
                             notes: String, context: String, answers: [(question: String, answer: String)],
                             agent: any ToolAgent, connection: Connection = .claudeCode) async throws -> DraftResult {
        let answered = answers.isEmpty ? "" : "\n\nAnswers the user gave to your earlier questions:\n"
            + answers.map { "- \($0.question)\n  \($0.answer)" }.joined(separator: "\n")
        let prompt = """
        Use \(agent.useSkill("polarion-requirements")) to turn these action items from a meeting into backlog items for the Polarion project "\(project)" on the Polarion server \(connection.server).

        You run inside an app without a conversation:
        - Step 0 is answered: target is \(connection.server), project id "\(project)"; the Polarion tools you have (\(connection.prefix)…) are already authenticated, no PAT is needed. Verify the project with a read call.
        - Step 1: the meeting notes and the extra context below are all the material there is. Fill the brief from them. Do not ask about anything you can take from them; ask only for need-level facts that are really missing, as short German questions in "questions", and then return no drafts.
        - Steps 2 to 5: do them (SIM instructions, schema and creatable type ids per rule 8, gold examples, duplicate check, self-check).
        - Do not write anything. The app shows your drafts to the user (Gate 2) and creates them only after approval.
        - \(kind.instruction)

        Return every draft with: "type" (a type id verified as creatable in this project), "title", "descriptionHtml" (the full description in the house HTML style), "implements" (the index in your list of the draft it implements, -1 for none), "source" (the action item it comes from).

        Action items:
        \(items.map { "- \($0)" }.joined(separator: "\n"))

        Meeting: \(meetingTitle), \(meetingDate.formatted(date: .long, time: .shortened))
        Extra context from the user: \(context.isEmpty ? "none" : context)

        Meeting notes:
        \(notes)\(answered)
        """
        let reply = try await agent.structured(prompt, schema: draftSchema)
        return try JSONDecoder().decode(DraftResult.self, from: Data(reply.utf8))
    }

    /// Creates exactly the approved drafts and their links, then reads them back.
    public static func create(_ drafts: [Draft], project: String, agent: any ToolAgent,
                              connection: Connection = .claudeCode) async throws -> Created {
        let list = try String(decoding: JSONEncoder().encode(drafts), as: UTF8.self)
        let prompt = """
        The user approved these backlog items (Gate 2 of the polarion-requirements process). Create exactly them in the Polarion project "\(project)" on \(connection.server) with the tools \(connection.prefix)…, nothing else:
        1. Post each item with its "type", "title" and "descriptionHtml" (description type text/html). Do not set a status, do not change any other item.
        2. For every item with "implements" >= 0, add a linked work item with role "implements" from this item to the item at that index.
        3. Read each created item back and check type, title and links.

        Items as JSON (index = position in the list):
        \(list)

        Return "created" with title and id ("PROJECT-123" form, without the project prefix in the path) per item, and "problems" with anything that did not work.
        """
        let reply = try await agent.structured(prompt, schema: createdSchema)
        return try JSONDecoder().decode(Created.self, from: Data(reply.utf8))
    }
}
