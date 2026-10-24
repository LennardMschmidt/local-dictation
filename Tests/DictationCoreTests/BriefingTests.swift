import Foundation
import Testing
@testable import DictationCore

struct BriefingTests {
    private func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briefing-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("08 Meetings/2026-KW42/2026-10-14")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        ---
        type: meeting
        datum: 2026-10-14
        uhrzeit: "10:00–10:45"
        teilnehmer:
          - Jonas Weber
          - Mia Keller
        kunde: "[[Fabrikam]]"
        ---

        # Fabrikam Release-Abstimmung

        ## KI-Notizen

        ### 1. Aufgabenpunkte

        - [ ] Mia Keller schickt die Testergebnisse (Freitag). [12:40]
        - [x] Jonas prüft das Template. [20:01]

        ### 2. Release 2.4

        - Das Release verschiebt sich um eine Woche. [03:10]
        - Die Validierung startet am 3.11. [05:00]

        ## Transkript
        - nicht hier
        """.write(to: folder.appendingPathComponent("Fabrikam Release-Abstimmung.md"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func customerMeetingsComeFirst() throws {
        let root = try vault()
        let notes = VaultMeetingNote.scan(vault: root, since: .distantPast)
        #expect(notes.first?.customer == "Fabrikam")
        let briefing = BriefingBuilder.build(title: "Fabrikam Weekly", start: Date(), participants: [
            MeetingParticipant(name: "Jonas Weber", email: "jonas.weber@northwind.example"),
            MeetingParticipant(name: "Max Neu", email: "max@fabrikam-diagnostics.example"),
        ], ownName: "Jonas", customerMap: ["fabrikam-diagnostics.example": "Fabrikam"], notes: notes, vault: root)
        #expect(briefing.customer == "Fabrikam")
        #expect(briefing.previous.first?.title == "Fabrikam Release-Abstimmung")
        #expect(briefing.previous.first?.openItems == ["Mia Keller schickt die Testergebnisse (Freitag)."])
        #expect(briefing.previous.first?.points == ["Das Release verschiebt sich um eine Woche.", "Die Validierung startet am 3.11."])
    }

    @Test func internalMeetingsMatchThePeople() throws {
        let root = try vault()
        let notes = VaultMeetingNote.scan(vault: root, since: .distantPast)
        let withAnna = BriefingBuilder.build(title: "Sync", start: Date(), participants: [
            MeetingParticipant(name: "Mia Keller", email: "mia.keller@northwind.example")], ownName: "Jonas", customerMap: [:], notes: notes, vault: root)
        #expect(withAnna.previous.count == 1)
        let withOthers = BriefingBuilder.build(title: "Sync", start: Date(), participants: [
            MeetingParticipant(name: "Ben Kurz", email: "ben@northwind.example")], ownName: "Jonas", customerMap: [:], notes: notes, vault: root)
        #expect(withOthers.previous.isEmpty)
    }
}

struct BriefingTitleTests {
    @Test func customerInTheTitleCounts() {
        let briefing = BriefingBuilder.build(title: "Team Standup x Fabrikam Anomalien Abschaffen!", start: Date(),
                                             participants: [MeetingParticipant(name: "Ben Kurz", email: "ben@northwind.example")],
                                             ownName: "Jonas", customerMap: ["fabrikam-diagnostics.example": "Fabrikam"], notes: [],
                                             vault: FileManager.default.temporaryDirectory)
        #expect(briefing.customer == "Fabrikam")
    }
}

struct BriefingCleanTests {
    @Test func linkedTimesAreRemoved() {
        #expect(BriefingBuilder.clean("Nina prüft den Fehler. [05:26](/app/meetings/6ad0b9?t=326)") == "Nina prüft den Fehler.")
        #expect(BriefingBuilder.clean("Anna schickt es. [12:40]") == "Anna schickt es.")
    }
}
