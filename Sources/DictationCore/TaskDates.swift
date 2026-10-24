import Foundation

/// Start, due date and time budget of a task as an action item says them ("bis Freitag",
/// "führt heute Abend … durch", "zwei Stunden Aufwand"), in German or English. Relative words
/// count from the day of the meeting, not from the day the task is transferred.
public struct TaskDates: Equatable, Sendable {
    public var start: Date?
    public var due: Date?
    /// The planned effort in seconds, as awork stores it.
    public var plannedSeconds: Int?

    public init(start: Date? = nil, due: Date? = nil, plannedSeconds: Int? = nil) {
        self.start = start
        self.due = due
        self.plannedSeconds = plannedSeconds
    }

    /// Reads the dates and the budget from `text`. Dates are at noon of their day, so a time
    /// zone shift on the way to awork cannot move them to the day before.
    public static func parse(_ text: String, meetingDate: Date, calendar: Calendar = .current) -> TaskDates {
        let lower = " " + text.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        let base = calendar.startOfDay(for: meetingDate)
        var result = TaskDates(plannedSeconds: budget(in: lower))

        // "von Montag bis Mittwoch", "from Monday to Wednesday": a start and a due date.
        if let range = firstMatch(#"\b(?:von|vom|from|ab|starting)\s+(.+?)\s+(?:bis(?: zum)?|to|until|till)\s+(.+?)(?=[,.;)]|\s(?:und|and|durch|erledigen)\b|$)"#, in: lower),
           let start = day(in: range[1], base: base, calendar: calendar),
           let due = day(in: range[2], base: base, calendar: calendar) {
            result.start = noon(start, calendar)
            result.due = noon(due, calendar)
            return result
        }
        // "ab Montag", "starting Monday": only a start.
        if let match = firstMatch(#"\b(?:ab|starting|beginning)\s+(.+?)(?=[,.;)]|$)"#, in: lower),
           let start = day(in: match[1], base: base, calendar: calendar) {
            result.start = noon(start, calendar)
        }
        // Anything else that names a day is when the task is due.
        let rest = result.start == nil ? lower : lower.replacingOccurrences(of: firstMatch(#"\b(?:ab|starting|beginning)\s+(.+?)(?=[,.;)]|$)"#, in: lower)?[0] ?? "", with: " ")
        if let due = day(in: rest, base: base, calendar: calendar) {
            result.due = noon(due, calendar)
        }
        return result
    }

    static func noon(_ day: Date, _ calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    // MARK: Days

    static let weekdays: [(names: [String], number: Int)] = [
        (["sonntag", "sunday"], 1), (["montag", "monday"], 2), (["dienstag", "tuesday"], 3), (["mittwoch", "wednesday"], 4),
        (["donnerstag", "thursday"], 5), (["freitag", "friday"], 6), (["samstag", "sonnabend", "saturday"], 7),
    ]

    static let months: [(names: [String], number: Int)] = [
        (["januar", "jänner", "january", "jan"], 1), (["februar", "february", "feb"], 2), (["märz", "maerz", "march", "mär", "mar"], 3),
        (["april", "apr"], 4), (["mai", "may"], 5), (["juni", "june", "jun"], 6), (["juli", "july", "jul"], 7),
        (["august", "aug"], 8), (["september", "sept", "sep"], 9), (["oktober", "october", "okt", "oct"], 10),
        (["november", "nov"], 11), (["dezember", "december", "dez", "dec"], 12),
    ]

    /// The first day the text names, counted from `base` (the meeting's day), or nil.
    static func day(in text: String, base: Date, calendar: Calendar) -> Date? {
        let text = " " + text + " "
        func add(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: base) }
        let weekday = calendar.component(.weekday, from: base)
        // Days until the Friday of the meeting's week (Saturday and Sunday look at the next one).
        let toFriday = (6 - weekday + 7) % 7

        if contains(#"\b(?:übermorgen|day after tomorrow)\b"#, text) { return add(2) }
        if contains(#"\bheute (?:morgen|früh)\b"#, text) { return base }
        if contains(#"\b(?:heute|today|tonight|this (?:morning|afternoon|evening))\b"#, text) { return base }
        // "morgen" is tomorrow, but not in "am Morgen", "jeden Morgen" or "guten Morgen".
        if contains(#"\b(?:morgen|tomorrow)\b"#, text), !contains(#"\b(?:am|jeden|guten) morgen\b"#, text) { return add(1) }
        if contains(#"\b(?:ende (?:der|dieser) woche|end of (?:the|this) week|diese woche|this week|bis wochenende)\b"#, text) {
            return add(toFriday)
        }
        if contains(#"\b(?:nächste[nr]? woche|next week|kommende[nr]? woche)\b"#, text) { return add(toFriday + 7) }
        if contains(#"\b(?:ende (?:des|dieses) monats|monatsende|end of (?:the|this) month)\b"#, text),
           let interval = calendar.dateInterval(of: .month, for: base) {
            return calendar.date(byAdding: .day, value: -1, to: interval.end)
        }
        if let match = firstMatch(#"\bin (\d+|ein(?:em|en)?|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|one|two|three|four|five|six|seven|eight|nine|ten|a) (tag|tagen|days?|woche|wochen|weeks?)\b"#, in: text),
           let count = number(match[1]) {
            let unit = match[2]
            return add(unit.hasPrefix("w") ? count * 7 : count)
        }
        if let date = explicitDate(in: text, base: base, calendar: calendar) { return date }
        for (names, number) in weekdays {
            let pattern = #"\b(?:"# + names.joined(separator: "|") + #")\b"#
            guard contains(pattern, text) else { continue }
            // The next such day after the meeting; said on that weekday it means a week later.
            let ahead = (number - weekday + 7) % 7
            return add(ahead == 0 ? 7 : ahead)
        }
        return nil
    }

    /// "15.3.", "15.03.2027", "15. März", "March 15", "15 March"; without a year the next such day.
    static func explicitDate(in text: String, base: Date, calendar: Calendar) -> Date? {
        var day = 0, month = 0, year: Int?
        if let match = firstMatch(#"\b(\d{1,2})\.(\d{1,2})\.(\d{2,4})?"#, in: text) {
            day = Int(match[1]) ?? 0
            month = Int(match[2]) ?? 0
            year = match[3].isEmpty ? nil : Int(match[3]).map { $0 < 100 ? 2000 + $0 : $0 }
        } else {
            let names = months.flatMap(\.names).sorted { $0.count > $1.count }.joined(separator: "|")
            if let match = firstMatch(#"\b(\d{1,2})\.?\s+("# + names + #")\b\.?\s*(\d{4})?"#, in: text) {
                day = Int(match[1]) ?? 0
                month = months.first { $0.names.contains(match[2]) }?.number ?? 0
                year = Int(match[3])
            } else if let match = firstMatch(#"\b("# + names + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b,?\s*(\d{4})?"#, in: text) {
                month = months.first { $0.names.contains(match[1]) }?.number ?? 0
                day = Int(match[2]) ?? 0
                year = Int(match[3])
            }
        }
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }
        let baseYear = calendar.component(.year, from: base)
        var components = DateComponents(year: year ?? baseYear, month: month, day: day)
        guard var date = calendar.date(from: components) else { return nil }
        if year == nil, date < base {
            components.year = baseYear + 1
            date = calendar.date(from: components) ?? date
        }
        return date
    }

    // MARK: Budget

    /// Seconds of effort when the text names one ("zwei Stunden", "1,5 h", "30 Minuten", "half an
    /// hour"). "in zwei Stunden" means a point in time, not an effort, and does not count.
    static func budget(in text: String) -> Int? {
        if contains(#"\b(?:eine halbe stunde|half an hour)\b"#, text), !contains(#"\bin (?:einer halben stunde|half an hour)\b"#, text) {
            return 1800
        }
        if contains(#"\b(?:anderthalb|eineinhalb) stunden\b"#, text) { return 5400 }
        let numberWords = #"\d+(?:[.,]\d+)?|ein|eine|einer|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|one|an|a|two|three|four|five|six|seven|eight|nine|ten"#
        guard let match = firstMatch(#"(?<!\bin )\b("# + numberWords + #")\s?(stunden|stunde|std\.?|h|hours?|hrs?|minuten|minute|min|minutes?)\b"#, in: text),
              let amount = decimal(match[1]) else { return nil }
        let unit = match[2]
        let seconds = unit.hasPrefix("m") ? amount * 60 : amount * 3600
        return seconds > 0 ? Int(seconds.rounded()) : nil
    }

    // MARK: Helpers

    static let numberWords: [String: Int] = [
        "ein": 1, "eine": 1, "einen": 1, "einem": 1, "einer": 1, "one": 1, "a": 1, "an": 1,
        "zwei": 2, "two": 2, "drei": 3, "three": 3, "vier": 4, "four": 4, "fünf": 5, "five": 5,
        "sechs": 6, "six": 6, "sieben": 7, "seven": 7, "acht": 8, "eight": 8, "neun": 9, "nine": 9, "zehn": 10, "ten": 10,
    ]

    static func number(_ word: String) -> Int? { Int(word) ?? numberWords[word] }

    static func decimal(_ word: String) -> Double? {
        Double(word.replacingOccurrences(of: ",", with: ".")) ?? numberWords[word].map(Double.init)
    }

    static func contains(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The whole match and its groups (empty strings for groups that did not take part).
    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
