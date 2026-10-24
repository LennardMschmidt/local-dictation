import Foundation

/// What kind of app a dictation went to, for the usage breakdown.
public enum UsageCategory: String, CaseIterable, Sendable {
    case aiPrompts
    case documents
    case other
    case workMessages
    case emails
    case personalMessages

    public var title: String {
        switch self {
        case .aiPrompts: return "AI prompts"
        case .documents: return "Documents"
        case .other: return "Other tasks"
        case .workMessages: return "Work messages"
        case .emails: return "Emails"
        case .personalMessages: return "Personal messages"
        }
    }

    static let byBundleId: [String: UsageCategory] = [
        "com.anthropic.claudefordesktop": .aiPrompts,
        "com.openai.chat": .aiPrompts,
        "com.openai.codex": .aiPrompts,
        "com.microsoft.VSCode": .aiPrompts,
        "com.todesktop.230313mzl4w4u92": .aiPrompts,
        "com.apple.Terminal": .aiPrompts,
        "com.googlecode.iterm2": .aiPrompts,
        "com.mitchellh.ghostty": .aiPrompts,
        "com.cmuxterm.app": .aiPrompts,
        "dev.warp.Warp-Stable": .aiPrompts,
        "com.termius-dmg.mac": .aiPrompts,
        "ai.elementlabs.lmstudio": .aiPrompts,
        "com.microsoft.Word": .documents,
        "com.microsoft.onenote.mac": .documents,
        "com.microsoft.Powerpoint": .documents,
        "com.microsoft.Excel": .documents,
        "com.apple.iWork.Pages": .documents,
        "com.apple.TextEdit": .documents,
        "com.apple.Notes": .documents,
        "md.obsidian": .documents,
        "local.dictation.LocalDictation": .documents,
        "com.microsoft.teams2": .workMessages,
        "com.microsoft.teams": .workMessages,
        "com.tinyspeck.slackmacgap": .workMessages,
        "com.microsoft.Outlook": .emails,
        "com.apple.mail": .emails,
        "net.whatsapp.WhatsApp": .personalMessages,
        "com.apple.MobileSMS": .personalMessages,
        "ru.keepcoder.Telegram": .personalMessages,
        "org.whispersystems.signal-desktop": .personalMessages,
    ]

    public static func category(for bundleId: String?) -> UsageCategory {
        bundleId.flatMap { byBundleId[$0] } ?? .other
    }
}

/// The figures on the Insights page, computed from the history on this Mac.
public struct Insights: Sendable {
    public struct CategoryUsage: Equatable, Sendable {
        public var category: UsageCategory
        public var dictations: Int
        public var share: Double
    }

    /// Average typing speed the dictation speed is compared with.
    public static let typingWordsPerMinute = 40.0

    public var totalWords = 0
    public var wordsPerMinute = 0
    public var wordsCorrected = 0
    public var dictionaryFixes = 0
    public var appsUsed = 0
    public var categories: [CategoryUsage] = []
    public var currentStreak = 0
    public var longestStreak = 0
    /// Words dictated per calendar day (start of day).
    public var wordsPerDay: [Date: Int] = [:]

    public var languages: [(code: String, dictations: Int)] = []
    public var fillersRemoved = 0
    public var topWords: [(word: String, count: Int)] = []
    public var averageWords = 0
    /// Dictations per hour of the day, index 0 to 23.
    public var hours = Array(repeating: 0, count: 24)

    public var typingFactor: Double { Double(wordsPerMinute) / Self.typingWordsPerMinute }
    public var fixes: Int { wordsCorrected + dictionaryFixes }

    public init(entries: [HistoryEntry], vocabulary: [String] = [], replacements: [Replacement] = [],
                now: Date = Date(), calendar: Calendar = .current) {
        guard !entries.isEmpty else { return }
        let stats = DictationStats(entries: entries, now: now, calendar: calendar)
        totalWords = stats.totalWords
        wordsPerMinute = stats.wordsPerMinute
        currentStreak = stats.dayStreak

        let terms = Set(vocabulary + replacements.map(\.to)).filter { !$0.isEmpty }
        var categoryCounts: [UsageCategory: Int] = [:]
        var apps = Set<String>()
        var languageCounts: [String: Int] = [:]
        var wordCounts: [String: Int] = [:]

        for entry in entries {
            let rawWords = Self.words(entry.raw)
            let finalWords = Self.words(entry.text)
            wordsCorrected += max(0, rawWords.count - Self.commonSubsequenceLength(rawWords, finalWords))
            fillersRemoved += max(0, Self.fillerCount(rawWords) - Self.fillerCount(finalWords))
            for term in terms { dictionaryFixes += Self.occurrences(of: term, in: entry.text) }

            categoryCounts[UsageCategory.category(for: entry.bundleId), default: 0] += 1
            if let bundleId = entry.bundleId { apps.insert(bundleId) }
            if !entry.language.isEmpty { languageCounts[entry.language, default: 0] += 1 }
            hours[calendar.component(.hour, from: entry.date)] += 1
            wordsPerDay[calendar.startOfDay(for: entry.date), default: 0] += DictationStats.wordCount(entry.text)
            for word in finalWords where word.count >= 4 && !Self.stopWords.contains(word) {
                wordCounts[word, default: 0] += 1
            }
        }

        appsUsed = apps.count
        let total = Double(entries.count)
        categories = UsageCategory.allCases
            .map { CategoryUsage(category: $0, dictations: categoryCounts[$0] ?? 0, share: Double(categoryCounts[$0] ?? 0) / total) }
            .sorted { $0.dictations > $1.dictations }
        languages = languageCounts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        topWords = wordCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(10).map { ($0.key, $0.value) }
        averageWords = totalWords / entries.count
        longestStreak = Self.longestRun(of: Set(wordsPerDay.keys), calendar: calendar)
    }

    /// Lower-case words of letters and digits.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    /// Length of the longest common subsequence of two word lists: the words the cleanup kept.
    static func commonSubsequenceLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: b.count + 1)
        for x in a {
            var current = Array(repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[b.count]
    }

    static func fillerCount(_ words: [String]) -> Int {
        words.filter { fillerWords.contains($0) }.count
    }

    static func occurrences(of term: String, in text: String) -> Int {
        text.components(separatedBy: term).count - 1
    }

    static func longestRun(of days: Set<Date>, calendar: Calendar) -> Int {
        var longest = 0
        for day in days {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day), !days.contains(previous) else { continue }
            var length = 1
            var next = day
            while let following = calendar.date(byAdding: .day, value: 1, to: next), days.contains(following) {
                length += 1
                next = following
            }
            longest = max(longest, length)
        }
        return longest
    }

    static let fillerWords: Set<String> = [
        "äh", "ähm", "öhm", "hm", "hmm", "uh", "um", "uhm", "erm", "basically", "sozusagen", "halt",
    ]

    static let stopWords: Set<String> = [
        "aber", "alle", "also", "auch", "dann", "dass", "dein", "deine", "denn", "dich", "diese", "dieser",
        "doch", "eine", "einem", "einen", "einer", "haben", "hast", "hier", "ich", "ihre", "jetzt", "kann",
        "kannst", "mein", "meine", "mich", "mir", "mit", "muss", "nach", "nicht", "noch", "oder", "schon",
        "sein", "sich", "sind", "über", "und", "uns", "unser", "vielleicht", "noch", "wenn", "werden", "wieder",
        "wird", "wir", "wollen", "würde", "habe", "gibt", "dass", "einfach", "eben", "heute", "morgen", "gerade",
        "about", "after", "also", "been", "because", "could", "does", "from", "have", "here", "into", "just",
        "like", "more", "need", "only", "really", "should", "some", "than", "that", "their", "them", "then",
        "there", "these", "they", "this", "what", "when", "which", "will", "with", "would", "your",
    ]
}
