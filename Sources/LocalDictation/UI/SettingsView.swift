import AppKit
import DictationCore
import SwiftUI

/// The settings window over the app, laid out like Wispr Flow's: a navigation on the left,
/// the page on the right, dimmed app behind it. Click outside or press Esc to close.
struct SettingsOverlay: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { model.showingSettings = false }
                HStack(spacing: 0) {
                    navigation
                        .frame(width: 250)
                        .background(Theme.card)
                    ScrollView {
                        page
                            .padding(.horizontal, 56)
                            .padding(.vertical, 48)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Theme.panel)
                }
                .overlay(alignment: .topTrailing) {
                    Button { model.showingSettings = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.card))
                    }
                    .buttonStyle(.plain)
                    .help("Close settings  esc")
                    .padding(16)
                }
                .frame(width: min(1180, geometry.size.width - 60), height: min(860, geometry.size.height - 40))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
                .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
                Button("") { model.showingSettings = false }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SETTINGS")
                .font(.system(size: 13, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 30)
                .padding(.bottom, 12)
            ForEach(AppModel.SettingsPage.allCases) { page in
                Button { model.settingsPage = page } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.icon).font(.system(size: 14)).frame(width: 20)
                        Text(page.title).font(.system(size: 14))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 8).fill(model.settingsPage == page ? Theme.selection : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack {
                Text("LocalDictation v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Image(systemName: "lock.shield").foregroundStyle(Theme.secondary).help("Everything runs on this Mac")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var page: some View {
        switch model.settingsPage {
        case .general: GeneralSettings(model: model)
        case .system: SystemSettings(model: model)
        case .notetaker: NotetakerSettings(model: model)
        case .vibeCoding: VibeCodingSettings(model: model)
        case .connectors: ConnectorsSettings(model: model)
        case .mcp: MCPSettings(model: model)
        case .ai: AISettingsPage(model: model)
        }
    }
}

// MARK: - Building blocks

private struct PageTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 24, design: .serif))
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 20)
    }
}

/// A rounded group of rows, separated by lines, like the blocks in Wispr's settings.
private struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 0) {
                _VariadicView.Tree(DividedLayout()) { content }
            }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        }
        .padding(.bottom, 14)
    }
}

/// Puts a divider between the rows of a group.
private struct DividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last { Divider().overlay(Theme.border) }
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// A subtitle with more than text, such as key chips; shown instead of `subtitle`.
    var subtitleView: AnyView?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let subtitleView {
                    subtitleView.foregroundStyle(Theme.secondary)
                } else if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 12)
    }
}

private struct ChangeButton: View {
    var title = "Change"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 150, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.selection))
        }
        .buttonStyle(.plain)
    }
}

private struct KeyChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border))
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @State private var dialog: Dialog?

    enum Dialog: String, Identifiable {
        case shortcuts, microphone, languages
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "General")
            SettingsGroup {
                SettingsRow(title: "Shortcuts", subtitleView: AnyView(
                    HStack(spacing: 3) {
                        Text("Hold")
                        KeyChip(label: "fn")
                        Text("and speak.")
                        Button("Learn more →") {
                            model.showingSettings = false
                            model.section = .help
                        }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.text)
                    }
                    .font(.system(size: 12)))) {
                    ChangeButton { dialog = .shortcuts }
                }
                SettingsRow(title: "Microphone", subtitle: microphoneName) {
                    ChangeButton { dialog = .microphone }
                }
                SettingsRow(title: "My languages", subtitle: languagesText) {
                    ChangeButton { dialog = .languages }
                }
                SettingsRow(title: "Theme") {
                    SelectBox(options: AppearanceMode.allCases.map { ($0, $0.title, $0.icon) },
                              selection: Binding(get: { model.appearanceMode }, set: { model.appearanceMode = $0 }),
                              width: 150, height: 30, fontSize: 13)
                }
            }
        }
        .sheet(item: $dialog) { dialog in
            switch dialog {
            case .shortcuts: ShortcutsDialog { self.dialog = nil }
            case .microphone: MicrophoneDialog(model: model) { self.dialog = nil }
            case .languages: LanguagesDialog(model: model) { self.dialog = nil }
            }
        }
    }

    private var microphoneName: String {
        if !model.settings.microphoneUID.isEmpty, let device = AudioDevices.device(uid: model.settings.microphoneUID) {
            return device.name
        }
        let name = AudioDevices.resolve(uid: "")?.name ?? "No microphone"
        return "Auto-detect (\(name))"
    }

    private var languagesText: String {
        let names = model.settings.languages.map(LanguagesDialog.name(for:))
        return names.isEmpty ? "No languages selected" : names.joined(separator: " · ")
    }
}

private struct DialogFrame<Content: View>: View {
    let title: String
    let subtitle: String
    let done: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 20, design: .serif))
                Text(subtitle).foregroundStyle(Theme.secondary)
            }
            content
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(19)
        .frame(width: 395)
        .background(Theme.panel)
    }
}

private struct ShortcutsDialog: View {
    let done: () -> Void

    private let shortcuts: [(title: String, description: String, keys: [String])] = [
        ("Push to talk", "Hold to say something short", ["fn"]),
        ("Hands-free mode", "Press while holding fn to keep dictating; fn again stops", ["fn", "space"]),
        ("Command Mode", "Select text and say what should happen to it", ["ctrl", "fn"]),
        ("Cancel", "Dismiss the dictation", ["esc"]),
        ("Transform", "Apply your transforms to the selection or the last dictation", ["⌥", "1–9"]),
        ("Transform view changes", "Opens a window with the changes of the last transform", ["⌥", "O"]),
        ("Paste last transcript", "Paste the last thing you dictated", ["⌥", "⇧", "V"]),
        ("Copy last transcript", "Copy the last thing you dictated", ["⌥", "⇧", "C"]),
        ("Open Scratchpad", "Open the scratchpad", ["⌥", "⇧", "S"]),
        ("Join meeting / start Notetaker", "Open the Notetaker and start recording", ["⌥", "M"]),
    ]

    var body: some View {
        DialogFrame(title: "Shortcuts", subtitle: "Your shortcuts for using LocalDictation. They are fixed in this version.", done: done) {
            VStack(spacing: 0) {
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, shortcut in
                    if index > 0 { Divider().overlay(Theme.border) }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.title).font(.system(size: 14, weight: .medium))
                            Text(shortcut.description).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        HStack(spacing: 3) { ForEach(shortcut.keys, id: \.self) { KeyChip(label: $0) } }
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        }
    }
}

private struct MicrophoneDialog: View {
    @ObservedObject var model: AppModel
    let done: () -> Void
    @State private var devices: [AudioDevices.Device] = []

    var body: some View {
        DialogFrame(title: "Microphone", subtitle: "Used for dictation and the Notetaker.", done: done) {
            VStack(spacing: 0) {
                row(uid: "", title: "Auto-detect",
                    detail: "The system microphone. Dictation takes the built-in one while Bluetooth headphones are connected, so your music keeps playing; the Notetaker takes the headphones, which hear you best in a call. Now: dictation \(AudioDevices.resolve(uid: "")?.name ?? "none"), Notetaker \(AudioDevices.resolve(uid: "", avoidBluetooth: false)?.name ?? "none")")
                ForEach(devices) { device in
                    Divider().overlay(Theme.border)
                    row(uid: device.uid, title: device.name, detail: device.isBuiltIn ? "Built-in mic (recommended)"
                        : device.isBluetooth ? "Switches the headphones to headset mode while recording: music pauses briefly and its volume changes" : nil)
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        }
        .onAppear { devices = AudioDevices.inputs() }
    }

    private func row(uid: String, title: String, detail: String?) -> some View {
        Button { model.settings.microphoneUID = uid } label: {
            HStack {
                Image(systemName: model.settings.microphoneUID == uid ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(model.settings.microphoneUID == uid ? Theme.tealDark : Theme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary) }
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LanguagesDialog: View {
    @ObservedObject var model: AppModel
    let done: () -> Void

    static let available = ["de", "en", "fr", "es", "it", "nl", "pl", "pt", "sv", "da", "tr", "cs"]

    static func name(for code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    var body: some View {
        DialogFrame(title: "My languages", subtitle: "Select the languages you speak for better accuracy. With one language, recognition is fixed to it.", done: done) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(Self.available, id: \.self) { code in
                    let selected = model.settings.languages.contains(code)
                    Button {
                        if selected { model.settings.languages.removeAll { $0 == code } } else { model.settings.languages.append(code) }
                    } label: {
                        HStack {
                            Image(systemName: selected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected ? Theme.tealDark : Theme.secondary)
                            Text(Self.name(for: code))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.card))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - System

/// Claude Code status and the engine per task.
struct ClaudeSettings: View {
    @ObservedObject var model: AppModel
    @State private var testResult: String?
    @State private var testing = false

    private var path: String? { ClaudeCLI.locate(custom: model.settings.ai.claudePath) }
    private var codexPath: String? { CodexCLI.locate(custom: model.settings.ai.codexPath) }
    @State private var codexResult: String?
    @State private var codexTesting = false

    var body: some View {
        SettingsGroup(title: "Claude") {
            SettingsRow(title: "Claude Code",
                        subtitle: path.map { "Found at \($0). Uses the Claude subscription Claude Code is logged in with." }
                            ?? "Not found. Install Claude Code and log in once with \"claude\" in Terminal, or enter its path.") {
                HStack(spacing: 10) {
                    if let testResult {
                        Text(testResult).font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(2)
                            .frame(maxWidth: 220, alignment: .trailing)
                    }
                    ChangeButton(title: testing ? "Testing…" : "Test") { test() }
                        .disabled(path == nil || testing)
                }
            }
            SettingsRow(title: "Path", subtitle: "Leave empty to search the usual install locations") {
                TextField("/opt/homebrew/bin/claude", text: $model.settings.ai.claudePath)
                    .textFieldStyle(.roundedBorder).frame(width: 170)
            }
            SettingsRow(title: "What Claude receives",
                        subtitle: "Only the text of the tasks set to Claude below, sent to Anthropic. Claude gets no tools, no files and keeps no session. If Claude does not answer, the local model takes over.") {
                EmptyView()
            }
        }

        SettingsGroup(title: "Codex") {
            SettingsRow(title: "Codex CLI",
                        subtitle: codexPath.map { "Found at \($0). Uses the ChatGPT or OpenAI account Codex is logged in with." }
                            ?? "Not found. Install the Codex CLI and log in once with \"codex login\" in Terminal, or enter its path.") {
                HStack(spacing: 10) {
                    if let codexResult {
                        Text(codexResult).font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(2)
                            .frame(maxWidth: 220, alignment: .trailing)
                    }
                    ChangeButton(title: codexTesting ? "Testing…" : "Test") { testCodex() }
                        .disabled(codexPath == nil || codexTesting)
                }
            }
            SettingsRow(title: "Path", subtitle: "Leave empty to search the usual install locations") {
                TextField("/opt/homebrew/bin/codex", text: $model.settings.ai.codexPath)
                    .textFieldStyle(.roundedBorder).frame(width: 170)
            }
            SettingsRow(title: "What Codex receives",
                        subtitle: "Only the text of the tasks set to Codex below, sent to OpenAI. Codex runs without your Codex configuration, in a read-only sandbox in an empty folder, and keeps no session. If Codex does not answer, the local model takes over.") {
                EmptyView()
            }
        }

        SettingsGroup(title: "AI per task") {
            ForEach(AITask.allCases, id: \.self) { task in
                TaskEngineRow(task: task, choice: $model.settings.ai[task], claudeAvailable: path != nil, codexAvailable: codexPath != nil)
            }
            SettingsRow(title: "Recommended setup",
                        subtitle: "Cleanup stays local because it runs after every dictation; transforms and meeting notes use Claude Sonnet.") {
                ChangeButton(title: "Use recommended") {
                    for task in AITask.allCases { model.settings.ai[task] = task.recommended }
                }
            }
        }
    }

    private func testCodex() {
        guard let codexPath else { return }
        codexTesting = true
        codexResult = nil
        let codex = CodexCLI(path: codexPath, effort: .low, timeout: 90)
        let started = Date()
        Task {
            let result: String
            do {
                let text = try await codex.transform("das meeting ist um drei", instruction: "Rewrite formally.")
                result = String(format: "Answered in %.1f s: %@", Date().timeIntervalSince(started), text)
            } catch {
                result = "No answer: \(error). Is Codex logged in?"
            }
            await MainActor.run {
                codexResult = result
                codexTesting = false
            }
        }
    }

    private func test() {
        guard let path else { return }
        testing = true
        testResult = nil
        let claude = ClaudeCLI(path: path, model: .sonnet, effort: .low, timeout: 60)
        let started = Date()
        Task {
            let result: String
            do {
                let text = try await claude.transform("das meeting ist um drei", instruction: "Rewrite formally.")
                result = String(format: "Answered in %.1f s: %@", Date().timeIntervalSince(started), text)
            } catch {
                result = "No answer: \(error)"
            }
            await MainActor.run {
                testResult = result
                testing = false
            }
        }
    }
}

private struct TaskEngineRow: View {
    let task: AITask
    @Binding var choice: AIChoice
    let claudeAvailable: Bool
    let codexAvailable: Bool

    private var subtitle: String {
        let recommended = "Recommended: \(task.recommended.summary)."
        switch task {
        case .cleanup: return "After every dictation. Claude or Codex adds several seconds each time. \(recommended)"
        case .transforms: return "⌥1 to ⌥9, the Transform button, auto apply and ctrl + fn. \(recommended)"
        case .meetings: return "Title, summary and action items after a meeting. \(recommended)"
        }
    }

    var body: some View {
        SettingsRow(title: task.title, subtitle: subtitle) {
            VStack(alignment: .trailing, spacing: 8) {
                SelectBox(options: [(AIEngine.local, "Local model", "desktopcomputer")]
                              + (claudeAvailable || choice.engine == .claude ? [(AIEngine.claude, "Claude", "sparkle")] : [])
                              + (codexAvailable || choice.engine == .codex ? [(AIEngine.codex, "Codex", "chevron.left.forwardslash.chevron.right")] : []),
                          selection: $choice.engine, width: 150, height: 30, fontSize: 13)
                    .disabled(!claudeAvailable && !codexAvailable && choice.engine == .local)
                if choice.engine == .codex {
                    TextField("Model (Codex default)", text: $choice.codexModel)
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                    SelectBox(options: ClaudeEffort.allCases.filter { $0 != .max }.map { ($0, "\($0.title) effort", nil) },
                              selection: $choice.effort, width: 150, height: 30, fontSize: 13)
                }
                if choice.engine == .claude {
                    SelectBox(options: ClaudeModel.allCases.map { ($0, $0.title, nil) }, selection: $choice.model,
                              width: 150, height: 30, fontSize: 13)
                    SelectBox(options: ClaudeEffort.allCases.map { ($0, "\($0.title) effort", nil) }, selection: $choice.effort,
                              width: 150, height: 30, fontSize: 13)
                }
            }
        }
    }
}

private struct SystemSettings: View {
    @ObservedObject var model: AppModel
    @State private var confirmDeleteHistory = false
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "System")

            SettingsGroup(title: "App settings") {
                SettingsRow(title: "Launch app at login") {
                    Toggle("", isOn: Binding(get: { model.startsAtLogin }, set: { model.setStartsAtLogin($0) })).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Show the bar", subtitle: "The small bar at the bottom of the screen") {
                    Toggle("", isOn: $model.settings.showIdlePill).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Smart Formatting", subtitle: "Automatically formats your dictation with the local AI model.") {
                    Toggle("", isOn: $model.settings.llm.enabled).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsGroup(title: "AI") {
                SettingsRow(title: "Models, Claude, Codex and the assistant", subtitle: "Which model does what, on this Mac or in the cloud") {
                    ChangeButton(title: "Open") { model.settingsPage = .ai }
                }
            }

            SettingsGroup(title: "Sound") {
                SettingsRow(title: "Dictation and notification sounds") {
                    Toggle("", isOn: $model.settings.playSounds).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Mute all audio while dictating") {
                    Toggle("", isOn: $model.settings.muteAudioWhileDictating).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsGroup(title: "Notetaker") {
                SettingsRow(title: "Make the bar and scratchpad invisible while screen sharing",
                            subtitle: "They won't appear in screenshots or when you share your screen.") {
                    Toggle("", isOn: $model.settings.hideInScreenShare).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsGroup(title: "Notifications") {
                SettingsRow(title: "Milestones", subtitle: "Word-count milestones and streaks") {
                    Toggle("", isOn: $model.settings.notifyMilestones).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Suggestions", subtitle: "Tips about getting set up or improving how you use LocalDictation") {
                    Toggle("", isOn: $model.settings.notifySuggestions).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsGroup(title: "Extras") {
                SettingsRow(title: "Email auto signature",
                            subtitle: model.settings.emailSignatureEnabled ? "Add the following signature when dictating an email" : "Add a signature when dictating an email") {
                    Toggle("", isOn: $model.settings.emailSignatureEnabled).labelsHidden().toggleStyle(.switch)
                }
                if model.settings.emailSignatureEnabled {
                    TextEditor(text: $model.settings.emailSignature)
                        .font(.system(size: 14))
                        .frame(height: 51)
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel))
                        .padding(.vertical, 8)
                }
            }

            SettingsGroup(title: "Permissions") {
                ForEach(Permission.allCases, id: \.self) { permission in
                    SettingsRow(title: permission.title, subtitle: permission.purpose) {
                        if model.permissions[permission] == true {
                            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                        } else {
                            ChangeButton(title: "Grant") { permission.request() }
                        }
                    }
                }
            }

            SettingsGroup(title: "Data") {
                SettingsRow(title: "Data folder", subtitle: "History, settings, meetings and the log, all on this Mac") {
                    ChangeButton(title: "Open") { NSWorkspace.shared.open(AppPaths.supportDirectory) }
                }
                SettingsRow(title: "Delete history", subtitle: "Removes all dictations from the history and the insights") {
                    ChangeButton(title: "Delete") { confirmDeleteHistory = true }
                }
                SettingsRow(title: "Reset settings", subtitle: "Restores all settings to their defaults. History and meetings stay.") {
                    ChangeButton(title: "Reset") { confirmReset = true }
                }
            }
        }
        .confirmationDialog("Delete the dictation history?", isPresented: $confirmDeleteHistory) {
            Button("Delete history", role: .destructive) { model.deleteHistory() }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset settings", role: .destructive) { model.settings = DictationSettings() }
        }
    }
}

// MARK: - Notetaker, Vibe coding, empty pages

private struct NotetakerSettings: View {
    @ObservedObject var model: AppModel
    @State private var screenRecording = ScreenRecordingPermission.isGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Notetaker", subtitle: "Records your microphone and the meeting audio, then writes the transcript, summary and action items on this Mac.")
            SettingsGroup {
                SettingsRow(title: "Meeting audio",
                            subtitle: screenRecording ? "Other participants are recorded through the system audio." : "Needs the Screen Recording permission. Without it only your microphone is recorded.") {
                    if screenRecording {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                    } else {
                        ChangeButton(title: "Grant") { ScreenRecordingPermission.request() }
                    }
                }
                SettingsRow(title: "Maximum length", subtitle: "Notetaker stops automatically at this length") {
                    SelectBox(options: [30, 60, 90, 120, 180, 240].map {
                        ($0, $0 < 60 ? "\($0) minutes" : "\($0 / 60)\($0 % 60 == 0 ? "" : ".5") hours", nil)
                    }, selection: $model.settings.notetakerMaxMinutes)
                }
                SettingsRow(title: "Briefing before meetings", subtitle: "A card with the earlier meetings, open action items and awork tasks of the people you meet") {
                    SelectBox(options: [0, 2, 5, 10, 15].map { ($0, $0 == 0 ? "Off" : "\($0) min before", nil) },
                              selection: $model.settings.briefingMinutes)
                }
                SettingsRow(title: "Shortcut", subtitle: "Join meeting / start Notetaker") {
                    HStack(spacing: 3) { KeyChip(label: "⌥"); KeyChip(label: "M") }
                }
                SettingsRow(title: "Open Notetaker", subtitle: "See your meetings and start a recording") {
                    ChangeButton(title: "Open") {
                        model.showingSettings = false
                        model.section = .notetaker
                    }
                }
            }
            if let calendar = model.calendar { CalendarSettings(model: model, calendar: calendar) }
        }
        .onAppear { screenRecording = ScreenRecordingPermission.isGranted }
    }
}

/// Which calendars the Notetaker reads meetings, titles and participants from. macOS Calendar
/// holds every account added in System Settings › Internet Accounts; an Outlook or Microsoft
/// 365 calendar appears here once its account is added there as "Microsoft Exchange".
private struct CalendarSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calendar: CalendarService

    @State private var signInCode: GraphCalendar.DeviceCode?
    @State private var signInError: String?

    var body: some View {
        SettingsGroup(title: "Calendars") {
            SettingsRow(title: "Microsoft 365", subtitle: microsoftNote) {
                ChangeButton(title: calendar.microsoftConnected ? "Disconnect" : (signInCode == nil ? "Connect" : "Open page again")) {
                    if calendar.microsoftConnected {
                        calendar.disconnectMicrosoft()
                    } else if let code = signInCode {
                        NSWorkspace.shared.open(code.verificationURL)
                    } else {
                        connectMicrosoft()
                    }
                }
            }
            if !calendar.authorized {
                SettingsRow(title: "Calendar access", subtitle: "Meeting titles and participants come from your calendar.") {
                    ChangeButton(title: "Connect") { calendar.connect() }
                }
            } else {
                ForEach(accounts, id: \.self) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(account.isEmpty ? "On this Mac" : account).font(.system(size: 13, weight: .semibold))
                        ForEach(calendar.calendars.filter { $0.account == account }) { item in
                            Toggle(isOn: binding(for: item.id)) {
                                HStack(spacing: 8) {
                                    Circle().fill(Color(cgColor: item.color ?? CGColor(gray: 0.5, alpha: 1))).frame(width: 9, height: 9)
                                    Text(item.title).font(.system(size: 13))
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 18)
                }
                SettingsRow(title: "Outlook calendar",
                            subtitle: hasExchange
                                ? "Connected through your Microsoft Exchange account in System Settings › Internet Accounts. Untick the calendars without meetings, such as holidays and birthdays."
                                : "The new Outlook keeps its calendar to itself. Add your Microsoft 365 account in System Settings › Internet Accounts as Microsoft Exchange, with Calendars switched on; it then shows up here.") {
                    ChangeButton(title: hasExchange ? "Accounts" : "Open") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .onAppear { calendar.refresh() }
    }

    private var microsoftNote: String {
        if let signInCode {
            return "Enter the code \(signInCode.userCode) on the Microsoft page that opened (it is copied) and sign in with your work account."
        }
        if let signInError { return signInError }
        if calendar.microsoftConnected {
            return "Meetings come straight from Outlook, the same as Teams shows them\(calendar.source == "Microsoft 365" ? "" : "; Microsoft cannot be reached right now, the macOS calendar stands in"). Read only."
        }
        return "Reads your meetings straight from Outlook, the same as Teams shows them, with the Teams link to join. Read only; the macOS calendar stays as the fallback."
    }

    private func connectMicrosoft() {
        signInError = nil
        Task {
            do {
                try await calendar.connectMicrosoft { code in
                    signInCode = code
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                    NSWorkspace.shared.open(code.verificationURL)
                }
            } catch {
                signInError = error.localizedDescription
            }
            signInCode = nil
        }
    }

    private var hasExchange: Bool { calendar.calendars.contains { $0.account.localizedCaseInsensitiveContains("exchange") } }

    private var accounts: [String] {
        var seen = Set<String>()
        return calendar.calendars.map(\.account).filter { seen.insert($0).inserted }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { !model.settings.excludedCalendars.contains(id) }, set: { on in
            if on { model.settings.excludedCalendars.removeAll { $0 == id } } else { model.settings.excludedCalendars.append(id) }
            calendar.refresh()
        })
    }
}

/// Where Polarion and awork are reached, with their logins, and the Microsoft 365 calendar.
private struct ConnectorsSettings: View {
    @ObservedObject var model: AppModel
    @State private var token = ""
    @State private var hasToken = Connectors.hasPolarionToken
    @State private var polarionStatus: String?
    @State private var aworkStatus: String?
    @State private var aworkLoggedIn = false
    @State private var testing = false

    private var connectors: Binding<ConnectorSettings> { $model.settings.connectors }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Connectors", subtitle: "Where backlog items and tasks go, and how the app logs in. Logins stay on this Mac in files only you can read, outside the repo.")
            polarion
            awork
            if let calendar = model.calendar { MicrosoftRow(calendar: calendar) }
        }
        .task { aworkLoggedIn = await AworkClient.shared.hasOwnLogin }
    }

    private var polarion: some View {
        SettingsGroup(title: "Polarion") {
            SettingsRow(title: "Connection", subtitle: connectors.wrappedValue.polarionSource == .mcp
                        ? "Claude Code's MCP server polarion-openapi with its own server and PAT. Drafting always runs in Claude Code with the polarion-requirements skill."
                        : "The app starts the Polarion MCP program itself with the server and PAT below, independent of Claude Code's configuration.") {
                SelectBox(options: [(ConnectorSettings.PolarionSource.mcp, "Claude Code MCP", nil), (.own, "Own connection", nil)],
                          selection: connectors.polarionSource, width: 200, height: 30, fontSize: 13)
            }
            if connectors.wrappedValue.polarionSource == .mcp {
                SettingsRow(title: "Server", subtitle: "Set in Claude Code's configuration of polarion-openapi (claude mcp get polarion-openapi).") {
                    Text(Connectors.claudeCodePolarionServer ?? "not found").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
            } else {
                SettingsRow(title: "Server", subtitle: "Address of the Polarion server, without /polarion.") {
                    TextField("https://polarion.example.com", text: connectors.polarionServer).textFieldStyle(.roundedBorder).frame(width: 240)
                }
                SettingsRow(title: "Personal access token", subtitle: hasToken
                            ? "Saved. Paste a new one to replace it."
                            : "Create one in Polarion under My Account › Personal Access Tokens.") {
                    HStack(spacing: 8) {
                        SecureField(hasToken ? "••••••••" : "Paste token", text: $token).textFieldStyle(.roundedBorder).frame(width: 150)
                        Button(token.isEmpty ? "Remove" : "Save") {
                            Connectors.setPolarionToken(token.isEmpty ? nil : token)
                            token = ""
                            hasToken = Connectors.hasPolarionToken
                        }
                        .buttonStyle(SheetButtonStyle(primary: !token.isEmpty))
                        .disabled(token.isEmpty && !hasToken)
                    }
                }
                SettingsRow(title: "MCP program", subtitle: FileManager.default.fileExists(atPath: NSString(string: connectors.wrappedValue.polarionProgram).expandingTildeInPath)
                            ? "Found. The same program Claude Code's polarion-openapi starts."
                            : "Not found: build mcp-openapi-polarion or give its build/index.js.") {
                    TextField("~/path/to/polarion-mcp/build/index.js", text: connectors.polarionProgram).textFieldStyle(.roundedBorder).frame(width: 240)
                }
            }
            SettingsRow(title: "Test", subtitle: polarionStatus ?? "Loads the project list through the chosen connection.") {
                ChangeButton(title: testing ? "Testing …" : "Test") { testPolarion() }.disabled(testing)
            }
        }
    }

    private var awork: some View {
        SettingsGroup(title: "awork") {
            SettingsRow(title: "Connection", subtitle: connectors.wrappedValue.aworkViaMCP
                        ? "Every awork call goes through the awork MCP in Claude Code: no own login, but each step takes several seconds."
                        : "The app's own awork API client: fast, with its own login below.") {
                SelectBox(options: [(false, "Direct API", nil), (true, "awork MCP only", nil)],
                          selection: connectors.aworkViaMCP, width: 200, height: 30, fontSize: 13)
            }
            if !connectors.wrappedValue.aworkViaMCP {
                SettingsRow(title: "Login", subtitle: aworkLoggedIn ? "Logged in." : "Not logged in. The browser opens for the awork login.") {
                    ChangeButton(title: aworkLoggedIn ? "Log out" : "Log in") {
                        _Concurrency.Task {
                            if aworkLoggedIn {
                                await AworkClient.shared.logout()
                            } else {
                                do { try await AworkClient.shared.login() } catch { aworkStatus = "\(error)" }
                            }
                            aworkLoggedIn = await AworkClient.shared.hasOwnLogin
                        }
                    }
                }
            }
            SettingsRow(title: "Test", subtitle: aworkStatus ?? "Loads the open projects through the chosen connection.") {
                ChangeButton(title: testing ? "Testing …" : "Test") { testAwork() }.disabled(testing)
            }
        }
    }

    private func testPolarion() {
        testing = true
        polarionStatus = "Loading the projects …"
        let settings = model.settings
        _Concurrency.Task {
            defer { testing = false }
            do {
                let connection = try Connectors.polarion(settings.connectors)
                guard let agent = await AgentFactory.make(settings, tools: [connection.projectsTool], model: .haiku, timeout: 180,
                                                          mcpConfig: connection.mcpConfig) else {
                    polarionStatus = "Claude Code was not found."
                    return
                }
                let started = Date()
                let projects = try await PolarionBacklog.projects(agent: agent, connection: connection)
                polarionStatus = String(format: "Connected to %@: %d projects in %.0f s.", connection.host, projects.count, Date().timeIntervalSince(started))
            } catch {
                polarionStatus = "Failed: \(error)"
            }
        }
    }

    private func testAwork() {
        testing = true
        aworkStatus = "Loading the projects …"
        let settings = model.settings
        _Concurrency.Task {
            defer { testing = false }
            await Connectors.applyAwork(settings)
            let started = Date()
            do {
                let projects = try await AworkClient.shared.projects()
                let via = await AworkClient.shared.usesMCP ? "awork MCP" : "direct API"
                aworkStatus = String(format: "Connected through the %@: %d open projects in %.1f s.", via, projects.count, Date().timeIntervalSince(started))
            } catch {
                aworkStatus = "Failed: \(error)"
            }
        }
    }
}

/// The Microsoft 365 calendar's state, managed on the Notetaker page.
private struct MicrosoftRow: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        SettingsGroup(title: "Microsoft 365") {
            SettingsRow(title: "Calendar", subtitle: calendar.microsoftConnected
                        ? "Connected: meetings come straight from Outlook. Change it under Notetaker › Calendars."
                        : "Not connected. Connect it under Notetaker › Calendars.") {
                Text(calendar.microsoftConnected ? "Connected" : "Not connected").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// Everything about the models in one place: the local model in LM Studio, Claude Code and
/// Codex, which of them does which task, and the assistant behind ⌥ + fn with its places.
private struct AISettingsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "AI", subtitle: "The local model runs on this Mac. Claude and Codex use the account their command line is logged in with; only the text of the tasks you give them leaves the Mac.")
            SettingsGroup(title: "Speech recognition") {
                SettingsRow(title: "Dictation engine",
                            subtitle: "Whisper takes your dictionary as a hint while listening. Parakeet Ultra (NVIDIA) is 6 to 20 times faster and more accurate on ordinary speech, but hears dictionary terms where none were said a little more often. Meetings always use Whisper.") {
                    SelectBox(options: [("whisper", "Whisper", nil), ("parakeet", "Parakeet Ultra", nil)],
                              selection: $model.settings.asr.dictationEngine, width: 150, height: 30, fontSize: 13)
                }
            }
            SettingsGroup(title: "Local model") {
                SettingsRow(title: "Which local model", subtitle: appleNote) {
                    SelectBox(options: [("lmstudio", "LM Studio", "shippingbox"), ("apple", "Apple Intelligence", "apple.logo")],
                              selection: $model.settings.llm.provider, width: 170, height: 30, fontSize: 13)
                }
                if !model.settings.llm.usesAppleModel {
                    SettingsRow(title: "Model", subtitle: "The model LM Studio loads") {
                        TextField("", text: $model.settings.llm.model).textFieldStyle(.roundedBorder).frame(width: 170)
                    }
                    SettingsRow(title: "Server") {
                        TextField("", text: $model.settings.llm.baseURL).textFieldStyle(.roundedBorder).frame(width: 170)
                    }
                }
                SettingsRow(title: "Status") {
                    Label(model.llmReady ? (model.settings.llm.usesAppleModel ? "Ready" : "Connected")
                          : (model.settings.llm.usesAppleModel ? AppleModelCleaner.unavailableReason ?? "Not ready, raw text is used" : "Not reachable, raw text is used"),
                          systemImage: model.llmReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.llmReady ? Theme.teal : Theme.orange)
                }
            }
            ClaudeSettings(model: model)
            AssistantSettingsGroup(model: model)
            PlacesSettingsGroup(model: model)
        }
    }

    /// Whether Apple's model can run here, so the choice is made knowingly.
    /// What "Local model" under "AI per task" means, and whether Apple's model can run here.
    private var appleNote: String {
        let meaning = "What \"Local model\" under AI per task means. It also takes over when Claude or Codex fails."
        if let reason = AppleModelCleaner.unavailableReason { return meaning + " Apple Intelligence: \(reason)" }
        return meaning + " Apple Intelligence needs no LM Studio but is weaker on lists and corrections, and its context is small (about 4,000 tokens), so long meetings are better with LM Studio or Claude."
    }
}

/// The assistant behind ⌥ + fn: which engine plans, and what it uses.
private struct AssistantSettingsGroup: View {
    @ObservedObject var model: AppModel

    private var claudeFound: Bool { ClaudeCLI.locate(custom: model.settings.ai.claudePath) != nil }
    private var codexFound: Bool { CodexCLI.locate(custom: model.settings.ai.codexPath) != nil }

    var body: some View {
        SettingsGroup(title: "Assistant (⌥ + fn)") {
            SettingsRow(title: "Plans with", subtitle: engineNote) {
                VStack(alignment: .trailing, spacing: 8) {
                    SelectBox(options: [(AIEngine.claude, "Claude", "sparkle"),
                                        (AIEngine.codex, "Codex", "chevron.left.forwardslash.chevron.right"),
                                        (AIEngine.local, "Local model", "desktopcomputer")],
                              selection: $model.settings.assistant.planner.engine, width: 150, height: 30, fontSize: 13)
                    if model.settings.assistant.planner.engine == .claude {
                        SelectBox(options: ClaudeModel.allCases.map { ($0, $0.title, nil) }, selection: $model.settings.assistant.planner.model,
                                  width: 150, height: 30, fontSize: 13)
                    }
                    if model.settings.assistant.planner.engine == .codex {
                        TextField("Model (Codex default)", text: $model.settings.assistant.planner.codexModel)
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                    }
                    if model.settings.assistant.planner.engine != .local {
                        SelectBox(options: ClaudeEffort.allCases.filter { $0 != .max }.map { ($0, "\($0.title) effort", nil) },
                                  selection: $model.settings.assistant.planner.effort, width: 150, height: 30, fontSize: 13)
                    }
                }
            }
            SettingsRow(title: "Agent with tools", subtitle: "Answers questions with MCP tools, looks up awork changes and writes Polarion items. Both use the servers switched on on the MCP page; the other one takes over when the chosen one is missing.") {
                SelectBox(options: [(AIEngine.claude, "Claude Code", "sparkle"), (AIEngine.codex, "Codex", "chevron.left.forwardslash.chevron.right")],
                          selection: $model.settings.assistant.agentEngine, width: 150, height: 30, fontSize: 13)
            }
            SettingsRow(title: "Browser", subtitle: "For places and web addresses; empty uses the default browser") {
                TextField("Default browser", text: $model.settings.assistant.browser).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            SettingsRow(title: "awork activity type", subtitle: "For time entries when you name none; empty asks each time") {
                TextField("Ask each time", text: $model.settings.assistant.defaultActivity).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            SettingsRow(title: "Tools for questions", subtitle: "Which MCP servers the assistant may use to look things up: \(model.settings.assistant.agentTools.count) tools on") {
                ChangeButton(title: "MCP") { model.settingsPage = .mcp }
            }
        }
    }

    /// Says what happens when the chosen command line is missing on this Mac.
    private var engineNote: String {
        switch model.settings.assistant.planner.engine {
        case .claude where !claudeFound:
            return codexFound ? "Claude Code is not installed here, so Codex plans." : "Neither Claude Code nor Codex is installed here, so the local model plans."
        case .codex where !codexFound:
            return claudeFound ? "Codex is not installed here, so Claude plans." : "Neither Codex nor Claude Code is installed here, so the local model plans."
        case .local:
            return "Plans on this Mac; weaker with longer requests. Questions with MCP tools still need Claude Code."
        default:
            return "Turns what you say into the plan on the card. Questions that need looking up go to the agent with the MCP tools you allowed."
        }
    }
}

/// The places the assistant opens by name.
private struct PlacesSettingsGroup: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsGroup(title: "Places") {
            ForEach($model.settings.places) { $place in
                PlaceRow(place: $place) { model.settings.places.removeAll { $0.id == place.id } }
            }
            SettingsRow(title: "Add a place", subtitle: "Say „öffne <Name>“ or one of its other names with ⌥ + fn") {
                ChangeButton(title: "Add") { model.settings.places.append(Place(name: "", url: "")) }
            }
        }
    }
}

/// One place to edit. The other names are typed as one comma-separated text; the field keeps it
/// as typed (a comma at the end stays) and the names are read from it.
private struct PlaceRow: View {
    @Binding var place: Place
    let remove: () -> Void
    @State private var aliases = ""

    var body: some View {
        HStack(spacing: 10) {
            TextField("Name", text: $place.name).textFieldStyle(.roundedBorder).frame(width: 150)
            TextField("Also called", text: $aliases)
                .textFieldStyle(.roundedBorder).frame(width: 170)
                .onChange(of: aliases) { _, text in
                    let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if names != place.aliases { place.aliases = names }
                }
            TextField("https://", text: $place.url).textFieldStyle(.roundedBorder)
            Button(action: remove) {
                Image(systemName: "trash").foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.vertical, 10)
        .onAppear { aliases = place.aliases.joined(separator: ", ") }
    }
}

/// The MCP servers Claude Code knows, and which of them the assistant (⌥ + fn) may use for
/// questions. Servers are added in Claude Code (`claude mcp add`, or `/mcp` to sign in); this page
/// shows them and switches them on for the assistant.
private struct MCPSettings: View {
    @ObservedObject var model: AppModel
    @State private var servers: [MCPServer] = []
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "MCP", subtitle: "The servers your \(engineName) knows. Switch on the ones the assistant (⌥ + fn) may use to answer questions; it always shows its plan and waits for Return first.")
            if loading && servers.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Asking \(engineName) for its MCP servers …").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                .padding(.vertical, 20)
            } else if let problem {
                Text(problem).font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !servers.isEmpty {
                SettingsGroup(title: "Servers") {
                    ForEach(servers) { server in
                        SettingsRow(title: server.name, subtitle: detail(for: server)) {
                            Toggle("", isOn: binding(for: server)).labelsHidden().toggleStyle(.switch).tint(Theme.text)
                                .disabled(!server.isConnected && !isOn(server))
                        }
                    }
                }
            }
            SettingsGroup {
                SettingsRow(title: "Add a server", subtitle: usesCodex
                            ? "In Terminal: codex mcp add <name> --url <url>, then sign in once with codex mcp login <name>."
                            : "In Terminal: claude mcp add --transport http --scope user <name> <url>, then sign in once with /mcp inside claude.") {
                    ChangeButton(title: loading ? "Loading…" : "Reload") { load() }.disabled(loading)
                }
            }
        }
        .onAppear { if servers.isEmpty { load() } }
    }

    private func detail(for server: MCPServer) -> String {
        var text = server.isConnected ? "Connected" : server.status.replacingOccurrences(of: "! ", with: "")
        if server.toolPrefix == "mcp__awork" { text += " · read only: the assistant looks things up, tasks are created by the app after Return" }
        return text
    }

    private func isOn(_ server: MCPServer) -> Bool {
        server.assistantTools.allSatisfy(model.settings.assistant.agentTools.contains)
    }

    private func binding(for server: MCPServer) -> Binding<Bool> {
        Binding(get: { isOn(server) }, set: { on in
            var tools = model.settings.assistant.agentTools.filter { !$0.hasPrefix(server.toolPrefix) }
            if on { tools += server.assistantTools }
            model.settings.assistant.agentTools = tools
        })
    }

    /// The servers come from the command line that runs the agent with tools: Codex when it is
    /// chosen there or when Claude Code is missing, otherwise Claude Code.
    private var usesCodex: Bool {
        let claude = ClaudeCLI.locate(custom: model.settings.ai.claudePath)
        let codex = CodexCLI.locate(custom: model.settings.ai.codexPath)
        return codex != nil && (model.settings.assistant.agentEngine == .codex || claude == nil)
    }

    private var engineName: String { usesCodex ? "Codex" : "Claude Code" }

    private func load() {
        if DemoMode.isOn {
            servers = MCPServer.parseList(DemoMode.mcpList)
            return
        }
        let codex = usesCodex
        guard let path = codex ? CodexCLI.locate(custom: model.settings.ai.codexPath) : ClaudeCLI.locate(custom: model.settings.ai.claudePath) else {
            problem = "Neither Claude Code nor Codex was found. Install one and log in once in Terminal."
            return
        }
        loading = true
        problem = nil
        Task {
            let output = try? await ProcessRunner().run(path, arguments: codex ? ["mcp", "list", "--json"] : ["mcp", "list"], timeout: 90)
            let list = output.map { codex ? MCPServer.parseCodexList($0) : MCPServer.parseList(String(decoding: $0, as: UTF8.self)) } ?? []
            await MainActor.run {
                servers = list.sorted { ($0.isConnected ? 0 : 1, $0.name.lowercased()) < ($1.isConnected ? 0 : 1, $1.name.lowercased()) }
                if list.isEmpty { problem = "\(codex ? "Codex" : "Claude Code") lists no MCP servers." }
                loading = false
            }
        }
    }
}

private struct VibeCodingSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Vibe coding")
            SettingsGroup {
                SettingsRow(title: "Code mode in editors and terminals",
                            subtitle: "Keeps identifiers, file names and commands exactly as spoken in VS Code, Cursor, cmux, Terminal and other code tools.") {
                    Toggle("", isOn: $model.settings.codeModeEnabled).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Prompts for AI tools",
                            subtitle: "Turn spoken thoughts into a clean prompt with the Prompt Engineer transform (⌥2).") {
                    ChangeButton(title: "Transforms") {
                        model.showingSettings = false
                        model.section = .transforms
                    }
                }
            }
        }
    }
}

private struct EmptySettingsPage: View {
    let title: String
    let subtitle: String
    let empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: title, subtitle: subtitle)
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.secondary)
                Text(empty).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 38)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
    }
}
