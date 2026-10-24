import Foundation

/// Notices when the cleanup model translated part of a dictation, which rule 2 of the prompt
/// forbids but a small model still does now and then ("…, but the frontend still shows the old
/// version" came back in German). Cleaning removes fillers and repeated words, but it keeps the
/// short function words of a language; when most of them are gone, the words were translated.
public enum TranslationGuard {
    /// The cleaned text lost a language of the transcript; the section is taken by rule.
    public struct Translated: Error {}

    static let functionWords: [String: Set<String>] = [
        "de": ["der", "die", "das", "den", "dem", "und", "aber", "ist", "sind", "war", "noch", "nicht", "mit",
               "für", "auf", "ein", "eine", "einen", "dass", "wir", "ich", "es", "zu", "von", "im", "auch"],
        "en": ["the", "and", "but", "is", "are", "was", "were", "still", "this", "that", "with", "for", "not",
               "have", "has", "will", "to", "of", "it", "we", "you", "in", "on", "be"],
    ]

    /// True when the cleaned text keeps fewer than half of a language's function words (at least
    /// three in the transcript) and at the same time has more of the other language's than the
    /// transcript. A self-correction drops words too ("the blue design, scratch that, the green
    /// one"), but it adds none of another language.
    public static func translated(_ cleaned: String, transcript: String) -> Bool {
        let before = words(transcript)
        let after = words(cleaned)
        func count(_ words: [String], _ language: String) -> Int {
            words.filter { functionWords[language]?.contains($0) ?? false }.count
        }
        for (language, other) in [("de", "en"), ("en", "de")] {
            let had = count(before, language)
            guard had >= 3 else { continue }
            if Double(count(after, language)) < Double(had) * 0.5, count(after, other) > count(before, other) { return true }
        }
        return false
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }
}
