import Foundation

/// The first transcription and the first LLM request after loading are several times slower
/// than later ones. Throwaway calls with the same options a real dictation uses (language
/// detection or the fixed language, vocabulary prompt) move that cost to launch time.
public enum Warmup {
    public static func run(transcriber: Transcriber, cleaner: TextCleaner?, settings: DictationSettings) async {
        let noise = (0..<48_000).map { _ in Float.random(in: -0.01...0.01) }
        _ = try? await transcriber.transcribe(samples: noise, language: settings.recognitionLanguage,
                                              vocabulary: settings.vocabulary)
        if let cleaner {
            // With the tones, so the system prompt is the one every dictation sends.
            let request = CleanupRequest(transcript: "this is a warm up", language: "en", style: .plain,
                                         vocabulary: settings.vocabulary, tones: settings.tonesByStyle)
            _ = try? await cleaner.clean(request)
        }
    }

    /// A tiny cleanup with the prompt every dictation starts with. LM Studio keeps its prompt
    /// cache on disk with a fixed size and drops entries; after a pause the cleanup took 25 to
    /// 70 % longer. Sent when a recording starts, it puts the prefix back into memory while the
    /// user speaks.
    public static func cleanupPrefix(_ cleaner: TextCleaner, settings: DictationSettings) async {
        let request = CleanupRequest(transcript: "kurzer test", language: "de", style: .plain, vocabulary: [],
                                     tones: settings.tonesByStyle)
        _ = try? await cleaner.clean(request)
    }
}
