import Foundation
import Testing
@testable import DictationCore

struct SpeechPauseTests {
    static func speech(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.07) * 0.3) }
    }

    static func quiet(_ seconds: Double, level: Float = 0.001) -> [Float] {
        (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -level...level) }
    }

    @Test func pauseAfterSpeechIsFoundAndAShortGapIsNot() {
        #expect(SpeechPause.endsInPause(Self.speech(1.5) + Self.quiet(0.5)))
        #expect(!SpeechPause.endsInPause(Self.speech(1.5) + Self.quiet(0.2)))
        #expect(!SpeechPause.endsInPause(Self.speech(1.5)))
        // A long silence after the pause was handled is not a new pause.
        #expect(!SpeechPause.endsInPause(Self.speech(1.5) + Self.quiet(2.5)))
    }

    @Test func aShortWordAfterThePauseCounts() {
        let recording = Self.speech(2) + Self.quiet(0.5)
        let cut = recording.count
        #expect(SpeechPause.nothingSaid(in: recording + Self.quiet(0.6, level: 0.002), after: cut))
        #expect(!SpeechPause.nothingSaid(in: recording + Self.quiet(0.2) + Self.speech(0.15) + Self.quiet(0.3), after: cut))
    }
}
