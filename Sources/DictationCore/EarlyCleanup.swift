import Foundation

/// Cleans the finished sections of a long dictation while the user is still speaking, so after
/// the key is released only the last section is left.
///
/// After every stretch recognised during the recording, the text so far is prepared and split
/// exactly as at the end. Every section but the last can no longer change: the split decides a
/// section's end from its own sentences and the one after it, which are all known. The last
/// section may still grow or be continued ("zweitens", "nein, …"), so it waits. At the end a
/// section of the final text takes the early result only when its text is the same, character
/// for character; any other section is cleaned then.
public actor EarlyCleanup {
    private var tasks: [String: Task<(String, Error?), Never>] = [:]

    public init() {}

    /// Starts the cleanup of every finished section of `text`, the stretches recognised so far.
    public func update(text: String, language: String?, bundleId: String?, pipeline: DictationPipeline) {
        guard pipeline.cleansInSections, let cleaner = pipeline.cleaner else { return }
        let main = language.flatMap { $0.isEmpty ? nil : $0 } ?? "en"
        let corrected = pipeline.prepared(TextProcessing.cleanTranscript(text), language: main)
        let sections = CleanupChunks.split(corrected)
        guard sections.count > 1 else { return }
        let settings = pipeline.settings
        let style = pipeline.style(for: bundleId)
        let vocabulary = settings.promptVocabulary(for: corrected, matcher: VocabularyMatcher(settings.vocabularyByPriority))
        let tones = settings.tonesByStyle
        for section in sections.dropLast() where tasks[Self.key(section, main)] == nil {
            tasks[Self.key(section, main)] = Task {
                await DictationPipeline.cleanSection(section, language: main, style: style, vocabulary: vocabulary,
                                                     tones: tones, cleaner: cleaner)
            }
        }
    }

    /// The cleanup started for exactly this section, if any.
    public func started(_ section: String, language: String) -> Task<(String, Error?), Never>? {
        tasks[Self.key(section, language)]
    }

    public var count: Int { tasks.count }

    public func cancel() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }

    static func key(_ section: String, _ language: String) -> String { language + "\u{1}" + section }
}
