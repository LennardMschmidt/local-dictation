import DictationCore
import Foundation

/// The invented world of demo mode: settings with a sample dictionary, a few past dictations,
/// finished meetings with notes, a small vault and the customer map. Written once into the demo
/// folder (`AppPaths.supportDirectory` in demo mode); `--demo-reset` writes it again from scratch.
enum DemoSeed {
    static func prepare(reset: Bool) {
        let folder = AppPaths.supportDirectory
        let files = FileManager.default
        if reset { try? files.removeItem(at: folder) }
        guard !files.fileExists(atPath: AppPaths.settingsFile.path) else { return }
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        try? SettingsStore(url: AppPaths.settingsFile).save(settings())
        writeHistory(to: HistoryStore(url: AppPaths.historyFile, limit: 20_000))
        writeMeetings(to: AppPaths.meetingsDirectory)
        writeVault()
        if let map = try? JSONEncoder().encode(DemoMode.customerMap) {
            try? map.write(to: CustomerRouting.mapFile)
        }
    }

    static var vault: URL { AppPaths.supportDirectory.appendingPathComponent("Vault", isDirectory: true) }

    static func settings() -> DictationSettings {
        var settings = DictationSettings()
        settings.vocabulary = ["Polarion", "LiveDoc", "Work Item", "Velocity", "Risk Suite", "Clinical Suite", "Northwind",
                               "Fabrikam", "Litware", "Tailspin", "Mia Keller", "Paul Braun", "Lea Fischer", "awork", "tl;dv"]
        settings.replacements = [Replacement(from: "polarian", to: "Polarion"), Replacement(from: "Livedock", to: "LiveDoc"),
                                 Replacement(from: "Fabricam", to: "Fabrikam"), Replacement(from: "btw", to: "by the way")]
        settings.starredWords = ["Polarion", "Fabrikam"]
        settings.wordGroups = ["Mia Keller": "Kollegen", "Paul Braun": "Kollegen", "Lea Fischer": "Kollegen",
                               "Fabrikam": "Kunden & Firmen", "Litware": "Kunden & Firmen", "Tailspin": "Kunden & Firmen",
                               "Northwind": "Kunden & Firmen", "Polarion": "Produkte & Polarion", "LiveDoc": "Produkte & Polarion",
                               "Work Item": "Produkte & Polarion", "Velocity": "Produkte & Polarion", "Risk Suite": "Produkte & Polarion",
                               "Clinical Suite": "Produkte & Polarion", "awork": "Tools", "tl;dv": "Tools", "by the way": "Tools"]
        settings.snippets = [Snippet(trigger: "meine Signatur", text: "Viele Grüße\nJonas Weber\nNorthwind Consulting"),
                             Snippet(trigger: "my calendar link", text: "https://example.com/book/jonas")]
        settings.places = DictationSettings.defaultPlaces + [
            Place(name: "Polarion", aliases: ["polarion server"], url: DemoMode.polarionServer + "/polarion"),
            Place(name: "Staging", aliases: ["stage"], url: "https://staging.example.com"),
        ]
        settings.meetingVault = vault.path
        return settings
    }

    static func writeHistory(to history: HistoryStore) {
        let samples: [(Double, String, String, String, Double)] = [
            (-600, "com.microsoft.teams2", "kurze frage hast du den fix für das table framework schon gepusht",
             "Kurze Frage: hast du den Fix für das Table Framework schon gepusht?", 4),
            (-3_600, "com.microsoft.Outlook", "hi paul danke für deine mail ich schau mir das heute nachmittag an viele grüße jonas",
             "Hi Paul,\n\ndanke für deine Mail. Ich schau mir das heute Nachmittag an.\n\nViele Grüße\nJonas", 8),
            (-7_200, "com.tinyspeck.slackmacgap", "ähm the review moves to thursday at three no at four",
             "The review moves to Thursday at 4.", 5),
            (-90_000, "md.obsidian", "meine stichpunkte für den workshop erstens die anforderungen zweitens die risikoanalyse drittens der zeitplan",
             "Meine Stichpunkte für den Workshop:\n- die Anforderungen\n- die Risikoanalyse\n- der Zeitplan", 7),
            (-95_000, "com.microsoft.VSCode", "returns the list of work items that belong to the current document",
             "Returns the list of work items that belong to the current document.", 3),
            (-180_000, "com.apple.mail", "hallo frau wolf anbei die unterlagen zur infusionspumpe ich melde mich morgen beste grüße jonas weber",
             "Hallo Frau Wolf,\n\nanbei die Unterlagen zur Infusionspumpe. Ich melde mich morgen.\n\nBeste Grüße\nJonas Weber", 9),
        ]
        for (offset, app, raw, text, audio) in samples {
            var result = DictationResult(rawTranscript: raw, language: "de", style: .plain, text: text,
                                         cleanup: .cleaned, transcriptionSeconds: 0.8, cleanupSeconds: 1.1)
            result.audioSeconds = audio
            try? history.append(HistoryEntry(date: Date().addingTimeInterval(offset), bundleId: app, result: result))
        }
    }

    static func writeMeetings(to directory: URL) {
        let store = MeetingStore(directory: directory)
        let me = MeetingParticipant(name: DemoMode.userName, email: "jonas.weber@\(DemoMode.ownDomain)")
        var release = Meeting(
            title: "Release 2.4 Sync", date: Date().addingTimeInterval(-7_200), duration: 1_860, status: .done,
            transcript: """
            Jonas: Wir gehen kurz die offenen Punkte für das Release durch.
            Mia: Das Table Framework ist fertig, die Tests laufen.
            Paul: Ich kümmere mich bis Donnerstag um die Release Notes.
            Jonas: Gut. Die Abnahme beim Kunden planen wir für nächste Woche.
            """,
            summary: "Das Release 2.4 ist technisch fertig. Offen sind die Release Notes und die Abnahme beim Kunden, die für nächste Woche geplant ist.",
            actionItems: ["Paul: Release Notes bis Donnerstag", "Jonas: Abnahmetermin mit dem Kunden vereinbaren"])
        release.participants = [me, MeetingParticipant(name: "Mia Keller", email: "mia.keller@\(DemoMode.ownDomain)"),
                                MeetingParticipant(name: "Paul Braun", email: "paul.braun@\(DemoMode.ownDomain)")]
        release.notesMarkdown = MeetingNotes(
            actionItems: [.init(owner: "Paul", action: "schreibt die Release Notes", due: "bis Donnerstag", time: "04:10"),
                          .init(owner: "Jonas", action: "vereinbart den Abnahmetermin mit dem Kunden", due: "", time: "12:30")],
            topics: [.init(title: "Stand Release 2.4", points: [.init(text: "Das Table Framework ist fertig, die Tests laufen", time: "01:05"),
                                                                 .init(text: "Die Abnahme ist für nächste Woche geplant", time: "12:30")])],
            language: "de").markdown
        try? store.save(release)

        var fabrikam = Meeting(
            title: "Fabrikam Weekly", date: Calendar.current.date(byAdding: .day, value: -6, to: Date())!, duration: 1_500, status: .done,
            summary: "Fabrikam braucht den Validierungsplan bis Monatsende. Das Risk Suite Update läuft auf dem Testsystem.",
            actionItems: ["Mia: Validierungsplan entwerfen", "Sara Wolf: Testsystem freigeben"])
        fabrikam.participants = [me, MeetingParticipant(name: "Mia Keller", email: "mia.keller@\(DemoMode.ownDomain)"),
                                 MeetingParticipant(name: "Sara Wolf", email: "sara.wolf@fabrikam-diagnostics.example")]
        fabrikam.notesMarkdown = MeetingNotes(
            actionItems: [.init(owner: "Mia", action: "entwirft den Validierungsplan", due: "bis Monatsende", time: "06:20"),
                          .init(owner: "Sara Wolf", action: "gibt das Testsystem frei", due: "bis Freitag", time: "15:45")],
            topics: [.init(title: "Validierung", points: [.init(text: "Der Plan muss die Infusionspumpe und das Zubehör abdecken", time: "06:20")]),
                     .init(title: "Risk Suite Update", points: [.init(text: "Das Update läuft auf dem Testsystem ohne Fehler", time: "11:02")])],
            language: "de").markdown
        try? store.save(fabrikam)

        for (title, daysAgo, minutes) in [("Support Daily Stand-up", 0, 6), ("Testing Training", 1, 49),
                                          ("Polarion Specs Development", 3, 58), ("Kickoff Litware Upgrade", 45, 60)] {
            var meeting = Meeting(title: title, date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date().addingTimeInterval(-10_800))!,
                                  duration: Double(minutes * 60), status: .done,
                                  summary: "Kurzer Abgleich, keine Entscheidungen.", actionItems: ["Paul: Protokoll verschicken"])
            meeting.participants = [me, MeetingParticipant(name: "Tim Hoffmann", email: "tim.hoffmann@\(DemoMode.ownDomain)"),
                                    MeetingParticipant(name: "Lea Fischer", email: "lea.fischer@\(DemoMode.ownDomain)")]
            try? store.save(meeting)
        }
    }

    /// Two customer notes and a past meeting note, for the briefing and "open the note on …".
    static func writeVault() {
        let customers = vault.appendingPathComponent("Kunden", isDirectory: true)
        let meetings = vault.appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: customers, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        try? "# Fabrikam\n\nFabrikam Diagnostics, Validierung der Infusionspumpe mit der Risk Suite.\n"
            .write(to: customers.appendingPathComponent("Fabrikam.md"), atomically: true, encoding: .utf8)
        try? "# Litware\n\nLitware Devices, laufende Weiterentwicklung.\n"
            .write(to: customers.appendingPathComponent("Litware.md"), atomically: true, encoding: .utf8)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Calendar.current.date(byAdding: .day, value: -13, to: Date())!)
        try? """
        ---
        datum: \(date)
        teilnehmer:
          - Jonas Weber
          - Sara Wolf
        kunde: "[[Fabrikam]]"
        ---

        # Fabrikam Release-Abstimmung

        ### 1. Aufgabenpunkte

        - [ ] Sara Wolf schickt die Testergebnisse (Freitag). [12:40]
        - [x] Jonas prüft das Template. [20:01]

        ### 2. Release

        - Das Release verschiebt sich um eine Woche. [03:10]
        - Die Validierung startet am Monatsanfang. [08:45]
        """.write(to: meetings.appendingPathComponent("Fabrikam Release-Abstimmung.md"), atomically: true, encoding: .utf8)
    }
}

/// Today's and tomorrow's meetings of the demo user.
enum DemoCalendar {
    static func events(now: Date) -> [CalendarService.Event] {
        let me = MeetingParticipant(name: DemoMode.userName, email: "jonas.weber@\(DemoMode.ownDomain)")
        let mia = MeetingParticipant(name: "Mia Keller", email: "mia.keller@\(DemoMode.ownDomain)")
        let sara = MeetingParticipant(name: "Sara Wolf", email: "sara.wolf@fabrikam-diagnostics.example")
        let paul = MeetingParticipant(name: "Paul Braun", email: "paul.braun@\(DemoMode.ownDomain)")
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        func at(_ minutes: Double) -> Date { hour.addingTimeInterval(minutes * 60) }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return [
            CalendarService.Event(id: "demo-1", title: "Fabrikam Weekly", start: at(65), end: at(95), organizer: sara,
                                  participants: [sara, me, mia], joinURL: URL(string: "https://example.com/join/fabrikam")),
            CalendarService.Event(id: "demo-2", title: "Release 2.4 Sync", start: at(150), end: at(180), organizer: me,
                                  participants: [me, mia, paul]),
            CalendarService.Event(id: "demo-3", title: "Focus time", start: at(200), end: at(260), participants: [me], isInfo: true),
            CalendarService.Event(id: "demo-4", title: "Risk Suite Review", start: tomorrow.addingTimeInterval(10 * 3_600),
                                  end: tomorrow.addingTimeInterval(11 * 3_600), organizer: paul, participants: [paul, me]),
        ]
    }
}
