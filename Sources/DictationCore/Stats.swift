import Foundation

/// The figures on the home page, computed from the history.
public struct DictationStats: Equatable, Sendable {
    public var totalWords: Int
    /// Words per minute of speaking time, over the entries that recorded their audio length.
    public var wordsPerMinute: Int
    /// Days in a row with at least one dictation, ending today or yesterday.
    public var dayStreak: Int

    public init(entries: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) {
        totalWords = entries.reduce(0) { $0 + Self.wordCount($1.text) }

        let timed = entries.filter { ($0.audioSeconds ?? 0) > 0 }
        let seconds = timed.reduce(0.0) { $0 + ($1.audioSeconds ?? 0) }
        let words = timed.reduce(0) { $0 + Self.wordCount($1.text) }
        wordsPerMinute = seconds > 0 ? Int((Double(words) / seconds * 60).rounded()) : 0

        let days = Set(entries.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        dayStreak = streak
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }.count
    }
}

/// History entries grouped by calendar day, newest day first and newest entry first.
public struct HistoryDay: Identifiable, Equatable, Sendable {
    public var id: Date { day }
    public var day: Date
    public var entries: [HistoryEntry]

    public static func group(_ entries: [HistoryEntry], calendar: Calendar = .current) -> [HistoryDay] {
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            HistoryDay(day: day, entries: grouped[day]!.sorted { $0.date > $1.date })
        }
    }
}
