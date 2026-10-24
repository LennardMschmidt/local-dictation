import Foundation
import Testing
@testable import DictationCore

struct TaskDatesTests {
    /// Wednesday, 21 October 2026, in Berlin.
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
    var meeting: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 30))! }

    func day(_ text: String) -> String? {
        TaskDates.parse(text, meetingDate: meeting, calendar: calendar).due.map(format)
    }

    func format(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d-%02d-%02d %02d", parts.year!, parts.month!, parts.day!, parts.hour!)
    }

    @Test func relativeDaysCountFromTheMeeting() {
        #expect(day("Jonas Weber führt heute Abend das Litware-Update des Coordinators durch") == "2026-10-21 12")
        #expect(day("Paul schickt die Testergebnisse (bis morgen)") == "2026-10-22 12")
        #expect(day("Anna prüft das übermorgen") == "2026-10-23 12")
        #expect(day("Send the report tomorrow") == "2026-10-22 12")
        #expect(day("Ich habe das heute Morgen gesehen") == "2026-10-21 12")
        #expect(day("Wir sprechen jeden Morgen kurz") == nil)
    }

    @Test func weekdaysAndWeeks() {
        #expect(day("Paul schickt die Testergebnisse (bis Freitag)") == "2026-10-23 12")
        #expect(day("Review am Mittwoch") == "2026-10-28 12")  // said on a Wednesday: next week's
        #expect(day("bis Ende der Woche") == "2026-10-23 12")
        #expect(day("nächste Woche fertig") == "2026-10-30 12")
        #expect(day("in zwei Wochen") == "2026-11-04 12")
        #expect(day("bis Ende des Monats") == "2026-10-31 12")
    }

    @Test func explicitDates() {
        #expect(day("Abgabe am 15.11.") == "2026-11-15 12")
        #expect(day("Abgabe am 15. März") == "2027-03-15 12")  // already past this year
        #expect(day("due March 3rd") == "2027-03-03 12")
        #expect(day("Termin 03.12.2026") == "2026-12-03 12")
    }

    @Test func startAndDue() {
        let both = TaskDates.parse("Migration von Montag bis Mittwoch", meetingDate: meeting, calendar: calendar)
        #expect(both.start.map(format) == "2026-10-26 12")
        #expect(both.due.map(format) == "2026-10-28 12")
        let start = TaskDates.parse("Tests ab Montag", meetingDate: meeting, calendar: calendar)
        #expect(start.start.map(format) == "2026-10-26 12")
        #expect(start.due == nil)
    }

    @Test func budgets() {
        #expect(TaskDates.parse("Aufwand etwa zwei Stunden", meetingDate: meeting).plannedSeconds == 7200)
        #expect(TaskDates.parse("1,5 h für das Review", meetingDate: meeting).plannedSeconds == 5400)
        #expect(TaskDates.parse("30 Minuten Abstimmung", meetingDate: meeting).plannedSeconds == 1800)
        #expect(TaskDates.parse("about half an hour", meetingDate: meeting).plannedSeconds == 1800)
        #expect(TaskDates.parse("Ich melde mich in zwei Stunden", meetingDate: meeting).plannedSeconds == nil)
        #expect(TaskDates.parse("Update des Coordinators (Multi-Instance)", meetingDate: meeting) == TaskDates())
    }
}
