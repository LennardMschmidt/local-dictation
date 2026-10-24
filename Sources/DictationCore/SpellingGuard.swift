import Foundation

/// Keeps the cleanup model from misspelling words it should only have copied. When a word in the
/// cleaned text is missing from the transcript but differs from a transcript word by one or two
/// letters ("glabe" for "glaube"), and it is no dictionary term, the transcript's word is put
/// back. Changes of case, numbers, punctuation and dictionary corrections stay.
public enum SpellingGuard {
    public static func repair(_ cleaned: String, transcript: String, vocabulary: [String]) -> String {
        let spoken = Set(words(transcript).map { $0.lowercased() })
        let terms = Set(vocabulary.flatMap { words($0) }.map { $0.lowercased() })
        let candidates = Array(spoken)
        var result = cleaned
        for range in VocabularyMatcher.words(in: cleaned).reversed() {
            let word = String(cleaned[range])
            let lower = word.lowercased()
            guard lower.count >= 4, !spoken.contains(lower), !terms.contains(lower), !lower.contains(where: \.isNumber) else { continue }
            let near = candidates.filter { candidate in
                candidate.count >= 4 && candidate.first == lower.first && abs(candidate.count - lower.count) <= 2
                    && distance(candidate, lower) <= (lower.count >= 8 ? 2 : 1)
            }
            // Only a clear single match is restored; two candidates mean the model chose one.
            guard near.count == 1, let original = near.first else { continue }
            let restored = word.first?.isUppercase == true ? original.prefix(1).uppercased() + original.dropFirst() : original
            result.replaceSubrange(range, with: restored)
        }
        return result
    }

    static func words(_ text: String) -> [String] {
        VocabularyMatcher.words(in: text).map { String(text[$0]) }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return a.isEmpty ? b.count : previous[b.count]
    }
}
