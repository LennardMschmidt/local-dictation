import Foundation
import Testing
@testable import DictationCore

private func tone(seconds: Double, amplitude: Float = 0.2) -> [Float] {
    (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.2) }
}

private func silence(seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * 16_000))
}

struct TimedTrackTests {
    @Test func gapsBecomeSilenceSoTracksStayAligned() {
        var track = TimedTrack()
        track.add([Float](repeating: 0.5, count: 16_000), at: 0)
        // The next block arrives 3 s after the start: two seconds were never delivered.
        track.add([Float](repeating: 0.5, count: 16_000), at: 3)
        #expect(track.samples.count == 64_000)
        #expect(track.samples[20_000] == 0)
        #expect(track.samples[50_000] == 0.5)
    }

    @Test func smallJitterIsNotCorrected() {
        var track = TimedTrack()
        track.add([Float](repeating: 0.5, count: 1_600), at: 0)
        track.add([Float](repeating: 0.5, count: 1_600), at: 0.11)
        #expect(track.samples.count == 3_200)
    }

    @Test func padExtendsToTheLongerTrack() {
        var track = TimedTrack()
        track.add([1, 1], at: 0)
        track.pad(to: 10)
        #expect(track.samples.count == 10)
    }
}

struct SpeechRegionTests {
    @Test func findsTheSpokenParts() {
        let samples = silence(seconds: 2) + tone(seconds: 3) + silence(seconds: 4) + tone(seconds: 2) + silence(seconds: 1)
        let regions = SpeechRegions.find(samples)
        #expect(regions.count == 2)
        #expect(abs(Double(regions[0].lowerBound) / 16_000 - 2) < 0.3)
        #expect(abs(Double(regions[1].lowerBound) / 16_000 - 9) < 0.3)
    }

    @Test func shortPausesStayInOneRegion() {
        let samples = tone(seconds: 2) + silence(seconds: 0.4) + tone(seconds: 2)
        #expect(SpeechRegions.find(samples).count == 1)
    }
}

struct MeetingTranscriberTests {
    private func pipeline(turns: [SpeakerTurn], languageAfter: Double = .infinity) -> MeetingTranscriber {
        MeetingTranscriber(
            diarize: { _ in turns },
            transcribe: { piece, _ in
                // The fake says how long the piece was, so the test can tell the turns apart.
                let seconds = Double(piece.count) / 16_000
                return Transcript(text: String(format: "%.0f", seconds), language: seconds > languageAfter ? "en" : "de")
            })
    }

    @Test func microphoneIsMeAndSystemTrackIsSplitIntoSpeakers() async throws {
        let microphone = tone(seconds: 3) + silence(seconds: 9)
        let system = silence(seconds: 4) + tone(seconds: 4) + silence(seconds: 4)
        let turns = [SpeakerTurn(start: 4, end: 6, speaker: "S1"), SpeakerTurn(start: 6, end: 8, speaker: "S2")]
        let segments = try await pipeline(turns: turns).transcribe(microphone: microphone, system: system)
        #expect(segments.map(\.speaker) == [MeetingSpeakers.me, "S1", "S2"])
        #expect(segments[0].start < 0.5)
        // The turn is widened by a second, because detection tends to start late.
        #expect(segments[1].start == 3)
    }

    @Test func mixedRecordingsAreSplitWithoutAMicrophoneTrack() async throws {
        let mixed = tone(seconds: 6)
        let turns = [SpeakerTurn(start: 0, end: 3, speaker: "S1"), SpeakerTurn(start: 3, end: 6, speaker: "S2")]
        let segments = try await pipeline(turns: turns).transcribe(microphone: mixed, system: nil)
        #expect(segments.map(\.speaker) == ["S1", "S2"])
    }

    @Test func longTurnsAreCutAndEachPieceGetsItsLanguage() async throws {
        let audio = tone(seconds: 40)
        let segments = try await pipeline(turns: [SpeakerTurn(start: 0, end: 40, speaker: "S1")], languageAfter: 20)
            .transcribe(microphone: audio, system: nil)
        // Two pieces of one speaker are merged into one segment, which keeps the later language.
        #expect(segments.count == 1)
        #expect(segments[0].text.split(separator: " ").count == 2)
        #expect(segments[0].end > 39)
    }

    @Test func mergeJoinsOnlyCloseTurnsOfTheSameSpeaker() {
        let merged = MeetingTranscriber.merge([
            TranscriptSegment(start: 0, end: 2, speaker: "S1", text: "Hallo"),
            TranscriptSegment(start: 2.5, end: 4, speaker: "S1", text: "zusammen"),
            TranscriptSegment(start: 4.2, end: 5, speaker: "me", text: "Hi"),
            TranscriptSegment(start: 10, end: 11, speaker: "me", text: "Später"),
        ])
        #expect(merged.map(\.text) == ["Hallo zusammen", "Hi", "Später"])
    }

    @Test func linesUseNamesAndMainLanguageCountsWords() {
        let segments = [TranscriptSegment(start: 0, end: 1, speaker: "S1", text: "eins zwei drei", language: "de"),
                        TranscriptSegment(start: 1, end: 2, speaker: "me", text: "okay", language: "en")]
        var meeting = Meeting(segments: segments)
        meeting.speakerNames["S1"] = "Sara"
        let lines = MeetingTranscriber.lines(segments) { meeting.name(for: $0, ownName: "Jonas") }
        #expect(lines == "Sara: eins zwei drei\nJonas: okay")
        #expect(MeetingTranscriber.mainLanguage(segments) == "de")
        #expect(meeting.speakers == ["S1", "me"])
        #expect(meeting.name(for: "S2", ownName: "Jonas") == "Speaker 2")
    }

    @Test func notesFromBeforeSpeakersStillLoad() throws {
        let json = #"{"id":"6384D37D-EF74-45CB-9E40-C8D37EFC6663","date":0,"title":"Alt","transcript":"Text"}"#
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(json.utf8))
        #expect(meeting.segments.isEmpty)
        #expect(meeting.speakerNames.isEmpty)
    }

    @Test func summaryLanguageIsNamed() {
        #expect(MeetingSummarizer.languageInstruction("de")?.contains("German") == true)
    }
}

struct TurnPreparationTests {
    @Test func turnsAreJoinedAndWidenedWithoutOverlap() {
        let turns = [SpeakerTurn(start: 9.5, end: 11.7, speaker: "S1"), SpeakerTurn(start: 12.0, end: 14.4, speaker: "S1"),
                     SpeakerTurn(start: 15.6, end: 20.8, speaker: "S2")]
        let prepared = MeetingTranscriber.prepare(turns, limit: 34)
        #expect(prepared.count == 2)
        #expect(prepared[0].start == 8.5)
        #expect(prepared[0].end == 14.8)
        #expect(prepared[1].start == 14.8)
        #expect(prepared[1].end == 21.2)
    }
}

struct ScratchNoteTests {
    @Test func oldNotesLoadUnpinnedAndPreviewSkipsTheTitle() throws {
        let json = #"[{"id":"6384D37D-EF74-45CB-9E40-C8D37EFC6663","text":"Einkauf\nMilch\nBrot","created":"2026-10-20T09:00:00Z","updated":"2026-10-20T09:00:00Z"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note = try #require(try decoder.decode([ScratchNote].self, from: Data(json.utf8)).first)
        #expect(!note.pinned)
        #expect(note.title == "Einkauf")
        #expect(note.preview == "Milch Brot")
        #expect(ScratchNote().title == "Untitled")
    }
}

struct MeetingCleanupTests {
    private func segment(_ start: Double, _ end: Double, _ speaker: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, speaker: speaker, text: "x", language: "de")
    }

    @Test func noiseSpeakerJoinsTheNearestOne() {
        let segments = [segment(0, 300, "S1"), segment(300, 303, "S2"), segment(303, 600, "S1"), segment(10, 20, MeetingSpeakers.me)]
        let result = MeetingTranscriber.absorbRareSpeakers(segments)
        #expect(Set(result.map(\.speaker)) == ["S1", MeetingSpeakers.me])
    }

    @Test func calendarCountRemovesExtraSpeakers() {
        let segments = [segment(0, 60, "S1"), segment(60, 70, "S2"), segment(70, 130, "S1")]
        #expect(Set(MeetingTranscriber.absorbRareSpeakers(segments).map(\.speaker)) == ["S1", "S2"])
        #expect(Set(MeetingTranscriber.absorbRareSpeakers(segments, others: 1).map(\.speaker)) == ["S1"])
        let long = [segment(0, 300, "S1"), segment(300, 400, "S2"), segment(400, 600, "S1")]
        #expect(Set(MeetingTranscriber.absorbRareSpeakers(long, others: 1).map(\.speaker)) == ["S1"])
        #expect(Set(MeetingTranscriber.absorbRareSpeakers(long, others: 2).map(\.speaker)) == ["S1", "S2"])
    }

    @Test func titlesAreLeftOut() {
        #expect(MeetingParticipant(name: "Dr.-Ing. Kevin Berg", email: "k@x.de").displayName == "Kevin Berg")
        #expect(MeetingParticipant(name: "Prof. Dr. Mia Keller", email: "a@x.de").displayName == "Mia Keller")
    }

    @Test func realSpeakersStay() {
        let segments = (0..<20).map { segment(Double($0) * 30, Double($0) * 30 + 25, "S\($0 % 10 + 1)") }
        #expect(Set(MeetingTranscriber.absorbRareSpeakers(segments).map(\.speaker)).count == 10)
    }

    @Test func loopsAreCut() {
        #expect(TextProcessing.cleanTranscript("Danke dir. Ciao, ciao. S-T-R-O-L-O-L-O-L-O-L-O-L-O-L-O-L-O-L-O") == "Danke dir. Ciao, ciao.")
        #expect(TextProcessing.cleanTranscript("ja ja ja ja ja ja ja ja") == "")
        #expect(TextProcessing.cleanTranscript("Ja, ja, das passt.") == "Ja, ja, das passt.")
    }

    @Test func unsureTextIsUnreliable() {
        #expect(Transcript(text: "Hvala.", language: "de", logProb: -1.3).isUnreliable)
        #expect(Transcript(text: "Bye.", language: "en", logProb: -0.7, noSpeech: 0.8).isUnreliable)
        #expect(!Transcript(text: "Das passt.", language: "de", logProb: -0.3, noSpeech: 0.1).isUnreliable)
    }
}

struct ScriptTests {
    @Test func onlyGermanAndEnglishLetters() {
        #expect(TextProcessing.isGermanOrEnglishScript("Die Größe passt, das Café auch. I'll check."))
        #expect(!TextProcessing.isGermanOrEnglishScript("Morskjølmer, schnellere oss."))
        #expect(!TextProcessing.isGermanOrEnglishScript("Nå, Rik, по min past."))
    }
}
