import Foundation

/// Turns a counted enumeration ("erstens …, zweitens …" or "firstly …, secondly …") into a
/// numbered list by rule. The language model does this too; the rule keeps the list when the
/// model was skipped, timed out, or left the items in one line.
public enum CountedList {
    /// Ordinal words per position. German and the English "-ly" forms are only used for
    /// counting; the plain English "first", "second" also start ordinary sentences, so they
    /// count only at the start of a clause (see `clauseStart`).
    static let ordinals: [[String]] = [
        ["erstens", "firstly", "first"],
        ["zweitens", "secondly", "second"],
        ["drittens", "thirdly", "third"],
        ["viertens", "fourthly", "fourth"],
        ["fünftens", "fifthly", "fifth"],
        ["sechstens", "sixthly", "sixth"],
        ["siebtens", "siebentens", "seventhly", "seventh"],
        ["achtens", "eighthly", "eighth"],
        ["neuntens", "ninthly", "ninth"],
        ["zehntens", "tenthly", "tenth"],
    ]

    static let plainEnglish: Set<String> = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]

    /// The text with the enumeration as a numbered list, or the text unchanged when it holds
    /// fewer than two counted items in order.
    public static func format(_ text: String) -> String {
        let markers = findMarkers(in: text)
        guard markers.count >= 2 else { return text }
        var intro = String(text[..<markers[0].lowerBound])
        var items: [String] = []
        for (index, marker) in markers.enumerated() {
            let end = index + 1 < markers.count ? markers[index + 1].lowerBound : text.endIndex
            items.append(String(text[marker.upperBound..<end]))
        }
        items = items.map(cleanItem)
        // When the earlier items are phrases, the sentence's final period on the last one goes too.
        if items.dropLast().allSatisfy({ !".!?".contains($0.last ?? " ") }), let last = items.last, last.hasSuffix("."),
           !last.dropLast().contains(where: { ".!?".contains($0) }) {
            items[items.count - 1] = String(last.dropLast())
        }
        items = items.map(capitaliseSentence)
        guard !items.contains(where: \.isEmpty) else { return text }
        intro = cleanIntro(intro)
        let list = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return intro.isEmpty ? list : intro + "\n" + list
    }

    /// Turns bullets back into running text when the model made a list out of sentences that only
    /// followed each other: every item is a whole sentence of six words or more, and the speaker
    /// neither announced a list nor counted. A real enumeration ("den Laptop, den Beamer und das
    /// Testkonto") has short items and stays a list.
    public static func unlistSentences(_ text: String, transcript: String) -> String {
        let lower = transcript.lowercased()
        let cues = ["stichpunkt", "folgende", "punkte", "aufzählung", "liste", "bullet", "following", "points", "list",
                    "erstens", "zweitens", "firstly", "secondly", "first,", "second,"]
        guard !cues.contains(where: { lower.contains($0) }) else { return text }
        var lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("- ") else { index += 1; continue }
            var end = index
            while end + 1 < lines.count, lines[end + 1].hasPrefix("- ") { end += 1 }
            let items = lines[index...end].map { String($0.dropFirst(2)) }
            let sentences = items.allSatisfy { item in
                ".!?".contains(item.last ?? " ") && item.split(separator: " ").count >= 6 && item.first?.isUppercase == true
            }
            guard sentences, items.count >= 2 else { index = end + 1; continue }
            var paragraph = items.joined(separator: " ")
            // The line before the list ended with a colon only because a list followed.
            if index > 0, lines[index - 1].hasSuffix(":") {
                paragraph = String(lines[index - 1].dropLast()) + ". " + paragraph
                lines.replaceSubrange((index - 1)...end, with: [paragraph])
                index -= 1
            } else {
                lines.replaceSubrange(index...end, with: [paragraph])
            }
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    /// Moves a sentence the model attached to the last item of a list back out into a paragraph of
    /// its own: "3. Die Übersetzung stimmt nicht. Das nächste Review ist am Donnerstag." becomes the
    /// item and, after an empty line, the sentence. Only when every other item of that list is a
    /// single sentence, so an item that really has two sentences in a longer list stays as it is.
    public static func separateAfterList(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let marker = #"^(\d+\.|-) "#
        func isItem(_ line: String) -> Bool { line.range(of: marker, options: .regularExpression) != nil }
        // A sentence end inside the item's text, not the "1." in front of it.
        let boundary = #"(?<=.{3})[.!?] (?=\p{Lu}\p{Ll})"#
        func body(_ line: String) -> Substring {
            line.range(of: marker, options: .regularExpression).map { line[$0.upperBound...] } ?? Substring(line)
        }
        var index = 0
        while index < lines.count {
            guard isItem(lines[index]) else { index += 1; continue }
            var end = index
            while end + 1 < lines.count, isItem(lines[end + 1]) { end += 1 }
            let others = lines[index..<end]
            let last = lines[end]
            if end > index, !others.contains(where: { body($0).range(of: boundary, options: .regularExpression) != nil }),
               let split = last.range(of: boundary, options: .regularExpression, range: body(last).startIndex..<last.endIndex) {
                let item = String(last[..<split.upperBound]).trimmingCharacters(in: .whitespaces)
                let rest = String(last[split.upperBound...]).trimmingCharacters(in: .whitespaces)
                lines[end] = item
                // The sentence opens a paragraph of its own after the list.
                lines.insert(contentsOf: ["", rest], at: end + 1)
            }
            index = end + 1
        }
        return lines.joined(separator: "\n")
    }

    /// Numbers lines that start with the ordinal words in order ("Erstens, das Budget" on one
    /// line, "Zweitens, …" on the next), as the model sometimes leaves them. A run needs at
    /// least two such lines; all other lines stay as they are.
    public static func formatLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        func ordinal(_ line: String, at position: Int) -> String? {
            guard position < ordinals.count else { return nil }
            let lower = line.lowercased()
            return ordinals[position].first { lower.hasPrefix($0 + ",") || lower.hasPrefix($0 + " ") }
        }
        var index = 0
        while index < lines.count {
            var run: [(line: Int, word: String)] = []
            while index + run.count < lines.count, let word = ordinal(lines[index + run.count], at: run.count) {
                run.append((index + run.count, word))
            }
            if run.count >= 2 {
                for (position, entry) in run.enumerated() {
                    let item = String(lines[entry.line].dropFirst(entry.word.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", :"))
                    lines[entry.line] = "\(position + 1). " + capitaliseSentence(item)
                }
            }
            index += max(1, run.count)
        }
        return lines.joined(separator: "\n")
    }

    /// Numbers a "- " list when the speaker counted its items ("erstens …, zweitens …") and the
    /// model wrote them as bullets anyway: the first run of bullet lines with as many lines as
    /// the transcript has counted items.
    public static func numberCountedBullets(_ text: String, transcript: String) -> String {
        let counted = findMarkers(in: transcript).count
        guard counted >= 2 else { return text }
        var lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            var end = index
            while end < lines.count, lines[end].hasPrefix("- ") { end += 1 }
            if end - index == counted {
                for (position, line) in lines[index..<end].enumerated() {
                    lines[index + position] = "\(position + 1). " + line.dropFirst(2)
                }
                return lines.joined(separator: "\n")
            }
            index = max(end, index + 1)
        }
        return text
    }

    /// The ranges of the ordinal words, one per position, in order.
    static func findMarkers(in text: String) -> [Range<String.Index>] {
        var markers: [Range<String.Index>] = []
        var searchFrom = text.startIndex
        for words in ordinals {
            guard let range = firstOrdinal(words, in: text, from: searchFrom) else { break }
            markers.append(range)
            searchFrom = range.upperBound
        }
        return markers
    }

    static func firstOrdinal(_ words: [String], in text: String, from start: String.Index) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for word in words {
            var from = start
            while let range = text.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive], range: from..<text.endIndex) {
                if !plainEnglish.contains(word) || clauseStart(before: range.lowerBound, in: text) {
                    if best == nil || range.lowerBound < best!.lowerBound { best = range }
                    break
                }
                from = range.upperBound
            }
        }
        return best
    }

    /// Whether a word begins a clause: at the start of the text, after a punctuation mark, or
    /// after "and"/"und".
    static func clauseStart(before index: String.Index, in text: String) -> Bool {
        let before = text[..<index].trimmingCharacters(in: .whitespaces)
        guard let last = before.last else { return true }
        if ".,;:!?\n".contains(last) { return true }
        let lower = before.lowercased()
        return lower.hasSuffix(" and") || lower.hasSuffix(" und") || lower == "and" || lower == "und"
    }

    static func cleanItem(_ item: String) -> String {
        var result = item.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.first, ",:;-".contains(first) { result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces) }
        for suffix in [" und", " and", " Und", " And"] where result.hasSuffix(suffix) { result = String(result.dropLast(suffix.count)) }
        while let last = result.last, ",;".contains(last) || last.isWhitespace { result = String(result.dropLast()) }
        return result
    }

    /// An item that is a full sentence starts with a capital; a short phrase stays as spoken.
    static func capitaliseSentence(_ item: String) -> String {
        guard let last = item.last, ".!?".contains(last), let first = item.first, first.isLowercase else { return item }
        return first.uppercased() + item.dropFirst()
    }

    static func cleanIntro(_ intro: String) -> String {
        var result = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" und", " and"] where result.lowercased().hasSuffix(suffix) { result = String(result.dropLast(suffix.count)) }
        while let last = result.last, ",.;".contains(last) || last.isWhitespace { result = String(result.dropLast()) }
        guard !result.isEmpty else { return "" }
        return result.hasSuffix(":") || result.hasSuffix("?") || result.hasSuffix("!") ? result : result + ":"
    }
}
