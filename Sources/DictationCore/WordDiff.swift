import Foundation

/// Word-level differences between an original text and its transformed version, for the
/// "view changes" window.
public enum WordDiff {
    public enum Kind: Equatable, Sendable {
        case same, removed, added
    }

    public struct Part: Equatable, Sendable {
        public var text: String
        public var kind: Kind

        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// Splits both texts into words (keeping the whitespace after each word) and marks the
    /// words that stay, the removed ones and the added ones, based on the longest common
    /// subsequence of the words.
    public static func diff(_ old: String, _ new: String) -> [Part] {
        let a = tokens(old), b = tokens(new)
        let keyA = a.map(key), keyB = b.map(key)
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = keyA[i] == keyB[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var parts: [Part] = []
        func append(_ text: String, _ kind: Kind) {
            if let last = parts.last, last.kind == kind {
                parts[parts.count - 1].text += text
            } else {
                parts.append(Part(text: text, kind: kind))
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, keyA[i] == keyB[j] {
                append(b[j], .same)
                i += 1
                j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                append(b[j], .added)
                j += 1
            } else {
                append(a[i], .removed)
                i += 1
            }
        }
        return parts
    }

    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inSpace = false
        for character in text {
            if character.isWhitespace {
                current.append(character)
                inSpace = true
            } else {
                if inSpace && !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                inSpace = false
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func key(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
