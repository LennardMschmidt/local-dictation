import Foundation

/// A Claude Code process that is started before it is needed: `claude -p` with stream-json input
/// waits for its first message, so starting it, loading its settings and connecting its MCP
/// servers happens while nobody waits. Each process answers one prompt and is then replaced by
/// a fresh one, so no request sees the context of the one before.
public final class ClaudeSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    /// Tools Claude Code called for the prompt, in order; added to the result as "tools_called".
    private var toolsCalled: [String] = []
    /// The text of each tool result, in order; added to the result as "tool_results".
    private var toolResults: [String] = []
    private var resultLine: Data?
    private var waiting: CheckedContinuation<Data, Error>?
    public let startedAt = Date()

    /// `arguments` are those of a one-shot call without `-p <prompt>` and `--output-format`.
    public init(path: String, arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"] + arguments
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDictation-claude")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.received(handle.availableData) }
        process.terminationHandler = { [weak self] _ in self?.finish(with: nil) }
        try process.run()
    }

    public var isRunning: Bool { process.isRunning }

    /// Sends `prompt` and returns the final result message, in the shape `--output-format json`
    /// prints, so `ClaudeCLI.answer(from:)` reads it.
    public func ask(_ prompt: String, timeout: TimeInterval) async throws -> Data {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.process.terminate()
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let resultLine {
                lock.unlock()
                continuation.resume(returning: resultLine)
            } else {
                waiting = continuation
                lock.unlock()
            }
        }
    }

    public func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines {
            guard var object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if object["type"] as? String == "assistant",
               let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                let names = content.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["name"] as? String }
                lock.withLock { toolsCalled += names }
            }
            if object["type"] as? String == "user",
               let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                let texts = content.filter { $0["type"] as? String == "tool_result" }.map(Self.text(ofToolResult:))
                lock.withLock { toolResults += texts }
            }
            guard object["type"] as? String == "result" else { continue }
            object["tools_called"] = lock.withLock { toolsCalled }
            object["tool_results"] = lock.withLock { toolResults }
            finish(with: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(line))
        }
    }

    /// A tool result's content is a string or a list of text blocks.
    static func text(ofToolResult block: [String: Any]) -> String {
        if let text = block["content"] as? String { return text }
        let parts = block["content"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    private func finish(with line: Data?) {
        lock.lock()
        if let line { resultLine = line }
        let continuation = waiting
        waiting = nil
        let result = resultLine
        lock.unlock()
        guard let continuation else { return }
        if let result {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: ClaudeCLI.Failure.timedOut)
        }
        stop()
    }
}

/// Keeps one started `ClaudeSession` per kind of call, so the next agent step skips the start.
/// A spare older than 30 minutes is replaced, as is one whose arguments changed.
public actor ClaudeSessionPool {
    public static let shared = ClaudeSessionPool()

    public init() {}
    private var spares: [String: (arguments: [String], session: ClaudeSession)] = [:]

    public func run(kind: String, path: String, arguments: [String], prompt: String, timeout: TimeInterval) async throws -> Data {
        let session: ClaudeSession
        if let spare = spares[kind], spare.arguments == arguments, spare.session.isRunning,
           Date().timeIntervalSince(spare.session.startedAt) < 30 * 60 {
            session = spare.session
        } else {
            spares[kind]?.session.stop()
            session = try ClaudeSession(path: path, arguments: arguments)
        }
        spares[kind] = nil
        // The next spare starts now, while this one answers.
        if let next = try? ClaudeSession(path: path, arguments: arguments) { spares[kind] = (arguments, next) }
        return try await session.ask(prompt, timeout: timeout)
    }

    /// Starts a spare ahead of the first request.
    public func prepare(kind: String, path: String, arguments: [String]) {
        guard spares[kind] == nil, let session = try? ClaudeSession(path: path, arguments: arguments) else { return }
        spares[kind] = (arguments, session)
    }
}
