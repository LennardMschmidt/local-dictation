import Foundation

/// Puts dictionary terms into a transcript by rule, so they come out right also when the language
/// model is skipped or did not know them, and so the dictionary can grow without making
/// dictation slower: matching a thousand terms takes milliseconds, while every term in Whisper's
/// or the model's prompt costs time on every dictation.
///
/// - Words spoken apart are joined: "a work" becomes "awork", "Live Doc" becomes "LiveDoc".
/// - A long term (six letters or more) also replaces a close misspelling of one word with the
///   same first letter: "Nowaclinical" becomes "novaClinical". Terms of ten letters or more allow a little
///   more difference than shorter ones.
/// - A term with its own spelling fixes the case: "polarion" becomes "Polarion". Short plain
///   words such as "Word" are left alone there, so ordinary text does not change.
public struct VocabularyMatcher: Sendable {
    struct Term: Sendable {
        let text: String
        let key: String
    }

    let terms: [Term]

    public init(_ vocabulary: [String]) {
        terms = vocabulary.compactMap { term in
            let key = Self.key(term)
            return key.count >= 3 ? Term(text: term, key: key) : nil
        }
    }

    /// The transcript with every match replaced by the term.
    public func correct(_ text: String) -> String {
        guard !terms.isEmpty else { return text }
        let words = Self.words(in: text)
        var replacements: [(Range<String.Index>, String)] = []
        var index = 0
        while index < words.count {
            var matched = false
            for length in stride(from: min(3, words.count - index), through: 1, by: -1) {
                let span = words[index..<(index + length)]
                let candidate = text[span.first!.lowerBound..<span.last!.upperBound]
                if let term = match(String(candidate), words: length) {
                    if term != candidate { replacements.append((span.first!.lowerBound..<span.last!.upperBound, term)) }
                    index += length
                    matched = true
                    break
                }
            }
            if !matched { index += 1 }
        }
        var result = text
        for (range, term) in replacements.reversed() { result.replaceSubrange(range, with: term) }
        return result
    }

    /// The terms that occur in `text`, or nearly, for the model's prompt; at most `limit`.
    public func relevant(to text: String, limit: Int) -> [String] {
        let words = Self.words(in: text)
        var found: [String] = []
        for index in words.indices {
            for length in 1...3 where index + length <= words.count {
                let span = words[index..<(index + length)]
                let candidate = String(text[span.first!.lowerBound..<span.last!.upperBound])
                let key = Self.key(candidate)
                for term in terms where !found.contains(term.text)
                    && Self.similarity(key, term.key) >= 0.7 && abs(key.count - term.key.count) <= 3 {
                    found.append(term.text)
                }
            }
            if found.count >= limit { break }
        }
        return Array(found.prefix(limit))
    }

    /// The term `candidate` stands for, if any.
    func match(_ candidate: String, words: Int) -> String? {
        let key = Self.key(candidate)
        guard key.count >= 3 else { return nil }
        for term in terms where term.key == key {
            if words > 1 { return term.text }
            return Self.hasOwnSpelling(term.text) ? term.text : candidate
        }
        // Close misspellings only for a single word: across several words a fuzzy match swallows
        // the word next to the term ("Claude Code und" became "Claude Code").
        guard key.count >= 6, words == 1 else { return nil }
        var best: (term: Term, score: Double)?
        for term in terms where term.key.count >= 6 && term.key.first == key.first && abs(term.key.count - key.count) <= 3 {
            let score = Self.similarity(key, term.key)
            // Long terms tolerate a little more, short ones must be close, so words stay words.
            let needed = term.key.count >= 10 ? 0.74 : 0.82
            if score >= needed, score > (best?.score ?? 0) { best = (term, score) }
        }
        return best?.term.text
    }

    /// Terms whose spelling differs from an ordinary capitalised word, or long enough to be a name.
    static func hasOwnSpelling(_ term: String) -> Bool {
        let letters = term.filter(\.isLetter)
        guard let first = letters.first else { return false }
        let innerCapital = letters.dropFirst().contains { $0.isUppercase }
        return first.isLowercase || innerCapital || letters.count >= 5
    }

    /// Lower case letters and digits only, so "a work", "A-Work" and "awork" are the same.
    static func key(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func words(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let partOfWord = character.isLetter || character.isNumber || character == "-" || character == "'"
            if partOfWord, start == nil { start = index }
            if !partOfWord, let begin = start {
                ranges.append(begin..<index)
                start = nil
            }
            index = text.index(after: index)
        }
        if let begin = start { ranges.append(begin..<text.endIndex) }
        return ranges
    }

    /// 1 minus the edit distance divided by the longer length.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty && b.isEmpty ? 1 : 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}
