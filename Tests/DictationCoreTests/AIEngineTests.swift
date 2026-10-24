import Foundation
import Testing
@testable import DictationCore

private final class FakeRunner: CommandRunner, @unchecked Sendable {
    var output: Data
    var error: Error?
    private(set) var arguments: [String] = []
    private(set) var path = ""

    init(output: String, error: Error? = nil) {
        self.output = Data(output.utf8)
        self.error = error
    }

    func run(_ path: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        self.path = path
        self.arguments = arguments
        if let error { throw error }
        return output
    }
}

private struct FixedCompleter: ChatCompleter {
    let reply: String
    var fails = false

    func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String {
        if fails { throw ClaudeCLI.Failure.timedOut }
        return reply
    }
}

private final class RecordingCompleter: ChatCompleter, @unchecked Sendable {
    private(set) var calls: [[ChatMessage]] = []
    let reply: String

    init(reply: String) { self.reply = reply }

    func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String {
        calls.append(messages)
        return reply
    }
}

struct ClaudeCLITests {
    @Test func callsClaudeWithoutToolsSettingsOrSession() async throws {
        let runner = FakeRunner(output: #"{"is_error":false,"result":"","structured_output":{"text":"Hallo"}}"#)
        let claude = ClaudeCLI(path: "/opt/homebrew/bin/claude", model: .sonnet, effort: .medium, runner: runner)
        let reply = try await claude.complete(messages: [ChatMessage(role: "system", content: "Be brief."),
                                                         ChatMessage(role: "user", content: "hallo")],
                                              maxTokens: 100, schema: OpenAICompatibleCleaner.textSchema)
        #expect(reply == #"{"text":"Hallo"}"#)
        let arguments = runner.arguments
        #expect(arguments.first == "-p")
        #expect(arguments[1] == "hallo")
        for flag in ["--strict-mcp-config", "--no-session-persistence"] { #expect(arguments.contains(flag)) }
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        #expect(value("--model") == "sonnet")
        #expect(value("--effort") == "medium")
        #expect(value("--tools") == "")
        #expect(value("--setting-sources") == "")
        #expect(value("--system-prompt") == "Be brief.")
        #expect(value("--output-format") == "json")
        #expect(value("--json-schema")?.contains("\"text\"") == true)
    }

    @Test func examplesBecomePartOfThePrompt() {
        let prompt = ClaudeCLI.prompt(from: [
            ChatMessage(role: "system", content: "rules"),
            ChatMessage(role: "user", content: "eins"), ChatMessage(role: "assistant", content: "Eins."),
            ChatMessage(role: "user", content: "zwei"),
        ])
        #expect(prompt.contains("Input:\neins"))
        #expect(prompt.contains("Answer:\nEins."))
        #expect(prompt.hasSuffix("in the same form:\nzwei"))
        #expect(!prompt.contains("rules"))
    }

    @Test func errorsAndUnreadableOutputThrow() throws {
        #expect(throws: ClaudeCLI.Failure.error("Not logged in")) {
            try ClaudeCLI.answer(from: Data(#"{"is_error":true,"result":"Not logged in"}"#.utf8))
        }
        #expect(throws: ClaudeCLI.Failure.unreadable) { try ClaudeCLI.answer(from: Data("no json".utf8)) }
    }

    @Test func plainResultIsUsedWithoutStructuredOutput() throws {
        #expect(try ClaudeCLI.answer(from: Data(#"{"is_error":false,"result":"plain"}"#.utf8)) == "plain")
    }

    @Test func locatesTheCustomPathFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        #expect(ClaudeCLI.locate(custom: file.path) == file.path)
        try? FileManager.default.removeItem(at: directory)
    }
}

struct AISettingsTests {
    @Test func everythingStartsLocal() throws {
        let settings = try JSONDecoder().decode(DictationSettings.self, from: Data("{}".utf8))
        for task in AITask.allCases { #expect(settings.ai[task].engine == .local) }
        #expect(AITask.cleanup.recommended.engine == .local)
        #expect(AITask.meetings.recommended == AIChoice(engine: .claude, model: .sonnet, effort: .medium))
    }

    @Test func choicesSurviveSaving() throws {
        var settings = DictationSettings()
        settings.ai.meetings = AIChoice(engine: .claude, model: .opus, effort: .high)
        let decoded = try JSONDecoder().decode(DictationSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.ai.meetings == AIChoice(engine: .claude, model: .opus, effort: .high))
        #expect(decoded.ai.cleanup.engine == .local)
    }

    @Test func claudeGetsMoreTimeForCleanup() {
        var settings = DictationSettings()
        let pipelineLocal = DictationPipeline(settings: settings, transcriber: StubTranscriber(transcript: Transcript(text: "", language: "de")), cleaner: nil)
        settings.ai.cleanup.engine = .claude
        let pipelineClaude = DictationPipeline(settings: settings, transcriber: StubTranscriber(transcript: Transcript(text: "", language: "de")), cleaner: nil)
        #expect(pipelineClaude.cleanupTimeout(for: "x") - pipelineLocal.cleanupTimeout(for: "x") == AITask.cleanup.claudeTimeout)
    }
}

struct FallbackTests {
    @Test func localModelAnswersWhenClaudeFails() async throws {
        var reported: Error?
        let completer = FallbackCompleter(primary: FixedCompleter(reply: "claude", fails: true),
                                          fallback: FixedCompleter(reply: "local")) { reported = $0 }
        let reply = try await completer.complete(messages: [], maxTokens: 10, schema: [:])
        #expect(reply == "local")
        #expect(reported != nil)
    }

    @Test func transformReadsTheTextField() async throws {
        let result = try await FixedCompleter(reply: #"{"text":"Sehr geehrte Damen und Herren"}"#)
            .transform("hallo", instruction: "formal")
        #expect(result == "Sehr geehrte Damen und Herren")
    }
}

struct SummarizerTests {
    @Test func shortTranscriptIsSummarisedInOneCall() async throws {
        let client = RecordingCompleter(reply: #"{"title":"Release","summary":"Done.","actionItems":["Anna: tests"]}"#)
        let result = try await MeetingSummarizer(client: client).summarize("Anna macht die Tests bis Freitag.")
        #expect(client.calls.count == 1)
        #expect(result.title == "Release")
        #expect(result.actionItems == ["Anna: tests"])
    }

    @Test func longTranscriptGoesThroughNotes() async throws {
        let client = RecordingCompleter(reply: #"{"text":"notes","title":"T","summary":"S","actionItems":[]}"#)
        let transcript = Array(repeating: "wort", count: 30).joined(separator: " ")
        _ = try await MeetingSummarizer(client: client, wordsPerChunk: 10).summarize(transcript)
        #expect(client.calls.count == 4)
    }
}

/// Plays the Codex command: records the arguments and writes `answer` where `-o` points.
private final class CodexFake: CommandRunner, @unchecked Sendable {
    let answer: String
    private(set) var arguments: [String] = []
    private(set) var schema: [String: Any] = [:]
    init(answer: String) { self.answer = answer }
    func run(_ path: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        self.arguments = arguments
        if let index = arguments.firstIndex(of: "--output-schema"),
           let data = FileManager.default.contents(atPath: arguments[index + 1]),
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] { schema = object }
        if let index = arguments.firstIndex(of: "-o") {
            try answer.write(toFile: arguments[index + 1], atomically: true, encoding: .utf8)
        }
        return Data()
    }
}

struct CodexTests {
    @Test func answersFromTheOutputFile() async throws {
        let fake = CodexFake(answer: #"{"text":"Das Meeting ist um 15 Uhr."}"#)
        let codex = CodexCLI(path: "/bin/codex", model: "gpt-5.5", effort: .max, runner: fake)
        let text = try await codex.transform("das meeting ist um drei", instruction: "Rewrite formally.")
        #expect(text == "Das Meeting ist um 15 Uhr.")
        #expect(fake.arguments.starts(with: ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config"]))
        #expect(fake.arguments.contains("model_reasoning_effort=\"xhigh\""))
        #expect(fake.arguments.contains("read-only"))
        #expect(Array(fake.arguments.drop { $0 != "-m" }.prefix(2)) == ["-m", "gpt-5.5"])
        #expect(fake.schema["additionalProperties"] as? Bool == false)
    }

    @Test func schemasBecomeStrict() {
        let schema: [String: Any] = ["type": "object", "properties": [
            "items": ["type": "array", "items": ["type": "object", "properties": ["a": ["type": "string"], "b": ["type": "string"]]]],
        ]]
        let strict = CodexCLI.strict(schema)
        let item = ((strict["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"] as? [String: Any]
        #expect(strict["required"] as? [String] == ["items"])
        #expect(item?["required"] as? [String] == ["a", "b"])
        #expect(item?["additionalProperties"] as? Bool == false)
    }

    @Test func codexGetsTheCloudTime() {
        #expect(AITask.meetings.extraSeconds(for: AIChoice(engine: .codex)) == AITask.meetings.claudeTimeout)
        #expect(AIChoice(engine: .codex, effort: .medium).summary == "Codex default model · medium effort")
    }
}

struct ClaudeSessionTests {
    /// A stand-in for `claude -p --input-format stream-json`: waits for one line, then prints an
    /// init and a result message that echoes the prompt.
    private func fakeClaude() throws -> String {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString).sh")
        try """
        #!/bin/bash
        read -r line
        echo '{"type":"system","subtype":"init"}'
        prompt=$(printf '%s' "$line" | /usr/bin/python3 -c 'import sys,json; print(json.load(sys.stdin)["message"]["content"])')
        /usr/bin/python3 -c 'import json,sys; print(json.dumps({"type":"result","is_error":False,"result":"echo: "+sys.argv[1]}))' "$prompt"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    @Test func startedSessionAnswersOnce() async throws {
        let session = try ClaudeSession(path: try fakeClaude(), arguments: [])
        try await Task.sleep(nanoseconds: 300_000_000)
        let data = try await session.ask("Hallo", timeout: 10)
        #expect(try ClaudeCLI.answer(from: data) == "echo: Hallo")
    }

    @Test func poolHandsOutAFreshSessionEachTime() async throws {
        let path = try fakeClaude()
        let pool = ClaudeSessionPool()
        await pool.prepare(kind: "agent", path: path, arguments: [])
        let first = try await pool.run(kind: "agent", path: path, arguments: [], prompt: "eins", timeout: 10)
        let second = try await pool.run(kind: "agent", path: path, arguments: [], prompt: "zwei", timeout: 10)
        #expect(try ClaudeCLI.answer(from: first) == "echo: eins")
        #expect(try ClaudeCLI.answer(from: second) == "echo: zwei")
    }
}

struct CodexAgentTests {
    @Test func onlyAllowedToolsStayOn() {
        var agent = CodexAgent(path: "/bin/codex", tools: ["mcp__polarion-openapi__getProjects", "mcp__polarion-api", "Skill"],
                               servers: ["polarion-mcp", "polarion_api", "supabase", "cua_repl"])
        agent.localServers = ["cua_repl"]
        let arguments = agent.configArguments()
        #expect(arguments.contains("mcp_servers.cua_repl.command=\"/usr/bin/true\""))
        #expect(!arguments.contains("mcp_servers.supabase.command=\"/usr/bin/true\""))
        #expect(arguments.contains("mcp_servers.polarion-mcp.enabled_tools=[\"getProjects\"]"))
        #expect(arguments.contains("mcp_servers.supabase.enabled=false"))
        #expect(!arguments.contains { $0.contains("polarion_api") })
    }

    @Test func skillPathIsNamed() {
        let hint = CodexAgent(path: "/bin/codex", tools: [], servers: []).useSkill("polarion-requirements")
        #expect(hint.contains("polarion-requirements/SKILL.md"))
    }
}
