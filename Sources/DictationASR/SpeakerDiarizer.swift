import DictationCore
import Foundation
import SpeakerKit

/// Splits audio into speakers with SpeakerKit (pyannote on Core ML). The models download on
/// first use into the same folder as the Whisper model and stay loaded.
public actor SpeakerDiarizer {
    public let downloadBase: URL
    private var kit: SpeakerKit?

    public init(downloadBase: URL = AppPaths.modelsDirectory) {
        self.downloadBase = downloadBase
    }

    public func load() async throws {
        guard kit == nil else { return }
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        kit = try await SpeakerKit(PyannoteConfig(downloadBase: downloadBase.path, download: true, load: true, verbose: false))
    }

    /// Speaker turns in `samples` (16 kHz mono), labelled "S1", "S2", … in the order they first
    /// speak. `speakers` fixes the number of speakers when it is known.
    public func diarize(_ samples: [Float], speakers: Int? = nil) async throws -> [SpeakerTurn] {
        try await load()
        guard let kit else { return [] }
        let options = PyannoteDiarizationOptions(numberOfSpeakers: speakers)
        let result = try await kit.diarize(audioArray: samples, options: options)
        var labels: [Int: String] = [:]
        return result.segments.sorted { $0.startTime < $1.startTime }.compactMap { segment in
            guard let id = segment.speaker.speakerId else { return nil }
            let label = labels[id] ?? "S\(labels.count + 1)"
            labels[id] = label
            return SpeakerTurn(start: Double(segment.startTime), end: Double(segment.endTime), speaker: label)
        }
    }
}
