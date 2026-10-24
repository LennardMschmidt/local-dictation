import AppKit
import DictationCore
import SwiftUI

/// Moves action items into a Polarion backlog on the server of Settings › Connectors, written with the polarion-requirements skill:
/// choose the project and the kind, let Claude Code draft the items (it may only read), answer
/// its questions, check and edit the drafts, and only then create them.
struct PolarionTransferSheet: View {
    let meeting: Meeting
    let items: [String]
    let settings: DictationSettings
    /// Drafts to show at once in the review, for the snapshots.
    let preview: [PolarionBacklog.Draft]?
    let done: ([String: String]) -> Void

    init(meeting: Meeting, items: [String], settings: DictationSettings, preview: [PolarionBacklog.Draft]? = nil,
         done: @escaping ([String: String]) -> Void) {
        self.meeting = meeting
        self.items = items
        self.settings = settings
        self.preview = preview
        self.done = done
        _phase = State(initialValue: preview == nil ? .setup : .review)
        _drafts = State(initialValue: preview ?? [])
    }

    enum Phase: Equatable {
        case setup, drafting, questions([String]), review, creating, result(PolarionBacklog.Created), failed(String)

        /// The phases with little content, where the window shrinks to fit.
        var isCompact: Bool {
            switch self {
            case .result, .failed: return true
            default: return false
            }
        }
    }

    @AppStorage("polarionBacklogProject") private var project = ""
    @State private var projects: [PolarionBacklog.Project] = []
    @State private var query = ""
    @State private var loadingProjects = false
    @State private var projectProblem: String?
    @State private var confirming = false
    @State private var kind = PolarionBacklog.Kind.automatic
    @State private var context = ""
    @State private var phase: Phase
    @State private var drafts: [PolarionBacklog.Draft]
    @State private var answers: [String: String] = [:]
    @State private var asked: [(question: String, answer: String)] = []
    @State private var started = Date()
    /// The descriptions as editable text, per draft key; written back as HTML only when changed.
    @State private var texts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("In Polarion übertragen").font(.system(size: 22, design: .serif))
            switch phase {
            case .setup:
                // The fields scroll when the window is low; title and buttons stay in view.
                ScrollView { setup.padding(.trailing, 6) }
                setupButtons
            case .drafting: working("Claude schreibt Entwürfe mit polarion-requirements und liest dafür die SIM-Vorgaben, das Schema und die Beispiele im Backlog. Das dauert einige Minuten. In Polarion wird dabei nichts angelegt: Du prüfst und bearbeitest die Entwürfe im nächsten Schritt und legst sie erst dann mit „Erstellen“ an.")
            case .questions(let questions): questionsView(questions)
            case .review: review
            case .creating: working("Lege die Items in Polarion an und prüfe sie …")
            case .result(let created): resultView(created)
            case .failed(let message):
                Text(message).font(.system(size: 13)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Zurück") { phase = drafts.isEmpty ? .setup : .review }.buttonStyle(SheetButtonStyle()) }
            }
        }
        .padding(24)
        .frame(width: 720)
        // Tall enough for the project list or a draft with its fields without resizing; the
        // result and the failure message keep only the height they need.
        .frame(minHeight: phase.isCompact ? nil : 700)
        .task {
            if preview != nil { return }
            await loadProjects(force: false)
        }
        .alert("\(drafts.count) \(drafts.count == 1 ? "Item" : "Items") in \(selectedProject.map { "\($0.name) (\($0.id))" } ?? project) anlegen?",
               isPresented: $confirming) {
            Button("Abbrechen", role: .cancel) {}
            Button("Anlegen") { create() }
        } message: {
            Text(drafts.enumerated().map { "\($0.offset + 1). \($0.element.type): \($0.element.title)" }.joined(separator: "\n")
                 + "\n\nAuf \(connection.host), im Status Draft.")
        }
    }

    /// The connection from Settings › Connectors; Claude Code's polarion-openapi when the own
    /// one is incomplete, with the reason shown.
    private var connection: PolarionBacklog.Connection {
        (try? Connectors.polarion(settings.connectors)) ?? PolarionBacklog.Connection(
            server: Connectors.claudeCodePolarionServer ?? PolarionBacklog.Connection.claudeCode.server, serverName: "polarion-openapi")
    }

    private var connectionProblem: String? {
        do { _ = try Connectors.polarion(settings.connectors); return nil } catch { return "\(error)" }
    }

    private var selectedProject: PolarionBacklog.Project? {
        projects.first { $0.id == project }
    }

    /// The cached project list, one per server.
    private var cacheFile: URL {
        AppPaths.supportDirectory.appendingPathComponent("polarion-projects-\(connection.host).json")
    }

    /// The project list of the server, from a cache of at most one day or read anew.
    private func loadProjects(force: Bool) async {
        if !force, let data = try? Data(contentsOf: cacheFile),
           let attributes = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 86_400,
           let cached = try? JSONDecoder().decode([PolarionBacklog.Project].self, from: data), !cached.isEmpty {
            projects = cached.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return
        }
        loadingProjects = true
        projectProblem = nil
        if let connectionProblem {
            projectProblem = connectionProblem
            loadingProjects = false
            return
        }
        let connection = connection
        guard let agent = await AgentFactory.make(settings, tools: [connection.projectsTool], model: .haiku, timeout: 180,
                                                  mcpConfig: connection.mcpConfig) else {
            projectProblem = "Weder Claude Code noch Codex wurde gefunden."
            loadingProjects = false
            return
        }
        do {
            let list = try await PolarionBacklog.projects(agent: agent, connection: connection)
            projects = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            try? JSONEncoder().encode(list).write(to: cacheFile)
            AppLog.info("polarion projects loaded: \(list.count)")
        } catch {
            projectProblem = "Die Projektliste von \(connection.host) konnte nicht geladen werden: \(error)"
        }
        loadingProjects = false
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Theme.sectionLabel("Backlog-Projekt auf \(connection.host)")
                    Spacer()
                    Button(loadingProjects ? "Lade …" : "Liste neu laden") { Task { await loadProjects(force: true) } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary).disabled(loadingProjects)
                }
                TextField("Projekt suchen, z. B. „mdx back“ oder „woodgrove“", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(PolarionBacklog.search(query, in: projects).prefix(60)) { candidate in
                            Button { project = candidate.id } label: {
                                HStack {
                                    Text(candidate.name).font(.system(size: 13, weight: project == candidate.id ? .semibold : .regular))
                                    Text(candidate.id).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                    Spacer()
                                    if project == candidate.id { Image(systemName: "checkmark").foregroundStyle(Theme.tealDark) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .background(project == candidate.id ? Theme.selection : .clear)
                            }
                            .buttonStyle(.plain)
                        }
                        if loadingProjects && projects.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Lade die Projekte von \(connection.host) …").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 50)
                        }
                        if let projectProblem {
                            Text(projectProblem).font(.system(size: 12)).foregroundStyle(.orange).padding(10)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                if let chosen = selectedProject {
                    Text("Gewählt: \(chosen.name) (\(chosen.id))").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Theme.sectionLabel("Als")
                Picker("", selection: $kind) {
                    ForEach(PolarionBacklog.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Theme.sectionLabel(items.count == 1 ? "Aufgabe" : "Aufgaben")
                ForEach(items, id: \.self) { item in
                    Text("• \(item)").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Theme.sectionLabel("Zusätzlicher Kontext (optional)")
                TextField("Was Claude wissen sollte: Kunde, Umgebung, gefunden in UAT …", text: $context, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
            }
            Text("Claude liest in Polarion nur und schreibt nichts, bevor du die Entwürfe freigegeben hast. Angelegt wird im Status Draft.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }

    private var setupButtons: some View {
        HStack {
            Button("Abbrechen") { done([:]) }.buttonStyle(SheetButtonStyle())
            Spacer()
            Button("Entwürfe erstellen") { draft() }
                .buttonStyle(SheetButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(selectedProject == nil)
        }
    }

    private func working(_ text: String) -> some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Text("\(Int(context.date.timeIntervalSince(started))) s").font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.vertical, 20)
        }
    }

    private func questionsView(_ questions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude braucht noch ein paar Angaben:").font(.system(size: 14, weight: .medium))
            ForEach(questions, id: \.self) { question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    TextField("Antwort", text: Binding(get: { answers[question] ?? "" }, set: { answers[question] = $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                }
            }
            HStack {
                Button("Abbrechen") { done([:]) }.buttonStyle(SheetButtonStyle())
                Spacer()
                Button("Weiter") {
                    asked += questions.map { ($0, answers[$0] ?? "") }
                    draft()
                }
                .buttonStyle(SheetButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(drafts.count) \(drafts.count == 1 ? "Entwurf" : "Entwürfe") für \(project) auf \(connection.host). Noch ist nichts angelegt. Bearbeite die Felder; erst „Erstellen …“ und deine Bestätigung legen die Items an.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($drafts, id: \.key) { $draft in
                        let index = drafts.firstIndex { $0.key == draft.key } ?? 0
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text("#\(index + 1)").font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Button { drafts.removeAll { $0.key == draft.key } } label: {
                                    Image(systemName: "trash").foregroundStyle(Theme.secondary)
                                }
                                .buttonStyle(.plain).help("Diesen Entwurf nicht anlegen")
                            }
                            field("Typ") {
                                TextField("Typ-ID", text: $draft.type).textFieldStyle(.roundedBorder).frame(width: 240)
                            }
                            field("Titel") {
                                TextField("Titel", text: $draft.title).textFieldStyle(.roundedBorder)
                            }
                            field("Beschreibung") {
                                TextEditor(text: Binding(get: { texts[draft.key] ?? Self.plain(draft.descriptionHtml) },
                                                         set: { texts[draft.key] = $0 }))
                                    .font(.system(size: 12))
                                    .frame(minHeight: 140)
                                    .padding(4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                            }
                            field("Verlinkt") {
                                Picker("", selection: $draft.implements) {
                                    Text("Kein Link").tag(-1)
                                    ForEach(drafts.indices.filter { $0 != index }, id: \.self) { other in
                                        Text("implements #\(other + 1)").tag(other)
                                    }
                                }
                                .labelsHidden().frame(width: 240)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: .infinity)
            HStack {
                Button("Abbrechen") { done([:]) }.buttonStyle(SheetButtonStyle())
                Button("Neu entwerfen") { draft() }.buttonStyle(SheetButtonStyle())
                Spacer()
                Button("Erstellen …") { confirming = true }
                    .buttonStyle(SheetButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(drafts.isEmpty)
            }
        }
    }

    private func resultView(_ created: PolarionBacklog.Created) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(created.created, id: \.id) { item in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                    Text("\(item.id) · \(item.title)").font(.system(size: 13))
                    Spacer()
                    if let url = connection.link(project: project, id: item.id) {
                        Button("Öffnen") { NSWorkspace.shared.open(url) }.buttonStyle(SheetButtonStyle())
                    }
                }
            }
            ForEach(created.problems, id: \.self) { problem in
                Text(problem).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Fertig") { done(mapping(created)) }.buttonStyle(SheetButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Each action item to the id of the first item created from it.
    private func mapping(_ created: PolarionBacklog.Created) -> [String: String] {
        var result: [String: String] = [:]
        for (index, draft) in drafts.enumerated() where index < created.created.count {
            let source = items.first { $0 == draft.source } ?? (items.count == 1 ? items[0] : draft.source)
            if result[source] == nil, items.contains(source) { result[source] = created.created[index].id }
        }
        return result
    }

    private func draft() {
        started = Date()
        phase = .drafting
        let project = project.trimmingCharacters(in: .whitespaces)
        Task {
            let connection = connection
            guard let agent = await AgentFactory.make(settings, tools: connection.readTools, builtinTools: ["Skill", "Read", "Grep", "Glob"],
                                                      effort: .medium, timeout: 1_200, mcpConfig: connection.mcpConfig) else {
                phase = .failed("Weder Claude Code noch Codex wurde gefunden.")
                return
            }
            do {
                let result = try await PolarionBacklog.draft(items: items, project: project, kind: kind, meetingTitle: meeting.title,
                                                             meetingDate: meeting.date, notes: meeting.notesMarkdown, context: context,
                                                             answers: asked, agent: agent, connection: connection)
                AppLog.info(String(format: "polarion drafts in %.0f s: %d drafts, %d questions", Date().timeIntervalSince(started),
                                   result.drafts.count, result.questions.count))
                if !result.questions.isEmpty && result.drafts.isEmpty {
                    phase = .questions(result.questions)
                } else {
                    drafts = result.drafts
                    phase = .review
                }
            } catch {
                phase = .failed("Die Entwürfe sind nicht zustande gekommen: \(error)")
            }
        }
    }

    private func create() {
        started = Date()
        phase = .creating
        let project = project.trimmingCharacters(in: .whitespaces)
        // Edited descriptions go back as HTML; untouched ones keep Claude's HTML.
        let approved = drafts.map { draft -> PolarionBacklog.Draft in
            var draft = draft
            if let text = texts[draft.key], text != Self.plain(draft.descriptionHtml) {
                draft.descriptionHtml = PolarionBacklog.html(fromText: text)
            }
            return draft
        }
        Task {
            let connection = connection
            guard let agent = await AgentFactory.make(settings, tools: connection.writeTools, effort: .medium, timeout: 1_200,
                                                      mcpConfig: connection.mcpConfig) else {
                phase = .failed("Weder Claude Code noch Codex wurde gefunden.")
                return
            }
            do {
                let created = try await PolarionBacklog.create(approved, project: project, agent: agent, connection: connection)
                AppLog.info("polarion items created: \(created.created.count), problems: \(created.problems.count)")
                phase = .result(created)
            } catch {
                phase = .failed("Anlegen fehlgeschlagen: \(error)")
            }
        }
    }

    /// The description as readable text for the review.
    /// A labelled field of a draft.
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            content()
        }
    }

    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"</p>|</h\d>|</ul>|</ol>"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<br\s*/?>|</li>|</tr>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<li[^>]*>"#, with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
