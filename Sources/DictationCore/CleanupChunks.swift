import Foundation
import NaturalLanguage

/// Splits a long transcript into sections the cleanup model handles one by one. A small model
/// keeps self-corrections and lists right in a short text and loses them in a long one, and the
/// sections can be cleaned at the same time.
///
/// Sections end at sentence ends. A sentence that continues an enumeration ("zweitens",
/// "second") or corrects the one before ("Nein, …") stays with what precedes it, and a list
/// stays with the sentence that introduces it, so the model sees the whole list.
public enum CleanupChunks {
    /// The model's text lost a number of the transcript that could not be put back sentence by
    /// sentence; the section was taken by rule.
    public struct NumberLost: Error {}

    /// Transcripts up to this length go to the model in one piece.
    public static let maximumCharacters = 400

    public static func split(_ text: String, maximumCharacters: Int = maximumCharacters) -> [String] {
        let sentences = Self.sentences(text)
        guard text.count > maximumCharacters, sentences.count > 1 else { return [text] }
        var chunks: [[String]] = [[]]
        for (index, sentence) in sentences.enumerated() {
            let current = chunks[chunks.count - 1]
            let length = current.joined(separator: " ").count
            let next = index + 1 < sentences.count ? sentences[index + 1] : nil
            // A sentence that opens a list or announces one keeps the list with it.
            let opensList = startsEnumeration(sentence, first: true) || (next.map { startsEnumeration($0, first: true) } ?? false)
            if !current.isEmpty, length + sentence.count > maximumCharacters,
               !continuesPrevious(sentence), !(opensList && startsEnumeration(sentence, first: false)) {
                chunks.append([sentence])
            } else {
                chunks[chunks.count - 1].append(sentence)
            }
        }
        return chunks.map { $0.joined(separator: " ") }
    }

    /// Sentences as Whisper punctuated them: a ".", "?" or "!" followed by a space ends one.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let atEnd = index + 1 == characters.count
            if ".?!".contains(character), !atEnd, characters[index + 1] == " ",
               !(character == "." && index > 0 && characters[index - 1].isNumber && isDateOrOrdinal(followedBy: characters[(index + 2)...])) {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    static let months = ["januar", "jänner", "februar", "märz", "april", "mai", "juni", "juli", "august", "september",
                         "oktober", "november", "dezember", "jan", "feb", "mär", "apr", "jun", "jul", "aug", "sep", "okt", "nov", "dez"]

    /// After "15." a month or a lowercase word means the number is a date or an ordinal ("am
    /// 15. November", "der 3. größte"), not the end of a sentence.
    static func isDateOrOrdinal(followedBy rest: ArraySlice<Character>) -> Bool {
        let word = String(rest.prefix { $0.isLetter })
        guard let first = word.first else { return false }
        return first.isLowercase || months.contains(word.lowercased())
    }

    static let continuations = ["zweitens", "drittens", "viertens", "fünftens", "sechstens", "siebtens", "achtens",
                                "second", "secondly", "third", "thirdly", "fourth", "fifth",
                                "und zweitens", "und drittens", "und viertens", "and second", "and third"]
    static let openers = ["erstens", "first", "firstly", "punkt eins"]

    static func continuesPrevious(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        return continuations.contains { lower.hasPrefix($0) } || opensCorrection(sentence)
    }

    /// Words with which a speaker takes back what was just said. The phrases count anywhere; the
    /// short words only with a comma or a sentence end after them, so "no problem", "no idea" or
    /// "oder so" are not corrections, but "um 3, no, um 4" and "at 3? No, at 5" are.
    static let correctionMarker = try! NSRegularExpression(pattern:
        #"\b(?:ach nein|oder nein|nein|ich meine|sorry|no wait|actually|i mean|scratch that|quatsch)\b"# +
        #"|\b(?:no|nope|ne|nee|oder|wait)\b(?=\s*[,.!?])"#, options: [.caseInsensitive])

    /// Where the last correction word of the sentence starts, if it has one.
    static func lastCorrection(in sentence: String) -> String.Index? {
        let matches = correctionMarker.matches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence))
        return matches.last.flatMap { Range($0.range, in: sentence)?.lowerBound }
    }

    /// True when the sentence begins by taking back the one before ("No, at 5.", "Nein, bis Dienstag.").
    static func opensCorrection(_ sentence: String) -> Bool {
        guard let first = correctionMarker.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) else { return false }
        return first.range.location == 0
    }

    /// `first`: the sentence starts a counted list ("Erstens, …"); otherwise any enumeration word.
    static func startsEnumeration(_ sentence: String, first: Bool) -> Bool {
        let lower = sentence.lowercased()
        return openers.contains { lower.hasPrefix($0) } || (!first && continuesPrevious(sentence))
    }

    /// "de", or "de+en" when sentences of several of the allowed languages occur. A sentence
    /// counts for another language only with at least four words and a clear detection, so a
    /// single English term in German speech does not count.
    public static func languages(_ text: String, main: String, allowed: [String] = ["de", "en"]) -> String {
        var found = [main]
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = allowed.map { NLLanguage(rawValue: $0) }
        for sentence in sentences(text) where sentence.split(separator: " ").count >= 4 {
            recognizer.reset()
            recognizer.processString(sentence)
            guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first, probability > 0.85 else { continue }
            if !found.contains(language.rawValue) { found.append(language.rawValue) }
        }
        return found.joined(separator: "+")
    }

    /// The cleaned text with each sentence that lost a number of the transcript replaced by
    /// that transcript sentence, cleaned by rule. The model's other sentences, with their
    /// corrections and lists, stay. Nil when a sentence cannot be matched; then the whole text
    /// is to be cleaned by rule.
    public static func repairNumbers(_ cleaned: String, transcript: String) -> String? {
        if keepsNumbers(cleaned, transcript: transcript) { return cleaned }
        var lines = cleaned.components(separatedBy: "\n")
        for sentence in sentences(transcript) where !keepsNumbers(cleaned, transcript: sentence) {
            let wanted = Set(words(sentence))
            var best: (line: Int, range: Range<String.Index>, score: Double)?
            for (index, line) in lines.enumerated() {
                for candidate in sentences(line) {
                    let score = Double(Set(words(candidate)).intersection(wanted).count) / Double(max(1, wanted.count))
                    if score > (best?.score ?? 0.5), let range = lines[index].range(of: candidate) { best = (index, range, score) }
                }
            }
            guard let best else { return nil }
            lines[best.line].replaceSubrange(best.range, with: TextProcessing.basicCleanup(sentence))
        }
        let repaired = lines.joined(separator: "\n")
        return keepsNumbers(repaired, transcript: transcript) ? repaired : nil
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// True when every number of the transcript is still in the cleaned text. A number the
    /// speaker took back may go: one before a correction in the same sentence ("Sprint 42,
    /// nein, Sprint 43"), or any number of a sentence the next one corrects ("At 3? No, at 5.").
    ///
    /// Only a fact of the kind that the correction brings may go: in "am Donnerstag um 10, nein, um
    /// 11" the 10 is taken back, Donnerstag is not.
    public static func keepsNumbers(_ cleaned: String, transcript: String) -> Bool {
        let kept = Set(numbers(cleaned))
        let all = sentences(transcript)
        func isWord(_ fact: String) -> Bool { fact.first?.isLetter == true }
        for (index, sentence) in all.enumerated() {
            let next = index + 1 < all.count && opensCorrection(all[index + 1]) ? all[index + 1] : nil
            let correction = lastCorrection(in: sentence)
            for (fact, range) in numberMatches(sentence) where !kept.contains(fact) {
                // What follows the correction: the rest of the sentence, or the correcting next sentence.
                var replacement: [String] = []
                if let correction, range.lowerBound < correction {
                    replacement = numberMatches(String(sentence[correction...])).map(\.number)
                }
                if let next { replacement += numberMatches(next).map(\.number) }
                guard replacement.contains(where: { isWord($0) == isWord(fact) }) else { return false }
            }
        }
        return true
    }

    /// The model's text holds a number the speaker never said (12.500 came back as 6500).
    public struct NumberInvented: Error {}

    /// True when the cleaned text has a number of three or more digits that is not in the
    /// transcript. Times and dates ("10.30", "15.11") are left out, because "halb 11" may rightly
    /// become 10:30; so is everything when the transcript spells out large numbers in words,
    /// which the model turns into digits.
    public static func inventsNumbers(_ cleaned: String, transcript: String) -> Bool {
        let lower = transcript.lowercased()
        if ["hundert", "tausend", "million", "hundred", "thousand"].contains(where: { lower.contains($0) }) { return false }
        let said = Set(numbers(transcript))
        return numbers(cleaned).contains { number in
            guard number.range(of: #"^\d{1,2}\.\d{1,2}$"#, options: .regularExpression) == nil else { return false }
            return number.filter(\.isNumber).count >= 3 && !said.contains(number)
        }
    }

    /// True when the transcript says "halb 11" or "viertel nach 3" and the cleaned text kept the
    /// hour but lost what goes with it: neither the word nor a time like 10:30 is left.
    public static func losesHalfHour(_ cleaned: String, transcript: String) -> Bool {
        let pattern = #"\b(?:halb|viertel nach|viertel vor|dreiviertel|half past|quarter past|quarter to)\s+\d{1,2}\b"#
        guard transcript.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        let lower = cleaned.lowercased()
        return !["halb", "viertel", "half", "quarter"].contains(where: { lower.contains($0) })
            && cleaned.range(of: #"\b\d{1,2}[:.][0-5]\d\b"#, options: .regularExpression) == nil
    }

    /// Numbers with their thousands separators removed, so "12.000" and "12,000" are the same,
    /// "14.30" and "14:30" too, and "0,10" stays different from "10".
    static func numbers(_ text: String) -> [String] {
        numberMatches(text).map(\.number)
    }

    /// Weekdays and months count like numbers: a dropped "am Donnerstag" loses a fact as much as
    /// a dropped "11" does.
    static let factWords = ["montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag",
                            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                            "januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september",
                            "oktober", "november", "dezember", "january", "february", "march", "may", "june",
                            "july", "october", "december"]

    static func numberMatches(_ text: String) -> [(number: String, range: Range<String.Index>)] {
        let words = factWords.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "\\d+(?:[.,:]\\d+)*|\\b(?:" + words + ")\\b", options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text)
        }.map { range in
            let number = String(text[range])
            if number.first?.isLetter == true { return (number.lowercased(), range) }
            // A separator followed by exactly three digits groups thousands; any other is a
            // decimal point or a time and stays.
            return (number.replacingOccurrences(of: "[.,](?=\\d{3}(?!\\d))", with: "", options: .regularExpression)
                .replacingOccurrences(of: ":", with: "."), range)
        }
    }
}
