import Foundation

/// Which model does the text work: the local model in LM Studio, Claude through the Claude
/// Code command line, or OpenAI's models through the Codex command line. Both command lines use
/// the subscription they are logged in with.
public enum AIEngine: String, Codable, CaseIterable, Sendable {
    case local, claude, codex

    /// Whether the text leaves the Mac for this engine.
    public var isCloud: Bool { self != .local }
}

/// Claude models by their Claude Code alias; each alias always means the latest version.
public enum ClaudeModel: String, Codable, CaseIterable, Sendable {
    case haiku, sonnet, opus

    public var title: String {
        switch self {
        case .haiku: return "Haiku (fastest)"
        case .sonnet: return "Sonnet (balanced)"
        case .opus: return "Opus (most capable)"
        }
    }
}

/// How much Claude thinks before answering (`--effort`).
public enum ClaudeEffort: String, Codable, CaseIterable, Sendable {
    case low, medium, high, xhigh, max

    public var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }
}

/// The parts of the app that use a language model.
public enum AITask: String, CaseIterable, Sendable {
    /// Cleanup of every dictation.
    case cleanup
    /// Transforms (⌥1 to ⌥9, the bar's Transform button, auto apply) and ctrl + fn instructions.
    case transforms
    /// Notetaker summary, title and action items.
    case meetings

    public var title: String {
        switch self {
        case .cleanup: return "Dictation cleanup"
        case .transforms: return "Transforms and instructions"
        case .meetings: return "Meeting notes"
        }
    }

    /// The setting suggested for this task: cleanup runs after every dictation and has to be
    /// fast, so it stays local; transforms are short and benefit from a better writer; meeting
    /// notes are long, read once, and gain the most from a large model.
    /// How long a Claude or Codex call for this task may take before the local model takes over.
    public var claudeTimeout: TimeInterval {
        switch self {
        case .cleanup: return 12
        case .transforms: return 30
        case .meetings: return 600
        }
    }

    /// Extra time the caller allows when this task runs in the cloud, on top of its local timeout.
    public func extraSeconds(for choice: AIChoice) -> Double {
        choice.engine.isCloud ? claudeTimeout : 0
    }

    public var recommended: AIChoice {
        switch self {
        case .cleanup: return AIChoice(engine: .local)
        case .transforms: return AIChoice(engine: .claude, model: .sonnet, effort: .low)
        case .meetings: return AIChoice(engine: .claude, model: .sonnet, effort: .medium)
        }
    }
}

public struct AIChoice: Codable, Equatable, Sendable {
    public var engine: AIEngine
    public var model: ClaudeModel
    /// The Codex model, such as "gpt-5.5"; empty uses the model Codex picks itself.
    public var codexModel: String
    /// The reasoning effort, for Claude and Codex alike.
    public var effort: ClaudeEffort

    public init(engine: AIEngine = .local, model: ClaudeModel = .sonnet, codexModel: String = "", effort: ClaudeEffort = .low) {
        self.engine = engine
        self.model = model
        self.codexModel = codexModel
        self.effort = effort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = (try? c.decodeIfPresent(AIEngine.self, forKey: .engine)) ?? .local
        model = (try? c.decodeIfPresent(ClaudeModel.self, forKey: .model)) ?? .sonnet
        codexModel = (try? c.decodeIfPresent(String.self, forKey: .codexModel)) ?? ""
        effort = (try? c.decodeIfPresent(ClaudeEffort.self, forKey: .effort)) ?? .low
    }

    public var summary: String {
        switch engine {
        case .local: return "Local model"
        case .claude: return "Claude \(model.rawValue.capitalized) · \(effort.title.lowercased()) effort"
        case .codex: return "Codex \(codexModel.isEmpty ? "default model" : codexModel) · \(effort.title.lowercased()) effort"
        }
    }
}

/// The engine per task. Everything starts local; Claude is switched on per task.
public struct AISettings: Codable, Equatable, Sendable {
    public var cleanup: AIChoice
    public var transforms: AIChoice
    public var meetings: AIChoice
    /// Path of the `claude` command; empty means it is searched in the usual install locations.
    public var claudePath: String
    /// Path of the `codex` command, searched the same way when empty.
    public var codexPath: String

    public init(cleanup: AIChoice = AIChoice(), transforms: AIChoice = AIChoice(),
                meetings: AIChoice = AIChoice(), claudePath: String = "", codexPath: String = "") {
        self.cleanup = cleanup
        self.transforms = transforms
        self.meetings = meetings
        self.claudePath = claudePath
        self.codexPath = codexPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cleanup = try c.decodeIfPresent(AIChoice.self, forKey: .cleanup) ?? AIChoice()
        transforms = try c.decodeIfPresent(AIChoice.self, forKey: .transforms) ?? AIChoice()
        meetings = try c.decodeIfPresent(AIChoice.self, forKey: .meetings) ?? AIChoice()
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? ""
        codexPath = try c.decodeIfPresent(String.self, forKey: .codexPath) ?? ""
    }

    public subscript(task: AITask) -> AIChoice {
        get {
            switch task {
            case .cleanup: return cleanup
            case .transforms: return transforms
            case .meetings: return meetings
            }
        }
        set {
            switch task {
            case .cleanup: cleanup = newValue
            case .transforms: transforms = newValue
            case .meetings: meetings = newValue
            }
        }
    }
}

/// Sends a chat to a model and returns its raw answer, which follows `schema`.
public protocol ChatCompleter: Sendable {
    func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String
}

extension ChatCompleter {
    /// Rewrites `text` by `instruction`. Unlike the cleanup, the length may change freely.
    public func transform(_ text: String, instruction: String) async throws -> String {
        let reply = try await complete(messages: TransformPrompt.messages(instruction: instruction, text: text),
                                       maxTokens: max(400, text.count * 2), schema: OpenAICompatibleCleaner.textSchema)
        let cleaned = ResponseSanitizer.stripThinking(reply)
        let result = (ResponseSanitizer.extractJSONText(cleaned) ?? cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw LLMError.rejected(.empty) }
        return result
    }
}

/// Uses `primary`, and `fallback` when it fails, for example when Claude is not reachable.
public struct FallbackCompleter: ChatCompleter {
    let primary: ChatCompleter
    let fallback: ChatCompleter
    let onFallback: @Sendable (Error) -> Void

    public init(primary: ChatCompleter, fallback: ChatCompleter, onFallback: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.primary = primary
        self.fallback = fallback
        self.onFallback = onFallback
    }

    public func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String {
        do {
            return try await primary.complete(messages: messages, maxTokens: maxTokens, schema: schema)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            onFallback(error)
            return try await fallback.complete(messages: messages, maxTokens: maxTokens, schema: schema)
        }
    }
}

/// The cleanup prompt and answer checks on any model.
public struct CompleterCleaner: TextCleaner {
    let completer: ChatCompleter
    private let builder = PromptBuilder()
    private let sanitizer = ResponseSanitizer()

    public init(completer: ChatCompleter) {
        self.completer = completer
    }

    public func clean(_ request: CleanupRequest) async throws -> String {
        let messages = builder.messages(transcript: request.transcript, language: request.language, style: request.style,
                                        vocabulary: request.vocabulary, tones: request.tones)
        let reply = try await completer.complete(messages: messages, maxTokens: max(200, request.transcript.count),
                                                 schema: OpenAICompatibleCleaner.textSchema)
        switch sanitizer.sanitize(reply: reply, transcript: request.transcript) {
        case .success(let text): return text
        case .failure(let rejection): throw LLMError.rejected(rejection)
        }
    }
}

extension AISettings {
    /// The model for `task`: the local one, or Claude or Codex with the local one as fallback.
    public func completer(for task: AITask, llm: LLMSettings,
                          onFallback: @escaping @Sendable (Error) -> Void = { _ in }) -> ChatCompleter {
        let local = LocalModel.make(llm)
        guard let primary = cloud(self[task], timeout: task.claudeTimeout) else { return local }
        return FallbackCompleter(primary: primary, fallback: local, onFallback: onFallback)
    }

    /// Claude or Codex for `choice`. When the chosen command line is not installed, the other one
    /// takes its place, so a Mac with only Codex still gets a cloud model; nil for a local choice
    /// or when neither is installed.
    public func cloud(_ choice: AIChoice, timeout: TimeInterval) -> ChatCompleter? {
        let claude = ClaudeCLI.locate(custom: claudePath).map { ClaudeCLI(path: $0, model: choice.model, effort: choice.effort, timeout: timeout) }
        let codex = CodexCLI.locate(custom: codexPath).map { CodexCLI(path: $0, model: choice.codexModel, effort: choice.effort, timeout: timeout) }
        switch choice.engine {
        case .local: return nil
        case .claude: return claude ?? codex
        case .codex: return codex ?? claude
        }
    }

    public func cleaner(llm: LLMSettings, onFallback: @escaping @Sendable (Error) -> Void = { _ in }) -> TextCleaner {
        if cleanup.engine == .local { return LocalModel.make(llm) }
        return CompleterCleaner(completer: completer(for: .cleanup, llm: llm, onFallback: onFallback))
    }
}

/// Runs a command and returns its standard output.
public protocol CommandRunner: Sendable {
    func run(_ path: String, arguments: [String], timeout: TimeInterval) async throws -> Data
}

public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ path: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            // An empty, private working directory, so no project files or CLAUDE.md are picked up.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDictation-claude")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            process.currentDirectoryURL = directory
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            let collected = OutputCollector()
            output.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
            process.terminationHandler = { process in
                output.fileHandleForReading.readabilityHandler = nil
                collected.append(output.fileHandleForReading.readDataToEndOfFile())
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: ClaudeCLI.Failure.timedOut)
                } else if process.terminationStatus != 0 && collected.data.isEmpty {
                    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(300), as: UTF8.self)
                    continuation.resume(throwing: ClaudeCLI.Failure.exited(process.terminationStatus, message))
                } else {
                    continuation.resume(returning: collected.data)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Claude through `claude -p`, Claude Code's headless mode. The call has no tools, no MCP
/// servers, no settings, hooks or plugins and keeps no session, so only the prompt goes out.
public struct ClaudeCLI: ChatCompleter {
    public enum Failure: Error, Equatable {
        case notFound
        case timedOut
        case exited(Int32, String)
        case error(String)
        case unreadable
    }

    public let path: String
    public let model: ClaudeModel
    public let effort: ClaudeEffort
    let runner: CommandRunner
    let timeout: TimeInterval

    public init(path: String, model: ClaudeModel, effort: ClaudeEffort, runner: CommandRunner = ProcessRunner(),
                timeout: TimeInterval = 300) {
        self.path = path
        self.model = model
        self.effort = effort
        self.runner = runner
        self.timeout = timeout
    }

    /// Where Claude Code is usually installed.
    public static let searchPaths = [
        "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        "~/.local/bin/claude", "~/.claude/local/claude", "~/.npm-global/bin/claude",
    ]

    public static func locate(custom: String = "", fileManager: FileManager = .default) -> String? {
        let candidates = (custom.isEmpty ? [] : [custom]) + searchPaths
        return candidates.map { NSString(string: $0).expandingTildeInPath }.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Takes a started process from `ClaudeSessionPool`; the system prompt then goes into the
    /// message, because a started process cannot change it.
    public var usesSpare = false

    public func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String {
        if usesSpare {
            let schemaText = ClaudeAgent.text(schema)
            let data = try await ClaudeSessionPool.shared.run(kind: "plain-" + schemaText, path: path,
                                                              arguments: sessionArguments(schema: schemaText),
                                                              prompt: CodexCLI.prompt(from: messages), timeout: timeout)
            return try Self.answer(from: data)
        }
        let data = try await runner.run(path, arguments: arguments(messages: messages, schema: schema), timeout: timeout)
        return try Self.answer(from: data)
    }

    /// A started process without tools, MCP servers or settings, answering by `schema`.
    func sessionArguments(schema: String) -> [String] {
        ["--model", model.rawValue, "--effort", effort.rawValue, "--tools", "", "--setting-sources", "", "--strict-mcp-config",
         "--no-session-persistence", "--json-schema", schema]
    }

    /// Starts the process for the next call with `schema` ahead of time.
    public func prepare(schema: [String: Any]) async {
        let schemaText = ClaudeAgent.text(schema)
        await ClaudeSessionPool.shared.prepare(kind: "plain-" + schemaText, path: path, arguments: sessionArguments(schema: schemaText))
    }

    func arguments(messages: [ChatMessage], schema: [String: Any]) -> [String] {
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let schemaText = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var arguments = ["-p", Self.prompt(from: messages),
                         "--model", model.rawValue, "--effort", effort.rawValue,
                         "--tools", "", "--setting-sources", "", "--strict-mcp-config",
                         "--no-session-persistence", "--output-format", "json", "--json-schema", schemaText]
        if !system.isEmpty { arguments += ["--system-prompt", system] }
        return arguments
    }

    /// The conversation as one prompt: earlier user and assistant turns are the examples of the
    /// prompt and are shown as such, the last user turn is the input to answer.
    static func prompt(from messages: [ChatMessage]) -> String {
        let turns = messages.filter { $0.role != "system" }
        guard let last = turns.last else { return "" }
        let examples = turns.dropLast()
        guard !examples.isEmpty else { return last.content }
        var text = "Examples of input and the expected answer:\n"
        for turn in examples {
            text += turn.role == "assistant" ? "\nAnswer:\n\(turn.content)\n" : "\nInput:\n\(turn.content)\n"
        }
        return text + "\nNow answer for this input, in the same form:\n\(last.content)"
    }

    /// The structured answer as JSON text, so callers read it like a local model's reply.
    static func answer(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        if (object["is_error"] as? Bool) == true {
            throw Failure.error((object["result"] as? String) ?? (object["subtype"] as? String) ?? "unknown error")
        }
        if let structured = object["structured_output"], JSONSerialization.isValidJSONObject(structured),
           let json = try? JSONSerialization.data(withJSONObject: structured) {
            return String(decoding: json, as: UTF8.self)
        }
        if let result = object["result"] as? String, !result.isEmpty { return result }
        throw Failure.unreadable
    }
}

/// OpenAI's models through `codex exec`, the Codex command line's non-interactive mode. The call
/// ignores the user's Codex configuration (so no MCP servers or profiles load), runs in a
/// read-only sandbox in an empty folder, keeps no session, and the answer follows the JSON
/// schema through `--output-schema`.
public struct CodexCLI: ChatCompleter {
    public let path: String
    /// Empty uses the model Codex picks itself.
    public let model: String
    public let effort: ClaudeEffort
    let runner: CommandRunner
    let timeout: TimeInterval

    public init(path: String, model: String = "", effort: ClaudeEffort, runner: CommandRunner = ProcessRunner(),
                timeout: TimeInterval = 300) {
        self.path = path
        self.model = model
        self.effort = effort
        self.runner = runner
        self.timeout = timeout
    }

    public static let searchPaths = [
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex", "~/.npm-global/bin/codex",
        "~/.codex/bin/codex", "/Applications/Codex.app/Contents/Resources/codex",
    ]

    public static func locate(custom: String = "", fileManager: FileManager = .default) -> String? {
        let candidates = (custom.isEmpty ? [] : [custom]) + searchPaths
        return candidates.map { NSString(string: $0).expandingTildeInPath }.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Codex knows low, medium, high and xhigh; "max" is its highest.
    var reasoning: String { effort == .max ? "xhigh" : effort.rawValue }

    public func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDictation-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let schemaFile = folder.appendingPathComponent("schema.json")
        let answerFile = folder.appendingPathComponent("answer.json")
        try JSONSerialization.data(withJSONObject: Self.strict(schema), options: [.sortedKeys]).write(to: schemaFile)
        _ = try await runner.run(path, arguments: arguments(messages: messages, schemaFile: schemaFile.path, answerFile: answerFile.path),
                                 timeout: timeout)
        guard let data = try? Data(contentsOf: answerFile) else { throw ClaudeCLI.Failure.unreadable }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeCLI.Failure.unreadable }
        return text
    }

    func arguments(messages: [ChatMessage], schemaFile: String, answerFile: String) -> [String] {
        var arguments = ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                         "--sandbox", "read-only", "--color", "never",
                         "-c", "model_reasoning_effort=\"\(reasoning)\"",
                         "--output-schema", schemaFile, "-o", answerFile]
        if !model.isEmpty { arguments += ["-m", model] }
        return arguments + [Self.prompt(from: messages)]
    }

    /// Codex has no separate system prompt, so the instructions come first, then the examples and
    /// the input as for Claude.
    static func prompt(from messages: [ChatMessage]) -> String {
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let rest = ClaudeCLI.prompt(from: messages)
        let note = "Answer directly from the text below. Do not run commands or read files."
        return system.isEmpty ? note + "\n\n" + rest : system + "\n\n" + note + "\n\n" + rest
    }

    /// OpenAI's structured output takes only strict schemas: every object lists all its
    /// properties as required and allows no others.
    static func strict(_ schema: [String: Any]) -> [String: Any] {
        var result = schema
        if let properties = schema["properties"] as? [String: Any] {
            result["properties"] = properties.mapValues { value in (value as? [String: Any]).map(strict) ?? value }
            result["required"] = properties.keys.sorted()
            result["additionalProperties"] = false
        }
        if let items = schema["items"] as? [String: Any] { result["items"] = strict(items) }
        return result
    }
}
