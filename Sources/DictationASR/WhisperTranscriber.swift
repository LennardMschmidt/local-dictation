import DictationCore
import Foundation
import WhisperKit

/// Speech recognition with WhisperKit. The model loads once and stays in memory.
public actor WhisperTranscriber: Transcriber {
    public nonisolated let modelName: String
    public let downloadBase: URL
    private var whisper: WhisperKit?

    public init(modelName: String, downloadBase: URL = AppPaths.modelsDirectory) {
        self.modelName = modelName
        self.downloadBase = downloadBase
    }

    /// Downloads the model on first use, then loads and prewarms it. The first run also
    /// compiles the model for the Neural Engine and can take several minutes.
    public func load() async throws {
        guard whisper == nil else { return }
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: downloadBase,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true
        )
        whisper = try await WhisperKit(config)
    }

    public var isLoaded: Bool { whisper != nil }

    /// Whisper's input window: 30 s at 16 kHz.
    static let windowSamples = 16_000 * 30
    static let maxPromptTokens = 60
    /// 1.2 s; shorter audio is padded with silence.
    static let minimumSamples = 16_000 * 12 / 10

    public func transcribe(samples: [Float], language: String?, vocabulary: [String]) async throws -> Transcript {
        try await load()
        guard let whisper else { throw WhisperTranscriberError.notLoaded }
        // WhisperKit returns nothing for less than a second of audio, so a quick "Hallo" is
        // filled up with silence.
        var samples = samples
        if samples.count < Self.minimumSamples { samples += [Float](repeating: 0, count: Self.minimumSamples - samples.count) }
        var options = DecodingOptions(
            language: language,
            temperature: 0,
            detectLanguage: language == nil,
            withoutTimestamps: true
        )
        // When a result looks unreliable, Whisper decodes again at a higher temperature (about
        // 0.5 s each). Two retries instead of WhisperKit's five passed as many noisy test cases
        // and halved the slowest case.
        options.temperatureFallbackCount = 2
        // Whisper sees 30 s at a time. For longer recordings WhisperKit's VAD chunking cuts at
        // speech pauses; moving the window over the audio without it lost words at the boundary.
        if samples.count > Self.windowSamples {
            options.chunkingStrategy = .vad
        }
        if !vocabulary.isEmpty, let tokenizer = whisper.tokenizer {
            // Every prompt token runs through the decoder before the audio, about 4 ms each, so the
            // hint holds only the first terms (starred ones come first); the rest is put right
            // after recognition by the vocabulary matcher. Each term is counted once.
            let special = tokenizer.specialTokens.specialTokenBegin
            var terms: [String] = []
            var count = 2
            for term in vocabulary {
                let cost = tokenizer.encode(text: " \(term),").filter { $0 < special }.count
                if count + cost > Self.maxPromptTokens { break }
                terms.append(term)
                count += cost
            }
            if !terms.isEmpty {
                options.promptTokens = tokenizer.encode(text: " " + terms.joined(separator: ", ") + ".").filter { $0 < special }
                options.usePrefillPrompt = true
            }
        }
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbacks = results.reduce(0) { $0 + Int($1.timings.totalDecodingFallbacks) }
        let segments = results.flatMap(\.segments)
        let tokens = segments.reduce(0) { $0 + max(1, $1.tokens.count) }
        let logProb = segments.isEmpty ? 0 : segments.reduce(0.0) { $0 + Double($1.avgLogprob) * Double(max(1, $1.tokens.count)) } / Double(tokens)
        let noSpeech = segments.map { Double($0.noSpeechProb) }.max() ?? 0
        return Transcript(text: text, language: results.first?.language ?? language ?? "", fallbacks: fallbacks,
                          logProb: logProb, noSpeech: noSpeech)
    }

    /// Transcribes one piece of a meeting (at most 30 s). With several allowed languages the
    /// most likely of them is chosen for this piece, so a meeting may switch between them;
    /// languages outside the list are never used.
    /// A piece under four seconds is read in `preferred`, the meeting's main language so far:
    /// detection on a word or two often picks the wrong one.
    public func transcribePiece(samples: [Float], languages: [String], preferred: String? = nil,
                                vocabulary: [String]) async throws -> Transcript {
        try await load()
        guard let whisper else { throw WhisperTranscriberError.notLoaded }
        var language = languages.first
        if let preferred, languages.contains(preferred), samples.count < 16_000 * 4 {
            language = preferred
        } else if languages.count > 1, let detected = try? await whisper.detectLangauge(audioArray: samples) {
            language = languages.max { (detected.langProbs[$0] ?? -.infinity) < (detected.langProbs[$1] ?? -.infinity) }
        }
        var result = try await transcribe(samples: samples, language: language, vocabulary: vocabulary)
        // Whisper now and then returns nothing for a long stretch of clear speech, mostly when
        // the vocabulary prompt throws it off; a second pass without the prompt finds the words.
        if result.text.trimmingCharacters(in: .whitespaces).isEmpty, samples.count >= 16_000 * 3, !AudioLevel.isSilent(samples) {
            result = try await transcribe(samples: samples, language: language, vocabulary: [])
        }
        return result
    }
}

public enum AudioFile {
    /// Reads an audio file and converts it to 16 kHz mono floats.
    public static func loadSamples(path: String) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
    }
}

public enum WhisperTranscriberError: Error {
    case notLoaded
}
