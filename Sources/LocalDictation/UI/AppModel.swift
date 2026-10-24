import AppKit
import Combine
import DictationCore
import ServiceManagement

/// State shared by the app window, the pill and the menu. Lives on the main thread.
///
/// Changing `settings` (from any view) calls `onSettingsChange`, which saves the file and
/// applies the change to the running controller.
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case home, notetaker, insights, dictionary, snippets, style, transforms, scratchpad, settings, help

        var id: Self { self }

        /// The entries in the upper part of the sidebar; settings and help sit at the bottom.
        static let main: [Section] = [.home, .notetaker, .insights, .dictionary, .snippets, .style, .transforms, .scratchpad]

        var title: String {
            switch self {
            case .home: return "Dictation"
            case .notetaker: return "Notetaker"
            case .insights: return "Insights"
            case .dictionary: return "Dictionary"
            case .snippets: return "Snippets"
            case .style: return "Style"
            case .transforms: return "Transforms"
            case .scratchpad: return "Scratchpad"
            case .settings: return "Settings"
            case .help: return "Help"
            }
        }

        var icon: String {
            switch self {
            case .home: return "mic"
            case .notetaker: return "record.circle"
            case .insights: return "chart.bar.xaxis"
            case .dictionary: return "book.closed"
            case .snippets: return "scissors"
            case .style: return "textformat"
            case .transforms: return "wand.and.stars"
            case .scratchpad: return "note.text"
            case .settings: return "gearshape"
            case .help: return "questionmark.circle"
            }
        }
    }

    /// Something the user should know about, shown under the bell in the window.
    struct Event: Identifiable, Equatable {
        let id = UUID()
        var date: Date
        var title: String
        var detail: String
    }

    enum SettingsPage: String, CaseIterable, Identifiable {
        case general, system, ai, notetaker, vibeCoding, connectors, mcp

        var id: Self { self }

        var title: String {
            switch self {
            case .general: return "General"
            case .system: return "System"
            case .notetaker: return "Notetaker"
            case .vibeCoding: return "Vibe coding"
            case .connectors: return "Connectors"
            case .mcp: return "MCP"
            case .ai: return "AI"
            }
        }

        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .system: return "laptopcomputer"
            case .notetaker: return "record.circle"
            case .vibeCoding: return "number"
            case .connectors: return "point.3.connected.trianglepath.dotted"
            case .mcp: return "puzzlepiece.extension"
            case .ai: return "sparkles"
            }
        }
    }

    @Published var section: Section = .home
    /// The settings window shown over the app, like Wispr Flow's.
    @Published var showingSettings = false
    @Published var settingsPage: SettingsPage = .general
    @Published var settings: DictationSettings {
        didSet { if settings != oldValue { onSettingsChange?(settings) } }
    }
    @Published private(set) var history: [HistoryEntry] = []
    @Published var status: DictationController.Status = .loadingModel
    @Published var llmReady = false
    @Published private(set) var permissions: [Permission: Bool] = [:]
    @Published private(set) var startsAtLogin = false
    @Published private(set) var insights = Insights(entries: [])
    @Published private(set) var events: [Event] = []
    @Published var unreadEvents = 0

    var onSettingsChange: ((DictationSettings) -> Void)?
    /// Rewrites text by an instruction with the local LLM; set by the app delegate.
    var runTransform: ((String, String) async throws -> String)?
    var notetaker: NotetakerController?
    var calendar: CalendarService?
    let scratchpad = ScratchpadModel()
    /// Opens the floating scratchpad window, with a new note or the given one.
    var openScratchpad: ((UUID?) -> Void)?
    private let historyStore: HistoryStore

    init(settings: DictationSettings, historyStore: HistoryStore) {
        self.settings = settings
        self.historyStore = historyStore
        reloadHistory()
        refreshSystemState()
    }

    var stats: DictationStats { DictationStats(entries: history) }

    var firstName: String {
        DemoMode.fullUserName.split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    func openSettings(_ page: SettingsPage = .general) {
        settingsPage = page
        showingSettings = true
    }

    /// Deletes the dictation history file and empties the statistics.
    func deleteHistory() {
        try? FileManager.default.removeItem(at: AppPaths.historyFile)
        reloadHistory()
    }

    func reloadHistory() {
        history = (try? historyStore.entries()) ?? []
        insights = Insights(entries: history, vocabulary: settings.vocabulary, replacements: settings.replacements)
    }

    func notify(_ title: String, _ detail: String) {
        events.insert(Event(date: Date(), title: title, detail: detail), at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
        unreadEvents += 1
    }

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: settings.appearance) ?? .system }
        set { settings.appearance = newValue.rawValue }
    }

    func refreshSystemState() {
        let current = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.isGranted) })
        if current != permissions { permissions = current }
        let login = SMAppService.mainApp.status == .enabled
        if login != startsAtLogin { startsAtLogin = login }
    }

    func setStartsAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            AppLog.info("start at login \(on ? "on" : "off")")
        } catch {
            AppLog.error("login item change failed: \(error)")
            NSSound.beep()
        }
        refreshSystemState()
    }
}

/// Display names of apps, looked up once per bundle id.
enum AppNames {
    private static var cache: [String: String] = [:]

    static func name(for bundleId: String?) -> String? {
        guard let bundleId else { return nil }
        if let cached = cache[bundleId] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        cache[bundleId] = name
        return name
    }
}
