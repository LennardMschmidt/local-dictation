import Foundation

/// Turns the raw model reply into the cleaned text and rejects replies that are not a
/// cleanup of the transcript.
public struct ResponseSanitizer: Sendable {
    public enum Rejection: Error, Equatable, Sendable {
        case empty
        /// The reply is much longer than the transcript, so the model most likely answered it.
        case tooLong
        /// The reply lost most of the transcript, so the model most likely followed it.
        case tooShort
    }

    public init() {}

    public func sanitize(reply: String, transcript: String) -> Result<String, Rejection> {
        var text = Self.stripThinking(reply)
        text = Self.extractJSONText(text) ?? text
        text = Self.stripWrappingQuotes(text.trimmingCharacters(in: .whitespacesAndNewlines))
        text = Self.normalizeLineEndings(text)

        guard !text.isEmpty else { return .failure(.empty) }

        let inputLength = transcript.count
        if text.count > inputLength * 2 + 60 {
            return .failure(.tooLong)
        }
        let inputWords = Self.wordCount(transcript)
        if inputWords >= 6 && Double(Self.wordCount(text)) < Double(inputWords) * 0.35 {
            return .failure(.tooShort)
        }
        return .success(text)
    }

    static func stripThinking(_ text: String) -> String {
        guard let end = text.range(of: "</think>", options: .backwards) else { return text }
        return String(text[end.upperBound...])
    }

    static func extractJSONText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else { return nil }
        let candidate = Data(trimmed[start...end].utf8)
        guard let object = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any],
              let value = object["text"] as? String else { return nil }
        return value
    }

    static func stripWrappingQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("„", "“"), ("“", "”"), ("'", "'")]
        for (open, close) in pairs where text.count >= 2 && text.first == open && text.last == close {
            let inner = text.dropFirst().dropLast()
            if !inner.contains(open) && !inner.contains(close) {
                return String(inner)
            }
        }
        return text
    }

    /// Removes the trailing spaces some models put before line breaks (Markdown hard breaks).
    static func normalizeLineEndings(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                var line = Substring(line)
                while line.last == " " || line.last == "\t" { line = line.dropLast() }
                return String(line)
            }
            .joined(separator: "\n")
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
