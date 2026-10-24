@testable import DictationCore
import AppKit
import AVFoundation
import Foundation
import Testing

final class CapturingTransport: HTTPTransport, @unchecked Sendable {
    var lastRequest: URLRequest?
    let status: Int
    let body: String

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

struct CleanerTests {
    static func completion(_ content: String) -> String {
        let object: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    let request = CleanupRequest(transcript: "äh hallo welt wie geht es", language: "de", style: .chat, vocabulary: ["Polarion"])

    @Test func appleModelGetsInstructionsWithExamplesAndTheLastTurnAsPrompt() {
        let messages = [ChatMessage(role: "system", content: "Clean up."), ChatMessage(role: "user", content: "ähm hallo"),
                        ChatMessage(role: "assistant", content: "{\"text\":\"Hallo\"}"), ChatMessage(role: "user", content: "äh test")]
        let (instructions, prompt) = AppleModelCleaner.split(messages)
        #expect(instructions == "Clean up.\n\nExamples:\nInput: ähm hallo\nAnswer: {\"text\":\"Hallo\"}")
        #expect(prompt == "äh test")
        #expect(LocalModel.make(LLMSettings(provider: "apple")) is AppleModelCleaner)
        #expect(LocalModel.make(LLMSettings()) is OpenAICompatibleCleaner)
    }

    @Test func buildsChatCompletionRequest() async throws {
        let transport = CapturingTransport(body: Self.completion(#"{"text":"Hallo Welt, wie geht es?"}"#))
        let cleaner = OpenAICompatibleCleaner(settings: LLMSettings(baseURL: "http://localhost:1234/"), transport: transport)
        let text = try await cleaner.clean(request)
        #expect(text == "Hallo Welt, wie geht es?")

        let sent = try #require(transport.lastRequest)
        #expect(sent.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
        let body = try #require(JSONSerialization.jsonObject(with: sent.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "qwen/qwen3-4b-2507")
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.first?["role"] == "system")
        #expect(messages.first?["content"]?.contains("Polarion") == false)
        #expect(messages.last?["content"] == "<terms>Polarion</terms>\n" + #"<transcript lang="de" target="chat">äh hallo welt wie geht es</transcript>"#)
    }

    @Test func promptPrefixDoesNotDependOnStyleOrTranscript() {
        let builder = PromptBuilder()
        let a = builder.messages(transcript: "eins", language: "de", style: .mail, vocabulary: ["X"])
        let b = builder.messages(transcript: "zwei", language: "en", style: .code, vocabulary: ["Y", "Z"])
        #expect(Array(a.dropLast()) == Array(b.dropLast()))
        #expect(a.last != b.last)
    }

    @Test func httpErrorThrows() async {
        let transport = CapturingTransport(status: 404, body: #"{"error":"model not found"}"#)
        let cleaner = OpenAICompatibleCleaner(settings: LLMSettings(), transport: transport)
        await #expect(throws: LLMError.self) { try await cleaner.clean(request) }
    }

    @Test func rejectedReplyThrows() async {
        let transport = CapturingTransport(body: Self.completion(#"{"text":""}"#))
        let cleaner = OpenAICompatibleCleaner(settings: LLMSettings(), transport: transport)
        await #expect(throws: LLMError.rejected(.empty)) { try await cleaner.clean(request) }
    }

    @Test func promptExamplesAlternateAndEndWithTranscript() {
        let messages = PromptBuilder().messages(transcript: "x", language: "en", style: .plain, vocabulary: [])
        #expect(messages.count == 2 + PromptBuilder.examples.count * 2)
        for (index, message) in messages.dropFirst().enumerated() {
            #expect(message.role == (index.isMultiple(of: 2) ? "user" : "assistant"))
        }
        #expect(!messages.last!.content.contains("<terms>"))
    }
}

struct SettingsTests {
    @Test func partialFileFallsBackToDefaults() throws {
        let json = #"{"llm": {"model": "other"}, "vocabulary": ["Foo"]}"#
        let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
        #expect(settings.llm.model == "other")
        #expect(settings.llm.baseURL == "http://localhost:1234")
        #expect(settings.vocabulary == ["Foo"])
        #expect(settings.asr.model == ASRSettings().model)
        #expect(settings.minimumPressSeconds == 0.25)
    }

    @Test func storeCreatesDefaultsAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        var settings = try store.load()
        #expect(settings == DictationSettings())
        settings.snippets = [Snippet(trigger: "a", text: "b")]
        settings.appStyles = ["com.example": .code]
        try store.save(settings)
        #expect(try store.load() == settings)
    }

    @Test func fixedLanguage() {
        #expect(ASRSettings(language: "auto").fixedLanguage == nil)
        #expect(ASRSettings(language: "de").fixedLanguage == "de")
    }

    @Test func styleResolverPrefersOverrides() {
        let resolver = AppStyleResolver(overrides: ["md.obsidian": .plain])
        #expect(resolver.style(for: "md.obsidian") == .plain)
        #expect(resolver.style(for: "com.microsoft.teams2") == .work)
        #expect(resolver.style(for: "unknown.app") == .plain)
        #expect(resolver.style(for: nil) == .plain)
    }
}

struct HistoryTests {
    @Test func keepsOnlyTheLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url, limit: 3)
        for i in 0..<5 {
            let result = DictationResult(rawTranscript: "r\(i)", language: "de", style: .plain, text: "t\(i)",
                                         cleanup: .cleaned, transcriptionSeconds: 0.5, cleanupSeconds: 0.7)
            try store.append(HistoryEntry(date: Date(timeIntervalSince1970: Double(i)), bundleId: nil, result: result))
        }
        let entries = try store.entries()
        #expect(entries.map(\.text) == ["t2", "t3", "t4"])
        #expect(store.last()?.raw == "r4")
    }
}

struct PasteboardTests {
    @Test func restoresPreviousContents() {
        let board = NSPasteboard(name: NSPasteboard.Name("LocalDictationTest-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("previous", forType: .string)

        let snapshot = PasteboardSnapshot(pasteboard: board)
        snapshot.save()
        snapshot.write("dictated")
        #expect(board.string(forType: .string) == "dictated")
        #expect(board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        #expect(snapshot.restore())
        #expect(board.string(forType: .string) == "previous")
    }

    @Test func skipsPromisedTypes() {
        #expect(PasteboardSnapshot.isPromise(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")))
        #expect(PasteboardSnapshot.isPromise(NSPasteboard.PasteboardType("dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu")))
        #expect(!PasteboardSnapshot.isPromise(.string))
        #expect(!PasteboardSnapshot.isPromise(.rtf))
    }

    @Test func leavesNewerCopyAlone() {
        let board = NSPasteboard(name: NSPasteboard.Name("LocalDictationTest-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("previous", forType: .string)

        let snapshot = PasteboardSnapshot(pasteboard: board)
        snapshot.save()
        snapshot.write("dictated")
        board.clearContents()
        board.setString("user copied this", forType: .string)
        #expect(!snapshot.restore())
        #expect(board.string(forType: .string) == "user copied this")
    }
}

struct AudioTests {
    @Test func resamples48kStereoTo16kMono() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for channel in 0..<2 {
            for i in 0..<4_800 { buffer.floatChannelData![channel][i] = 0.5 }
        }
        let resampler = try #require(AudioResampler(inputFormat: input))
        var samples: [Float] = []
        for _ in 0..<3 { samples += resampler.convert(buffer) }
        samples += resampler.flush()
        #expect(abs(samples.count - 4_800) <= 16)
        let middle = samples[samples.count / 2]
        #expect(abs(middle - 0.5) < 0.05)

        let next = resampler.convert(buffer) + resampler.flush()
        #expect(abs(next.count - 1_600) <= 16)
    }

    @Test func silenceDetection() {
        #expect(AudioLevel.isSilent([Float](repeating: 0.001, count: 16_000)))
        var samples = [Float](repeating: 0, count: 16_000)
        for i in 8_000..<8_400 { samples[i] = 0.3 }
        #expect(!AudioLevel.isSilent(samples))
    }

    @Test func meterValueRange() {
        #expect(AudioLevel.meterValue(rms: 0) == 0)
        #expect(AudioLevel.meterValue(rms: 1) == 1)
        #expect(AudioLevel.meterValue(rms: 0.01) > 0)
    }
}

struct WAVFileTests {
    @Test func writesHeaderAndSamples() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WAVFile.write(samples: [0, 1, -1, 0.5], sampleRate: 16_000, to: url)
        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        let second = data.subdata(in: 46..<48).withUnsafeBytes { $0.load(as: Int16.self) }
        #expect(second == Int16.max)
    }
}

struct ToneTests {
    @Test func tonesAppearInSystemPromptExceptForCode() {
        let builder = PromptBuilder()
        let prompt = builder.systemPrompt(tones: [.chat: .veryCasual, .code: .veryCasual, .mail: .formal])
        #expect(prompt.contains("Tone very casual"))
        #expect(prompt.components(separatedBy: "Tone very casual").count == 2)
        #expect(!prompt.contains("Tone casual"))
    }

    @Test func settingsMapTonesToStyles() throws {
        let json = #"{"tones": {"chat": "veryCasual", "mail": "casual", "unknown": "formal"}}"#
        let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
        // Work messengers start with the tone of the messengers.
        #expect(settings.tonesByStyle == [.chat: .veryCasual, .work: .veryCasual, .mail: .casual])
        #expect(DictationSettings().tonesByStyle == [.chat: .casual, .work: .casual])
    }
}

struct StatsTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    func entry(_ text: String, daysAgo: Int, audio: Double?, now: Date) -> HistoryEntry {
        var result = DictationResult(rawTranscript: text, language: "de", style: .plain, text: text,
                                     cleanup: .cleaned, transcriptionSeconds: 0.8, cleanupSeconds: 1)
        result.audioSeconds = audio ?? 0
        var e = HistoryEntry(date: calendar.date(byAdding: .day, value: -daysAgo, to: now)!, bundleId: nil, result: result)
        e.audioSeconds = audio
        return e
    }

    @Test func countsWordsSpeedAndStreak() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let entries = [
            entry("eins zwei drei vier", daysAgo: 0, audio: 2, now: now),
            entry("fünf sechs", daysAgo: 1, audio: 1, now: now),
            entry("alt - eintrag ohne Länge", daysAgo: 2, audio: nil, now: now),
            entry("vor langer zeit", daysAgo: 5, audio: 3, now: now),
        ]
        let stats = DictationStats(entries: entries, now: now, calendar: calendar)
        #expect(stats.totalWords == 4 + 2 + 4 + 3)
        #expect(stats.wordsPerMinute == Int((Double(4 + 2 + 3) / 6 * 60).rounded()))
        #expect(stats.dayStreak == 3)
    }

    @Test func streakSurvivesUntilTheEndOfToday() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let entries = [entry("gestern", daysAgo: 1, audio: 1, now: now), entry("vorgestern", daysAgo: 2, audio: 1, now: now)]
        #expect(DictationStats(entries: entries, now: now, calendar: calendar).dayStreak == 2)
        #expect(DictationStats(entries: [], now: now, calendar: calendar) == DictationStats(entries: [], now: now, calendar: calendar))
        #expect(DictationStats(entries: [], now: now, calendar: calendar).wordsPerMinute == 0)
    }

    @Test func groupsByDayNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let days = HistoryDay.group([entry("a", daysAgo: 1, audio: 1, now: now), entry("b", daysAgo: 0, audio: 1, now: now),
                                     entry("c", daysAgo: 1, audio: 1, now: now.addingTimeInterval(60))], calendar: calendar)
        #expect(days.count == 2)
        #expect(days[0].entries.map(\.text) == ["b"])
        #expect(days[1].entries.map(\.text) == ["c", "a"])
    }

    @Test func oldHistoryLinesWithoutAudioStillDecode() throws {
        let line = #"{"bundleId":null,"cleanup":"cleaned","cleanupSeconds":1,"date":"2026-10-19T21:00:00Z","language":"de","raw":"x","text":"x","transcriptionSeconds":0.8}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(HistoryEntry.self, from: Data(line.utf8))
        #expect(entry.audioSeconds == nil)
    }
}

struct TeamSettingsTests {
    @Test func teamFileIsReadAsSettings() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../team/team-settings.json")
        let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(contentsOf: file))
        #expect(settings.vocabulary.contains("novaClinical"))
        #expect(settings.replacements.contains { $0.from == "Cloud Code" && $0.to == "Claude Code" })
        #expect(settings.places.contains { $0.name == "Servicedesk" })
        #expect(settings.transforms.count >= 9)
        #expect(settings.llm.model == "qwen/qwen3-4b-2507")
    }
}
