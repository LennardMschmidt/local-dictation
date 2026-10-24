@testable import DictationCore
import Foundation
import Testing

struct MeetingGroupingTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func date(_ day: Int, _ hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func daysNewestFirstWithTodayAndYesterday() {
        let now = date(21, 15)
        let items = [date(21, 14), date(21, 13), date(20, 15), date(19), date(12)]
        let sections = MeetingGrouping.day.sections(items, date: { $0 }, now: now, calendar: calendar)
        #expect(sections.map(\.items.count) == [2, 1, 1, 1])
        #expect(sections[0].title == "Today")
        #expect(sections[1].title == "Yesterday")
        #expect(sections[0].items == [date(21, 14), date(21, 13)])
    }

    @Test func weeksStartOnMonday() {
        let now = date(21, 15)
        // 19 and 21 October 2026 share a week (Monday 19), 18 is the Sunday before.
        let sections = MeetingGrouping.week.sections([date(21), date(19), date(18), date(5)], date: { $0 }, now: now, calendar: calendar)
        #expect(sections.map(\.items.count) == [2, 1, 1])
        #expect(sections[0].title == "This week")
        #expect(sections[1].title == "Last week")
        #expect(sections[2].title.hasPrefix("Week 41"))
    }
}

struct TimelineTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 10))!
    }

    @Test func coarserWithAge() {
        // Wednesday 21 October 2026.
        let now = date(2026, 10, 21)
        let items = [date(2026, 10, 21), date(2026, 10, 20), date(2026, 10, 19), date(2026, 10, 14), date(2026, 10, 5),
                     date(2026, 9, 30), date(2026, 9, 2), date(2026, 3, 1), date(2025, 12, 1), date(2025, 1, 1), date(2024, 6, 1)]
        let sections = MeetingGrouping.timeline(items, date: { $0 }, now: now, calendar: calendar)
        #expect(sections.count == 9)
        #expect(sections.prefix(4).map(\.title) == ["Today", "Yesterday", "This week", "Last week"])
        #expect(sections.map(\.items.count) == [1, 1, 1, 1, 1, 2, 1, 2, 1])
        #expect(sections[7].title == "2025")
        #expect(sections[8].title == "2024")
    }
}
