import Foundation

/// Which calendar meeting a recording started now belongs to.
///
/// Only a real meeting counts: at least two people and at most four hours long, so focus blocks
/// and day-long entries never give a note their title. It has to be running, or start within
/// two minutes; a meeting later on gets its note from the bar's meeting list instead. Of
/// several, the one whose start is closest to now.
public enum MeetingMatch {
    public struct Candidate: Sendable {
        public let start: Date
        public let end: Date
        public let people: Int

        public init(start: Date, end: Date, people: Int) {
            self.start = start
            self.end = end
            self.people = people
        }
    }

    public static let earlyStart: TimeInterval = 2 * 60
    public static let longest: TimeInterval = 4 * 60 * 60

    /// The index of the matching candidate, nil for a note without a meeting.
    public static func pick(_ candidates: [Candidate], now: Date = Date()) -> Int? {
        candidates.indices.filter { index in
            let candidate = candidates[index]
            return candidate.people >= 2 && candidate.end.timeIntervalSince(candidate.start) <= longest
                && candidate.start <= now.addingTimeInterval(earlyStart) && candidate.end > now
        }.min { abs(candidates[$0].start.timeIntervalSince(now)) < abs(candidates[$1].start.timeIntervalSince(now)) }
    }
}
