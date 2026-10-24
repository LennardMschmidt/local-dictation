@testable import DictationCore
import Foundation
import Testing

struct InsightsTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func entry(raw: String, text: String, app: String?, daysAgo: Int, language: String = "de", audio: Double = 3) -> HistoryEntry {
        var result = DictationResult(rawTranscript: raw, language: language, style: .plain, text: text,
                                     cleanup: .cleaned, transcriptionSeconds: 0.8, cleanupSeconds: 1)
        result.audioSeconds = audio
        return HistoryEntry(date: calendar.date(byAdding: .day, value: -daysAgo, to: now)!, bundleId: app, result: result)
    }

    @Test func emptyHistoryGivesZeros() {
        let insights = Insights(entries: [], now: now, calendar: calendar)
        #expect(insights.totalWords == 0)
        #expect(insights.categories.isEmpty)
        #expect(insights.longestStreak == 0)
    }

    @Test func countsCorrectionsFillersAndDictionaryUse() {
        let entries = [
            entry(raw: "äh das polarion projekt am dienstag nein am mittwoch",
                  text: "Das Polarion-Projekt am Mittwoch.", app: "com.microsoft.teams2", daysAgo: 0),
        ]
        let insights = Insights(entries: entries, vocabulary: ["Polarion"], now: now, calendar: calendar)
        // Raw words: äh das polarion projekt am dienstag nein am mittwoch (9); kept: das polarion projekt am mittwoch (5).
        #expect(insights.wordsCorrected == 4)
        #expect(insights.fillersRemoved == 1)
        #expect(insights.dictionaryFixes == 1)
    }

    @Test func groupsAppsIntoCategories() {
        let entries = [
            entry(raw: "a", text: "eins", app: "com.microsoft.teams2", daysAgo: 0),
            entry(raw: "b", text: "zwei", app: "com.microsoft.teams2", daysAgo: 0),
            entry(raw: "c", text: "drei", app: "com.microsoft.Outlook", daysAgo: 0),
            entry(raw: "d", text: "vier", app: "com.unknown.app", daysAgo: 0),
        ]
        let insights = Insights(entries: entries, now: now, calendar: calendar)
        #expect(insights.appsUsed == 3)
        #expect(insights.categories.first == .init(category: .workMessages, dictations: 2, share: 0.5))
        #expect(insights.categories.first { $0.category == .emails }?.dictations == 1)
        #expect(insights.categories.first { $0.category == .other }?.dictations == 1)
        #expect(insights.categories.count == UsageCategory.allCases.count)
    }

    @Test func longestStreakAndWordsPerDay() {
        let entries = [0, 1, 4, 5, 6, 7].map { entry(raw: "x", text: "zwei Wörter", app: nil, daysAgo: $0) }
            + [entry(raw: "x", text: "noch drei Wörter", app: nil, daysAgo: 0)]
        let insights = Insights(entries: entries, now: now, calendar: calendar)
        #expect(insights.currentStreak == 2)
        #expect(insights.longestStreak == 4)
        #expect(insights.wordsPerDay[calendar.startOfDay(for: now)] == 5)
    }

    @Test func voiceFigures() {
        let entries = [
            entry(raw: "x", text: "Polarion Workshop Polarion", app: nil, daysAgo: 0, language: "de"),
            entry(raw: "x", text: "Deploy the Polarion widget", app: nil, daysAgo: 0, language: "en"),
            entry(raw: "x", text: "Polarion und Workshop", app: nil, daysAgo: 0, language: "de"),
        ]
        let insights = Insights(entries: entries, now: now, calendar: calendar)
        #expect(insights.languages.first?.code == "de")
        #expect(insights.languages.first?.dictations == 2)
        #expect(insights.topWords.first?.word == "polarion")
        #expect(insights.topWords.first?.count == 4)
        #expect(!insights.topWords.contains { $0.word == "und" || $0.word == "the" })
        #expect(insights.averageWords == (3 + 4 + 3) / 3)
        #expect(insights.hours.reduce(0, +) == 3)
    }

    @Test func typingFactor() {
        let entries = [entry(raw: "x", text: Array(repeating: "wort", count: 20).joined(separator: " "), app: nil, daysAgo: 0, audio: 10)]
        let insights = Insights(entries: entries, now: now, calendar: calendar)
        #expect(insights.wordsPerMinute == 120)
        #expect(insights.typingFactor == 3)
    }
}

struct TransformTests {
    @Test func matchesSpokenTransformNames() {
        let transforms = Transform.presets
        #expect(Transform.matching("polish", in: transforms)?.name == "Polish")
        #expect(Transform.matching("Mach mal Polish.", in: transforms)?.name == "Polish")
        #expect(Transform.matching("prompt engineer", in: transforms)?.name == "Prompt Engineer")
        #expect(Transform.matching("make this sound a lot friendlier and also more formal please", in: transforms) == nil)
        #expect(Transform.matching("übersetze das ins Spanische", in: transforms) == nil)
    }

    @Test func toleratesMisheardShortNames() {
        let transforms = Transform.presets
        let formal = [Transform(name: "Formal", instruction: "x"), Transform(name: "Shorter", instruction: "y")]
        #expect(Transform.matching("Sonal.", in: formal)?.name == "Formal")
        #expect(Transform.matching("Shorta", in: formal)?.name == "Shorter")
        #expect(Transform.matching("prompt engineers", in: transforms)?.name == "Prompt Engineer")
        #expect(Transform.matching("hello", in: transforms) == nil)
        #expect(Transform.matching("Deutsch", in: transforms) == nil)
        #expect(Transform.matching("okay", in: transforms) == nil)
        #expect(Transform.matching("danke", in: transforms) == nil)
        #expect(Transform.matching("make it nicer", in: transforms) == nil)
        #expect(Transform.similarity("formal", "formal") == 1)
        #expect(Transform.similarity("", "") == 1)
    }

    @Test func transformRequestCarriesInstructionAndText() async throws {
        let transport = CapturingTransport(body: CleanerTests.completion(#"{"text":"Sehr geehrte Damen und Herren"}"#))
        let client = OpenAICompatibleCleaner(settings: LLMSettings(), transport: transport)
        let result = try await client.transform("hi leute, wie geht es euch heute", instruction: "Formal")
        #expect(result == "Sehr geehrte Damen und Herren")
        let body = try #require(JSONSerialization.jsonObject(with: transport.lastRequest!.httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.last?["content"] == "<instruction>Formal</instruction>\n<text lang=\"de\">hi leute, wie geht es euch heute</text>")
    }

    @Test func detectsLanguageOfSelection() {
        #expect(TransformPrompt.detectLanguage("Das Meeting ist morgen um zehn Uhr im großen Raum.") == "de")
        #expect(TransformPrompt.detectLanguage("We need the change log before Friday.") == "en")
    }

    @Test func scratchpadRoundTripNewestFirst() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(url: url)
        #expect(store.load().isEmpty)
        let old = ScratchNote(text: "alt\nzweite Zeile", updated: Date(timeIntervalSince1970: 1))
        let new = ScratchNote(text: "", updated: Date(timeIntervalSince1970: 2))
        try store.save([old, new])
        let loaded = store.load()
        #expect(loaded.map(\.id) == [new.id, old.id])
        #expect(loaded[1].title == "alt")
        #expect(loaded[0].title == "Untitled")
    }

    @Test func settingsCarryTransformPresets() throws {
        let settings = try JSONDecoder().decode(DictationSettings.self, from: Data("{}".utf8))
        #expect(settings.transforms.map(\.name) == Transform.presets.map(\.name))
    }
}

struct WisprSettingsTests {
    @Test func legacyTransformDefaultsAreReplaced() throws {
        let legacy = ["Polish", "Formal", "Shorter", "Bullet points", "Email", "English", "German"]
            .map { Transform(name: $0, instruction: "x") }
        let data = try JSONEncoder().encode(["transforms": legacy])
        let settings = try JSONDecoder().decode(DictationSettings.self, from: data)
        #expect(settings.transforms.map(\.name) == ["Polish", "Prompt Engineer", "Formal", "Shorter",
                                                     "Bullet points", "Email", "English", "German", "Correct"])
        #expect(settings.transforms.first?.id == Transform.polishID)
    }

    @Test func twoTransformDefaultsGetTheFullList() throws {
        let data = try JSONEncoder().encode(["transforms": [Transform(name: "Polish", instruction: "x"),
                                                            Transform(name: "Prompt Engineer", instruction: "y")]])
        let settings = try JSONDecoder().decode(DictationSettings.self, from: data)
        #expect(settings.transforms == Transform.presets)
        #expect(Set(Transform.presets.map(\.id)).count == Transform.presets.count)
    }

    @Test func customTransformListsAreKept() throws {
        let custom = [Transform(name: "Boss Mode", summary: "Sound like a CEO", instruction: "x")]
        let data = try JSONEncoder().encode(["transforms": custom])
        #expect(try JSONDecoder().decode(DictationSettings.self, from: data).transforms == custom)
    }

    @Test func recognitionLanguageFollowsMyLanguages() {
        var settings = DictationSettings()
        #expect(settings.recognitionLanguage == nil)
        settings.languages = ["de"]
        #expect(settings.recognitionLanguage == "de")
        settings.asr.language = "en"
        #expect(settings.recognitionLanguage == "en")
    }

    @Test func autoTransformNeedsSwitchAndId() {
        var settings = DictationSettings()
        settings.autoTransformID = Transform.polishID.uuidString
        #expect(settings.autoTransform == nil)
        settings.autoTransformEnabled = true
        #expect(settings.autoTransform?.name == "Polish")
    }
}

struct SignatureTests {
    @Test func appendsSignatureOnlyInMailApps() async throws {
        var settings = DictationSettings()
        settings.llm.enabled = false
        settings.emailSignatureEnabled = true
        settings.emailSignature = "Jonas Weber\nNorthwind"
        let pipeline = DictationPipeline(settings: settings,
                                         transcriber: StubTranscriber(transcript: Transcript(text: "danke für die info", language: "de")),
                                         cleaner: nil)
        let mail = try await pipeline.run(samples: PipelineTests.speechLikeSamples, bundleId: "com.microsoft.Outlook")
        #expect(mail.text.trimmingCharacters(in: .whitespaces).hasSuffix("info\n\nJonas Weber\nNorthwind"))
        let chat = try await pipeline.run(samples: PipelineTests.speechLikeSamples, bundleId: "com.microsoft.teams2")
        #expect(!chat.text.contains("Northwind"))
    }
}

struct WordDiffTests {
    @Test func marksRemovedAndAddedWords() {
        let parts = WordDiff.diff("hey leute das hat nicht geklappt", "Hallo zusammen, das hat leider nicht geklappt")
        #expect(parts.filter { $0.kind == .removed }.map(\.text).joined() == "hey leute ")
        #expect(parts.filter { $0.kind == .added }.map(\.text).joined().contains("Hallo"))
        #expect(parts.filter { $0.kind == .added }.map(\.text).joined().contains("leider"))
        let rebuiltNew = parts.filter { $0.kind != .removed }.map(\.text).joined()
        #expect(rebuiltNew == "Hallo zusammen, das hat leider nicht geklappt")
        let rebuiltOld = parts.filter { $0.kind != .added }.map(\.text).joined()
        #expect(rebuiltOld.replacingOccurrences(of: " ", with: "") == "heyleutedashatnichtgeklappt")
    }

    @Test func identicalTextsAreOnePart() {
        #expect(WordDiff.diff("eins zwei", "eins zwei") == [WordDiff.Part(text: "eins zwei", kind: .same)])
        #expect(WordDiff.diff("", "neu") == [WordDiff.Part(text: "neu", kind: .added)])
    }
}

struct MeetingTests {
    @Test func oldMeetingFilesStillLoad() throws {
        let json = #"{"id":"6A1F0C3E-0000-4000-8000-0000000000AA","title":"Alt","date":"2026-10-20T07:00:00Z","duration":60,"status":"done","transcript":"t","summary":"s","actionItems":["a"],"problem":""}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(json.utf8))
        #expect(meeting.notes.isEmpty && meeting.folder.isEmpty && meeting.completedActions.isEmpty)
    }

    @Test func markdownMarksDoneActionsAndNotes() {
        let meeting = Meeting(title: "Sync", status: .done, actionItems: ["A", "B"], notes: "Idee", completedActions: ["B"])
        #expect(meeting.markdown.contains("- [ ] A"))
        #expect(meeting.markdown.contains("- [x] B"))
        #expect(meeting.markdown.contains("## My thoughts\n\nIdee"))
    }

    @Test func searchCoversTitleTranscriptAndNotes() {
        let meeting = Meeting(title: "Release", transcript: "Exportfunktion nach Word", notes: "Kunde fragen")
        #expect(meeting.matches("word"))
        #expect(meeting.matches("kunde"))
        #expect(!meeting.matches("budget"))
        #expect(meeting.matches(" "))
    }
}

struct StarredVocabularyTests {
    @Test func starredWordsComeFirst() {
        var settings = DictationSettings(vocabulary: ["Jonas", "Polarion", "LiveDoc"])
        settings.replacements = [Replacement(from: "btw", to: "by the way")]
        settings.starredWords = ["LiveDoc", "by the way", "Removed"]
        #expect(settings.vocabularyByPriority == ["LiveDoc", "by the way", "Jonas", "Polarion"])
    }

    @Test func starsSurviveSaving() throws {
        var settings = DictationSettings()
        settings.starredWords = ["Polarion"]
        let decoded = try JSONDecoder().decode(DictationSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.starredWords == ["Polarion"])
        #expect(try JSONDecoder().decode(DictationSettings.self, from: Data("{}".utf8)).starredWords.isEmpty)
    }
}

struct BarTransformTests {
    @Test func barUsesTheChosenTransformOrTheFirst() {
        var settings = DictationSettings()
        #expect(settings.barTransformIndex == 0)
        settings.barTransformID = Transform.presets[2].id.uuidString
        #expect(settings.barTransformIndex == 2)
        settings.barTransformID = UUID().uuidString
        #expect(settings.barTransformIndex == 0)
        settings.transforms = []
        #expect(settings.barTransformIndex == nil)
    }
}

struct StyleVocabularyTests {
    @Test func groupsOfTheStyleComeFirst() {
        var settings = DictationSettings(vocabulary: ["Polarion", "Kevin", "Proseware"])
        settings.wordGroups = ["Kevin": "Kollegen", "Proseware": "Kunden & Firmen", "Polarion": "Produkte & Polarion"]
        #expect(settings.vocabularyByPriority(for: .work) == ["Kevin", "Proseware", "Polarion"])
        #expect(settings.vocabularyByPriority(for: .plain) == ["Polarion", "Kevin", "Proseware"])
    }

    @Test func languageCanBeFixedPerStyle() {
        var settings = DictationSettings()
        settings.styleLanguages = [AppStyle.work.rawValue: "de"]
        #expect(settings.recognitionLanguage(for: .work) == "de")
        #expect(settings.recognitionLanguage(for: .mail) == settings.recognitionLanguage)
    }
}
