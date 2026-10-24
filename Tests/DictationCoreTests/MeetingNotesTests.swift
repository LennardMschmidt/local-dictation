import AppKit
import Foundation
import Testing
@testable import DictationCore

private func sampleMeeting() -> Meeting {
    var meeting = Meeting(title: "Fabrikam / Contoso Plan", date: ISO8601DateFormatter().date(from: "2026-10-20T09:00:00Z")!,
                          duration: 1_320, status: .done)
    meeting.participants = [MeetingParticipant(name: "Jonas Weber", email: "jonas.weber@northwind.example"),
                            MeetingParticipant(name: "Sara Wolf", email: "sara.wolf@litware.example")]
    meeting.organizer = meeting.participants[0]
    meeting.segments = [TranscriptSegment(start: 3, end: 8, speaker: MeetingSpeakers.me, text: "Ich schicke dir das Angebot bis Freitag."),
                        TranscriptSegment(start: 9, end: 20, speaker: "S1", text: "Danke, dann schauen wir uns das an."),
                        TranscriptSegment(start: 21, end: 23, speaker: "S2", text: "Ja.")]
    meeting.notesMarkdown = MeetingNotes(actionItems: [.init(owner: "Jonas", action: "schickt das Angebot", due: "bis Freitag", time: "00:03")],
                                         topics: [.init(title: "Angebot", points: [.init(text: "Das Angebot kommt diese Woche", time: "00:03")])]).markdown
    return meeting
}

private func temporaryVault() throws -> URL {
    let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: vault.appendingPathComponent("02 Kunden"), withIntermediateDirectories: true)
    try "# Contoso\n\n## Meetings\n- 2026-10-01 — [[alt|Alt]]\n".write(to: vault.appendingPathComponent("02 Kunden/Contoso.md"),
                                                                    atomically: true, encoding: .utf8)
    return vault
}

struct MeetingNotesFormatTests {
    @Test func markdownLooksLikeTldv() {
        let notes = MeetingNotes(actionItems: [.init(owner: "Paul", action: "schickt die Testergebnisse", due: "bis Donnerstag", time: "12:40")],
                                 topics: [.init(title: "Release 2.4", points: [.init(text: "Tests laufen bis Donnerstag [12:40]", time: "12:40")])],
                                 language: "de")
        #expect(notes.markdown == """
        ### 1. Aufgabenpunkte

        - [ ] Paul schickt die Testergebnisse (bis Donnerstag). [12:40]

        ### 2. Release 2.4

        - Tests laufen bis Donnerstag. [12:40]
        """)
        #expect(MeetingNotes(language: "en").markdown.hasPrefix("### 1. Action Items"))
    }

    @Test func ownersMustBeParticipants() {
        #expect(MeetingNotesWriter.isParticipant("Paul", ["Jonas Weber", "Paul Braun"]))
        #expect(MeetingNotesWriter.isParticipant("Paul Braun", ["Jonas", "Paul Braun"]))
        #expect(!MeetingNotesWriter.isParticipant("Team", ["Jonas", "Paul"]))
        #expect(!MeetingNotesWriter.isParticipant("", ["Jonas"]))
    }

    @Test func commitmentsNeedEvidence() {
        #expect(MeetingNotesWriter.soundsLikeCommitment("Ok, ich schick dir das morgen."))
        #expect(MeetingNotesWriter.soundsLikeCommitment("Sure, I'll check that by Friday."))
        #expect(!MeetingNotesWriter.soundsLikeCommitment("Blitztext ist ein gutes Open-Source-Tool."))
    }

    @Test func limitsGrowSlowerThanTheMeeting() {
        #expect(MeetingNotesWriter.actionItemLimit(words: 300) == 4)
        #expect(MeetingNotesWriter.actionItemLimit(words: 2_800) == 9)
        #expect(MeetingNotesWriter.actionItemLimit(words: 15_000) == 12)
        #expect(MeetingNotesWriter.topicLimit(words: 400) == 2)
        #expect(MeetingNotesWriter.topicLimit(words: 6_000) == 8)
        #expect(MeetingNotesWriter.clock(3_725) == "1:02:05")
        #expect(MeetingNotesWriter.seconds("[1:02:05]") == 3_725)
    }

    @Test func theOnlyOtherPersonGetsTheMainVoice() {
        var meeting = sampleMeeting()
        meeting.nameTheOtherPerson(ownName: "Jonas")
        #expect(meeting.speakerNames["S1"] == "Sara Wolf")
        #expect(meeting.participantNames(ownName: "Jonas") == ["Jonas Weber", "Sara Wolf"])
        #expect(meeting.noteLines(ownName: "Jonas").first?.speaker == "Jonas")
    }

    @Test func customerComesFromTheMailDomain() {
        CustomerRouting.ownDomain = "northwind.example"
        let map = ["litware.example": "Contoso"]
        #expect(CustomerRouting.customer(for: sampleMeeting().participants, map: map) == "Contoso")
        #expect(CustomerRouting.isInternal([MeetingParticipant(name: "A", email: "a@northwind.example")]))
    }
}

struct VaultExportTests {
    @Test func writesTheNoteWhereTheTldvSyncWouldAndLinksTheCustomer() throws {
        let vault = try temporaryVault()
        let export = VaultMeetingExport(vault: vault, customerMap: ["litware.example": "Contoso"])
        let meeting = sampleMeeting()
        let result = try export.write(meeting, ownName: "Jonas")
        #expect(result.path == "08 Meetings/2026-KW43/2026-10-20/Fabrikam Contoso Plan")
        #expect(result.customerLink == "verlinkt")
        let note = try String(contentsOf: vault.appendingPathComponent(result.path + ".md"), encoding: .utf8)
        #expect(note.contains("quelle: localdictation"))
        #expect(note.contains("kw: 43"))
        #expect(note.contains("uhrzeit: \"11:00–11:22\""))
        #expect(note.contains("kunde: \"[[Contoso]]\""))
        #expect(note.contains("## KI-Notizen\n\n### 1. Aufgabenpunkte"))
        #expect(note.contains("**Jonas** _(00:03)_\nIch schicke dir das Angebot bis Freitag."))
        let customer = try String(contentsOf: vault.appendingPathComponent("02 Kunden/Contoso.md"), encoding: .utf8)
        #expect(customer.contains("## Meetings\n- 2026-10-20 — [[08 Meetings/2026-KW43/2026-10-20/Fabrikam Contoso Plan|Fabrikam / Contoso Plan]]"))
        // Writing again updates the same note and does not link twice.
        #expect(try export.write(meeting, ownName: "Jonas").customerLink == "schon verlinkt")
    }

    @Test func aTldvNoteOfTheSameMeetingStays() throws {
        let vault = try temporaryVault()
        let folder = vault.appendingPathComponent("08 Meetings/2026-KW43/2026-10-20")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nquelle: tldv\n---\n".write(to: folder.appendingPathComponent("Fabrikam Contoso Plan.md"), atomically: true, encoding: .utf8)
        let result = try VaultMeetingExport(vault: vault, customerMap: [:]).write(sampleMeeting(), ownName: "Jonas")
        #expect(result.path.hasSuffix("Fabrikam Contoso Plan (LocalDictation)"))
        #expect(try String(contentsOf: folder.appendingPathComponent("Fabrikam Contoso Plan.md"), encoding: .utf8).contains("tldv"))
    }

    @Test func unknownCustomerDomainsAreFlagged() throws {
        let vault = try temporaryVault()
        let result = try VaultMeetingExport(vault: vault, customerMap: [:]).write(sampleMeeting(), ownName: "Jonas")
        let note = try String(contentsOf: vault.appendingPathComponent(result.path + ".md"), encoding: .utf8)
        #expect(note.contains("- unrouted"))
        #expect(note.contains("Kunde nicht zugeordnet — Domains: litware.example"))
    }
}

struct ToneRuleTests {
    @Test func tonesLookLikeWisprsExamples() {
        let formal = "Hey, hast du morgen Zeit zum Mittagessen? Lass uns um 12 gehen, wenn das passt."
        #expect(ToneRules.apply(.formal, to: formal) == formal)
        #expect(ToneRules.apply(.casual, to: formal) == "Hey hast du morgen Zeit zum Mittagessen? Lass uns um 12 gehen, wenn das passt")
        #expect(ToneRules.apply(.veryCasual, to: formal) == "hey hast du morgen zeit zum mittagessen? lass uns um 12 gehen, wenn das passt")
    }

    @Test func numbersAddressesAndAbbreviationsStay() {
        let text = "Version 2.4 kommt am 3.11. Infos auf northwind.example. Danke."
        #expect(ToneRules.apply(.veryCasual, to: text) == "version 2.4 kommt am 3.11. infos auf northwind.example danke")
        #expect(ToneRules.apply(.casual, to: "Erstens.\nZweitens.") == "Erstens\nZweitens")
    }

    @Test func workMessengersAreTheirOwnCategory() {
        let resolver = AppStyleResolver()
        #expect(resolver.style(for: "com.microsoft.teams2") == .work)
        #expect(resolver.style(for: "net.whatsapp.WhatsApp") == .chat)
        #expect(resolver.apps(for: .work).contains("com.tinyspeck.slackmacgap"))
        let moved = AppStyleResolver(overrides: ["com.tinyspeck.slackmacgap": .chat])
        #expect(!moved.apps(for: .work).contains("com.tinyspeck.slackmacgap"))
        #expect(moved.apps(for: .chat).contains("com.tinyspeck.slackmacgap"))
    }

    @Test func oldSettingsGiveWorkTheMessagesTone() throws {
        let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(#"{"tones":{"chat":"veryCasual","plain":"casual"}}"#.utf8))
        #expect(settings.tone(for: .work) == .veryCasual)
        #expect(settings.tone(for: .notes) == .casual)
        #expect(settings.tone(for: .code) == .formal)
    }
}

struct RichSnippetTests {
    @Test func markdownIsRecognisedAndStrippedForPlainText() {
        let text = "**Jonas Weber**\n*Northwind GmbH*\n- Polarion\n[LinkedIn](https://linkedin.com/in/x)"
        #expect(RichSnippet.hasFormatting(text))
        #expect(!RichSnippet.hasFormatting("Viele Grüße, Jonas"))
        #expect(RichSnippet.plain(text) == "Jonas Weber\nNorthwind GmbH\n• Polarion\nLinkedIn (https://linkedin.com/in/x)")
    }

    @Test func rtfKeepsTheText() throws {
        let data = try #require(RichSnippet.rtf("**fett** und *kursiv*\n- Punkt"))
        let back = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(back.string == "fett und kursiv\n• Punkt")
        let font = back.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }
}

struct ShortDictationTests {
    @Test func shortPlainSentencesSkipTheModel() {
        #expect(TextProcessing.isShortAndPlain("Hallo."))
        #expect(TextProcessing.isShortAndPlain("Ich bin in 5 Minuten da."))
        #expect(!TextProcessing.isShortAndPlain("Wir treffen uns um drei, nein, ich meine um vier."))
        #expect(!TextProcessing.isShortAndPlain("Erstens Milch zweitens Brot."))
        // Without punctuation from Whisper the model still has a look.
        #expect(!TextProcessing.isShortAndPlain("hallo welt"))
        #expect(!TextProcessing.isShortAndPlain("Kannst du mir bitte bis Freitag die Zahlen für den Kunden schicken"))
    }

    @Test func shortTextKeepsReplacementsAndStyle() async throws {
        var settings = DictationSettings()
        settings.replacements = [Replacement(from: "polarian", to: "Polarion")]
        settings.tones["chat"] = .veryCasual
        let pipeline = DictationPipeline(settings: settings, transcriber: StubTranscriber(transcript: Transcript(text: "Hallo", language: "de")),
                                         cleaner: StubCleaner(reply: { _ in "should not be used" }))
        let result = await pipeline.process(transcript: Transcript(text: "Läuft polarian wieder?", language: "de"), style: .chat)
        #expect(result.cleanup == .short)
        #expect(result.text.trimmingCharacters(in: .whitespaces) == "läuft polarion wieder?")
    }
}

struct VocabularyMatcherTests {
    let matcher = VocabularyMatcher(["awork", "LiveDoc", "novaClinical", "Polarion", "Word", "Fabrikam", "Contoso"])

    @Test func joinsSpokenPartsAndFixesSpelling() {
        #expect(matcher.correct("Leg das bitte in a work an.") == "Leg das bitte in awork an.")
        #expect(matcher.correct("Das Live Doc ist offen.") == "Das LiveDoc ist offen.")
        #expect(matcher.correct("Weil ich mit Nowaclinical zu tun habe") == "Weil ich mit novaClinical zu tun habe")
        #expect(matcher.correct("im polarion projekt") == "im Polarion projekt")
    }

    @Test func leavesOrdinaryWordsAlone() {
        #expect(matcher.correct("Ein word in a sentence.") == "Ein word in a sentence.")
        #expect(matcher.correct("Wir arbeiten mit Kolonnen.") == "Wir arbeiten mit Kolonnen.")
        #expect(matcher.correct("a work of art") == "awork of art")
    }

    @Test func findsTheTermsOfADictation() {
        #expect(matcher.relevant(to: "Im polarion LiveDok für Contoso", limit: 30).sorted() == ["Contoso", "LiveDoc", "Polarion"])
    }

    @Test func aThousandTermsStayFast() {
        let many = VocabularyMatcher((0..<1_000).map { "Begriff\($0)xy" } + ["awork"])
        let started = Date()
        _ = many.correct(String(repeating: "Wir legen das in a work an und schauen morgen weiter. ", count: 10))
        #expect(Date().timeIntervalSince(started) < 0.5)
    }
}

private struct ScriptedCompleter: ChatCompleter {
    let reply: String
    func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String { reply }
}

struct TranscriptPolisherTests {
    let segments = [TranscriptSegment(start: 0, end: 5, speaker: "S1", text: "Das ist für ihn schon mal eine Brügke."),
                    TranscriptSegment(start: 5, end: 9, speaker: "S1", text: "Er schreibt meine Unit-Sests mit.")]

    @Test func lightFixesAreTaken() async {
        let client = ScriptedCompleter(reply: #"{"lines": ["1. Das ist für ihn schon mal eine Brücke.", "Er schreibt meine Unit-Tests mit."]}"#)
        let polished = await TranscriptPolisher(client: client).polish(segments, vocabulary: [])
        #expect(polished.map(\.text) == ["Das ist für ihn schon mal eine Brücke.", "Er schreibt meine Unit-Tests mit."])
        #expect(polished[0].start == 0)
    }

    @Test func rewordedLinesKeepTheOriginal() async {
        let client = ScriptedCompleter(reply: #"{"lines": ["Brücke.", "Er erstellt automatisch alle Unit-Tests für mich, was sehr hilfreich ist."]}"#)
        let polished = await TranscriptPolisher(client: client).polish(segments, vocabulary: [])
        #expect(polished.map(\.text) == segments.map(\.text))
    }

    @Test func aWrongNumberOfLinesKeepsEverything() async {
        let client = ScriptedCompleter(reply: #"{"lines": ["Das ist für ihn schon mal eine Brücke."]}"#)
        #expect(await TranscriptPolisher(client: client).polish(segments, vocabulary: []).map(\.text) == segments.map(\.text))
    }
}

/// Answers each call with the next reply.
private final class SequenceCompleter: ChatCompleter, @unchecked Sendable {
    private var replies: [String]
    private(set) var prompts: [String] = []
    init(_ replies: [String]) { self.replies = replies }
    func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String {
        prompts.append(messages.first?.content ?? "")
        return replies.removeFirst()
    }
}

struct UnknownParticipantsTests {
    @Test func ownersComeFromTheTranscriptWithoutACalendar() async throws {
        let extract = #"{"title":"Plugin","topics":[],"commitments":[{"owner":"Paul","action":"lädt das Plugin hoch","due":"","time":"00:10","quote":"Ich lade das Plugin morgen hoch."},{"owner":"Team","action":"plant das Release","due":"","time":"00:20","quote":"Ja, machen wir."}]}"#
        let verify = #"{"actionItems":[{"keep":true,"owner":"Paul","action":"Lädt das Plugin hoch","due":"morgen","time":"00:10"},{"keep":true,"owner":"Team","action":"Plant das Release","due":"","time":"00:20"}]}"#
        let client = SequenceCompleter([extract, verify])
        let lines = [MeetingNotesWriter.Line(time: 10, speaker: "Speaker 1", text: "Ich lade das Plugin morgen hoch."),
                     MeetingNotesWriter.Line(time: 20, speaker: "Speaker 1", text: "Ja, machen wir.")]
        let notes = try await MeetingNotesWriter(client: client).write(lines: lines, participants: ["Jonas"], me: "Jonas", language: "de")
        #expect(notes.actionItems.map(\.owner) == ["Paul"])
        #expect(client.prompts.first?.contains("take their names from the transcript") == true)
    }

    @Test func groupsAreNoPeople() {
        #expect(MeetingNotesWriter.isPerson("Paul"))
        #expect(!MeetingNotesWriter.isPerson("Team"))
        #expect(!MeetingNotesWriter.isPerson("wir"))
    }
}

struct FollowUpMailTests {
    @Test func mailIsReadAndAddressed() async throws {
        let client = SequenceCompleter([#"{"subject":"Zusammenfassung Release","body":"Hallo Mia,\n\n- Release verschoben\n\nViele Grüße\nJonas"}"#])
        let mail = try await FollowUpMail.write(meetingTitle: "Release", date: Date(), notes: "### 1. Aufgabenpunkte", recipients: ["Mia Keller"],
                                                me: "Jonas Weber", signature: "", language: "de", client: client)
        #expect(mail.subject == "Zusammenfassung Release")
        let url = mail.mailto(to: ["mia@example.com"])
        #expect(url?.absoluteString.hasPrefix("mailto:mia@example.com?subject=Zusammenfassung%20Release") == true)
        #expect(client.prompts.first?.contains("Mia Keller") == true)
    }
}

struct MatcherNeighbourTests {
    @Test func neighbouringWordsStay() {
        let matcher = VocabularyMatcher(["Claude Code", "Table Framework", "awork"])
        #expect(matcher.correct("Ich nutze Claude Code und Granola.") == "Ich nutze Claude Code und Granola.")
        #expect(matcher.correct("in Table Framework The table") == "in Table Framework The table")
        #expect(matcher.correct("nach a work übertragen") == "nach awork übertragen")
    }
}
