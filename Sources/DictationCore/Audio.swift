import AVFoundation
import Foundation

public enum AudioLevel {
    /// Root mean square of the samples, 0 for an empty buffer.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Maps an RMS value to 0...1 for a level meter, on a logarithmic scale from -50 dB to 0 dB.
    public static func meterValue(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 50))
    }

    /// True when no part of the recording is louder than the threshold, so Whisper would only
    /// hallucinate. The check uses 100 ms windows so a short word in a long pause still counts.
    public static func isSilent(_ samples: [Float], threshold: Float = 0.005, window: Int = 1_600) -> Bool {
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + window)
            if rms(Array(samples[index..<end])) > threshold { return false }
            index = end
        }
        return true
    }
}

/// Converts microphone buffers in the hardware format to 16 kHz mono floats for Whisper.
public final class AudioResampler {
    public static let targetSampleRate: Double = 16_000
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    public init?(inputFormat: AVAudioFormat) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        self.converter = converter
        self.outputFormat = output
    }

    /// Converts one buffer. The converter keeps a few milliseconds back for its filter, which
    /// come out with the next buffer or with `flush()`.
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        var consumed = false
        return run(capacity: capacity) { inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
    }

    /// Returns the samples the converter still holds and resets it for the next recording.
    public func flush() -> [Float] {
        let samples = run(capacity: 4_096) { inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        converter.reset()
        return samples
    }

    private func run(capacity: AVAudioFrameCount,
                     input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) -> [Float] {
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in input(inputStatus) }
        guard status != .error, let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
