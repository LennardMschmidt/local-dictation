@testable import DictationCore
import Foundation
import Testing

struct StubTranscriber: Transcriber {
    var transcript: Transcript
    func transcribe(samples: [Float], language: String?, vocabulary: [String]) async throws -> Transcript {
        transcript
    }
}

struct StubCleaner: TextCleaner {
    var reply: @Sendable (CleanupRequest) async throws -> String
    func clean(_ request: CleanupRequest) async throws -> String {
        try await reply(request)
    }
}

struct FailingCleaner: TextCleaner {
    struct Failure: Error {}
    func clean(_ request: CleanupRequest) async throws -> String { throw Failure() }
}

struct PipelineTests {
    /// One second of a 440 Hz tone, loud enough to pass the silence check.
    static let speechLikeSamples: [Float] = (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.2 }

    func pipeline(_ text: String, language: String = "de", cleaner: TextCleaner?,
                  settings: DictationSettings = DictationSettings()) -> DictationPipeline {
        DictationPipeline(settings: settings,
                          transcriber: StubTranscriber(transcript: Transcript(text: text, language: language)),
                          cleaner: cleaner)
    }

    @Test func cleanedTextGetsTrailingSpace() async throws {
        let p = pipeline("äh hallo welt", cleaner: StubCleaner { _ in "Hallo Welt." })
        let result = try await p.run(samples: Self.speechLikeSamples, bundleId: nil)
        #expect(result.text == "Hallo Welt. ")
        #expect(result.cleanup == .cleaned)
        #expect(result.rawTranscript == "äh hallo welt")
    }

    @Test func codeStyleGetsNoTrailingSpace() async throws {
        let p = pipeline("git status", language: "en", cleaner: StubCleaner { _ in "git status" })
        let result = try await p.run(samples: Self.speechLikeSamples, bundleId: "com.microsoft.VSCode")
        #expect(result.style == .code)
        #expect(result.text == "git status")
    }

    @Test func cleanerReceivesLanguageStyleAndVocabulary() async throws {
        let seen = Recorder()
        let p = pipeline("hi paul", language: "de", cleaner: StubCleaner { request in
            await seen.set(request)
            return "Hi Paul"
        })
        _ = try await p.run(samples: Self.speechLikeSamples, bundleId: "com.microsoft.Outlook")
        let request = try #require(await seen.request)
        #expect(request.language == "de")
        #expect(request.style == .mail)
        // Only terms that occur in the dictation go into the prompt.
        #expect(request.vocabulary.contains("Jonas") == false)
        #expect(request.vocabulary.isEmpty)
    }

    @Test func failingCleanerFallsBackToRawText() async throws {
        let p = pipeline("hallo welt", cleaner: FailingCleaner())
        let result = try await p.run(samples: Self.speechLikeSamples, bundleId: nil)
        #expect(result.text == "Hallo welt ")
        guard case .failed = result.cleanup else {
            Issue.record("expected a failed cleanup, got \(result.cleanup)")
            return
        }
    }

    @Test func slowCleanerTimesOut() async throws {
        var settings = DictationSettings()
        settings.llm.timeoutSeconds = 0.2
        let p = pipeline("hallo welt", cleaner: StubCleaner { _ in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return "too late"
        }, settings: settings)
        let start = Date()
        let result = try await p.run(samples: Self.speechLikeSamples, bundleId: nil)
        #expect(Date().timeIntervalSince(start) < 1.5)
        #expect(result.text == "Hallo welt ")
    }

    @Test func disabledCleanupSkipsCleaner() async throws {
        var settings = DictationSettings()
        settings.llm.enabled = false
        let p = pipeline("hallo welt", cleaner: FailingCleaner(), settings: settings)
        let result = try await p.run(samples: Self.speechLikeSamples, bundleId: nil)
        #expect(result.cleanup == .disabled)
        #expect(result.text == "Hallo welt ")
    }

    @Test func silenceIsNotTranscribed() async throws {
        let p = pipeline("Untertitel im Auftrag des ZDF", cleaner: FailingCleaner())
        let result = try await p.run(samples: [Float](repeating: 0, count: 16_000), bundleId: nil)
        #expect(result.isEmpty)
    }

    @Test func hallucinationIsDropped() async throws {
        let p = pipeline("Vielen Dank fürs Zuschauen!", cleaner: FailingCleaner())
        let result = try await p.run(samples: Self.speechLikeSamples, bundleId: nil)
        #expect(result.isEmpty)
    }

    @Test func snippetReplacesWholeDictation() async throws {
        var settings = DictationSettings()
        settings.snippets = [Snippet(trigger: "meine signatur", text: "Viele Grüße\nJonas")]
        let p = pipeline("Meine Signatur.", cleaner: FailingCleaner(), settings: settings)
        let result = try await p.run(samples: Self.speechLikeSamples, bundleId: nil)
        #expect(result.text == "Viele Grüße\nJonas")
        #expect(result.cleanup == .snippet)
    }

    @Test func replacementsApplyBeforeAndAfterCleanup() async throws {
        var settings = DictationSettings()
        settings.replacements = [Replacement(from: "polarian", to: "Polarion")]
        let seen = Recorder()
        let p = pipeline("das polarian projekt", cleaner: StubCleaner { request in
            await seen.set(request)
            return "Das Polarian Projekt."
        }, settings: settings)
        let result = try await p.run(samples: Self.speechLikeSamples, bundleId: nil)
        #expect(await seen.request?.transcript == "das Polarion projekt")
        #expect(result.text == "Das Polarion Projekt. ")
    }
}

/// Echoes the vocabulary prompt while it gets one, and returns real text without it.
struct EchoingTranscriber: Transcriber {
    let calls = Counter()
    func transcribe(samples: [Float], language: String?, vocabulary: [String]) async throws -> Transcript {
        await calls.increment()
        if vocabulary.isEmpty { return Transcript(text: "das ist der echte text", language: "de") }
        return Transcript(text: vocabulary.joined(separator: ", ") + ".", language: "de")
    }
}

actor Counter {
    var value = 0
    func increment() { value += 1 }
}

struct PromptEchoPipelineTests {
    @Test func promptEchoTriggersSecondAttemptWithoutVocabulary() async throws {
        var settings = DictationSettings(vocabulary: ["Jonas", "Polarion", "LiveDoc"])
        settings.llm.enabled = false
        let transcriber = EchoingTranscriber()
        let pipeline = DictationPipeline(settings: settings, transcriber: transcriber, cleaner: nil)
        let result = try await pipeline.run(samples: PipelineTests.speechLikeSamples, bundleId: nil)
        #expect(result.rawTranscript == "das ist der echte text")
        #expect(await transcriber.calls.value == 2)
    }
}

actor Recorder {
    var request: CleanupRequest?
    func set(_ request: CleanupRequest) { self.request = request }
}

struct EarlyRecognitionTests {
    private func speech(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16_000)).map { sin(Float($0) * 0.05) * 0.3 } }
    private func pause(_ seconds: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(seconds * 16_000)) }

    @Test func cutsInThePauseAfterEnoughSpeech() {
        let samples = speech(5) + pause(0.8) + speech(5) + pause(0.8) + speech(3)
        let cut = EarlyRecognition.cut(in: samples, from: 0) ?? 0
        let seconds = Double(cut) / 16_000
        // The first pause is too early (5 s), the second one (after 10.8 s) is taken.
        #expect(seconds > 10.8)
        #expect(seconds < 11.6)
    }

    @Test func noCutWithoutPauseOrTooShort() {
        #expect(EarlyRecognition.cut(in: speech(20), from: 0) == nil)
        #expect(EarlyRecognition.cut(in: speech(4) + pause(1) + speech(2), from: 0) == nil)
    }
}
