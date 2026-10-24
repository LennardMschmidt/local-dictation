import Foundation

/// Recognition while the user is still speaking: finished stretches of a long dictation are cut
/// at a speech pause and transcribed during the recording, so after fn is released only the last
/// stretch is left. Cutting only at pauses keeps words whole.
public enum EarlyRecognition {
    static let frame = 800 // 50 ms at 16 kHz

    /// Where to cut the recording after `start`: in the middle of the last pause of at least
    /// `minPause` seconds that leaves a stretch of at least `minChunk` seconds, or nil.
    public static func cut(in samples: [Float], from start: Int, minChunk: Double = 8, minPause: Double = 0.45) -> Int? {
        let earliest = start + Int(minChunk * 16_000)
        // The newest half second may still be a word starting; it is never cut into.
        let latest = samples.count - 8_000
        guard latest > earliest else { return nil }
        let levels = stride(from: start, to: latest - frame, by: frame).map { index in
            (index, AudioLevel.rms(Array(samples[index..<(index + frame)])))
        }
        guard !levels.isEmpty else { return nil }
        let sorted = levels.map(\.1).sorted()
        let loud = sorted[Int(Double(sorted.count - 1) * 0.9)]
        let quiet = max(0.003, loud * 0.12)
        let needed = Int(minPause * 16_000) / frame
        var best: Int?
        var run = 0
        for (index, level) in levels {
            if level < quiet {
                run += 1
                if run >= needed {
                    let middle = index - (run / 2) * frame
                    if middle >= earliest { best = middle }
                }
            } else {
                run = 0
            }
        }
        return best
    }
}

/// Stretches of a dictation already recognised during the recording.
public struct EarlyTranscript: Sendable {
    public var texts: [String] = []
    public var language: String?
    /// The sample index up to which the recording is recognised.
    public var end = 0
    public init() {}
}
