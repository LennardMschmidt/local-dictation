import AppKit
import DictationCore
import SwiftUI

/// Moves action items from a meeting into awork: choose the project, whether they become tasks,
/// subtasks of an existing task, or subtasks of a new parent task, and who gets each one.
struct AworkTransferSheet: View {
    let meeting: Meeting
    /// The items to transfer; the user can drop some before creating.
    let items: [String]
    /// Sample projects and people instead of awork, for the snapshots.
    let preview: Bool
    let done: ([String: String]) -> Void

    init(meeting: Meeting, items: [String], preview: Bool = false, previewCreated: [String: String] = [:],
         done: @escaping ([String: String]) -> Void) {
        self.meeting = meeting
        self.items = items
        self.preview = preview
        self.done = done
        guard preview else { return }
        let sample = [AworkClient.Project(id: "p1", name: "[NW] Interne Aufgaben", key: "NWI", company: "Northwind Consulting GmbH"),
                      AworkClient.Project(id: "p2", name: "[TS] - Tailspin - Continuous Support FY 27", key: "TSCS", company: "Tailspin Optics GmbH")]
        _loggedIn = State(initialValue: true)
        _projects = State(initialValue: sample)
        _project = State(initialValue: sample.first)
        _users = State(initialValue: [AworkClient.User(id: "u1", firstName: "Jonas", lastName: "Weber")])
        _rows = State(initialValue: items.map { Row(original: $0, name: $0, description: "Aus dem Meeting, mit Kontext.", assignee: "u1", meetingDate: meeting.date) })
        _created = State(initialValue: previewCreated)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case tasks = "Aufgabe"
        case subtasks = "Unteraufgabe von …"
        case parent = "Hauptaufgabe mit Unteraufgaben"
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        let id = UUID()
        let original: String
        var name: String
        var description = ""
        var include = true
        var assignee: String?
        var hasStart = false
        var start = Date()
        var hasDue = false
        var due = Date()
        /// The time budget in hours; nil for none.
        var hours: Double?

        /// A row with the start, due date and budget the item's text names, counted from the
        /// meeting's day ("bis Freitag", "heute Abend", "zwei Stunden").
        init(original: String, name: String, description: String = "", assignee: String? = nil, meetingDate: Date) {
            self.original = original
            self.name = name
            self.description = description
            self.assignee = assignee
            let dates = TaskDates.parse(original, meetingDate: meetingDate)
            if let start = dates.start {
                hasStart = true
                self.start = start
            }
            if let due = dates.due {
                hasDue = true
                self.due = due
            }
            hours = dates.plannedSeconds.map { Double($0) / 3600 }
        }
    }

    @State private var loggedIn = false
    @State private var loading = false
    @State private var error: String?
    @State private var projects: [AworkClient.Project] = []
    @State private var users: [AworkClient.User] = []
    @State private var me: AworkClient.User?
    @State private var query = ""
    @State private var project: AworkClient.Project?
    @State private var mode = Mode.tasks
    @State private var parents: [AworkClient.Task] = []
    @State private var parent: AworkClient.Task?
    @State private var parentName = ""
    @State private var rows: [Row] = []
    @State private var creating = false
    @State private var created: [String: String] = [:]

    private static let lastProjectKey = "aworkLastProject"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("In awork übertragen").font(.system(size: 22, design: .serif))
            if !loggedIn {
                connect
            } else if !created.isEmpty {
                result
            } else {
                // The fields scroll when the window is low; title and buttons stay in view.
                ScrollView { form.padding(.trailing, 6) }
                    .frame(maxHeight: .infinity)
                formButtons
            }
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 660)
        // Tall enough that project list, mode and the tasks are visible without resizing; the
        // short result after creating keeps only the height it needs.
        .frame(minHeight: loggedIn && created.isEmpty ? 700 : nil)
        .task { await start() }
    }

    // MARK: Steps

    private var connect: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LocalDictation meldet sich mit deinem awork-Konto an, über denselben API-Client wie der Bulk Planner. Der Browser öffnet sich für die Anmeldung.")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Abbrechen") { done([:]) }.buttonStyle(SheetButtonStyle())
                Spacer()
                Button {
                    _Concurrency.Task { await login() }
                } label: {
                    Text(loading ? "Warte auf den Browser …" : "Mit awork verbinden")
                }
                .buttonStyle(SheetButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(loading)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Theme.sectionLabel("Projekt")
                TextField("Projekt suchen", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredProjects.prefix(60)) { candidate in
                            Button {
                                project = candidate
                                _Concurrency.Task { await loadParents() }
                            } label: {
                                HStack {
                                    Text(candidate.name).font(.system(size: 13, weight: project == candidate ? .semibold : .regular))
                                    if !candidate.company.isEmpty {
                                        Text(candidate.company).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                    }
                                    Spacer()
                                    if project == candidate { Image(systemName: "checkmark").foregroundStyle(Theme.tealDark) }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .background(project == candidate ? Theme.selection : .clear)
                            }
                            .buttonStyle(.plain)
                        }
                        if loading && projects.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Lade Projekte …").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 56)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            }

            VStack(alignment: .leading, spacing: 6) {
                Theme.sectionLabel("Als")
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases.filter { $0 != .parent || rows.count > 1 }) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if mode == .subtasks {
                    // The open top-level tasks of the chosen project, in one dropdown.
                    Picker("Hauptaufgabe", selection: $parent) {
                        Text(project == nil ? "Erst ein Projekt wählen" : parents.isEmpty ? "Lade Aufgaben …" : "Hauptaufgabe wählen")
                            .tag(AworkClient.Task?.none)
                        ForEach(parents) { task in
                            Text(task.identifier.isEmpty ? task.name : "\(task.identifier) · \(task.name)").tag(AworkClient.Task?.some(task))
                        }
                    }
                    .disabled(project == nil || parents.isEmpty)
                }
                if mode == .parent {
                    TextField("Name der Hauptaufgabe", text: $parentName).textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Theme.sectionLabel(rows.count == 1 ? "Aufgabe" : "Aufgaben")
                ForEach($rows) { $row in
                    // One card per task: title, description, who does it and by when.
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: $row.include).labelsHidden().toggleStyle(.checkbox).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Titel", text: $row.name).textFieldStyle(.roundedBorder)
                            TextField("Beschreibung", text: $row.description, axis: .vertical)
                                .textFieldStyle(.roundedBorder).lineLimit(2...6).font(.system(size: 12))
                            HStack(spacing: 10) {
                                Picker("Zuständig", selection: $row.assignee) {
                                    Text("Niemand").tag(String?.none)
                                    ForEach(users) { user in Text(user.name).tag(String?.some(user.id)) }
                                }
                                .frame(width: 230)
                                Text("Budget")
                                TextField("–", value: $row.hours, format: .number.precision(.fractionLength(0...2)))
                                    .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
                                Text("h").foregroundStyle(.secondary)
                                Spacer()
                            }
                            .font(.system(size: 12))
                            // When it is worked on: from, to. Filled in from the item when it names a day.
                            HStack(spacing: 10) {
                                Toggle("Start", isOn: $row.hasStart).toggleStyle(.checkbox)
                                if row.hasStart {
                                    DatePicker("", selection: $row.start, displayedComponents: .date).labelsHidden()
                                }
                                Toggle("Fällig", isOn: $row.hasDue).toggleStyle(.checkbox)
                                if row.hasDue {
                                    DatePicker("", selection: $row.due, displayedComponents: .date).labelsHidden()
                                }
                                Spacer()
                            }
                            .font(.system(size: 12))
                        }
                        .opacity(row.include ? 1 : 0.45)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                }
            }
        }
    }

    private var formButtons: some View {
        HStack {
            Button("Abbrechen") { done([:]) }.buttonStyle(SheetButtonStyle())
            Spacer()
            Button {
                _Concurrency.Task { await create() }
            } label: {
                Text(creating ? "Lege an …" : "In awork anlegen")
            }
            .buttonStyle(SheetButtonStyle(primary: true))
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate || creating)
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(created.sorted(by: { $0.key < $1.key }), id: \.key) { item, link in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                    Text(item).font(.system(size: 13))
                    Spacer()
                    if let url = URL(string: link) {
                        Button("Öffnen") { NSWorkspace.shared.open(url) }.buttonStyle(SheetButtonStyle())
                    }
                }
            }
            HStack {
                Spacer()
                Button("Fertig") { done(created) }.buttonStyle(SheetButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Logic

    private var filteredProjects: [AworkClient.Project] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(trimmed) || $0.company.localizedCaseInsensitiveContains(trimmed) }
    }

    private var canCreate: Bool {
        guard project != nil, rows.contains(where: { $0.include && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        switch mode {
        case .tasks: return true
        case .subtasks: return parent != nil
        case .parent: return !parentName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func start() async {
        parentName = meeting.title
        if preview { return }
        rows = items.map { Row(original: $0, name: $0, meetingDate: meeting.date) }
        loggedIn = await AworkClient.shared.isLoggedIn
        if loggedIn { await loadBasics() }
    }

    private func login() async {
        loading = true
        error = nil
        do {
            try await AworkClient.shared.login()
            loggedIn = true
            NSApp.activate(ignoringOtherApps: true)
            await loadBasics()
        } catch {
            self.error = String(describing: error)
        }
        loading = false
    }

    private func loadBasics() async {
        loading = true
        do {
            async let projectList = AworkClient.shared.projects()
            async let userList = AworkClient.shared.users()
            async let current = AworkClient.shared.me()
            projects = try await projectList
            users = try await userList
            me = try await current
            if let last = UserDefaults.standard.string(forKey: Self.lastProjectKey), let match = projects.first(where: { $0.id == last }) {
                project = match
                await loadParents()
            }
            // Each item goes to the person named as its owner, otherwise to the person recording.
            rows = rows.map { row in
                var row = row
                let owner = row.original.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
                row.assignee = users.first { $0.firstName.lowercased() == owner }?.id ?? me?.id
                return row
            }
        } catch {
            self.error = String(describing: error)
        }
        loading = false
    }

    private func loadParents() async {
        guard let project else { return }
        parent = nil
        parents = (try? await AworkClient.shared.parentCandidates(project: project.id)) ?? []
    }

    private func create() async {
        guard let project else { return }
        creating = true
        error = nil
        UserDefaults.standard.set(project.id, forKey: Self.lastProjectKey)
        let description = "Aus dem Meeting „\(meeting.title)“ vom \(meeting.date.formatted(date: .long, time: .shortened)), übertragen mit LocalDictation."
        do {
            var parentID = parent?.id
            if mode == .parent {
                let head = try await AworkClient.shared.createTask(name: parentName, description: description, project: project.id,
                                                                   parent: nil, due: nil, assignee: me?.id)
                parentID = head.id
                created[parentName] = AworkClient.taskURL(head).absoluteString
            }
            for row in rows where row.include {
                let text = row.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = (text.isEmpty ? "" : text.components(separatedBy: "\n").map { "<p>\(Self.escaped($0))</p>" }.joined()) + "<p><em>\(Self.escaped(description))</em></p>"
                let task = try await AworkClient.shared.createTask(name: row.name, description: body, project: project.id,
                                                                   parent: mode == .tasks ? nil : parentID,
                                                                   start: row.hasStart ? row.start : nil, due: row.hasDue ? row.due : nil,
                                                                   planned: row.hours.map { Int(($0 * 3600).rounded()) }, assignee: row.assignee)
                created[row.original] = AworkClient.taskURL(task).absoluteString
            }
            AppLog.info("\(created.count) awork tasks created in a project")
        } catch {
            self.error = String(describing: error)
        }
        creating = false
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
