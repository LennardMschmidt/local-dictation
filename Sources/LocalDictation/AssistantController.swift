import AppKit
import Combine
import DictationCore
import Foundation

/// The assistant behind ⌥ + fn: plans a spoken request, shows the plan on a card above the bar
/// and runs it after Return. Opening places, apps and notes runs on this Mac at once; awork
/// tasks go through the awork connection; questions go to Claude Code with read-only tools.
@MainActor
final class AssistantController {
    let card = AssistantCard()
    private var phaseWatch: AnyCancellable?
    private let settings: () -> DictationSettings
    private let anchor: () -> (centerX: CGFloat, bottom: CGFloat)
    private let paster = Paster()
    /// The last minutes of a running meeting recording, for questions about it.
    var liveMeeting: (() async -> String?)?
    /// Takes Return and Esc for the card while it is open.
    var setAwaitsConfirmation: ((Bool) -> Void)?

    private var work: Task<Void, Never>?
    private var closeWork: DispatchWorkItem?
    private var projects: (loaded: Date, list: [AworkClient.Project])?
    /// The turns since the card opened; a new request on the open card continues them.
    private var conversation: [(request: String, reply: String)] = []

    /// While the card is open and not busy, fn answers the assistant instead of dictating.
    var takesReplies: Bool {
        guard card.isOpen else { return false }
        switch card.model.phase {
        case .proposal, .answer, .failed, .done: return true
        case .thinking, .running: return false
        }
    }

    init(settings: @escaping () -> DictationSettings, anchor: @escaping () -> (centerX: CGFloat, bottom: CGFloat)) {
        self.settings = settings
        self.anchor = anchor
        // Return and Esc belong to the card only while a proposal waits for a decision; in every
        // other state they reach the app in front, so the user can keep working while it thinks.
        phaseWatch = card.model.$phase.sink { [weak self] phase in
            if case .proposal = phase { self?.setAwaitsConfirmation?(true) } else { self?.setAwaitsConfirmation?(false) }
        }
        card.model.onConfirm = { [weak self] in self?.confirm() }
        card.model.onCancel = { [weak self] in self?.dismiss() }
        card.model.onCopy = { [weak self] text in
            self?.paster.copy(text)
            self?.finish("Copied", link: nil)
        }
        card.model.onInsert = { [weak self] text in self?.insert(text) }
        card.model.onOpen = { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.dismiss()
        }
    }

    /// Return or Esc while the card shows a proposal (the only state that takes them).
    func key(_ key: HotkeyMonitor.ConfirmationKey) {
        switch (key, card.model.phase) {
        case (.cancel, _): dismiss()
        case (.confirm, .proposal): confirm()
        case (.confirm, .answer(let text)): insert(text)
        case (.confirm, .done), (.confirm, .failed): dismiss()
        case (.confirm, _): break
        }
    }

    func handle(request: String, frontApp bundleId: String?) {
        work?.cancel()
        closeWork?.cancel()
        card.model.request = request
        card.model.status = "Thinking …"
        card.model.phase = .thinking
        card.show(at: anchor())
        let settings = settings()
        let frontApp = bundleId.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }?
            .deletingPathExtension().lastPathComponent ?? ""
        let started = Date()
        let earlier = conversation
        work = Task {
            var context = await self.context(settings: settings, frontApp: frontApp)
            context.conversation = earlier
            if let live = await self.liveMeeting?() {
                context.liveMeeting = live
                AppLog.info(String(format: "assistant got %d characters of the running meeting after %.1f s", live.count, Date().timeIntervalSince(started)))
            }
            AppLog.info(String(format: "assistant context ready after %.1f s, %d awork projects", Date().timeIntervalSince(started), context.projects.count))
            do {
                var plan = try await AssistantPlanner(completer: Self.planner(settings)).plan(request, context: context)
                guard !Task.isCancelled else { return }
                // awork changes are looked up first, so the card shows exactly what will be written.
                if plan.actions.contains(where: { $0.kind == .aworkChange }) {
                    self.card.model.status = "Looking it up in awork …"
                    let (resolved, question) = try await self.resolveAworkChanges(plan, settings: settings)
                    guard !Task.isCancelled else { return }
                    if let question {
                        self.conversation.append((request, question))
                        self.card.model.phase = .answer(question)
                        return
                    }
                    plan = resolved
                }
                AppLog.info(String(format: "assistant planned %d steps (%@) in %.1f s, turn %d", plan.actions.count,
                                   plan.actions.map(\.type).joined(separator: ", "), Date().timeIntervalSince(started), earlier.count + 1))
                let reply = plan.isOnlyAnswer ? plan.actions.map(\.answer).joined(separator: "\n\n")
                    : "Proposed: \(plan.summary); " + plan.actions.map(\.title).joined(separator: "; ")
                self.conversation.append((request, reply))
                if plan.isOnlyAnswer {
                    AssistantUsage.append(AssistantUsage(steps: plan.actions.map(\.type), seconds: Date().timeIntervalSince(started)))
                    self.card.model.phase = .answer(reply)
                } else {
                    self.card.model.phase = .proposal(plan)
                    // Questions only read, so they run at once like a chat; anything that opens,
                    // creates or changes something waits for Return.
                    if plan.isOnlyQuestions { self.confirm() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.error("assistant planning failed: \(error)")
                self.card.model.phase = .failed("I could not turn that into a plan. \(Self.describe(error))")
            }
        }
    }

    private func confirm() {
        guard case .proposal(let plan) = card.model.phase else { return }
        card.model.phase = .running(plan)
        let settings = settings()
        let started = Date()
        work = Task {
            var answers: [String] = []
            var link: URL?
            var tools: [String] = []
            var opened: [String] = []
            for action in plan.actions {
                guard !Task.isCancelled else { return }
                do {
                    switch action.kind {
                    case .openURL:
                        try self.open(url: action.url, in: action.app.isEmpty ? settings.assistant.browser : action.app)
                        opened.append(Self.openedName(url: action.url))
                    case .openApp:
                        try self.open(app: action.app)
                        opened.append(action.app)
                    case .openNote:
                        try self.open(note: action.note, vault: settings.meetingVault)
                        opened.append("Obsidian")
                    case .aworkTask: link = try await self.createTask(action)
                    case .agent:
                        let result = try await self.agent(action.prompt, settings: settings)
                        answers.append(result.answer)
                        tools += result.tools
                    case .answer: answers.append(action.answer)
                    case .aworkCall:
                        try await AworkClient.shared.perform(AworkCall(method: action.method, path: action.path, body: action.body,
                                                                       description: action.title))
                        AppLog.info("assistant sent \(action.method) \(action.path.split(separator: "/").first ?? "") to awork")
                    case .aworkChange, .none: throw AssistantError.unknownAction(action.type)
                    }
                } catch {
                    AppLog.error("assistant step \(action.type) failed: \(error)")
                    self.card.model.phase = .failed("„\(action.title)“ hat nicht geklappt. \(Self.describe(error))")
                    return
                }
            }
            AppLog.info("assistant ran \(plan.actions.count) steps, \(tools.count) tool calls")
            AssistantUsage.append(AssistantUsage(steps: plan.actions.map(\.type), tools: tools, opened: opened,
                                                 seconds: Date().timeIntervalSince(started)))
            if !answers.isEmpty {
                self.card.model.phase = .answer(answers.joined(separator: "\n\n"))
            } else {
                self.finish(plan.actions.contains { $0.kind == .aworkTask } ? "Created" : "Done", link: link)
            }
        }
    }

    private func finish(_ message: String, link: URL?) {
        card.model.phase = .done(message, link: link)
        let close = DispatchWorkItem { [weak self] in self?.dismiss() }
        closeWork = close
        DispatchQueue.main.asyncAfter(deadline: .now() + (link == nil ? 1.6 : 4), execute: close)
    }

    private func insert(_ text: String) {
        dismiss()
        // Gives the card a moment to go, then pastes into the app in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [paster] in _ = paster.insert(text) }
    }

    /// Keeps the open card above the bar when the bar moves, unless the user dragged the card.
    func followBar() {
        card.follow(anchor())
    }

    func dismiss() {
        conversation = []
        work?.cancel()
        work = nil
        closeWork?.cancel()
        setAwaitsConfirmation?(false)
        card.close()
    }

    // MARK: Planning

    private static func planner(_ settings: DictationSettings) -> ChatCompleter {
        if DemoMode.isOn { return DemoPlanner() }
        let local = LocalModel.make(settings.llm)
        guard var cloud = settings.ai.cloud(settings.assistant.planner, timeout: 90) else { return local }
        if var claude = cloud as? ClaudeCLI {
            claude.usesSpare = true
            cloud = claude
        }
        return FallbackCompleter(primary: cloud, fallback: local)
    }

    private func context(settings: DictationSettings, frontApp: String) async -> AssistantContext {
        let projects = await aworkProjects()
        return AssistantContext(places: settings.places,
                                projects: projects.map { ($0.id, $0.name, $0.company) },
                                notes: Self.vaultNotes(settings.meetingVault),
                                frontApp: frontApp, agentTools: settings.assistant.agentTools,
                                userName: DemoMode.fullUserName)
    }

    /// The awork projects, loaded at most every 15 minutes; none when awork is not connected or
    /// does not answer within 6 seconds, so planning never waits long for it.
    private func aworkProjects() async -> [AworkClient.Project] {
        if let projects, Date().timeIntervalSince(projects.loaded) < 15 * 60 { return projects.list }
        // Reading the awork login can wait for a Keychain dialog, which no cancellation ends, so
        // the answer is raced against a timer instead of awaited.
        let list = await Self.first(within: 6) { () -> [AworkClient.Project] in
            guard await AworkClient.shared.isLoggedIn else { return [] }
            return (try? await AworkClient.shared.projects()) ?? []
        }
        guard let list, !list.isEmpty else { return projects?.list ?? [] }
        projects = (Date(), list)
        return list
    }

    /// The result of `operation`, or nil when it takes longer than `seconds`; the operation
    /// may go on in the background.
    nonisolated static func first<T: Sendable>(within seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            Task { let value = await operation(); once.run { continuation.resume(returning: value) } }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.run { continuation.resume(returning: nil) }
            }
        }
    }

    /// Loads the awork projects in the background, so the first request does not wait.
    func prepare() {
        Task { _ = await aworkProjects() }
    }

    /// Note names of the vault for "open the note on Fabrikam": customer notes, project maps of
    /// content and the knowledge folders, as paths without ".md".
    nonisolated static func vaultNotes(_ path: String) -> [String] {
        let vault = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard let files = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var notes: [String] = []
        for case let file as URL in files where file.pathExtension == "md" {
            let relative = String(file.path.dropFirst(vault.path.count + 1).dropLast(3))
            let top = relative.split(separator: "/").first.map(String.init) ?? ""
            let isCustomer = top.hasPrefix("02 ") && relative.split(separator: "/").count <= 3
            let isMap = relative.hasSuffix(" MOC")
            let isKnowledge = ["03 ", "04 ", "05 "].contains { top.hasPrefix($0) } && relative.split(separator: "/").count == 2
            if isCustomer || isMap || isKnowledge { notes.append(relative) }
            if notes.count >= 400 { break }
        }
        return notes.sorted()
    }

    // MARK: Running

    enum AssistantError: LocalizedError {
        case badAddress(String)
        case appNotFound(String)
        case notConnected
        case unknownAction(String)
        case noClaude

        var errorDescription: String? {
            switch self {
            case .badAddress(let url): return "The address \"\(url)\" is not valid."
            case .appNotFound(let app): return "I could not find the app \"\(app)\"."
            case .notConnected: return "awork is not connected; connect it once in the Notetaker with \"Alle in awork übertragen\"."
            case .unknownAction(let type): return "The step \"\(type)\" is unknown."
            case .noClaude: return "This question needs Claude Code or Codex."
            }
        }
    }

    /// The name a quick open counts under: the site without "www." ("github.com"), or the app
    /// of a link such as "spotify:" ("Spotify").
    static func openedName(url text: String) -> String {
        guard let url = URL(string: text) else { return text }
        if let host = url.host, url.scheme?.hasPrefix("http") == true {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return (url.scheme ?? text).capitalized
    }

    private func open(url text: String, in browser: String) throws {
        guard let url = URL(string: text), url.scheme != nil else { throw AssistantError.badAddress(text) }
        if !browser.isEmpty, url.scheme?.hasPrefix("http") == true, let app = Self.application(named: browser) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func open(app name: String) throws {
        guard let app = Self.application(named: name) else { throw AssistantError.appNotFound(name) }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func open(note: String, vault path: String) throws {
        let vault = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).lastPathComponent
        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [URLQueryItem(name: "vault", value: vault), URLQueryItem(name: "file", value: note)]
        guard let url = components.url else { throw AssistantError.badAddress(note) }
        NSWorkspace.shared.open(url)
    }

    /// An installed app by its name, with or without ".app", in the usual folders.
    static func application(named name: String) -> URL? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       NSString(string: "~/Applications").expandingTildeInPath]
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            if let item = items.first(where: { $0.lowercased() == wanted + ".app" })
                ?? items.first(where: { $0.lowercased().hasPrefix(wanted) && $0.hasSuffix(".app") }) {
                return URL(fileURLWithPath: folder).appendingPathComponent(item)
            }
        }
        return nil
    }

    private func createTask(_ action: AssistantAction) async throws -> URL? {
        guard await AworkClient.shared.isLoggedIn else { throw AssistantError.notConnected }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let due = formatter.date(from: action.due).map { Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: $0) ?? $0 }
        let me = try? await AworkClient.shared.me()
        let task = try await AworkClient.shared.createTask(name: action.taskName, description: "Created with the LocalDictation assistant.",
                                                           project: action.projectId, parent: nil, due: due, assignee: me?.id)
        AppLog.info("assistant created an awork task")
        return AworkClient.taskURL(task)
    }

    /// Replaces every awork change of `plan` by the calls the lookup found, or returns its
    /// question when the change is not clear.
    private func resolveAworkChanges(_ plan: AssistantPlan, settings: DictationSettings) async throws -> (AssistantPlan, String?) {
        guard await AworkClient.shared.isLoggedIn else { throw AssistantError.notConnected }
        guard let agent = await AgentFactory.make(settings, tools: MCPServer.aworkReadTools, timeout: 240, usesSpare: true)
        else { throw AssistantError.noClaude }
        var actions: [AssistantAction] = []
        for action in plan.actions {
            guard action.kind == .aworkChange else {
                actions.append(action)
                continue
            }
            let started = Date()
            let resolution = try await AworkResolution.resolve(action.prompt, agent: agent,
                                                               defaultActivity: settings.assistant.defaultActivity)
            AppLog.info(String(format: "assistant looked up an awork change in %.1f s: %d calls", Date().timeIntervalSince(started),
                               resolution.calls.count))
            if !resolution.question.isEmpty || resolution.calls.isEmpty {
                return (plan, resolution.question.isEmpty ? "I found nothing in awork that matches." : resolution.question)
            }
            actions += resolution.calls.map(AssistantAction.aworkCall)
        }
        return (AssistantPlan(summary: plan.summary, actions: actions), nil)
    }

    private func agent(_ prompt: String, settings: DictationSettings) async throws -> (answer: String, tools: [String]) {
        guard let agent = await AgentFactory.make(settings, tools: settings.assistant.agentTools, builtinTools: ClaudeAgent.webTools,
                                                  model: ClaudeAgent.questionModel, timeout: 180, usesSpare: true)
        else { throw AssistantError.noClaude }
        return try await agent.runWithTools(prompt)
    }

    /// Starts Claude Code for the next question and the next awork lookup in the background, so
    /// they skip the start of Claude Code and its MCP servers (about four seconds each).
    func prepareSpares() {
        let settings = settings()
        guard !DemoMode.isOn, let path = ClaudeCLI.locate(custom: settings.ai.claudePath) else { return }
        let planner = settings.ai.cloud(settings.assistant.planner, timeout: 90) as? ClaudeCLI
        Task.detached {
            await planner?.prepare(schema: AssistantPlanner.schema)
            var questions = ClaudeAgent(path: path, model: ClaudeAgent.questionModel, tools: settings.assistant.agentTools)
            questions.builtinTools = ClaudeAgent.webTools
            questions.serverScope = .user
            await questions.prepare(schemas: [:])
            var awork = ClaudeAgent(path: path, effort: .low, tools: MCPServer.aworkReadTools)
            awork.serverScope = .user
            await awork.prepare(schemas: ["awork": AworkResolution.schema])
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Runs a block only the first time.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}
