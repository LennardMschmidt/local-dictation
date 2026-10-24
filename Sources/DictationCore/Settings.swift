import Foundation

/// User settings, stored as JSON. Every field has a default, so a settings file that
/// lists only some keys still loads and the rest falls back to the defaults.
public struct DictationSettings: Codable, Equatable, Sendable {
    public var llm: LLMSettings
    /// Local model or Claude, per task.
    public var ai: AISettings
    public var asr: ASRSettings
    /// Terms that recognition and cleanup should spell exactly like this.
    public var vocabulary: [String]
    /// Deterministic replacements applied to the transcript and to the final text.
    public var replacements: [Replacement]
    /// Dictionary entries marked with a star: vocabulary terms or the target of a replacement.
    /// They go first in the hints for recognition and cleanup.
    public var starredWords: [String]
    /// The dictionary's groups, in the order of its tabs. They only sort the entries.
    public var dictionaryGroups: [String]
    /// The group of each dictionary entry, keyed like a star: the term, or the correct spelling
    /// of a replacement. Entries without a group appear only under "All".
    public var wordGroups: [String: String]
    /// Calendars the Notetaker ignores, by calendar identifier; every other calendar counts,
    /// also ones added later.
    public var excludedCalendars: [String]
    /// Per app style: the dictionary groups that come first in the recognition hint.
    public var styleGroups: [String: [String]]
    /// Corrections found after dictations, waiting for the user to take them into the dictionary.
    public var dictionarySuggestions: [Replacement]
    /// Suggestions the user dismissed, as "from→to", so they do not come back.
    public var dismissedSuggestions: [String]
    /// Per app style: a fixed recognition language ("de", "en"); missing means automatic.
    public var styleLanguages: [String: String]
    /// Servers and web apps the assistant opens by name.
    public var places: [Place]
    public var assistant: AssistantSettings
    /// How Polarion and awork are reached: the app's own connection or the MCP servers.
    public var connectors = ConnectorSettings()
    /// A dictation that consists only of a trigger phrase is replaced by the snippet text.
    public var snippets: [Snippet]
    /// Bundle id to style overrides, on top of the built-in mapping in `AppStyleResolver`.
    public var appStyles: [String: AppStyle]
    /// Fn presses shorter than this are ignored.
    public var minimumPressSeconds: Double
    public var playSounds: Bool
    public var historyLimit: Int
    /// Appends a space after inserted text so that consecutive dictations do not run together.
    public var appendTrailingSpace: Bool
    /// Tone per app category (keys are `AppStyle` raw values). Missing entries are formal.
    public var tones: [String: Tone]
    /// Shows the small bar at the bottom of the screen while idle.
    public var showIdlePill: Bool
    /// The scratchpad button on the bar ("Add to Flow Bar" in Wispr Flow).
    public var scratchpadOnBar: Bool
    /// The Obsidian vault meetings are written to (like the tl;dv sync); empty switches it off.
    public var meetingVault: String
    /// "light", "dark" or "system".
    public var appearance: String
    /// Saved rewrite instructions for Ctrl+fn on selected text.
    public var transforms: [Transform]
    /// Core Audio UID of the microphone to use; empty means the system default.
    public var microphoneUID: String
    /// Transforms with ⌥1 to ⌥9 and ⌥O (the \"Opt in\" switch).
    public var transformsEnabled: Bool
    /// Runs `autoTransformID` on every dictation before it is pasted.
    public var autoTransformEnabled: Bool
    /// Id of the transform for auto apply, empty for none.
    public var autoTransformID: String
    /// Appends `emailSignature` to dictations into mail apps that end with a sign-off.
    public var emailSignatureEnabled: Bool
    /// Signature text for `emailSignatureEnabled`.
    public var emailSignature: String
    /// Mutes the system output while recording, so music does not end up in the recording.
    public var muteAudioWhileDictating: Bool
    /// Keeps the pill and the scratchpad out of screenshots and screen sharing.
    public var hideInScreenShare: Bool
    /// Languages the user speaks; one language fixes recognition to it.
    public var languages: [String]
    /// A meeting recording stops at this length.
    public var notetakerMaxMinutes: Int
    /// Minutes before a calendar meeting the briefing card opens; 0 turns it off.
    public var briefingMinutes: Int
    /// Notifications for word-count milestones and streaks.
    public var notifyMilestones: Bool
    /// Notifications with tips, such as LM Studio being offline.
    public var notifySuggestions: Bool
    /// The transform the Transform button on the bar applies: the last one chosen from its menu.
    public var barTransformID: String
    /// Keeps text as spoken in code editors and terminals; off treats them like other apps.
    public var codeModeEnabled: Bool
    /// Lets other local processes start and stop recordings through distributed notifications,
    /// for automated live tests. Off by default.
    public var testControl: Bool

    public init(
        llm: LLMSettings = LLMSettings(),
        ai: AISettings = AISettings(),
        asr: ASRSettings = ASRSettings(),
        vocabulary: [String] = DictationSettings.defaultVocabulary,
        replacements: [Replacement] = [],
        starredWords: [String] = [],
        dictionaryGroups: [String] = DictationSettings.defaultDictionaryGroups,
        wordGroups: [String: String] = [:],
        excludedCalendars: [String] = [],
        styleGroups: [String: [String]] = DictationSettings.defaultStyleGroups,
        dictionarySuggestions: [Replacement] = [],
        dismissedSuggestions: [String] = [],
        styleLanguages: [String: String] = [:],
        places: [Place] = DictationSettings.defaultPlaces,
        assistant: AssistantSettings = AssistantSettings(),
        snippets: [Snippet] = [],
        appStyles: [String: AppStyle] = [:],
        minimumPressSeconds: Double = 0.25,
        playSounds: Bool = true,
        historyLimit: Int = 20_000,
        appendTrailingSpace: Bool = true,
        tones: [String: Tone] = ["chat": .casual, "work": .casual],
        showIdlePill: Bool = true,
        scratchpadOnBar: Bool = true,
        meetingVault: String = "~/Documents/Obsidian Vault",
        appearance: String = "system",
        transforms: [Transform] = Transform.presets,
        microphoneUID: String = "",
        transformsEnabled: Bool = true,
        autoTransformEnabled: Bool = false,
        autoTransformID: String = "",
        emailSignatureEnabled: Bool = false,
        emailSignature: String = "",
        muteAudioWhileDictating: Bool = false,
        hideInScreenShare: Bool = false,
        languages: [String] = ["de", "en"],
        notetakerMaxMinutes: Int = 120,
        briefingMinutes: Int = 5,
        notifyMilestones: Bool = true,
        notifySuggestions: Bool = true,
        barTransformID: String = "",
        codeModeEnabled: Bool = true,
        testControl: Bool = false
    ) {
        self.llm = llm
        self.ai = ai
        self.asr = asr
        self.vocabulary = vocabulary
        self.replacements = replacements
        self.starredWords = starredWords
        self.dictionaryGroups = dictionaryGroups
        self.wordGroups = wordGroups
        self.excludedCalendars = excludedCalendars
        self.styleGroups = styleGroups
        self.dictionarySuggestions = dictionarySuggestions
        self.dismissedSuggestions = dismissedSuggestions
        self.styleLanguages = styleLanguages
        self.places = places
        self.assistant = assistant
        self.snippets = snippets
        self.appStyles = appStyles
        self.minimumPressSeconds = minimumPressSeconds
        self.playSounds = playSounds
        self.historyLimit = historyLimit
        self.appendTrailingSpace = appendTrailingSpace
        self.tones = tones
        self.showIdlePill = showIdlePill
        self.scratchpadOnBar = scratchpadOnBar
        self.meetingVault = meetingVault
        self.appearance = appearance
        self.transforms = transforms
        self.microphoneUID = microphoneUID
        self.transformsEnabled = transformsEnabled
        self.autoTransformEnabled = autoTransformEnabled
        self.autoTransformID = autoTransformID
        self.emailSignatureEnabled = emailSignatureEnabled
        self.emailSignature = emailSignature
        self.muteAudioWhileDictating = muteAudioWhileDictating
        self.hideInScreenShare = hideInScreenShare
        self.languages = languages
        self.notetakerMaxMinutes = notetakerMaxMinutes
        self.briefingMinutes = briefingMinutes
        self.notifyMilestones = notifyMilestones
        self.notifySuggestions = notifySuggestions
        self.barTransformID = barTransformID
        self.codeModeEnabled = codeModeEnabled
        self.testControl = testControl
    }

    /// The language recognition is fixed to: the one chosen in the pill, or the only language
    /// in "My languages". Nil means detect it.
    public var recognitionLanguage: String? {
        if let fixed = asr.fixedLanguage { return fixed }
        return languages.count == 1 ? languages.first : nil
    }

    /// Places everyone has; servers of one's own are added in the settings.
    public static let defaultPlaces = [
        Place(name: "Spotify", url: "https://open.spotify.com"),
        Place(name: "Gmail", aliases: ["Google Mail"], url: "https://mail.google.com"),
        Place(name: "GitHub", url: "https://github.com"),
    ]

    public static let defaultDictionaryGroups = ["Kollegen", "Kunden & Firmen", "Produkte & Polarion", "Tools"]

    /// Vocabulary for recognition and cleanup: starred entries first, then the other terms.
    public var vocabularyByPriority: [String] {
        let known = Set(vocabulary + replacements.map(\.to))
        let starred = starredWords.filter { known.contains($0) }
        var seen = Set<String>()
        return (starred + vocabulary).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The vocabulary for dictating into apps of `style`: starred entries, then the dictionary
    /// groups set for that style (colleagues in Teams, product terms in code editors), then the
    /// rest. Whisper's hint holds only the first terms, so this decides which ones it gets.
    public func vocabularyByPriority(for style: AppStyle) -> [String] {
        let groups = styleGroups[style.rawValue] ?? []
        guard !groups.isEmpty else { return vocabularyByPriority }
        let all = vocabularyByPriority
        let starred = all.prefix { starredWords.contains($0) }
        let inGroups = all.filter { term in wordGroups[term].map(groups.contains) ?? false }
        var seen = Set<String>()
        return (Array(starred) + inGroups + all).filter { seen.insert($0).inserted }
    }

    /// The language to recognise in apps of `style`: the one set for it, otherwise the general one.
    public func recognitionLanguage(for style: AppStyle) -> String? {
        if let fixed = styleLanguages[style.rawValue], !fixed.isEmpty { return fixed }
        return recognitionLanguage
    }

    public static let defaultStyleGroups: [String: [String]] = [
        AppStyle.work.rawValue: ["Kollegen", "Kunden & Firmen"],
        AppStyle.mail.rawValue: ["Kunden & Firmen", "Kollegen"],
        AppStyle.code.rawValue: ["Tools", "Produkte & Polarion"],
        AppStyle.notes.rawValue: ["Produkte & Polarion", "Kunden & Firmen"],
    ]

    /// Index of the transform the bar's Transform button applies; the first one when none was chosen.
    public var barTransformIndex: Int? {
        if let index = transforms.firstIndex(where: { $0.id.uuidString == barTransformID }) { return index }
        return transforms.isEmpty ? nil : 0
    }

    /// The dictionary terms for the cleanup prompt: the starred ones and those found in `text`,
    /// at most 30, so the prompt stays small whatever the dictionary holds.
    public func promptVocabulary(for text: String, matcher: VocabularyMatcher) -> [String] {
        var seen = Set<String>()
        let starred = vocabularyByPriority.prefix { starredWords.contains($0) }.prefix(10)
        return Array((Array(starred) + matcher.relevant(to: text, limit: 30)).filter { seen.insert($0).inserted }.prefix(30))
    }

    public var autoTransform: Transform? {
        guard autoTransformEnabled else { return nil }
        return transforms.first { $0.id.uuidString == autoTransformID }
    }

    /// `tones` keyed by style, ignoring unknown keys.
    public var tonesByStyle: [AppStyle: Tone] {
        var result = Dictionary(uniqueKeysWithValues: tones.compactMap { key, tone in AppStyle(rawValue: key).map { ($0, tone) } })
        // Notes follow "Other", as on Wispr Flow's Style page.
        if let other = result[.plain] { result[.notes] = other }
        return result
    }

    /// The tone used for text inserted into `style`; code keeps the text as spoken.
    public func tone(for style: AppStyle) -> Tone {
        style == .code ? .formal : (tonesByStyle[style] ?? .formal)
    }

    public static let defaultVocabulary: [String] = []

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DictationSettings()
        llm = try c.decodeIfPresent(LLMSettings.self, forKey: .llm) ?? d.llm
        ai = try c.decodeIfPresent(AISettings.self, forKey: .ai) ?? d.ai
        asr = try c.decodeIfPresent(ASRSettings.self, forKey: .asr) ?? d.asr
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? d.replacements
        starredWords = try c.decodeIfPresent([String].self, forKey: .starredWords) ?? d.starredWords
        dictionaryGroups = try c.decodeIfPresent([String].self, forKey: .dictionaryGroups) ?? d.dictionaryGroups
        wordGroups = try c.decodeIfPresent([String: String].self, forKey: .wordGroups) ?? d.wordGroups
        excludedCalendars = try c.decodeIfPresent([String].self, forKey: .excludedCalendars) ?? d.excludedCalendars
        styleGroups = try c.decodeIfPresent([String: [String]].self, forKey: .styleGroups) ?? d.styleGroups
        dictionarySuggestions = try c.decodeIfPresent([Replacement].self, forKey: .dictionarySuggestions) ?? d.dictionarySuggestions
        dismissedSuggestions = try c.decodeIfPresent([String].self, forKey: .dismissedSuggestions) ?? d.dismissedSuggestions
        styleLanguages = try c.decodeIfPresent([String: String].self, forKey: .styleLanguages) ?? d.styleLanguages
        places = try c.decodeIfPresent([Place].self, forKey: .places) ?? d.places
        assistant = try c.decodeIfPresent(AssistantSettings.self, forKey: .assistant) ?? d.assistant
        connectors = try c.decodeIfPresent(ConnectorSettings.self, forKey: .connectors) ?? d.connectors
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? d.snippets
        appStyles = try c.decodeIfPresent([String: AppStyle].self, forKey: .appStyles) ?? d.appStyles
        minimumPressSeconds = try c.decodeIfPresent(Double.self, forKey: .minimumPressSeconds) ?? d.minimumPressSeconds
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? d.historyLimit
        appendTrailingSpace = try c.decodeIfPresent(Bool.self, forKey: .appendTrailingSpace) ?? d.appendTrailingSpace
        tones = try c.decodeIfPresent([String: Tone].self, forKey: .tones) ?? d.tones
        // Work messengers used to share the tone of all messengers.
        if tones["work"] == nil { tones["work"] = tones["chat"] ?? d.tones["work"] }
        showIdlePill = try c.decodeIfPresent(Bool.self, forKey: .showIdlePill) ?? d.showIdlePill
        scratchpadOnBar = try c.decodeIfPresent(Bool.self, forKey: .scratchpadOnBar) ?? d.scratchpadOnBar
        meetingVault = try c.decodeIfPresent(String.self, forKey: .meetingVault) ?? d.meetingVault
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        transforms = Transform.migrated(try c.decodeIfPresent([Transform].self, forKey: .transforms) ?? d.transforms)
        microphoneUID = try c.decodeIfPresent(String.self, forKey: .microphoneUID) ?? d.microphoneUID
        transformsEnabled = try c.decodeIfPresent(Bool.self, forKey: .transformsEnabled) ?? d.transformsEnabled
        autoTransformEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoTransformEnabled) ?? d.autoTransformEnabled
        autoTransformID = try c.decodeIfPresent(String.self, forKey: .autoTransformID) ?? d.autoTransformID
        emailSignatureEnabled = try c.decodeIfPresent(Bool.self, forKey: .emailSignatureEnabled) ?? d.emailSignatureEnabled
        emailSignature = try c.decodeIfPresent(String.self, forKey: .emailSignature) ?? d.emailSignature
        muteAudioWhileDictating = try c.decodeIfPresent(Bool.self, forKey: .muteAudioWhileDictating) ?? d.muteAudioWhileDictating
        hideInScreenShare = try c.decodeIfPresent(Bool.self, forKey: .hideInScreenShare) ?? d.hideInScreenShare
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? d.languages
        notetakerMaxMinutes = try c.decodeIfPresent(Int.self, forKey: .notetakerMaxMinutes) ?? d.notetakerMaxMinutes
        briefingMinutes = try c.decodeIfPresent(Int.self, forKey: .briefingMinutes) ?? d.briefingMinutes
        notifyMilestones = try c.decodeIfPresent(Bool.self, forKey: .notifyMilestones) ?? d.notifyMilestones
        notifySuggestions = try c.decodeIfPresent(Bool.self, forKey: .notifySuggestions) ?? d.notifySuggestions
        barTransformID = try c.decodeIfPresent(String.self, forKey: .barTransformID) ?? d.barTransformID
        codeModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .codeModeEnabled) ?? d.codeModeEnabled
        testControl = try c.decodeIfPresent(Bool.self, forKey: .testControl) ?? d.testControl
    }
}

public struct LLMSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Which model runs on this Mac: "lmstudio" (the model below in LM Studio) or "apple" (the
    /// Apple Intelligence model of macOS 26, without LM Studio).
    public var provider: String
    /// Base URL of an OpenAI-compatible server, without the `/v1/...` path.
    public var baseURL: String
    public var model: String

    public var usesAppleModel: Bool { provider == "apple" }
    /// Base time the cleanup may take before the raw transcript is used instead; the pipeline
    /// adds one second per 100 characters of transcript.
    public var timeoutSeconds: Double
    public var temperature: Double

    public init(
        enabled: Bool = true,
        provider: String = "lmstudio",
        baseURL: String = "http://localhost:1234",
        model: String = "qwen/qwen3-4b-2507",
        timeoutSeconds: Double = 3,
        temperature: Double = 0.1
    ) {
        self.enabled = enabled
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.temperature = temperature
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
    }
}

public struct ASRSettings: Codable, Equatable, Sendable {
    /// WhisperKit model folder name in argmaxinc/whisperkit-coreml.
    public var model: String
    /// The model for meetings, where accuracy counts more than speed: the full large-v3 found
    /// more words and misheard fewer than the compressed turbo model used for dictation.
    public var meetingModel: String
    /// "auto" detects the language per recording, otherwise an ISO code such as "de".
    public var language: String
    /// Lets the meeting's AI engine correct obvious mishearings in the transcript.
    public var polishMeetingTranscript: Bool
    /// The model for dictations of `longDictationSeconds` or more; empty uses `model` always.
    /// On real dictations the full large-v3 misheard fewer words and needed 0.3 to 1.5 s more,
    /// which only pays off once a dictation is longer than a quick sentence.
    public var longDictationModel: String
    public var longDictationSeconds: Double
    /// The engine for dictation: "whisper", or "parakeet" (NVIDIA Parakeet Ultra with vocabulary
    /// boosting, much faster; measured on my own recordings: more accurate on ordinary speech,
    /// more false hits on dictionary terms). Meetings keep Whisper.
    public var dictationEngine: String

    public init(model: String = "openai_whisper-large-v3-v20240930_turbo_632MB",
                meetingModel: String = "openai_whisper-large-v3-v20240930", language: String = "auto",
                polishMeetingTranscript: Bool = true, longDictationModel: String = "openai_whisper-large-v3-v20240930",
                longDictationSeconds: Double = 6) {
        self.model = model
        self.meetingModel = meetingModel
        self.language = language
        self.polishMeetingTranscript = polishMeetingTranscript
        self.longDictationModel = longDictationModel
        self.longDictationSeconds = longDictationSeconds
        dictationEngine = "whisper"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ASRSettings()
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        meetingModel = try c.decodeIfPresent(String.self, forKey: .meetingModel) ?? d.meetingModel
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        polishMeetingTranscript = try c.decodeIfPresent(Bool.self, forKey: .polishMeetingTranscript) ?? d.polishMeetingTranscript
        longDictationModel = try c.decodeIfPresent(String.self, forKey: .longDictationModel) ?? d.longDictationModel
        longDictationSeconds = try c.decodeIfPresent(Double.self, forKey: .longDictationSeconds) ?? d.longDictationSeconds
        dictationEngine = try c.decodeIfPresent(String.self, forKey: .dictationEngine) ?? d.dictationEngine
    }

    /// The language to force, or nil for detection.
    public var fixedLanguage: String? { language == "auto" || language.isEmpty ? nil : language }
}

public struct Replacement: Codable, Hashable, Sendable {
    public var from: String
    public var to: String
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct Snippet: Codable, Equatable, Sendable {
    public var trigger: String
    public var text: String
    public init(trigger: String, text: String) {
        self.trigger = trigger
        self.text = text
    }
}

/// Reads and writes the settings file. A missing file is created with the defaults.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> DictationSettings {
        if !FileManager.default.fileExists(atPath: url.path) {
            let defaults = DictationSettings()
            try save(defaults)
            return defaults
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DictationSettings.self, from: data)
    }

    public func save(_ settings: DictationSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

/// Locations of the app's files under Application Support.
public enum AppPaths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(DemoMode.isOn ? "Library/Application Support/LocalDictation Demo"
                                                  : "Library/Application Support/LocalDictation", isDirectory: true)
    }

    public static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var historyFile: URL { supportDirectory.appendingPathComponent("history.jsonl") }
    public static var logFile: URL { supportDirectory.appendingPathComponent("app.log") }
    public static var scratchpadFile: URL { supportDirectory.appendingPathComponent("scratchpad.json") }
    public static var meetingsDirectory: URL { supportDirectory.appendingPathComponent("meetings", isDirectory: true) }
    /// The Whisper models hold no user data, so demo mode uses the same folder as normal use.
    public static var modelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalDictation/models", isDirectory: true)
    }
}


/// The connections behind "In Polarion übertragen" and the awork steps.
public struct ConnectorSettings: Codable, Equatable, Sendable {
    public enum PolarionSource: String, Codable, CaseIterable, Sendable {
        /// The `polarion-openapi` MCP server configured in Claude Code.
        case mcp
        /// The app starts the same server program with the server and PAT from its settings.
        case own
    }

    public var polarionSource: PolarionSource
    /// The Polarion server of the own connection, such as "https://polarion.example.com".
    public var polarionServer: String
    /// The program of the Polarion REST MCP server, started with Node for the own connection.
    public var polarionProgram: String
    /// awork through the awork MCP server in Claude Code instead of the app's own API client.
    public var aworkViaMCP: Bool

    /// Empty until the path of a local Polarion REST MCP server program is set in the settings.
    public static let defaultPolarionProgram = ""

    public init(polarionSource: PolarionSource = .mcp, polarionServer: String = "",
                polarionProgram: String = ConnectorSettings.defaultPolarionProgram, aworkViaMCP: Bool = false) {
        self.polarionSource = polarionSource
        self.polarionServer = polarionServer
        self.polarionProgram = polarionProgram
        self.aworkViaMCP = aworkViaMCP
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConnectorSettings()
        polarionSource = try c.decodeIfPresent(PolarionSource.self, forKey: .polarionSource) ?? d.polarionSource
        polarionServer = try c.decodeIfPresent(String.self, forKey: .polarionServer) ?? d.polarionServer
        polarionProgram = try c.decodeIfPresent(String.self, forKey: .polarionProgram) ?? d.polarionProgram
        aworkViaMCP = try c.decodeIfPresent(Bool.self, forKey: .aworkViaMCP) ?? d.aworkViaMCP
    }
}
