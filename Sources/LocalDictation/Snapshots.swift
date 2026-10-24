import AppKit
import DictationASR
import DictationCore
import SwiftUI

/// Draws every pill mode and every page of the window into PNG files, with sample data and
/// without touching the real settings or history. Used to review the interface:
/// `LocalDictation --render-snapshots <dir>`.
enum Snapshots {
    /// True while snapshots render, so views show their final state instead of starting an animation.
    nonisolated(unsafe) static var isRendering = false

    static func render(to directory: URL) throws {
        isRendering = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        checkPillHitTesting()
        let system = AudioDevices.defaultInput()
        print("system microphone: \(system?.name ?? "none") (Bluetooth: \(system?.isBluetooth ?? false))")
        print("auto-detect records from: \(AudioDevices.resolve(uid: "")?.name ?? "none")")

        let modes: [(String, PillModel.Mode)] = [
            ("pill-idle", .idle), ("pill-expanded", .expanded), ("pill-recording", .recording),
            ("pill-handsfree", .handsFree), ("pill-processing", .processing),
            ("pill-message", .message("App changed: text copied, paste with Cmd+V")),
        ]
        for (name, mode) in modes {
            let model = PillModel()
            model.mode = mode
            model.hoveredButton = .mic
            model.levels = (0..<PillModel.barCount).map { CGFloat(abs(sin(Double($0) * 0.7))) * 0.9 }
            let view = NSHostingView(rootView: PillView(model: model).background(Color(white: 0.45)))
            view.frame = NSRect(origin: .zero, size: DictationPill.panelSize)
            try write(view, to: directory.appendingPathComponent("\(name).png"))
        }
        let meeting = PillModel()
        meeting.mode = .idle
        meeting.meetingActive = true
        let meetingView = NSHostingView(rootView: PillView(model: meeting).background(Color(white: 0.18)))
        meetingView.frame = NSRect(origin: .zero, size: DictationPill.panelSize)
        try write(meetingView, to: directory.appendingPathComponent("pill-idle-meeting.png"))
        meeting.upcomingMeeting = ("Proseware Sync", Date().addingTimeInterval(240))
        let bothView = NSHostingView(rootView: PillView(model: meeting).background(Color(white: 0.18)))
        bothView.frame = NSRect(origin: .zero, size: DictationPill.panelSize)
        try write(bothView, to: directory.appendingPathComponent("pill-idle-meeting-and-upcoming.png"))
        let upcoming = PillModel()
        upcoming.mode = .message("Proseware Sync in 5 min")
        let upcomingView = NSHostingView(rootView: PillView(model: upcoming).background(Color(white: 0.18)))
        upcomingView.frame = NSRect(origin: .zero, size: DictationPill.panelSize)
        try write(upcomingView, to: directory.appendingPathComponent("pill-meeting-reminder.png"))

        let arrow = PillModel()
        arrow.mode = .expanded
        arrow.arrowFor = .transform
        arrow.hoveredButton = .transformMenu
        arrow.transformName = "Polish"
        let arrowView = NSHostingView(rootView: PillView(model: arrow).background(Color(white: 0.45)))
        arrowView.frame = NSRect(origin: .zero, size: DictationPill.panelSize)
        try write(arrowView, to: directory.appendingPathComponent("pill-transform-arrow.png"))

        let language = PillModel()
        language.mode = .expanded
        language.arrowFor = .language
        language.hoveredButton = .languageMenu
        let languageView = NSHostingView(rootView: PillView(model: language).background(Color(white: 0.45)))
        languageView.frame = NSRect(origin: .zero, size: DictationPill.panelSize)
        try write(languageView, to: directory.appendingPathComponent("pill-language-arrow.png"))

        let languagePicker = NSHostingView(rootView: LanguagePickerView(current: "de", choose: { _ in })
            .padding(20).background(Color(white: 0.3)))
        languagePicker.frame = NSRect(origin: .zero, size: languagePicker.fittingSize)
        try write(languagePicker, to: directory.appendingPathComponent("pill-language-card.png"))

        let picker = NSHostingView(rootView: TransformPickerView(transforms: Transform.presets, current: 0,
                                                                 choose: { _ in }, edit: {}).padding(20).background(Color(white: 0.3)))
        picker.frame = NSRect(origin: .zero, size: picker.fittingSize)
        try write(picker, to: directory.appendingPathComponent("pill-transform-card.png"))

        let assistantPlan = AssistantPlan(summary: "Aufgabe in awork anlegen", actions: [
            AssistantAction(type: .aworkTask, title: "„Release Notes prüfen“ in [NW] Release 2.4, fällig Fr 24.10."),
            AssistantAction(type: .openURL, title: "staging öffnen"),
        ])
        let phases: [(String, AssistantCardModel.Phase)] = [
            ("thinking", .thinking), ("proposal", .proposal(assistantPlan)), ("running", .running(assistantPlan)),
            ("done", .done("Angelegt", link: URL(string: "https://example.com"))),
            ("answer", .answer("Die Tabelle baut **novaReportingMacros** mit `#novaTraceTable($items)`; die Spalten kommen aus dem zweiten Parameter.")),
            ("answer-table", .answer("""
            ## Diese Woche
            Keine Aufgabe ist zwischen 19. und 25.10. fällig.

            ## Überfällig
            | Fällig | Titel | Projekt | Status |
            |---|---|---|---|
            | 28.08. | Implementierungsunterstützung | [NW] Risk Suite und Security trennen | To Do |
            | 28.08. | Plugin Updates und Vorbereitung für Core Update | [LW] Continuous development | In Progress |
            - **3 weitere** ohne Fälligkeit in [LW] Continuous development
            """)),
        ]
        for (name, phase) in phases {
            let cardModel = AssistantCardModel()
            cardModel.request = "Leg bei Fabrikam eine Aufgabe an: Release Notes prüfen, bis Freitag, und öffne staging"
            cardModel.phase = phase
            let view = NSHostingView(rootView: AssistantCardView(model: cardModel).padding(20).background(Color(white: 0.3)))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            try write(view, to: directory.appendingPathComponent("assistant-\(name).png"))
        }
        let assistantPill = PillModel()
        assistantPill.mode = .assistant
        assistantPill.levels = (0..<PillModel.barCount).map { CGFloat(abs(sin(Double($0) * 0.7))) * 0.9 }
        let assistantPillView = NSHostingView(rootView: PillView(model: assistantPill).background(Color(white: 0.45)))
        assistantPillView.frame = NSRect(origin: .zero, size: DictationPill.panelSize)
        try write(assistantPillView, to: directory.appendingPathComponent("pill-assistant.png"))

        let sampleBriefing = Briefing(title: "Fabrikam Weekly", start: Date().addingTimeInterval(5 * 60), customer: "Fabrikam", previous: [
            Briefing.PastMeeting(title: "Fabrikam Release-Abstimmung", date: Date().addingTimeInterval(-6 * 86_400), note: "x",
                                 openItems: ["Mia Keller schickt die Testergebnisse (Freitag)."],
                                 points: ["Das Release verschiebt sich um eine Woche.", "Die Validierung startet am 3.11."]),
        ], openTasks: ["Release Notes prüfen", "Template-Update auf Demo testen"])
        let briefingView = NSHostingView(rootView: BriefingCardView(briefing: sampleBriefing, loadingTasks: false, startNote: {},
                                                                    openNote: { _ in }, close: {}).padding(20).background(Color(white: 0.3)))
        briefingView.frame = NSRect(origin: .zero, size: briefingView.fittingSize)
        try write(briefingView, to: directory.appendingPathComponent("briefing-card.png"))

        let chips = NSHostingView(rootView: VStack(alignment: .trailing, spacing: 14) {
            StatusChip(status: .transcribing, progress: 0.42)
            StatusChip(status: .summarizing, progress: 0.9)
            StatusChip(status: .done)
            StatusChip(status: .recording)
            StatusChip(status: .failed)
        }.padding(24).background(Theme.panel))
        chips.frame = NSRect(origin: .zero, size: chips.fittingSize)
        try write(chips, to: directory.appendingPathComponent("status-chips.png"))

        let today = Calendar.current.startOfDay(for: Date())
        let sampleMeetings = [(9, 0, "Implementierungsblocker"), (11, 0, "Fabrikam / Contoso Plan"), (15, 30, "CoffeePals")]
            .map { hour, minute, title in
                let start = today.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
                return MeetingCardView.Meeting(id: title, title: title, start: start, end: start.addingTimeInterval(2700))
            }
        for (name, connected) in [("pill-meeting-card", true), ("pill-meeting-card-no-calendar", false)] {
            let card = NSHostingView(rootView: MeetingCardView(meetings: sampleMeetings, calendarConnected: connected, recording: false,
                                                               start: { _ in }, stop: {}, connectCalendar: {}, close: {})
                .padding(20).background(Color(white: 0.3)))
            card.frame = NSRect(origin: .zero, size: card.fittingSize)
            try write(card, to: directory.appendingPathComponent("\(name).png"))
        }
        let meetingArrow = PillModel()
        meetingArrow.mode = .expanded
        meetingArrow.arrowFor = .notetaker
        meetingArrow.hoveredButton = .notetakerMenu
        let meetingArrowView = NSHostingView(rootView: PillView(model: meetingArrow).background(Color(white: 0.45)))
        meetingArrowView.frame = NSRect(origin: .zero, size: DictationPill.panelSize)
        try write(meetingArrowView, to: directory.appendingPathComponent("pill-meeting-arrow.png"))

        let model = sampleModel(directory: directory)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            for section in AppModel.Section.allCases {
                model.section = section
                let view = NSHostingView(rootView: MainView(model: model))
                view.appearance = NSAppearance(named: appearance)
                view.frame = NSRect(x: 0, y: 0, width: 1200, height: 750)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                try write(view, to: directory.appendingPathComponent("window-\(section.rawValue)-\(suffix).png"))
            }
        }
        // The settings window over the app, every page.
        model.section = .home
        for page in AppModel.SettingsPage.allCases {
            model.openSettings(page)
            let view = NSHostingView(rootView: MainView(model: model))
            view.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            try write(view, to: directory.appendingPathComponent("settings-\(page.rawValue).png"))
        }
        // The settings at the smallest window size (content area below the title bar).
        model.openSettings(.general)
        let smallest = NSHostingView(rootView: MainView(model: model))
        smallest.appearance = NSAppearance(named: .darkAqua)
        smallest.frame = NSRect(x: 0, y: 0, width: 1000, height: 652)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try write(smallest, to: directory.appendingPathComponent("settings-smallest-window.png"))
        let languages = NSHostingView(rootView: LanguagesDialog(model: model, done: {}).padding(20).background(Color(white: 0.15)))
        languages.appearance = NSAppearance(named: .darkAqua)
        languages.frame = NSRect(origin: .zero, size: languages.fittingSize)
        try write(languages, to: directory.appendingPathComponent("settings-languages.png"))
        model.showingSettings = false
        let savedAI = model.settings.ai
        model.settings.ai.meetings = AITask.meetings.recommended
        let claude = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) { ClaudeSettings(model: model) }
            .padding(40).frame(width: 980).background(Theme.panel))
        claude.appearance = NSAppearance(named: .aqua)
        claude.frame = NSRect(origin: .zero, size: claude.fittingSize)
        try write(claude, to: directory.appendingPathComponent("settings-claude.png"))
        model.settings.ai = savedAI
        model.showingSettings = false

        let diff = NSHostingView(rootView: TransformDiffView(change: DictationController.TransformChange(
            name: "Polish", original: "hey leute, das deployment hat heute nicht geklappt, ich schau morgen nochmal rein",
            result: "Hallo zusammen, das Deployment hat heute nicht geklappt. Ich schaue es mir morgen noch einmal an."),
            close: {}))
        diff.appearance = NSAppearance(named: .aqua)
        diff.frame = NSRect(x: 0, y: 0, width: 860, height: 420)
        try write(diff, to: directory.appendingPathComponent("transform-diff.png"))

        var editorSnippets = [Snippet(trigger: "meine Signatur", text: "**Jonas Weber**\n*Northwind*")]
        let snippetEditor = NSHostingView(rootView: SnippetEditor(target: .edit(0), snippets: Binding(get: { editorSnippets },
                                                                                                      set: { editorSnippets = $0 }),
                                                                  done: {}).background(Theme.panel))
        snippetEditor.appearance = NSAppearance(named: .aqua)
        snippetEditor.frame = NSRect(origin: .zero, size: snippetEditor.fittingSize)
        try write(snippetEditor, to: directory.appendingPathComponent("snippet-editor.png"))

        let scratchFile = directory.appendingPathComponent("sample-scratchpad.json")
        try? FileManager.default.removeItem(at: scratchFile)
        let scratchNotes = ScratchpadModel(store: ScratchpadStore(url: scratchFile))
        let filled = scratchNotes.newNote()
        scratchNotes.setText("Release 2.4\n- Regressionstests bis Donnerstag\n- Release Notes an Paul", of: filled)
        for (name, list) in [("scratchpad-window", false), ("scratchpad-window-list", true)] {
            let state = ScratchpadWindowState(notes: scratchNotes)
            state.open(filled)
            state.open(scratchNotes.newNote())
            state.showList = list
            let window = NSHostingView(rootView: ScratchpadFloatingView(state: state, model: model, close: {}, toggleSize: {}))
            window.appearance = NSAppearance(named: .aqua)
            window.frame = NSRect(origin: .zero, size: ScratchpadWindowState.compactSize)
            try write(window, to: directory.appendingPathComponent("\(name).png"))
        }

        for (name, transform) in [("transform-editor", model.settings.transforms[1]),
                                  ("transform-editor-new", Transform(name: "", instruction: ""))] {
            let editor = NSHostingView(rootView: TransformEditor(model: model, transform: transform, done: {}))
            editor.appearance = NSAppearance(named: .aqua)
            editor.frame = NSRect(x: 0, y: 0, width: 960, height: 660)
            try write(editor, to: directory.appendingPathComponent("\(name).png"))
        }

        if let notetaker = model.notetaker, let meeting = notetaker.meetings.first {
            let page = NSHostingView(rootView: MeetingPage(meeting: meeting, notetaker: notetaker, back: {})
                .frame(width: 1470, height: 900).background(Theme.panel))
            page.appearance = NSAppearance(named: .aqua)
            page.frame = NSRect(x: 0, y: 0, width: 1470, height: 900)
            try write(page, to: directory.appendingPathComponent("meeting-page.png"))
        }

        // A narrow window on Insights: the sidebar must keep its place and the cards stack.
        model.section = .insights
        let narrow = NSHostingView(rootView: MainView(model: model))
        narrow.appearance = NSAppearance(named: .darkAqua)
        narrow.frame = NSRect(x: 0, y: 0, width: 1000, height: 780)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try write(narrow, to: directory.appendingPathComponent("window-insights-narrow.png"))

        // Full screen on a 13-inch MacBook Air: the pages fill the space, the sidebar open and folded.
        for collapsed in [false, true] {
            UserDefaults.standard.set(collapsed, forKey: "sidebarCollapsed")
            for section in [AppModel.Section.home, .insights, .notetaker, .dictionary] {
                model.section = section
                let full = NSHostingView(rootView: MainView(model: model))
                full.appearance = NSAppearance(named: .aqua)
                full.frame = NSRect(x: 0, y: 0, width: 1470, height: 920)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                try write(full, to: directory.appendingPathComponent("fullscreen-\(section.rawValue)\(collapsed ? "-collapsed" : "").png"))
            }
        }
        UserDefaults.standard.removeObject(forKey: "sidebarCollapsed")

        // The Notetaker and Assistant tabs of Insights, the assistant with a sample usage log.
        let sampleLog = [
            AssistantUsage(steps: ["agent"], tools: ["mcp__servicedesk__sd_queue", "mcp__servicedesk__sd_ticket", "mcp__servicedesk__sd_ticket"], seconds: 24),
            AssistantUsage(steps: ["agent"], tools: ["mcp__claude_ai_Microsoft_365__outlook_calendar_search"], seconds: 19),
            AssistantUsage(steps: ["agent"], tools: ["WebSearch", "WebFetch"], seconds: 31),
            AssistantUsage(steps: ["agent"], tools: ["mcp__polarion-api__search_polarion_api", "mcp__polarion-api__explain_polarion_symbol"], seconds: 44),
            AssistantUsage(steps: ["open_url"], opened: ["Spotify"], seconds: 1),
            AssistantUsage(steps: ["open_url"], opened: ["Spotify"], seconds: 1),
            AssistantUsage(steps: ["open_url"], opened: ["github.com"], seconds: 1),
            AssistantUsage(steps: ["awork_call"], seconds: 3),
            AssistantUsage(steps: ["answer"], seconds: 2),
        ]
        for (tab, name) in [(2, "notetaker"), (3, "assistant")] {
            let page = NSHostingView(rootView: InsightsView(model: model, tab: tab, assistantLog: sampleLog)
                .frame(width: 1200, height: 860).background(Theme.panel))
            page.appearance = NSAppearance(named: .aqua)
            page.frame = NSRect(x: 0, y: 0, width: 1200, height: 860)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            try write(page, to: directory.appendingPathComponent("insights-\(name).png"))
        }

        // The transfer sheets in a low window with many action items: title and buttons must stay visible.
        let items = (1...7).map { "Action item \($0) with a sentence long enough to fill the row" }
        let sheets: [(String, AnyView, CGFloat)] = [
            ("awork", AnyView(AworkTransferSheet(meeting: Meeting(title: "Sample"),
                                                 items: ["Jonas Weber führt heute Abend das Litware-Update des Coordinators durch",
                                                         "Paul schickt die Testergebnisse, etwa zwei Stunden Aufwand (bis Freitag)"],
                                                 preview: true) { _ in }), 660),
            ("polarion", AnyView(PolarionTransferSheet(meeting: Meeting(title: "Sample"), items: [items[0]], settings: DictationSettings(),
                                                       preview: [PolarionBacklog.Draft(type: "stakeholderRequirement",
                                                                                       title: "PDF exports include the audit trail",
                                                                                       descriptionHtml: "<p>As a quality manager I need the audit trail in every PDF export.</p><p><b>Acceptance criteria</b></p><ul><li>Every exported PDF lists the audit trail.</li></ul>")]) { _ in }), 720),
        ]
        for (name, sheet, width) in sheets {
            let view = NSHostingView(rootView: sheet.frame(width: width, height: 720).background(Theme.panel))
            view.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(x: 0, y: 0, width: width, height: 720)
            RunLoop.main.run(until: Date().addingTimeInterval(4))
            try write(view, to: directory.appendingPathComponent("sheet-\(name).png"))
        }

        // The awork result in the size it asks for, as the sheet shows it: only as high as its rows.
        let result = NSHostingView(rootView: AworkTransferSheet(
            meeting: Meeting(title: "Sample"), items: [items[0]], preview: true,
            previewCreated: ["Speaker 1 fragt Paul, wie der Sync vom Dev-Server in das Template-Repo funktioniert (23.10.)": "https://example.com"]
        ) { _ in }.background(Theme.panel))
        result.appearance = NSAppearance(named: .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        result.frame = NSRect(origin: .zero, size: result.fittingSize)
        try write(result, to: directory.appendingPathComponent("sheet-awork-result.png"))

        // A low window, where the sidebar has to scroll and the logo must stay below the window buttons.
        model.section = .home
        let small = NSHostingView(rootView: MainView(model: model))
        small.appearance = NSAppearance(named: .darkAqua)
        small.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try write(small, to: directory.appendingPathComponent("window-small-dark.png"))
    }

    /// Prints whether the pill takes clicks on the bar and lets clicks above it through.
    /// Points are in panel coordinates measured from the bottom, like a click on the screen.
    private static func checkPillHitTesting() {
        let model = PillModel()
        let view = PillHostingView(rootView: PillView(model: model))
        view.frame = NSRect(origin: .zero, size: DictationPill.panelSize)
        let centre = DictationPill.panelSize.width / 2
        for mode in [PillModel.Mode.idle, .expanded] {
            view.activeRect = model.with(mode: mode).activeRect(in: DictationPill.panelSize)
            for (label, height) in [("on the bar, 8 pt above the screen edge", 8.0),
                                    ("1 cm above the bar, 45 pt", 45.0), ("3 cm above, 100 pt", 100.0)] {
                let point = view.isFlipped ? NSPoint(x: centre, y: view.bounds.height - height) : NSPoint(x: centre, y: height)
                let hit = view.hitTest(view.convert(point, to: nil)) != nil
                print("pill \(mode) \(label): \(hit ? "takes the click" : "passes through")")
            }
        }
    }

    private static func sampleModel(directory: URL) -> AppModel {
        let history = HistoryStore(url: directory.appendingPathComponent("sample-history.jsonl"), limit: 50)
        try? FileManager.default.removeItem(at: history.url)
        let samples: [(Double, String, String, Double)] = [
            (-600, "com.microsoft.teams2", "Kurze Frage: hast du den Fix für das Table Framework schon gepusht?", 4),
            (-3_600, "com.microsoft.Outlook", "Hi Paul,\n\ndanke für deine Mail. Ich schau mir das heute Nachmittag an.\n\nViele Grüße\nJonas", 8),
            (-90_000, "md.obsidian", "Meine Stichpunkte für den Workshop:\n- die Anforderungen\n- die Risikoanalyse\n- der Zeitplan", 7),
            (-95_000, "com.microsoft.VSCode", "Returns the list of work items that belong to the current document.", 3),
        ]
        for (offset, app, text, audio) in samples {
            var result = DictationResult(rawTranscript: text, language: "de", style: .plain, text: text,
                                         cleanup: .cleaned, transcriptionSeconds: 0.8, cleanupSeconds: 1.1)
            result.audioSeconds = audio
            try? history.append(HistoryEntry(date: Date().addingTimeInterval(offset), bundleId: app, result: result))
        }
        var settings = DictationSettings()
        settings.replacements = [Replacement(from: "polarian", to: "Polarion"), Replacement(from: "btw", to: "by the way")]
        settings.starredWords = ["LiveDoc"]
        settings.wordGroups = ["Polarion": "Produkte & Polarion", "LiveDoc": "Produkte & Polarion", "by the way": "Tools"]
        settings.snippets = [Snippet(trigger: "meine Signatur", text: "Viele Grüße\nJonas Weber\nNorthwind")]
        let model = AppModel(settings: settings, historyStore: history)
        model.status = .ready
        model.llmReady = true

        let meetings = directory.appendingPathComponent("sample-meetings", isDirectory: true)
        try? FileManager.default.removeItem(at: meetings)
        try? MeetingStore(directory: meetings).save(Meeting(
            title: "Abstimmung Release 2.4", date: Date().addingTimeInterval(-7_200), duration: 1_860, status: .done,
            transcript: "Wir gehen kurz die offenen Punkte für das Release durch. Das Table Framework ist fertig, die Tests laufen. Paul kümmert sich bis Donnerstag um die Release Notes.",
            summary: "Das Release 2.4 ist technisch fertig. Offen sind die Release Notes und die Abnahme beim Kunden, die für nächste Woche geplant ist.",
            actionItems: ["Paul: Release Notes bis Donnerstag", "Jonas: Abnahmetermin mit dem Kunden vereinbaren"]))
        // A few more days, so the list shows its day and week sections.
        for (title, daysAgo, minutes) in [("Support Daily Stand-up", 0, 6), ("CoffeePals", 1, 31), ("Testing Training", 1, 49),
                                          ("Polarion Specs Development", 3, 58), ("Fabrikam Release-Abstimmung", 9, 25), ("Kickoff Litware Upgrade", 45, 60), ("Jahresplanung 2025", 400, 90)] {
            var meeting = Meeting(title: title, date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date().addingTimeInterval(-10_800))!,
                                  duration: Double(minutes * 60), status: .done, actionItems: ["Paul: Release Notes"])
            meeting.participants = [MeetingParticipant(name: "Tim Hoffmann", email: ""),
                                    MeetingParticipant(name: daysAgo % 2 == 0 ? "Sara Wolf" : "Lea Fischer", email: "")]
            try? MeetingStore(directory: meetings).save(meeting)
        }
        model.notetaker = NotetakerController(transcriber: WhisperTranscriber(modelName: "none"), directory: meetings,
                                              resumePending: false) { DictationSettings() }
        return model
    }

    /// Draws the assistant card for one record of `dictate --assistant`: the answer when the
    /// record has one, otherwise the proposal with its steps. For evaluating what the user sees.
    static func renderCard(record: URL, to output: URL) throws {
        isRendering = true
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any] else { return }
        let model = AssistantCardModel()
        model.request = object["request"] as? String ?? ""
        let answers = (object["agent"] as? [[String: Any]] ?? []).compactMap { $0["answer"] as? String ?? ($0["error"] as? String).map { "Error: " + $0 } }
        let actions = (object["actions"] as? [[String: Any]] ?? []).map { action in
            AssistantAction(type: AssistantAction.Kind(rawValue: action["type"] as? String ?? "") ?? AssistantAction.Kind.answer,
                            title: action["title"] as? String ?? "", url: action["url"] as? String ?? "")
        }
        if !answers.isEmpty {
            model.phase = .answer(answers.joined(separator: "\n\n"))
        } else if actions.allSatisfy({ $0.kind == AssistantAction.Kind.answer }), let text = (object["actions"] as? [[String: Any]])?.first?["answer"] as? String {
            model.phase = .answer(text)
        } else {
            model.phase = .proposal(AssistantPlan(summary: object["summary"] as? String ?? "", actions: actions))
        }
        let view = NSHostingView(rootView: AssistantCardView(model: model).padding(20).background(Color(white: 0.3)))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try write(view, to: output)
    }

    private static func write(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
}
