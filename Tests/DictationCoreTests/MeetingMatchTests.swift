import Foundation
import Testing
@testable import DictationCore

struct MeetingMatchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    @Test func meetingEightMinutesAwayAndFocusBlocksDoNotCount() {
        let candidates = [
            MeetingMatch.Candidate(start: at(-157), end: at(323), people: 1),   // focus block 9 to 17
            MeetingMatch.Candidate(start: at(-157), end: at(323), people: 3),   // a long all-day entry with people
            MeetingMatch.Candidate(start: at(8), end: at(23), people: 11),      // stand-up in eight minutes
        ]
        #expect(MeetingMatch.pick(candidates, now: now) == nil)
    }

    @Test func runningOrStartingMeetingCounts() {
        #expect(MeetingMatch.pick([MeetingMatch.Candidate(start: at(1.5), end: at(30), people: 2)], now: now) == 0)
        #expect(MeetingMatch.pick([MeetingMatch.Candidate(start: at(-20), end: at(40), people: 4)], now: now) == 0)
        let two = [MeetingMatch.Candidate(start: at(-50), end: at(10), people: 3), MeetingMatch.Candidate(start: at(1), end: at(30), people: 2)]
        #expect(MeetingMatch.pick(two, now: now) == 1)
    }
}
