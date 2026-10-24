import Foundation

public struct Transcript: Equatable, Sendable {
    public var text: String
    /// ISO code of the spoken language, such as "de" or "en".
    public var language: String
    /// How often Whisper decoded again at a higher temperature because a result looked unreliable.
    public var fallbacks: Int
    /// Whisper's mean token log probability; below -1 the text is mostly a guess.
    public var logProb: Double
    /// Whisper's estimate that the audio holds no speech at all, 0 to 1.
    public var noSpeech: Double

    public init(text: String, language: String, fallbacks: Int = 0, logProb: Double = 0, noSpeech: Double = 0) {
        self.text = text
        self.language = language
        self.fallbacks = fallbacks
        self.logProb = logProb
        self.noSpeech = noSpeech
    }

    /// Whisper's usual limits: a mean log probability below -1, or a likely silence with a
    /// doubtful text. Such text comes from noise, breathing or a cut word and is often in a
    /// language nobody spoke.
    public var isUnreliable: Bool {
        logProb < -1 || (noSpeech > 0.6 && logProb < -0.5)
    }
}

public protocol Transcriber: Sendable {
    /// Transcribes 16 kHz mono samples. `language` nil means detect it.
    func transcribe(samples: [Float], language: String?, vocabulary: [String]) async throws -> Transcript
}

public struct DictationResult: Equatable, Sendable {
    public enum CleanupOutcome: Equatable, Sendable {
        case cleaned
        case disabled
        case snippet
        /// Short and plain: Whisper's text was used as it is, without the language model.
        case short
        case failed(String)
    }

    public var rawTranscript: String
    public var language: String
    public var style: AppStyle
    /// The text to insert, including a trailing space when that setting is on.
    public var text: String
    public var cleanup: CleanupOutcome
    public var transcriptionSeconds: Double
    public var cleanupSeconds: Double
    /// Diagnostics: decoding fallbacks and whether the prompt echo retry ran.
    public var audioSeconds: Double = 0
    public var transcriptionFallbacks = 0
    public var promptEchoRetried = false
    /// Sections the cleanup model got, and how many of them were cleaned while the user spoke.
    public var sections = 0
    public var sectionsCleanedEarly = 0
    /// Sections taken by rule because the model failed or lost a number of the transcript.
    public var sectionsByRule = 0

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public init(rawTranscript: String, language: String, style: AppStyle, text: String,
                cleanup: CleanupOutcome, transcriptionSeconds: Double, cleanupSeconds: Double) {
        self.rawTranscript = rawTranscript
        self.language = language
        self.style = style
        self.text = text
        self.cleanup = cleanup
        self.transcriptionSeconds = transcriptionSeconds
        self.cleanupSeconds = cleanupSeconds
    }
}

/// Runs one dictation: transcription, deterministic fixes, LLM cleanup with fallback, snippets.
public struct DictationPipeline: Sendable {
    public var settings: DictationSettings
    private let transcriber: Transcriber
    /// Takes dictations of `settings.asr.longDictationSeconds` or more, when set.
    private let longTranscriber: Transcriber?
    let cleaner: TextCleaner?
    private let clock: @Sendable () -> Double

    public init(
        settings: DictationSettings,
        transcriber: Transcriber,
        longTranscriber: Transcriber? = nil,
        cleaner: TextCleaner?,
        clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.settings = settings
        self.transcriber = transcriber
        self.longTranscriber = longTranscriber
        self.cleaner = cleaner
        self.clock = clock
    }

    /// Samples shorter than this (0.3 s at 16 kHz) are not worth transcribing.
    public static let minimumSamples = 4_800

    public func run(samples: [Float], bundleId: String?) async throws -> DictationResult {
        var style = AppStyleResolver(overrides: settings.appStyles).style(for: bundleId)
        if style == .code && !settings.codeModeEnabled { style = .plain }
        guard samples.count >= Self.minimumSamples, !AudioLevel.isSilent(samples) else {
            return DictationResult(rawTranscript: "", language: "", style: style, text: "",
                                   cleanup: .disabled, transcriptionSeconds: 0, cleanupSeconds: 0)
        }

        let t0 = clock()
        let long = Double(samples.count) / 16_000 >= settings.asr.longDictationSeconds
        let transcriber = long ? longTranscriber ?? self.transcriber : self.transcriber
        var transcript = try await transcriber.transcribe(
            samples: samples, language: settings.recognitionLanguage(for: style), vocabulary: settings.vocabularyByPriority(for: style))
        var echoRetried = false
        if TextProcessing.echoesPrompt(transcript.text, vocabulary: settings.vocabularyByPriority(for: style)) {
            // Whisper repeated the vocabulary prompt; the second attempt runs without it.
            transcript = try await transcriber.transcribe(
                samples: samples, language: settings.recognitionLanguage(for: style), vocabulary: [])
            echoRetried = true
        }
        let t1 = clock()
        var result = await process(transcript: transcript, style: style)
        result.transcriptionSeconds = t1 - t0
        result.audioSeconds = Double(samples.count) / 16_000
        result.transcriptionFallbacks = transcript.fallbacks
        result.promptEchoRetried = echoRetried
        return result
    }

    /// Like `run`, for a dictation whose first stretches were recognised during the recording:
    /// only the samples after `early.end` are transcribed, in the language found before.
    /// `cleanup` holds the sections already cleaned during the recording.
    public func run(samples: [Float], bundleId: String?, early: EarlyTranscript, cleanup: EarlyCleanup? = nil) async throws -> DictationResult {
        guard !early.texts.isEmpty else { return try await run(samples: samples, bundleId: bundleId) }
        var style = AppStyleResolver(overrides: settings.appStyles).style(for: bundleId)
        if style == .code && !settings.codeModeEnabled { style = .plain }
        let t0 = clock()
        let tail = early.end < samples.count ? Array(samples[early.end...]) : []
        var texts = early.texts
        if tail.count >= Self.minimumSamples, !AudioLevel.isSilent(tail) {
            let transcriber = longTranscriber ?? self.transcriber
            let rest = try await transcriber.transcribe(samples: tail, language: early.language ?? settings.recognitionLanguage(for: style),
                                                        vocabulary: settings.vocabularyByPriority(for: style))
            texts.append(rest.text)
        }
        let t1 = clock()
        let transcript = Transcript(text: texts.joined(separator: " "), language: early.language ?? "")
        var result = await process(transcript: transcript, style: style, early: cleanup)
        result.transcriptionSeconds = t1 - t0
        result.audioSeconds = Double(samples.count) / 16_000
        return result
    }

    /// One stretch recognised during the recording, with the dictation's style and vocabulary.
    public func transcribeEarly(_ samples: [Float], bundleId: String?, language: String?) async throws -> Transcript {
        var style = AppStyleResolver(overrides: settings.appStyles).style(for: bundleId)
        if style == .code && !settings.codeModeEnabled { style = .plain }
        let transcriber = longTranscriber ?? self.transcriber
        return try await transcriber.transcribe(samples: samples, language: language ?? settings.recognitionLanguage(for: style),
                                                vocabulary: settings.vocabularyByPriority(for: style))
    }

    /// Everything after transcription. Separate so tests can run it without audio.
    /// The transcript as the cleanup model gets it: dictionary replacements, fillers and
    /// stutters removed, dictionary spelling applied. `raw` has passed `cleanTranscript`.
    public func prepared(_ raw: String, language: String) -> String {
        VocabularyMatcher(settings.vocabularyByPriority).correct(TextProcessing.removeFillers(
            TextProcessing.applyReplacements(raw, settings.replacements), language: language))
    }

    /// LM Studio gets a long dictation in sections, cleaned at the same time. A cloud model
    /// handles the whole text well, and Apple's model answers one request at a time, so sections
    /// would only make it slower; both get the text in one piece.
    public var cleansInSections: Bool {
        settings.llm.enabled && settings.ai.cleanup.engine == .local && !settings.llm.usesAppleModel
    }

    /// The app style for the app in front, as a dictation into it uses.
    public func style(for bundleId: String?) -> AppStyle {
        let style = AppStyleResolver(overrides: settings.appStyles).style(for: bundleId)
        return style == .code && !settings.codeModeEnabled ? .plain : style
    }

    /// `early` holds the sections already cleaned while the user spoke; a section with exactly
    /// the same text takes that result.
    public func process(transcript: Transcript, style: AppStyle, early: EarlyCleanup? = nil) async -> DictationResult {
        let raw = TextProcessing.cleanTranscript(transcript.text)
        let language = transcript.language.isEmpty ? "en" : transcript.language
        var result = DictationResult(rawTranscript: raw, language: language, style: style, text: "",
                                     cleanup: .disabled, transcriptionSeconds: 0, cleanupSeconds: 0)
        guard !raw.isEmpty else { return result }

        let matcher = VocabularyMatcher(settings.vocabularyByPriority)
        let corrected = prepared(raw, language: language)
        if let snippet = TextProcessing.expandSnippet(corrected, settings.snippets) {
            result.text = snippet
            result.cleanup = .snippet
            return result
        }

        var text = TextProcessing.basicCleanup(corrected)
        if TextProcessing.isShortAndPlain(corrected) {
            // Whisper already writes a short sentence with capitals and punctuation; the language
            // model would add one or two seconds and change nothing.
            text = TextProcessing.applyReplacements(style == .code ? corrected : text, settings.replacements)
            result.cleanup = .short
        } else if settings.llm.enabled, let cleaner {
            let start = clock()
            do {
                // Only the starred terms and those that occur in this dictation; the whole
                // dictionary in every prompt would make each dictation slower as it grows.
                let vocabulary = settings.promptVocabulary(for: corrected, matcher: matcher)
                let tones = settings.tonesByStyle
                let sections = cleansInSections ? CleanupChunks.split(corrected) : [corrected]
                let (parts, reused, byRule) = try await withTimeout(seconds: cleanupTimeout(for: corrected)) {
                    try await Self.clean(sections, language: language, style: style, vocabulary: vocabulary, tones: tones,
                                         cleaner: cleaner, early: early)
                }
                result.sections = sections.count
                result.sectionsCleanedEarly = reused
                result.sectionsByRule = byRule
                text = parts.joined(separator: style == .chat ? " " : "\n\n")
                text = SpellingGuard.repair(text, transcript: corrected, vocabulary: settings.vocabularyByPriority + settings.replacements.map(\.to))
                text = matcher.correct(TextProcessing.applyReplacements(text, settings.replacements))
                result.cleanup = .cleaned
            } catch {
                result.cleanup = .failed(String(describing: error))
            }
            result.cleanupSeconds = clock() - start
        }

        if let snippet = TextProcessing.expandSnippet(text, settings.snippets) {
            result.text = snippet
            result.cleanup = .snippet
            return result
        }
        // The model sets lists itself and can tell a list from talk about "erstens"; the rule
        // stands in when it did not run.
        if result.cleanup != .cleaned { text = CountedList.format(text) }
        // The chosen style by rule, so it holds even when the model ignored the instruction.
        text = ToneRules.apply(settings.tone(for: style), to: text)
        result.text = finish(withSignature(text, style: style), style: style)
        return result
    }

    /// Cleans the sections at the same time, each with the languages spoken in it. Counted items
    /// the model left as "Erstens, …" lines are numbered. A sentence whose cleaned text lost a
    /// number of the transcript ("10%" became "0,10") is taken by rule; a section whose cleanup
    /// failed too. When every section failed, the error is thrown.
    /// Returns the cleaned sections, how many of them came from `early` and how many were taken
    /// by rule.
    static func clean(_ sections: [String], language: String, style: AppStyle, vocabulary: [String],
                      tones: [AppStyle: Tone], cleaner: TextCleaner, early: EarlyCleanup? = nil) async throws -> ([String], Int, Int) {
        try await withThrowingTaskGroup(of: (Int, String, Error?, Bool).self) { group in
            for (index, section) in sections.enumerated() {
                group.addTask {
                    if let started = await early?.started(section, language: language) {
                        let (text, error) = await started.value
                        return (index, text, error, true)
                    }
                    let (text, error) = await cleanSection(section, language: language, style: style, vocabulary: vocabulary,
                                                           tones: tones, cleaner: cleaner)
                    return (index, text, error, false)
                }
            }
            var parts = [String](repeating: "", count: sections.count)
            var errors: [Error] = []
            var reused = 0
            for try await (index, text, error, early) in group {
                parts[index] = text
                if let error { errors.append(error) }
                if early { reused += 1 }
            }
            let failed = errors.filter { !($0 is CleanupChunks.NumberLost) }
            if failed.count == sections.count, let first = failed.first { throw first }
            return (parts, reused, errors.count)
        }
    }

    /// One section, cleaned by the model with the languages spoken in it, or by rule with the
    /// error when the model failed.
    static func cleanSection(_ section: String, language: String, style: AppStyle, vocabulary: [String],
                             tones: [AppStyle: Tone], cleaner: TextCleaner) async -> (String, Error?) {
        let request = CleanupRequest(transcript: section, language: CleanupChunks.languages(section, main: language),
                                     style: style, vocabulary: vocabulary, tones: tones)
        let byRule = CountedList.format(TextProcessing.basicCleanup(section))
        do {
            // The model sometimes leaves a counted enumeration in the running text ("firstly …,
            // secondly …"); the rule makes it a numbered list then.
            let answer = try await cleaner.clean(request)
            // A model that translated part of the dictation changed what was said; then the rule.
            if TranslationGuard.translated(answer, transcript: section) {
                return (byRule, TranslationGuard.Translated())
            }
            let cleaned = CountedList.separateAfterList(CountedList.formatLines(answer)
                .components(separatedBy: "\n").map(CountedList.format).joined(separator: "\n"))
            let text = CountedList.unlistSentences(CountedList.numberCountedBullets(cleaned, transcript: section), transcript: section)
            guard let repaired = CleanupChunks.repairNumbers(text, transcript: section) else {
                return (byRule, CleanupChunks.NumberLost())
            }
            // A number the speaker never said, or "halb 11" turned into 11, changes what was said.
            if CleanupChunks.inventsNumbers(repaired, transcript: section) || CleanupChunks.losesHalfHour(repaired, transcript: section) {
                return (byRule, CleanupChunks.NumberInvented())
            }
            return (repaired, nil)
        } catch {
            return (byRule, error)
        }
    }

    /// A long dictation needs longer than a short one: a 40 s dictation (560 characters) took
    /// 5.6 s to clean up on an M4, a 70 s one (880 characters) more than 12 s. The base timeout
    /// covers short dictations; every 100 characters add two seconds. Claude gets its own call
    /// time on top.
    func cleanupTimeout(for transcript: String) -> Double {
        settings.llm.timeoutSeconds + Double(transcript.count) / 50 + AITask.cleanup.extraSeconds(for: settings.ai.cleanup)
    }

    /// The email signature for mail apps, appended once.
    func withSignature(_ text: String, style: AppStyle) -> String {
        let signature = settings.emailSignature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.emailSignatureEnabled, style == .mail, !signature.isEmpty, !text.contains(signature) else { return text }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + signature
    }

    func finish(_ text: String, style: AppStyle) -> String {
        guard settings.appendTrailingSpace, style != .code, !text.hasSuffix("\n") else { return text }
        return text + " "
    }
}

public struct TimeoutError: Error, Equatable, Sendable {}

/// Runs `operation` and throws `TimeoutError` when it takes longer than `seconds`.
public func withTimeout<T: Sendable>(
    seconds: Double, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimeoutError() }
        return first
    }
}
