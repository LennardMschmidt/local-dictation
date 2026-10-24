import Foundation

/// Speech pauses in a recording that is still running. At a pause the whole dictation so far is
/// recognised and cleaned ahead of the release; when nothing is said after it, that result is
/// pasted and the user waits only for what was still running.
///
/// Levels are measured in 50 ms frames against the recording's own speech: a frame is quiet
/// below 12 % of the loud frames of the last ten seconds (at least 0.003), as for the stretches
/// recognised while speaking.
public enum SpeechPause {
    static let frame = 800

    /// The level under which a frame counts as quiet in this recording.
    static func quietLevel(_ samples: [Float]) -> Float {
        let start = max(0, samples.count - 160_000)
        let levels = stride(from: start, to: samples.count - frame + 1, by: frame).map {
            AudioSegmenter.rms(samples, $0..<($0 + frame))
        }.sorted()
        guard !levels.isEmpty else { return 0.003 }
        return max(0.003, levels[Int(Double(levels.count - 1) * 0.9)] * 0.12)
    }

    /// True when the recording ends with at least `seconds` of quiet right after speech.
    public static func endsInPause(_ samples: [Float], seconds: Double = 0.35) -> Bool {
        let quietFrames = Int(seconds * 16_000) / frame
        guard samples.count >= 16_000 + (quietFrames + 1) * frame else { return false }
        let quiet = quietLevel(samples)
        let end = samples.count - samples.count % frame
        for index in 1...quietFrames {
            let start = end - index * frame
            if AudioSegmenter.rms(samples, start..<(start + frame)) >= quiet { return false }
        }
        // Speech within the second before the pause, so a long silence does not count again.
        let before = end - quietFrames * frame
        return stride(from: before - 16_000, to: before, by: frame).contains {
            $0 >= 0 && AudioSegmenter.rms(samples, $0..<($0 + frame)) >= quiet * 2
        }
    }

    /// True when no frame after `index` reaches the quiet level of the recording: nothing was
    /// said after that point, not even a short word.
    public static func nothingSaid(in samples: [Float], after index: Int) -> Bool {
        guard index < samples.count else { return true }
        let quiet = quietLevel(Array(samples[..<index]))
        return !stride(from: index, to: samples.count, by: frame).contains {
            AudioSegmenter.rms(samples, $0..<min(samples.count, $0 + frame)) >= quiet
        }
    }
}
