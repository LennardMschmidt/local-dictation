import Foundation
import NaturalLanguage

/// Deterministic text steps that run without the LLM.
public enum TextProcessing {
    /// Phrases Whisper is known to produce on silence or noise, mostly from subtitle training data.
    static let hallucinations = [
        "untertitel im auftrag des zdf",
        "untertitel der amara.org-community",
        "untertitelung des zdf",
        "vielen dank fürs zuschauen",
        "thanks for watching",
        "thank you for watching",
        "[blank_audio]",
        "[musik]",
        "(musik)",
        "[music]",
        "(music)",
    ]

    /// Whether a transcript can go out without the language model: at most eight words, already
    /// ending with a punctuation mark from Whisper, and nothing the model would rework
    /// (corrections, lists, spoken punctuation or line breaks).
    public static func isShortAndPlain(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty, words.count <= 8, let last = trimmed.last, ".!?".contains(last) else { return false }
        // A self-correction needs the model even in a short sentence ("Let's meet at 3, no, at 4.").
        if CleanupChunks.lastCorrection(in: trimmed) != nil { return false }
        let lower = " " + text.lowercased() + " "
        let cues = [" also ", " erstens", " zweitens", " punkt ", " komma", " fragezeichen", " neue zeile", " absatz", " doppelpunkt",
                    " stichpunkt", " aufzählung", " first", " second", " bullet", " new line", " new paragraph", " period ", " comma"]
        return !cues.contains { lower.contains($0) }
    }

    /// Removes Whisper hallucinations and bracketed noise markers, and collapses whitespace.
    public static func cleanTranscript(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        // Whisper writes sounds between asterisks ("*Clap*", "*Lachen*").
        result = result.replacingOccurrences(of: #"\*[^*\n]{1,30}\*"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\((?:Musik|Music|Applaus|Applause|Lachen|Laughter)\)"#,
                                             with: " ", options: [.regularExpression, .caseInsensitive])
        result = collapseWhitespace(removeLoops(result))
        guard result.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return "" }
        return isHallucination(result) ? "" : result
    }

    /// Whether every letter belongs to the Latin alphabet as German and English write it,
    /// accents of borrowed words included. Letters such as ø, å, æ or Cyrillic only appear when
    /// Whisper read noise as another language.
    public static func isGermanOrEnglishScript(_ text: String) -> Bool {
        let foreign = Set("øØåÅæÆœŒłŁđĐþÞðÐ")
        return !text.unicodeScalars.contains { scalar in
            guard CharacterSet.letters.contains(scalar) else { return false }
            if foreign.contains(Character(scalar)) { return true }
            return scalar.value > 0x024F
        }
    }

    /// Short German and English answers that language detection cannot place ("Ja." reads as
    /// Finnish); a piece made only of these is never taken for another language.
    static let commonShortWords: Set<String> = [
        "ja", "nein", "ne", "nee", "jo", "okay", "ok", "genau", "gut", "klar", "stimmt", "richtig", "super", "danke",
        "mhm", "hm", "hmm", "mm", "mm-hmm", "äh", "ähm", "ah", "achso", "aha", "oh", "yes", "yeah", "yep", "no", "nope",
        "right", "sure", "thanks", "perfect", "good", "fine", "so", "also", "und", "and",
    ]

    /// A short piece (at most eight words) that reads clearly as a language other than German
    /// and English: Whisper is held to German or English, so such text ("Grazie.", "det er
    /// godt", "C'est un win-win") is made up from noise or from the other side's voice leaking
    /// into the microphone, not something that was said.
    public static func isForeignShortPiece(_ text: String, allowed: [String] = ["de", "en"]) -> Bool {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace || ",.!?;:…".contains($0) }).map(String.init)
        guard !words.isEmpty, words.count <= 8, !words.allSatisfy(commonShortWords.contains) else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        guard let top = hypotheses.max(by: { $0.value < $1.value }), !allowed.contains(top.key.rawValue) else { return false }
        let allowedShare = allowed.reduce(0.0) { $0 + (hypotheses[NLLanguage(rawValue: $1)] ?? 0) }
        return top.value >= 0.65 && allowedShare < 0.1
    }

    /// Thanks that Whisper writes when it hears only the other side faintly through the
    /// microphone; dropped from the recording person's track while somebody else speaks.
    public static func isEchoThanks(_ text: String) -> Bool {
        let normalized = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        let phrases: Set<String> = ["thank you", "thanks", "thank you very much", "vielen dank", "danke schön", "dankeschön",
                                    "grazie", "ende", "bye", "tschüss"]
        guard !normalized.isEmpty else { return false }
        // "Grazie. Grazie. Thank you." counts as well.
        var rest = normalized
        while !rest.isEmpty {
            guard let phrase = phrases.sorted(by: { $0.count > $1.count }).first(where: { rest.hasPrefix($0) }) else { return false }
            rest = String(rest.dropFirst(phrase.count)).trimmingCharacters(in: .whitespaces)
        }
        return true
    }

    /// Whisper sometimes gets stuck and repeats a short pattern until the window ends
    /// ("S-T-R-O-L-O-L-O-L-O …"). A run of six or more repeats of up to twelve characters is cut,
    /// together with the stray letters before it.
    static func removeLoops(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?:\b\S{1,3}-)*(\S{1,12}?[-\s,]*)\1{5,}\S*"#, with: " ", options: .regularExpression)
    }

    /// True when the transcript repeats the vocabulary prompt instead of the speech. Whisper does
    /// this on unclear audio: the output then starts with the first prompt terms in prompt order
    /// ("Jonas, Polarion, Proyect, ..."). Two of the first three terms in a row are enough.
    public static func echoesPrompt(_ text: String, vocabulary: [String]) -> Bool {
        guard vocabulary.count >= 2 else { return false }
        let words = normalizeForMatching(text).split(separator: " ").map(String.init)
        let terms = vocabulary.prefix(3).map { normalizeForMatching($0) }
        for start in 0..<max(0, terms.count - 1) {
            let pair = terms[start] + " " + terms[start + 1]
            if words.prefix(6).joined(separator: " ").contains(pair) { return true }
        }
        return false
    }

    /// True for a whole transcript that is one of the known phrases, or a short subtitle credit
    /// such as "Untertitel im Auftrag des ZDF, 2020".
    static func isHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        if hallucinations.contains(where: { normalized == $0 }) { return true }
        let words = normalized.split(separator: " ")
        return normalized.hasPrefix("untertitel") && words.count <= 8
    }

    /// Hesitation sounds that are never real words in the given language. English "um" is only
    /// removed for English, because German "um" is a preposition ("um 3 Uhr").
    static let fillers: [String: [String]] = [
        "de": ["äh", "ähm", "öhm", "ähh", "ehm", "hm", "hmm", "mhm"],
        "en": ["uh", "uhm", "um", "umm", "erm", "hmm", "mhm"],
    ]

    /// Removes hesitation sounds with the comma that usually follows them, and fixes the
    /// capital letter when the sentence started with one.
    public static func removeFillers(_ text: String, language: String) -> String {
        guard let words = fillers[language] else { return text }
        let alternation = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternation + ")(?![\\p{L}\\p{N}])[,.]?\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let removed = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let collapsed = collapseWhitespace(removeStutters(removed))
        let startedUpper = text.trimmingCharacters(in: .whitespaces).first?.isUppercase ?? false
        guard startedUpper, let first = collapsed.first, first.isLowercase else { return collapsed }
        return first.uppercased() + collapsed.dropFirst()
    }

    /// Short words that are never said twice in a row on purpose: "die die Testfälle" is a stutter.
    static let stutterWords = ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "ich", "wir", "du",
                               "er", "es", "und", "oder", "zu", "in", "mit", "the", "a", "an", "to", "and", "i", "we", "of", "in"]

    /// Removes a short word repeated right after itself. After a comma the pair is kept, because
    /// German relative clauses repeat the article on purpose ("Kunden, die die Software nutzen").
    static func removeStutters(_ text: String) -> String {
        let alternation = Set(stutterWords).sorted().joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(?<!,\\s)(?<![\\p{L}])(" + alternation + ")\\s+\\1(?![\\p{L}])",
                                                   options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    /// Replaces whole words or phrases, ignoring case. The replacement text is used as written.
    public static func applyReplacements(_ text: String, _ replacements: [Replacement]) -> String {
        var result = text
        for replacement in replacements where !replacement.from.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: replacement.from)
            let pattern = "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: replacement.to)
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    /// Returns the snippet text when the whole dictation is a snippet trigger.
    public static func expandSnippet(_ text: String, _ snippets: [Snippet]) -> String? {
        let key = normalizeForMatching(text)
        guard !key.isEmpty else { return nil }
        return snippets.first { normalizeForMatching($0.trigger) == key }?.text
    }

    /// The fallback cleanup when the LLM is off or failed: trims and capitalises the first letter.
    public static func basicCleanup(_ text: String) -> String {
        let trimmed = collapseWhitespace(text)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }

    static func normalizeForMatching(_ text: String) -> String {
        let letters = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return collapseWhitespace(String(letters))
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            .replacingOccurrences(of: " \n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
