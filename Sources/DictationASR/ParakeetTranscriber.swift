import DictationCore
import FluidAudio
import Foundation

/// Speech recognition with NVIDIA's Parakeet TDT (v3 or Ultra) through FluidAudio on the Neural
/// Engine. Parakeet writes punctuation and capitals itself and takes no vocabulary prompt; the
/// dictionary works after recognition. The language is not reported, so it is told apart by
/// common German words.
public actor ParakeetTranscriber: Transcriber {
    public enum Variant: String, Sendable {
        case v3, ultra

        var version: AsrModelVersion { self == .ultra ? .ultra : .v3 }
    }

    public nonisolated let variant: Variant
    private let directory: URL
    private var manager: AsrManager?
    /// Looks for dictionary terms in the audio after recognition and puts them in where it hears
    /// them; built for the vocabulary of the last call and rebuilt when it changes.
    private var boosting: (key: String, session: VocabularyBoostingSession)?
    private var ctcModels: CtcModels?
    /// Known misrecognitions per term ("TLD file" for "tl;dv"), from the dictionary's replacements.
    private var aliases: [String: [String]] = [:]
    public var boostsVocabulary = true

    public func setBoosting(_ on: Bool) {
        boostsVocabulary = on
    }

    public func setAliases(_ aliases: [String: [String]]) {
        self.aliases = aliases
    }

    public init(variant: Variant = .v3, directory: URL = AppPaths.modelsDirectory.appendingPathComponent("parakeet")) {
        self.variant = variant
        self.directory = directory.appendingPathComponent(variant.rawValue)
    }

    /// Downloads the model on first use (about 0.5 GB) and loads it.
    public func load() async throws {
        guard manager == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let models = try await AsrModels.downloadAndLoad(to: directory, version: variant.version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    public func transcribe(samples: [Float], language: String?, vocabulary: [String]) async throws -> Transcript {
        try await load()
        guard let manager else { throw WhisperTranscriberError.notLoaded }
        // Parakeet needs at least a second of audio; shorter recordings are padded with silence.
        var samples = samples
        if samples.count < 16_000 { samples += [Float](repeating: 0, count: 16_000 - samples.count) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let hint = language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if boostsVocabulary, !vocabulary.isEmpty, let timings = result.tokenTimings, !timings.isEmpty,
           let session = try? await session(for: vocabulary),
           let rescored = await session.rescore(text: text, tokenTimings: timings, audioSamples: samples), rescored.wasModified {
            text = rescored.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Transcript(text: text, language: language ?? Self.guessLanguage(text))
    }

    private func session(for vocabulary: [String]) async throws -> VocabularyBoostingSession {
        let key = vocabulary.joined(separator: "|") + "#" + aliases.map { "\($0.key)=\($0.value.joined(separator: ","))" }.sorted().joined()
        if let boosting, boosting.key == key { return boosting.session }
        if ctcModels == nil { ctcModels = try await CtcModels.downloadAndLoad() }
        guard let ctcModels else { throw WhisperTranscriberError.notLoaded }
        let terms = vocabulary.map { CustomVocabularyTerm(text: $0, aliases: aliases[$0]) }
        let session = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: terms), ctcModels: ctcModels)
        boosting = (key, session)
        return session
    }

    /// "de" when common German words make up a noticeable part of the text, otherwise "en".
    static func guessLanguage(_ text: String) -> String {
        let german: Set<String> = ["der", "die", "das", "und", "ist", "nicht", "ich", "wir", "du", "ein", "eine", "mit", "auf",
                                   "für", "zu", "den", "dem", "auch", "noch", "dass", "kannst", "habe", "hat", "bis", "wenn", "aber"]
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return "en" }
        let count = words.filter(german.contains).count
        return Double(count) / Double(words.count) >= 0.08 ? "de" : "en"
    }
}
