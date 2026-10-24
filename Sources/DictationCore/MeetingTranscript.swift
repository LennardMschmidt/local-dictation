import Foundation

/// One stretch of a meeting transcript: who spoke, when, and what.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    /// Seconds from the start of the recording.
    public var start: Double
    public var end: Double
    /// `MeetingSpeakers.me` for the microphone, otherwise a label from speaker detection such
    /// as "S1". The meeting maps labels to names.
    public var speaker: String
    public var text: String
    /// Recognised language, such as "de" or "en".
    public var language: String

    public init(start: Double, end: Double, speaker: String, text: String, language: String = "") {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.language = language
    }
}

/// A time range in which one speaker talks.
public struct SpeakerTurn: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String

    public init(start: Double, end: Double, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

public enum MeetingSpeakers {
    /// The speaker label of the microphone track: the person who records.
    public static let me = "me"

    /// "Speaker 1" for "S1"; names come from the meeting's speaker names.
    public static func defaultName(for label: String, ownName: String) -> String {
        if label == me { return ownName.isEmpty ? "Me" : ownName }
        if label.hasPrefix("S"), let number = Int(label.dropFirst()) { return "Speaker \(number)" }
        return label
    }
}

/// Finds where someone speaks in a track by its loudness: 100 ms frames above a threshold set
/// from the track's own noise floor, joined across short pauses.
public enum SpeechRegions {
    public static func find(_ samples: [Float], sampleRate: Int = 16_000, minPause: Double = 0.8,
                            minLength: Double = 0.4, padding: Double = 0.2) -> [Range<Int>] {
        let frame = sampleRate / 10
        guard samples.count >= frame else { return [] }
        let levels = stride(from: 0, to: samples.count - frame + 1, by: frame).map {
            AudioSegmenter.rms(samples, $0..<($0 + frame))
        }
        // The quietest tenth of the frames is the noise floor; speech is clearly above it. When
        // someone talks almost without pause, that tenth is speech too, so the threshold also
        // stays well below the loud frames.
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        let loud = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
        let threshold = max(0.006, min(floor * 4, loud * 0.3))
        var regions: [Range<Int>] = []
        var start: Int?
        var lastLoud = 0
        let pauseFrames = Int(minPause * 10)
        for (index, level) in levels.enumerated() {
            if level > threshold {
                if start == nil { start = index }
                lastLoud = index
            } else if let begin = start, index - lastLoud > pauseFrames {
                regions.append(begin..<(lastLoud + 1))
                start = nil
            }
        }
        if let begin = start { regions.append(begin..<(lastLoud + 1)) }
        let pad = Int(padding * Double(sampleRate))
        return regions
            .filter { Double($0.count) / 10 >= minLength }
            .map { max(0, $0.lowerBound * frame - pad)..<min(samples.count, $0.upperBound * frame + pad) }
    }
}

/// Turns the two tracks of a meeting into a transcript per speaker.
///
/// The microphone track is the person recording; the system track holds everyone else and is
/// split into speakers by `diarize`. Every turn is cut at pauses into pieces Whisper takes in one
/// pass, and each piece gets its own language, so meetings that switch between languages come out
/// right.
public struct MeetingTranscriber: Sendable {
    public typealias Diarize = @Sendable ([Float]) async throws -> [SpeakerTurn]
    /// Transcribes one piece of audio. The second argument is the meeting's main language so
    /// far, for pieces too short to detect their own.
    public typealias TranscribePiece = @Sendable ([Float], String?) async throws -> Transcript

    let diarize: Diarize
    let transcribe: TranscribePiece
    let sampleRate = 16_000

    public init(diarize: @escaping Diarize, transcribe: @escaping TranscribePiece) {
        self.diarize = diarize
        self.transcribe = transcribe
    }

    /// `microphone` and `system` are aligned 16 kHz tracks. Without a system track (older
    /// recordings with both mixed), the microphone track is split into speakers instead.
    /// `skipped` receives the text of pieces left out because Whisper was unsure of them.
    /// `others` is the number of other people when the calendar knows it.
    public func transcribe(microphone: [Float], system: [Float]?, others: Int? = nil,
                           progress: @Sendable (Double) -> Void = { _ in },
                           skipped: @Sendable (String) -> Void = { _ in }) async throws -> [TranscriptSegment] {
        var turns: [SpeakerTurn] = []
        var sources: [(turn: SpeakerTurn, samples: [Float])] = []
        if let system, !system.isEmpty {
            for region in SpeechRegions.find(microphone, sampleRate: sampleRate) {
                let turn = SpeakerTurn(start: seconds(region.lowerBound), end: seconds(region.upperBound), speaker: MeetingSpeakers.me)
                turns.append(turn)
                sources.append((turn, microphone))
            }
            for turn in Self.prepare(try await diarize(system), limit: seconds(system.count)) {
                turns.append(turn)
                sources.append((turn, system))
            }
        } else {
            for turn in Self.prepare(try await diarize(microphone), limit: seconds(microphone.count)) {
                sources.append((turn, microphone))
            }
        }
        sources.sort { $0.turn.start < $1.turn.start }

        var segments: [TranscriptSegment] = []
        var wordsByLanguage: [String: Int] = [:]
        for (index, source) in sources.enumerated() {
            let range = sampleIndex(source.turn.start)..<min(source.samples.count, sampleIndex(source.turn.end))
            guard range.count > sampleRate / 4 else { continue }
            let audio = Array(source.samples[range])
            for piece in AudioSegmenter.pieces(audio, silenceRMS: 0.002) {
                let main = wordsByLanguage.filter { $0.value >= 30 }.max { $0.value < $1.value }?.key
                let result = try await transcribe(Array(audio[piece]), main)
                let text = TextProcessing.cleanTranscript(result.text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // Noise, a laugh or a cut word comes out as a short, unsure text, often with
                // letters neither German nor English has. The mean log probability of a long
                // piece can be low although the text is right, so it only counts for short ones.
                let short = piece.count < sampleRate * 6 || text.split(separator: " ").count < 10
                let start = source.turn.start + seconds(piece.lowerBound), end = source.turn.start + seconds(piece.upperBound)
                // On the microphone, a lone "Thank you" while another person talks is that
                // person's voice from the speakers, read wrongly.
                let echo = source.turn.speaker == MeetingSpeakers.me && TextProcessing.isEchoThanks(text)
                    && Self.overlapsOthers(start: start, end: end, sources: sources)
                if (result.isUnreliable && short) || !TextProcessing.isGermanOrEnglishScript(text)
                    || TextProcessing.isForeignShortPiece(text) || echo {
                    skipped(text)
                    continue
                }
                wordsByLanguage[result.language, default: 0] += text.split(separator: " ").count
                segments.append(TranscriptSegment(
                    start: start, end: end,
                    speaker: source.turn.speaker, text: text, language: result.language))
            }
            progress(Double(index + 1) / Double(sources.count))
        }
        return Self.merge(Self.absorbRareSpeakers(segments, others: others))
    }

    /// Whether another speaker's turn covers at least half of `start`…`end`.
    static func overlapsOthers(start: Double, end: Double, sources: [(turn: SpeakerTurn, samples: [Float])]) -> Bool {
        guard end > start else { return false }
        let covered = sources.filter { $0.turn.speaker != MeetingSpeakers.me }
            .reduce(0.0) { $0 + max(0, min(end, $1.turn.end) - max(start, $1.turn.start)) }
        return covered >= (end - start) / 2
    }

    /// Speaker detection sometimes makes a speaker of its own from a few seconds of noise, a
    /// laugh or a voice that sounds different for a moment. A detected speaker with less than
    /// `minimumSeconds` of speech is given to the speaker talking closest in time when it has
    /// less than 2% of the detected speech, or when the calendar names fewer other people than
    /// were detected and this speaker is one of the extra, quietest ones. In a call with exactly
    /// one other person everything on the system track is that person. The person recording is
    /// never changed, and a meeting with many real speakers keeps everyone who spoke for more
    /// than a short remark.
    static func absorbRareSpeakers(_ segments: [TranscriptSegment], others: Int? = nil,
                                   minimumSeconds: Double = 20) -> [TranscriptSegment] {
        var speech: [String: Double] = [:]
        for segment in segments where segment.speaker != MeetingSpeakers.me {
            speech[segment.speaker, default: 0] += segment.end - segment.start
        }
        let total = speech.values.reduce(0, +)
        let ranked = speech.sorted { $0.value > $1.value }.map(\.key)
        let extra = Set(others.map { ranked.dropFirst(max(1, $0)) } ?? [])
        let rare = others == 1 ? extra
            : Set(speech.filter { $0.value < minimumSeconds && ($0.value < total * 0.02 || extra.contains($0.key)) }.keys)
        guard !rare.isEmpty, rare.count < speech.count else { return segments }
        let anchors = segments.filter { $0.speaker != MeetingSpeakers.me && !rare.contains($0.speaker) }
        return segments.map { segment in
            guard rare.contains(segment.speaker) else { return segment }
            let middle = (segment.start + segment.end) / 2
            guard let nearest = anchors.min(by: { distance($0, middle) < distance($1, middle) }) else { return segment }
            var segment = segment
            segment.speaker = nearest.speaker
            return segment
        }
    }

    static func distance(_ segment: TranscriptSegment, _ time: Double) -> Double {
        time < segment.start ? segment.start - time : time > segment.end ? time - segment.end : 0
    }

    /// Turns from speaker detection, ready to transcribe: consecutive turns of one speaker with a
    /// short gap are joined, so a sentence is not cut in two, and each turn is widened a little,
    /// because detection tends to start a turn late and cut off the first word. A turn never grows
    /// into its neighbour, so no audio is transcribed twice.
    static func prepare(_ turns: [SpeakerTurn], limit: Double, joinGap: Double = 1.0,
                        before: Double = 1.0, after: Double = 0.4) -> [SpeakerTurn] {
        var joined: [SpeakerTurn] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            if var last = joined.last, last.speaker == turn.speaker, turn.start - last.end < joinGap {
                last.end = max(last.end, turn.end)
                joined[joined.count - 1] = last
            } else {
                joined.append(turn)
            }
        }
        var widened: [SpeakerTurn] = []
        for (index, turn) in joined.enumerated() {
            let previousEnd = widened.last?.end ?? 0
            let nextStart = index + 1 < joined.count ? joined[index + 1].start : limit
            widened.append(SpeakerTurn(start: max(previousEnd, turn.start - before), end: min(nextStart, turn.end + after),
                                       speaker: turn.speaker))
        }
        return widened
    }

    /// Joins consecutive segments of the same speaker that are less than `gap` seconds apart.
    public static func merge(_ segments: [TranscriptSegment], gap: Double = 2) -> [TranscriptSegment] {
        var merged: [TranscriptSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, last.speaker == segment.speaker, segment.start - last.end < gap {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                if last.language != segment.language && !segment.language.isEmpty { last.language = segment.language }
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    /// The language most words are in, for the minutes.
    public static func mainLanguage(_ segments: [TranscriptSegment]) -> String? {
        var words: [String: Int] = [:]
        for segment in segments where !segment.language.isEmpty {
            words[segment.language, default: 0] += segment.text.split(separator: " ").count
        }
        return words.max { $0.value < $1.value }?.key
    }

    /// The transcript as lines "Name: text" for the summary, with the names the meeting knows.
    public static func lines(_ segments: [TranscriptSegment], names: (String) -> String) -> String {
        segments.map { "\(names($0.speaker)): \($0.text)" }.joined(separator: "\n")
    }

    private func seconds(_ samples: Int) -> Double { Double(samples) / Double(sampleRate) }
    private func sampleIndex(_ seconds: Double) -> Int { max(0, Int(seconds * Double(sampleRate))) }
}

/// A 16 kHz track that places each block of samples at the time it was recorded, so that two
/// tracks recorded side by side stay aligned. Gaps (a stream that sent nothing while it was
/// quiet) are filled with silence.
public struct TimedTrack: Sendable {
    public private(set) var samples: [Float] = []
    let sampleRate: Double
    /// Differences below this are timing jitter and are not corrected.
    let tolerance: Int

    public init(sampleRate: Double = 16_000, toleranceSeconds: Double = 0.03) {
        self.sampleRate = sampleRate
        tolerance = Int(toleranceSeconds * sampleRate)
    }

    /// Adds `block`, recorded `seconds` after the start of the recording.
    public mutating func add(_ block: [Float], at seconds: Double) {
        let position = max(0, Int((seconds * sampleRate).rounded()))
        if position > samples.count + tolerance {
            samples.append(contentsOf: [Float](repeating: 0, count: position - samples.count))
        }
        samples.append(contentsOf: block)
    }

    /// Pads the track with silence up to `count` samples.
    public mutating func pad(to count: Int) {
        if samples.count < count { samples.append(contentsOf: [Float](repeating: 0, count: count - samples.count)) }
    }
}
