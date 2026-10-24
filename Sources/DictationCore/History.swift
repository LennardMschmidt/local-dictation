import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable {
    public var date: Date
    public var bundleId: String?
    public var language: String
    public var raw: String
    public var text: String
    public var cleanup: String
    public var transcriptionSeconds: Double
    public var cleanupSeconds: Double
    /// Length of the recording; missing in entries written before it was recorded.
    public var audioSeconds: Double?

    public init(date: Date, bundleId: String?, result: DictationResult) {
        self.date = date
        self.bundleId = bundleId
        language = result.language
        raw = result.rawTranscript
        text = result.text
        switch result.cleanup {
        case .cleaned: cleanup = "cleaned"
        case .disabled: cleanup = "disabled"
        case .snippet: cleanup = "snippet"
        case .short: cleanup = "short"
        case .failed(let reason): cleanup = "failed: \(reason)"
        }
        transcriptionSeconds = result.transcriptionSeconds
        cleanupSeconds = result.cleanupSeconds
        audioSeconds = result.audioSeconds
    }
}

/// Keeps the last dictations in a JSON Lines file on this Mac.
public final class HistoryStore: @unchecked Sendable {
    public let url: URL
    public let limit: Int
    private let lock = NSLock()

    public init(url: URL, limit: Int) {
        self.url = url
        self.limit = max(1, limit)
    }

    public func append(_ entry: HistoryEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = (try? readUnlocked()) ?? []
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        try writeUnlocked(entries)
    }

    public func entries() throws -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return try readUnlocked()
    }

    public func last() -> HistoryEntry? {
        (try? entries())?.last
    }

    private func readUnlocked() throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
    }

    private func writeUnlocked(_ entries: [HistoryEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try entries.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
