import AppKit
import DictationCore
import SwiftUI

/// Meetings, laid out after Wispr Flow's Notetaker: setup, the start button, the tabs My notes,
/// Past notes and Folders with upcoming and past meetings, and a meeting view with Summary,
/// Tasks, Transcript and My thoughts.
struct NotetakerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let notetaker = model.notetaker {
            NotetakerPage(model: model, notetaker: notetaker, calendar: model.calendar ?? CalendarService())
        } else {
            Text("Notetaker is starting…").foregroundStyle(Theme.secondary).padding(43)
        }
    }
}

private struct NotetakerPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var notetaker: NotetakerController
    @ObservedObject var calendar: CalendarService
    @State private var tab = Tab.pastNotes
    @State private var query = ""
    @State private var searching = false
    @State private var showingTutorial = false
    @State private var openMeeting: UUID?
    @State private var openFolder: String?
    @State private var screenRecording = ScreenRecordingPermission.isGranted

    enum Tab: String, CaseIterable {
        case pastNotes = "Past notes", folders = "Folders"
    }

    var body: some View {
        if let id = openMeeting, let meeting = notetaker.meetings.first(where: { $0.id == id }) {
            MeetingPage(meeting: meeting, notetaker: notetaker) { openMeeting = nil }
        } else {
            overview
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 10) {
                    Theme.headline("Notetaker")
                    Spacer()
                    Button {
                        model.openSettings(.notetaker)
                    } label: {
                        Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 34, height: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Notetaker settings")
                    Button { showingTutorial = true } label: {
                        Label("Start tutorial", systemImage: "play.circle")
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                    }
                    .buttonStyle(.plain)
                    RecordToggle(notetaker: notetaker)
                }
                if !setupComplete { setupCard }
                todayCard
                    .padding(.bottom, 14)

                HStack(alignment: .bottom, spacing: 26) {
                    ForEach(Tab.allCases, id: \.self) { item in
                        Button { tab = item; openFolder = nil } label: {
                            Text(item.rawValue)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(tab == item ? Theme.text : Theme.secondary)
                                .padding(.bottom, 12)
                                .overlay(alignment: .bottom) { Rectangle().fill(tab == item ? Theme.text : .clear).frame(height: 2) }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if searching {
                        TextField("Search past notes and meetings", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .padding(.bottom, 8)
                    }
                    Button {
                        searching.toggle()
                        if !searching { query = "" }
                    } label: {
                        Image(systemName: searching ? "xmark" : "magnifyingglass")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.secondary)
                            .padding(.bottom, 12)
                    }
                    .buttonStyle(.plain)
                    .help("Search past notes and meetings")
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

                switch tab {
                case .pastNotes: pastNotes
                case .folders: folders
                }
            }
            .pageLayout()
        }
        .onAppear {
            screenRecording = ScreenRecordingPermission.isGranted
            calendar.refresh()
        }
        .sheet(isPresented: $showingTutorial) { NotetakerTutorial { showingTutorial = false } }
    }

    private var setupComplete: Bool { model.permissions[.microphone] == true && screenRecording }

    private var setupCard: some View {
        Card(padding: 26) {
            Text("Set up Notetaker").font(.system(size: 17, weight: .medium))
            Text("Complete setup to start Notetaker. These are required settings.")
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 12)
            SetupGate(done: model.permissions[.microphone] == true, title: "Enable Microphone",
                      doneTitle: "Microphone enabled", subtitle: "Capture what you say") { Permission.microphone.request() }
            Divider().overlay(Theme.border).padding(.vertical, 8)
            SetupGate(done: screenRecording, title: "Enable System Audio", doneTitle: "System audio enabled",
                      subtitle: screenRecording ? "Capture what others say"
                          : "Allow LocalDictation under Screen & System Audio Recording, then restart the app") {
                ScreenRecordingPermission.request()
            }
        }
    }

    @State private var showTomorrow = false

    private func meetingRows(_ events: [CalendarService.Event]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider().overlay(Theme.border) }
                HStack(spacing: 16) {
                    Text(event.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 15)).monospacedDigit()
                        .frame(width: 80, alignment: .leading)
                    // Entries without other people or marked free (focus time, support shifts)
                    // are shown lighter.
                    Text(event.title).font(.system(size: 15, weight: event.isMeeting ? .medium : .regular)).lineLimit(1)
                        .foregroundStyle(event.isMeeting ? Theme.text : Theme.secondary)
                    Spacer()
                    if let join = event.joinURL {
                        Button { NSWorkspace.shared.open(join) } label: {
                            Text("Join").font(.system(size: 14, weight: .medium))
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { notetaker.start(event: event) } label: {
                        Text("Start note").font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.selection))
                    }
                    .buttonStyle(.plain)
                    .disabled(notetaker.isRecording || notetaker.isFinishing)
                }
                .padding(.vertical, 12)
            }
        }
    }

    /// Calendar meetings of today and tomorrow, or the way to connect the calendar. Tomorrow's
    /// meetings sit in a section of their own, closed when the view opens, so today's are seen
    /// at a glance.
    private var todayCard: some View {
        let today = calendar.events.filter { Calendar.current.isDateInToday($0.start) }
        let tomorrow = calendar.events.filter { !Calendar.current.isDateInToday($0.start) }
        return VStack(alignment: .leading, spacing: 0) {
            Text("TODAY")
                .font(.system(size: 13, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(Theme.text)
                .padding(.bottom, 18)
            if calendar.authorized && !calendar.events.isEmpty {
                if today.isEmpty {
                    Text("No more meetings today.").font(.system(size: 15)).foregroundStyle(Theme.secondary).padding(.bottom, 12)
                } else {
                    meetingRows(today)
                }
                if !tomorrow.isEmpty {
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.top, today.isEmpty ? 0 : 10)
                    Button { withAnimation(.easeOut(duration: 0.15)) { showTomorrow.toggle() } } label: {
                        HStack(spacing: 8) {
                            Text("TOMORROW").font(.system(size: 13, weight: .semibold)).tracking(1.3)
                            Text("\(tomorrow.count)").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .rotationEffect(.degrees(showTomorrow ? 90 : 0))
                        }
                        .foregroundStyle(Theme.text)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showTomorrow { meetingRows(tomorrow) }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "calendar").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.secondary)
                    Text("No meetings found").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.secondary)
                    Text(calendar.authorized ? "There are no more meetings today or tomorrow."
                                             : "Connect your calendar to start a note for a meeting with one click.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                    if !calendar.authorized {
                        Button { calendar.connect() } label: {
                            Text("Connect calendar")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.panel)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.text))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.card))
    }

    // MARK: Tabs

    @ViewBuilder private var pastNotes: some View {
        if filtered.isEmpty {
            EmptyCard(text: query.isEmpty ? "Your meetings will appear here" : "No meetings found")
        } else {
            MeetingList(meetings: filtered, progress: notetaker.progress, searching: !query.isEmpty, open: { openMeeting = $0.id })
        }
    }

    @ViewBuilder private var folders: some View {
        if let folder = openFolder {
            Button { openFolder = nil } label: { Label("Folders", systemImage: "chevron.left") }.buttonStyle(.plain)
            Theme.sectionLabel("Notes in \(folder)")
            let notes = filtered.filter { $0.folder == folder }
            if notes.isEmpty {
                EmptyCard(text: "No notes in this folder yet. Add notes to \(folder) from a note's menu.")
            } else {
                MeetingList(meetings: notes, progress: notetaker.progress, open: { openMeeting = $0.id })
            }
        } else if notetaker.folders.isEmpty {
            EmptyCard(text: "No folders yet. Move a note into a new folder from its menu.")
        } else {
            Card {
                ForEach(Array(notetaker.folders.enumerated()), id: \.element) { index, folder in
                    if index > 0 { Divider().overlay(Theme.border) }
                    Button { openFolder = folder } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(folder).font(.system(size: 15, weight: .medium))
                            Spacer()
                            Text("\(notetaker.meetings.filter { $0.folder == folder }.count)").foregroundStyle(Theme.secondary)
                            Image(systemName: "chevron.right").foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var filtered: [Meeting] { notetaker.meetings.filter { $0.matches(query) } }
}

/// Start, Stop and Finishing up…, with the recording time.
private struct RecordToggle: View {
    @ObservedObject var notetaker: NotetakerController

    var body: some View {
        HStack(spacing: 10) {
            if notetaker.isRecording {
                // One meter per track, so a silent microphone shows during the meeting.
                LevelMeter(title: "You", level: notetaker.level)
                LevelMeter(title: "Others", level: notetaker.systemLevel)
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text(Self.duration(notetaker.elapsed)).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            Button { notetaker.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: notetaker.isRecording ? "stop.fill" : "record.circle")
                    Text(notetaker.isFinishing ? "Finishing up…" : (notetaker.isRecording ? "Stop" : "Start Notetaker"))
                }
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(notetaker.isRecording ? Color.red.opacity(0.85) : Theme.orange.opacity(0.22)))
                .foregroundStyle(notetaker.isRecording ? Color.white : Theme.text)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(notetaker.isFinishing)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

private struct SetupGate: View {
    let done: Bool
    let title: String
    let doneTitle: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(done ? Theme.teal : Theme.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(done ? doneTitle : title).font(.system(size: 14, weight: .medium))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if !done { Button("Enable", action: action) }
        }
    }
}

private struct EmptyCard: View {
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 17))
                .foregroundStyle(Theme.secondary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.panel))
                .overlay(Circle().strokeBorder(Theme.border))
            Text(text).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
    }
}

/// Past meetings in sections that get coarser with age (Today, Yesterday, This week, Last week,
/// the months of this year, earlier years), newest first. Today and yesterday are open, or the
/// newest section when neither exists; the others open on click, and a search opens all of them.
/// A long section shows its newest notes first and the rest on request.
private struct MeetingList: View {
    let meetings: [Meeting]
    var progress: [UUID: Double] = [:]
    var searching = false
    let open: (Meeting) -> Void

    @State private var toggled: Set<Date> = []
    @State private var showingAll: Set<Date> = []
    private static let pageSize = 25

    var body: some View {
        let sections = MeetingGrouping.timeline(meetings, date: \.date)
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                let isOpen = searching || (openByDefault(index: index, section: section) != toggled.contains(section.start))
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if toggled.contains(section.start) { toggled.remove(section.start) } else { toggled.insert(section.start) }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(section.title.uppercased()).font(.system(size: 13, weight: .semibold)).tracking(1.3)
                                .foregroundStyle(Theme.text)
                            Text(summary(section.items)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                        }
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if isOpen {
                        let all = searching || showingAll.contains(section.start) || section.items.count <= Self.pageSize + 5
                        rows(all ? section.items : Array(section.items.prefix(Self.pageSize)),
                             withDay: section.title != "Today" && section.title != "Yesterday")
                        if !all {
                            Button { showingAll.insert(section.start) } label: {
                                Text("Show all \(section.items.count) notes").font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.secondary).padding(.horizontal, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func openByDefault(index: Int, section: MeetingGrouping.Section<Meeting>) -> Bool {
        section.title == "Today" || section.title == "Yesterday" || index == 0
    }

    private func summary(_ items: [Meeting]) -> String {
        let minutes = items.reduce(0) { $0 + max(1, Int($1.duration / 60)) }
        let time = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return "\(items.count) \(items.count == 1 ? "note" : "notes") · \(time)"
    }

    private func rows(_ items: [Meeting], withDay: Bool) -> some View {
        Card {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, meeting in
                if index > 0 { Divider().overlay(Theme.border) }
                Button { open(meeting) } label: {
                    HStack(spacing: 14) {
                        Text(meeting.date.formatted(date: .omitted, time: .shortened))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 53, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.displayTitle).font(.system(size: 16, weight: .medium)).lineLimit(1)
                            // Today and Yesterday name the day; in the other sections the row says which one.
                            Text(!withDay ? "\(max(1, Int(meeting.duration / 60))) min"
                                 : "\(meeting.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(max(1, Int(meeting.duration / 60))) min")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        StatusChip(status: meeting.status, progress: progress[meeting.id])
                        Image(systemName: "chevron.right").foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The state of a meeting in the list, in Wispr Flow's quiet style: a small neutral pill with a
/// coloured dot. While a meeting is processed the pill fills from the left like a progress bar
/// with the real progress, and the dots after the label keep counting, so it is visible that
/// work goes on also during a long step.
struct StatusChip: View {
    let status: Meeting.Status
    var progress: Double?

    private var label: String {
        switch status {
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .summarizing: return "Writing notes"
        case .done: return "Ready"
        case .failed: return "Failed"
        }
    }

    private var dot: Color {
        switch status {
        case .recording, .failed: return .red
        case .transcribing, .summarizing: return Theme.orange
        case .done: return Theme.teal
        }
    }

    private var working: Bool { status == .transcribing || status == .summarizing }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.4, paused: !working && status != .recording)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.4)
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 6, height: 6)
                    .opacity(status == .recording ? (tick % 2 == 0 ? 1 : 0.35) : 1)
                HStack(spacing: 0) {
                    Text(label)
                    if working {
                        // Three dots that fill up one after another, then start again.
                        ForEach(0..<3, id: \.self) { index in
                            Text(".").opacity(index < tick % 4 ? 1 : 0.15)
                        }
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(status == .failed ? Color.red : Theme.text.opacity(0.75))
                if working, let progress {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .frame(minWidth: working ? 150 : nil, alignment: .leading)
            .background(
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.card)
                        if working {
                            Capsule().fill(Theme.orange.opacity(0.28))
                                .frame(width: max(24, geometry.size.width * (progress ?? 0.02)))
                                .animation(.easeOut(duration: 0.6), value: progress)
                        }
                    }
                }
            )
            .overlay(Capsule().strokeBorder(Theme.border))
        }
    }
}

// MARK: - One meeting

/// The action items chosen for the awork dialog.
struct AworkSelection: Identifiable {
    let id = UUID()
    let items: [String]
}

struct MeetingPage: View {
    let meeting: Meeting
    let notetaker: NotetakerController
    let back: () -> Void
    @State private var tab = Tab.summary
    @State private var newFolder = ""
    @State private var askingFolder = false

    enum Tab: String, CaseIterable {
        case summary = "Summary", tasks = "Tasks", transcript = "Transcript", thoughts = "My thoughts"
    }

    @State private var aworkItems: AworkSelection?
    @State private var polarionItems: AworkSelection?
    @State private var writingMail = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Button(action: back) { Label("All notes", systemImage: "chevron.left") }.buttonStyle(.plain)
                    Spacer()
                    Button {
                        writingMail = true
                    } label: {
                        Label("Folge-Mail", systemImage: "envelope")
                    }
                    .disabled(meeting.notesMarkdown.isEmpty)
                    Button("Copy as Markdown") {
                        let board = NSPasteboard.general
                        board.clearContents()
                        board.setString(meeting.markdown, forType: .string)
                    }
                    Menu {
                        Menu("Move to folder") {
                            ForEach(notetaker.folders, id: \.self) { folder in
                                Button(folder) { update { $0.folder = folder } }
                            }
                            Divider()
                            Button("New folder…") { askingFolder = true }
                            if !meeting.folder.isEmpty { Button("Remove from folder") { update { $0.folder = "" } } }
                        }
                        Button("Show recording in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([notetaker.audioURL(for: meeting)])
                        }
                        Button("Transcribe and summarize again") { notetaker.process(meeting) }
                        Divider()
                        Button("Delete note", role: .destructive) {
                            notetaker.delete(meeting)
                            back()
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }

                TextField("Untitled meeting", text: Binding(get: { meeting.title }, set: { title in update { $0.title = title } }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .medium))
                Text("\(meeting.date.formatted(date: .long, time: .shortened)) · \(max(1, Int(meeting.duration / 60))) min"
                     + (meeting.folder.isEmpty ? "" : " · \(meeting.folder)"))
                    .foregroundStyle(Theme.secondary)

                if meeting.status != .done { progress }

                HStack(spacing: 23) {
                    ForEach(Tab.allCases, id: \.self) { item in
                        Button { tab = item } label: {
                            Text(item.rawValue)
                                .font(.system(size: 13, weight: tab == item ? .medium : .regular))
                                .foregroundStyle(tab == item ? Theme.text : Theme.secondary)
                                .padding(.bottom, 8)
                                .overlay(alignment: .bottom) { Rectangle().fill(tab == item ? Theme.text : .clear).frame(height: 2) }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

                switch tab {
                case .summary: summary
                case .tasks: tasks
                case .transcript: transcript
                case .thoughts: thoughts
                }
            }
            // The same width and centring as the Notetaker page.
            .pageLayout()
        }
        .sheet(item: $aworkItems) { selection in
            AworkTransferSheet(meeting: meeting, items: selection.items) { created in
                if !created.isEmpty {
                    update { meeting in
                        for (item, link) in created { meeting.aworkTasks[item] = link }
                    }
                }
                aworkItems = nil
            }
        }
        .sheet(isPresented: $writingMail) {
            FollowUpMailSheet(meeting: meeting, settings: notetaker.currentSettings) { writingMail = false }
        }
        .sheet(item: $polarionItems) { selection in
            PolarionTransferSheet(meeting: meeting, items: selection.items, settings: notetaker.currentSettings) { created in
                if !created.isEmpty {
                    update { meeting in
                        for (item, id) in created { meeting.polarionItems[item] = id }
                    }
                }
                polarionItems = nil
            }
        }
        .alert("New folder", isPresented: $askingFolder) {
            TextField("Folder name", text: $newFolder)
            Button("Create") {
                let name = newFolder.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { update { $0.folder = name } }
                newFolder = ""
            }
            Button("Cancel", role: .cancel) { newFolder = "" }
        }
    }

    @ViewBuilder private var progress: some View {
        switch meeting.status {
        case .failed:
            Card(padding: 16) { Text("Processing failed: \(meeting.problem)").foregroundStyle(.red) }
        case .transcribing, .recording:
            ProgressLine(text: "Transcribing the recording …")
        case .summarizing:
            ProgressLine(text: "Writing the notes and action items …")
        case .done:
            if let interrupted = meeting.interruptedAt {
                Card(padding: 16) {
                    Label("The recording was interrupted at \(interrupted.formatted(date: .omitted, time: .shortened)) (the app quit or crashed). Everything up to then is in this note.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !meeting.warning.isEmpty {
                Card(padding: 16) {
                    Label(meeting.warning, systemImage: "mic.slash")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var summary: some View {
        if !meeting.notesMarkdown.isEmpty {
            NotesMarkdownView(markdown: meeting.notesMarkdown)
        } else if meeting.summary.isEmpty {
            Text(meeting.status == .done ? "No summary for this meeting." : "Summaries appear when a meeting ends")
                .foregroundStyle(Theme.secondary)
        } else {
            Theme.sectionLabel("Enhanced Summary")
            Text(meeting.summary).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
        }
    }

    @ViewBuilder private var tasks: some View {
        HStack {
            Text("Action Items").font(.system(size: 17, weight: .medium))
            Spacer()
            let open = meeting.actionItems.filter { meeting.aworkTasks[$0] == nil }
            if !open.isEmpty {
                Button { aworkItems = AworkSelection(items: open) } label: {
                    Label("Alle in awork übertragen …", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                Button { polarionItems = AworkSelection(items: open) } label: {
                    Label("In Polarion …", systemImage: "square.stack.3d.up")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
            }
        }
        if meeting.actionItems.isEmpty {
            Text("No remaining action items for this meeting").foregroundStyle(Theme.secondary)
        } else {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(meeting.actionItems, id: \.self) { item in
                        let done = meeting.completedActions.contains(item)
                        Button {
                            update { meeting in
                                if done { meeting.completedActions.removeAll { $0 == item } } else { meeting.completedActions.append(item) }
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(done ? Theme.teal : Theme.secondary)
                                Text(item).strikethrough(done).foregroundStyle(done ? Theme.secondary : Theme.text)
                                Spacer()
                                if let id = meeting.polarionItems[item] {
                                    Label(id, systemImage: "checkmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                                } else {
                                    Button { polarionItems = AworkSelection(items: [item]) } label: {
                                        Text("Polarion").font(.system(size: 12, weight: .medium))
                                            .padding(.horizontal, 8).frame(height: 22)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.selection))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Als Backlog-Item in Polarion anlegen")
                                }
                                if let link = meeting.aworkTasks[item], let url = URL(string: link) {
                                    Link(destination: url) {
                                        Label("In awork", systemImage: "checkmark").font(.system(size: 12, weight: .medium))
                                    }
                                } else {
                                    Button { aworkItems = AworkSelection(items: [item]) } label: {
                                        Text("awork").font(.system(size: 12, weight: .medium))
                                            .padding(.horizontal, 8).frame(height: 22)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.selection))
                                    }
                                    .buttonStyle(.plain)
                                    .help("In awork übertragen")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private var transcript: some View {
        if meeting.transcript.isEmpty {
            Text(meeting.status == .done ? "Nothing was said in this recording." : "The transcript appears when the recording is processed.")
                .foregroundStyle(Theme.secondary)
        } else if meeting.segments.isEmpty {
            Text("This note was transcribed before speakers were told apart. Use Transcribe and summarize again in the ··· menu to get the transcript per speaker.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .padding(.bottom, 8)
            Text(meeting.transcript).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
        } else {
            SpeakerTranscript(meeting: meeting) { label, name in
                notetaker.rename(speaker: label, to: name, in: meeting)
            }
        }
    }

    private var thoughts: some View {
        TextEditor(text: Binding(get: { meeting.notes }, set: { notes in update { $0.notes = notes } }))
            .font(.system(size: 14))
            .lineSpacing(4)
            .frame(minHeight: 199)
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(alignment: .topLeading) {
                if meeting.notes.isEmpty {
                    Text("Take your own notes here. Click in and hold fn to dictate.")
                        .foregroundStyle(Theme.secondary).padding(14).allowsHitTesting(false)
                }
            }
    }

    private func update(_ change: (inout Meeting) -> Void) {
        var copy = meeting
        change(&copy)
        notetaker.update(copy)
    }
}

private struct ProgressLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(Theme.secondary)
        }
    }
}

/// A short walkthrough of the Notetaker, opened by "Start tutorial".
private struct NotetakerTutorial: View {
    let done: () -> Void

    private let steps: [(icon: String, title: String, text: String)] = [
        ("record.circle", "Start a note", "Click Start Notetaker, press ⌥M anywhere, or use the record button on the bar. Your microphone and the other participants are both recorded."),
        ("calendar", "Or start from your calendar", "Connect your calendar and every meeting today gets a Start note button."),
        ("text.alignleft", "Get summary and tasks", "When you stop, the recording is transcribed and summarized on this Mac. Tasks show up with a checkbox."),
        ("folder", "Keep it organized", "Move notes into folders and search everything under Past notes."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How Notetaker works").font(.system(size: 22, design: .serif))
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: step.icon).font(.system(size: 18)).frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title).font(.system(size: 15, weight: .medium))
                        Text(step.text).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Got it", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 460)
    }
}

/// The transcript per speaker: the speakers as chips that can be renamed, then every turn with
/// its time and speaker.
private struct SpeakerTranscript: View {
    let meeting: Meeting
    let rename: (String, String) -> Void
    @State private var editing: String?
    @State private var newName = ""

    private static let palette: [Color] = [Theme.tealDark, Theme.orange, Color(red: 0.42, green: 0.36, blue: 0.75),
                                           Color(red: 0.78, green: 0.33, blue: 0.40), Color(red: 0.25, green: 0.52, blue: 0.80),
                                           Color(red: 0.55, green: 0.55, blue: 0.20)]

    private func color(_ label: String) -> Color {
        let index = meeting.speakers.firstIndex(of: label) ?? 0
        return Self.palette[index % Self.palette.count]
    }

    private func name(_ label: String) -> String { meeting.name(for: label, ownName: NotetakerController.ownName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Theme.sectionLabel("Speakers")
                HStack(spacing: 8) {
                    ForEach(meeting.speakers, id: \.self) { label in
                        Button {
                            newName = meeting.speakerNames[label] ?? ""
                            editing = label
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(color(label)).frame(width: 8, height: 8)
                                Text(name(label)).font(.system(size: 13, weight: .medium))
                                Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Capsule().fill(Theme.card))
                            .overlay(Capsule().strokeBorder(Theme.border))
                        }
                        .buttonStyle(.plain)
                        .help("Rename this speaker")
                        .popover(isPresented: Binding(get: { editing == label }, set: { if !$0 { editing = nil } })) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Who is \(name(label))?").font(.system(size: 13, weight: .medium))
                                TextField("Name", text: $newName)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)
                                    .onSubmit { save(label) }
                                HStack {
                                    Spacer()
                                    Button("Cancel") { editing = nil }
                                    Button("Save") { save(label) }.keyboardShortcut(.defaultAction)
                                }
                            }
                            .padding(14)
                        }
                    }
                }
                Text("Your microphone is you; the others are told apart by their voices. Rename a speaker once and the summary uses the name.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(meeting.segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Self.time(segment.start))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(name(segment.speaker)).font(.system(size: 13, weight: .semibold)).foregroundStyle(color(segment.speaker))
                                if segment.language == "en" && meeting.segments.contains(where: { $0.language != "en" }) {
                                    Text("EN").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                                        .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(Theme.card))
                                }
                            }
                            Text(segment.text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func save(_ label: String) {
        rename(label, newName)
        editing = nil
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A small level meter for one recording track.
private struct LevelMeter: View {
    let title: String
    let level: Float

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.card).frame(width: 46, height: 6)
                Capsule().fill(Theme.teal).frame(width: max(2, 46 * CGFloat(min(1, level))), height: 6)
            }
            .animation(.linear(duration: 0.1), value: level)
        }
        .help("\(title): how loud this track records right now")
    }
}

/// The meeting notes, laid out like the vault note: numbered headings, open tasks and points,
/// each with the time it was said.
private struct NotesMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        if line.hasPrefix("### ") {
            Text(line.dropFirst(4)).font(.system(size: 16, weight: .semibold)).padding(.top, 10)
        } else if line.hasPrefix("- [ ] ") {
            point(String(line.dropFirst(6)), icon: "circle")
        } else if line.hasPrefix("- ") {
            point(String(line.dropFirst(2)), icon: nil)
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(line).font(.system(size: 14))
        }
    }

    private func point(_ text: String, icon: String?) -> some View {
        let (body, time) = Self.split(text)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            } else {
                Text("•").foregroundStyle(Theme.secondary)
            }
            (Text(body) + Text(time.isEmpty ? "" : "  \(time)").foregroundColor(Theme.secondary).font(.system(size: 12)))
                .font(.system(size: 14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Splits "text. [12:40]" into the text and the time.
    static func split(_ text: String) -> (String, String) {
        guard text.hasSuffix("]"), let open = text.lastIndex(of: "[") else { return (text, "") }
        return (String(text[..<open]).trimmingCharacters(in: .whitespaces), String(text[open...]))
    }
}
