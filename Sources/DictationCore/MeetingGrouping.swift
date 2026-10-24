import Foundation

/// Sorts past meetings into sections for the list: one per day or one per week, newest first.
public enum MeetingGrouping: String, CaseIterable, Sendable {
    case day, week

    public struct Section<Item>: Identifiable {
        /// The day or the first day of the week, which also identifies the section.
        public let start: Date
        public let title: String
        public let items: [Item]
        public var id: Date { start }
    }

    /// `date` gives each item's start; items keep their order inside a section.
    public func sections<Item>(_ items: [Item], date: (Item) -> Date, now: Date = Date(),
                               calendar: Calendar = .current) -> [Section<Item>] {
        var order: [Date] = []
        var buckets: [Date: [Item]] = [:]
        for item in items {
            let start = self.start(of: date(item), calendar: calendar)
            if buckets[start] == nil { order.append(start) }
            buckets[start, default: []].append(item)
        }
        return order.sorted(by: >).map { Section(start: $0, title: title(for: $0, now: now, calendar: calendar), items: buckets[$0] ?? []) }
    }

    /// Sections that get coarser with age, so years of notes stay a short list: Today,
    /// Yesterday, This week, Last week, then each earlier month of this year, then each earlier
    /// year. Newest first; empty sections are left out.
    public static func timeline<Item>(_ items: [Item], date: (Item) -> Date, now: Date = Date(),
                                      calendar: Calendar = .current) -> [Section<Item>] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        let thisYear = calendar.dateInterval(of: .year, for: now)?.start ?? today
        func bucket(_ day: Date) -> (start: Date, title: String) {
            if day >= today { return (today, "Today") }
            if day >= yesterday { return (yesterday, "Yesterday") }
            if day >= thisWeek { return (thisWeek, "This week") }
            if day >= lastWeek { return (lastWeek, "Last week") }
            if day >= thisYear {
                let month = calendar.dateInterval(of: .month, for: day)?.start ?? day
                // The month the last week reaches into only holds what is older than that week.
                return (month, month.formatted(.dateTime.month(.wide)))
            }
            let year = calendar.dateInterval(of: .year, for: day)?.start ?? day
            return (year, String(calendar.component(.year, from: day)))
        }
        var order: [Date] = []
        var titles: [Date: String] = [:]
        var buckets: [Date: [Item]] = [:]
        for item in items {
            let (start, title) = bucket(date(item))
            if buckets[start] == nil { order.append(start) }
            titles[start] = title
            buckets[start, default: []].append(item)
        }
        return order.sorted(by: >).map { Section(start: $0, title: titles[$0] ?? "", items: buckets[$0] ?? []) }
    }

    func start(of date: Date, calendar: Calendar) -> Date {
        switch self {
        case .day: return calendar.startOfDay(for: date)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    /// "Today", "Yesterday", "Monday, 19 Oct" or "This week", "Last week", "Week 41 · 5–11 Oct".
    func title(for start: Date, now: Date, calendar: Calendar) -> String {
        switch self {
        case .day:
            if calendar.isDate(start, inSameDayAs: now) { return "Today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(start, inSameDayAs: yesterday) {
                return "Yesterday"
            }
            let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
            return start.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.abbreviated)
                                            : .dateTime.weekday(.wide).day().month(.abbreviated).year())
        case .week:
            let thisWeek = self.start(of: now, calendar: calendar)
            if start == thisWeek { return "This week" }
            if let last = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek), start == last { return "Last week" }
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            let number = calendar.component(.weekOfYear, from: start)
            return "Week \(number) · \(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
        }
    }
}
