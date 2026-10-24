@testable import DictationCore
import Foundation
import Testing

struct RecordingSpoolTests {
    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func spoolWritesOnlyNewSamples() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = TrackSpool(url: dir.appendingPathComponent("t.part"))
        var track: [Float] = [0.1, 0.2]
        spool.append(from: track)
        track += [0.3]
        spool.append(from: track)
        spool.append(from: track)
        spool.close()
        #expect(TrackSpool.read(spool.url) == [0.1, 0.2, 0.3])
        #expect(spool.written == 3)
    }

    @Test func interruptedRecordingIsRecovered() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(directory: dir)
        let meeting = Meeting(title: "Weekly", status: .recording)
        try store.save(meeting)
        let mic = TrackSpool(url: store.microphonePartURL(for: meeting.id))
        let system = TrackSpool(url: store.systemPartURL(for: meeting.id))
        mic.append(from: [Float](repeating: 0.01, count: 32_000))
        system.append(from: [Float](repeating: 0.02, count: 24_000))
        mic.close(); system.close()

        let recovered = try #require(try store.recoverInterrupted(meeting))
        #expect(recovered.duration == 2)
        #expect(recovered.interruptedAt != nil)
        #expect(recovered.status == .transcribing)
        #expect(FileManager.default.fileExists(atPath: store.microphoneURL(for: meeting.id).path))
        #expect(FileManager.default.fileExists(atPath: store.systemURL(for: meeting.id).path))
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: meeting.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.microphonePartURL(for: meeting.id).path))
        #expect(store.load().first?.interruptedAt != nil)
    }

    @Test func nothingToRecover() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try MeetingStore(directory: dir).recoverInterrupted(Meeting(title: "x")) == nil)
    }

    @Test func continuationMatchesTheSameMeeting() {
        let now = Date()
        var interrupted = Meeting(title: "Team Standup", date: now.addingTimeInterval(-1_200))
        interrupted.interruptedAt = now.addingTimeInterval(-60)
        interrupted.scheduledStart = now.addingTimeInterval(-1_500)
        var old = interrupted
        old.interruptedAt = now.addingTimeInterval(-5 * 3600)
        let done = Meeting(title: "Team Standup")
        #expect(MeetingContinuation.candidate(in: [done, old, interrupted], title: "Team Standup",
                                              scheduledStart: interrupted.scheduledStart, now: now)?.id == interrupted.id)
        #expect(MeetingContinuation.candidate(in: [interrupted], title: "Other", scheduledStart: nil, now: now) == nil)
        #expect(MeetingContinuation.candidate(in: [interrupted], title: "Team Standup",
                                              scheduledStart: now.addingTimeInterval(3_600), now: now) == nil)
        #expect(MeetingContinuation.candidate(in: [old], title: "Team Standup", scheduledStart: nil, now: now) == nil)
    }

    @Test func joinedPutsOneSecondBetween() {
        #expect(AudioMix.joined([1, 1], [2]).count == 2 + 16_000 + 1)
    }
}
