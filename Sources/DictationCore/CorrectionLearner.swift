import Foundation

/// Finds the words the user corrected after a dictation was pasted: the pasted text is aligned
/// with what the text field holds a little later, and short replacements inside it ("TLD file"
/// for "tl;dv", "Nowaclinical" for "novaClinical") become dictionary suggestions. Rewritten
/// sentences, added or deleted words and changes of punctuation are not corrections of the
/// recognition and are left out.
public enum CorrectionLearner {
    struct Word {
        let key: String
        let range: Range<String.Index>
    }

    public static func corrections(pasted: String, field: String) -> [Replacement] {
        let a = words(pasted)
        var b = words(field)
        guard a.count >= 2, !b.isEmpty else { return [] }
        if b.count > 3_000 { b = Array(b.suffix(3_000)) }
        // Longest common subsequence of the words, case-insensitive.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i].key == b[j].key ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        // The text must still be recognisably the dictation.
        guard Double(table[0][0]) >= Double(a.count) * 0.6 else { return [] }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i].key == b[j].key { pairs.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        var result: [Replacement] = []
        for (left, right) in zip(pairs, pairs.dropFirst()) {
            let removed = (left.0 + 1)..<right.0
            let added = (left.1 + 1)..<right.1
            guard (1...3).contains(removed.count), (1...3).contains(added.count) else { continue }
            let from = String(pasted[a[removed.lowerBound].range.lowerBound..<a[removed.upperBound - 1].range.upperBound])
            let to = String(field[b[added.lowerBound].range.lowerBound..<b[added.upperBound - 1].range.upperBound])
            guard from.lowercased() != to.lowercased() || from != to, to.contains(where: \.isLetter),
                  !to.allSatisfy({ $0.isNumber || $0.isPunctuation || $0.isWhitespace }) else { continue }
            // A changed ending ("Tests" for "Test") is grammar, not recognition.
            if from.count >= 4, to.lowercased().hasPrefix(from.lowercased()) || from.lowercased().hasPrefix(to.lowercased()) { continue }
            result.append(Replacement(from: from, to: to))
        }
        return result
    }

    /// Words with their ranges; ";" and "." inside a word stay part of it ("tl;dv", "v1.2").
    static func words(_ text: String) -> [Word] {
        var words: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        func close(at end: String.Index) {
            guard let begin = start else { return }
            var last = end
            while last > begin, let previous = Optional(text.index(before: last)), ".;,:!?".contains(text[previous]) { last = previous }
            if last > begin { words.append(Word(key: text[begin..<last].lowercased(), range: begin..<last)) }
            start = nil
        }
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || "()\"„“”".contains(character) { close(at: index) } else if start == nil { start = index }
            index = text.index(after: index)
        }
        close(at: text.endIndex)
        return words
    }
}
