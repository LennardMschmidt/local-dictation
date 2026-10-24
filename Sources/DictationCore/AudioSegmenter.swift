import Foundation

/// Cuts long audio into pieces Whisper takes in one pass (at most 28 s), at the quietest moment
/// near each cut, so that no word is split. Silent pieces are left out.
public enum AudioSegmenter {
    public static let sampleRate = 16_000

    /// Ranges into `samples`. A cut is placed at the quietest 100 ms in the last 8 s before the
    /// maximum length.
    public static func pieces(_ samples: [Float], maxSeconds: Double = 28, searchSeconds: Double = 8,
                              silenceRMS: Float = 0.004) -> [Range<Int>] {
        let frame = sampleRate / 10
        let maxLength = Int(maxSeconds * Double(sampleRate))
        let search = Int(searchSeconds * Double(sampleRate))
        var ranges: [Range<Int>] = []
        var start = 0
        while start < samples.count {
            var end = min(samples.count, start + maxLength)
            if end < samples.count {
                var quietest = end
                var lowest = Float.greatestFiniteMagnitude
                var position = end - frame
                while position >= end - search && position > start {
                    let level = rms(samples, position..<(position + frame))
                    if level < lowest {
                        lowest = level
                        quietest = position + frame / 2
                    }
                    position -= frame
                }
                end = quietest
            }
            if rms(samples, start..<end) > silenceRMS { ranges.append(start..<end) }
            start = end
        }
        return ranges
    }

    static func rms(_ samples: [Float], _ range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var sum: Float = 0
        for index in range { sum += samples[index] * samples[index] }
        return (sum / Float(range.count)).squareRoot()
    }
}
