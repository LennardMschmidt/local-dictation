import AppKit
import AVFoundation
import AudioToolbox
import Combine
import DictationASR
import DictationCore
import ScreenCaptureKit

/// Records a meeting: the microphone through AVAudioEngine and the system audio (the other
/// participants) through ScreenCaptureKit, as two 16 kHz mono tracks. Every block is placed at
/// the host time it was recorded, so the tracks stay aligned even when the system audio stream
/// pauses while nothing plays.
///
/// System audio needs the Screen Recording permission. Without it only the microphone is
/// recorded and `systemAudioAvailable` stays false.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var onLevel: ((Float) -> Void)?
    /// The level of the other participants (system audio), for the meter "Others".
    var onSystemLevel: ((Float) -> Void)?
    private(set) var systemAudioAvailable = false
    /// UID of the microphone to use; empty means auto-detect (see `AudioDevices.resolve`).
    var preferredDeviceUID = ""

    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "local.dictation.LocalDictation.meeting")
    private var configurationObserver: NSObjectProtocol?
    private var recording = false
    private var watchdog: Timer?
    /// Host time in seconds of the last microphone block; read on the main thread by the watchdog.
    private var lastMicrophoneBlock: Double = 0
    /// Host time in seconds of the last block that was not pure digital silence. A real
    /// microphone always has some noise, so only zeros mean it is not really recording.
    private var lastMicrophoneSound: Double = 0
    private var lastRestart: Double = 0
    /// The microphone restart that is running, if any. Restarts run off the main thread, because
    /// CoreAudio can block while a Bluetooth headset switches profiles; a restart that does not
    /// come back is given up after a few seconds and a later one starts on a fresh queue.
    private var restartInProgress: UUID?
    /// A restart waiting for the device switch to settle (see the configuration observer).
    private var pendingRestart: DispatchWorkItem?
    /// Restarts in a row that brought no sound; after two, the system default input is used.
    private var silentRestarts = 0
    /// Set when the chosen microphone stays silent and the system default input is used instead.
    private var useSystemDefault = false
    private var resampler: AudioResampler?
    private var systemResampler: AudioResampler?
    private var systemFormat: AVAudioFormat?
    private var microphone = TimedTrack()
    private var system = TimedTrack()
    /// Host time in seconds when the recording started; both tracks count from here.
    private var startSeconds: Double = 0
    private var stream: SCStream?
    /// Files both tracks are written to every second while recording, so a recording that
    /// never reaches `stop` keeps its audio (see `MeetingStore.recoverInterrupted`).
    var spool: (microphone: TrackSpool, system: TrackSpool)?
    private var spoolTimer: DispatchSourceTimer?

    /// The two tracks when the recording stopped.
    struct Tracks {
        var microphone: [Float]
        var system: [Float]?
    }

    func start() async throws {
        queue.sync {
            microphone = TimedTrack()
            system = TimedTrack()
            systemResampler = nil
            systemFormat = nil
        }
        startSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        useSystemDefault = false
        silentRestarts = 0
        lastRestart = 0
        do {
            (engine, resampler) = try makeMicrophone(useSystemDefault: useSystemDefault, preferredDeviceUID: preferredDeviceUID)
        } catch {
            // The chosen microphone did not start (no format while a call switches devices);
            // the system default records instead, rather than no meeting at all.
            AppLog.error("meeting microphone failed (\(error)), using the system default")
            useSystemDefault = true
            (engine, resampler) = try makeMicrophone(useSystemDefault: true, preferredDeviceUID: preferredDeviceUID)
        }
        recording = true
        if spool != nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.writeSpool() }
            timer.resume()
            spoolTimer = timer
        }
        // A call that starts after the recording (Teams switching the headset to call mode, a
        // new default device) stops every running audio engine; the microphone then restarts
        // on a fresh engine and the track continues at the right time.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.recording else { return }
            // A headset that connects or switches to call mode sends several changes in a row;
            // the restart waits until they have settled.
            self.pendingRestart?.cancel()
            let restart = DispatchWorkItem { [weak self] in
                guard let self, self.recording, !self.engine.isRunning else { return }
                self.restartMicrophone(reason: "audio configuration changed")
            }
            self.pendingRestart = restart
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: restart)
        }
        // Also when the engine stops without telling, or delivers nothing for a while.
        lastMicrophoneBlock = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        lastMicrophoneSound = lastMicrophoneBlock
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.recording, self.restartInProgress == nil else { return }
            let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            let noBlocks = now - self.lastMicrophoneBlock
            let onlyZeros = now - self.lastMicrophoneSound
            if !self.engine.isRunning {
                self.restartMicrophone(reason: "audio engine stopped")
            } else if noBlocks > 3 {
                self.restartMicrophone(reason: "no microphone audio for \(Int(noBlocks)) s")
            } else if onlyZeros > 5 {
                self.restartMicrophone(reason: "microphone delivered only silence for \(Int(onlyZeros)) s")
            }
        }
        MicrophoneShare.shared.setOpen(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.recording else { return }
            let (mic, other) = self.queue.sync { (Array(self.microphone.samples.suffix(16_000 * 5)), Array(self.system.samples.suffix(16_000 * 5))) }
            AppLog.info(String(format: "meeting levels after 10 s: microphone %.0f dB, system %.0f dB",
                               20 * log10(Double(AudioLevel.rms(mic)) + 1e-9), 20 * log10(Double(AudioLevel.rms(other)) + 1e-9)))
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return }
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.sampleRate = 16_000
            configuration.channelCount = 1
            configuration.excludesCurrentProcessAudio = true
            // Video cannot be switched off; a tiny frame once a second costs next to nothing.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                  configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            systemAudioAvailable = true
        } catch {
            AppLog.error("system audio not available, recording the microphone only: \(error)")
            systemAudioAvailable = false
        }
    }

    /// A restart now, regardless of the last one; for the `--mic-restart-test` check.
    func forceMicrophoneRestart(reason: String) {
        lastRestart = 0
        restartMicrophone(reason: reason)
    }

    private func restartMicrophone(reason: String) {
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        guard restartInProgress == nil, now - lastRestart > 20 else { return }
        lastRestart = now
        if reason.contains("only silence") {
            silentRestarts += 1
            if silentRestarts >= 2 && !useSystemDefault {
                useSystemDefault = true
                AppLog.info("chosen microphone stays silent, switching to the system default input")
            }
        }
        AppLog.info("\(reason) during the meeting, restarting the microphone")
        let attempt = UUID()
        restartInProgress = attempt
        let old = engine
        let oldResampler = resampler
        let useDefault = useSystemDefault
        let deviceUID = preferredDeviceUID
        lastMicrophoneBlock = now
        lastMicrophoneSound = now
        // A queue of its own for each attempt, so one that hangs in CoreAudio blocks nothing else.
        DispatchQueue(label: "local.dictation.LocalDictation.meeting.restart").async { [weak self] in
            guard let self else { return }
            old.inputNode.removeTap(onBus: 0)
            old.stop()
            if let oldResampler {
                self.queue.sync { self.microphone.add(oldResampler.flush(), at: Double(self.microphone.samples.count) / 16_000) }
            }
            let result = Result { try self.makeMicrophone(useSystemDefault: useDefault, preferredDeviceUID: deviceUID) }
            DispatchQueue.main.async {
                guard self.restartInProgress == attempt, self.recording else {
                    // Given up on, or the meeting ended meanwhile: this engine must not keep running.
                    if case .success(let (late, _)) = result {
                        late.inputNode.removeTap(onBus: 0)
                        late.stop()
                    }
                    return
                }
                self.restartInProgress = nil
                switch result {
                case .success(let (engine, resampler)):
                    self.engine = engine
                    self.resampler = resampler
                    self.lastMicrophoneBlock = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                    self.lastMicrophoneSound = self.lastMicrophoneBlock
                case .failure(let error):
                    AppLog.error("microphone could not be restarted: \(error)")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.restartInProgress == attempt else { return }
            self.restartInProgress = nil
            AppLog.error("microphone restart did not come back within 5 s; the watchdog tries again on a fresh engine")
        }
    }

    /// A started microphone on a fresh engine whose blocks go into the microphone track. Changes
    /// nothing on `self` except through the tap, so it can run off the main thread; the caller
    /// keeps the engine and the resampler.
    private func makeMicrophone(useSystemDefault: Bool, preferredDeviceUID: String) throws -> (AVAudioEngine, AudioResampler) {
        let engine = AVAudioEngine()
        let chosen = useSystemDefault ? nil : AudioDevices.resolve(uid: preferredDeviceUID, avoidBluetooth: false)
        let systemDefault = AudioDevices.defaultInput()
        AppLog.info("meeting microphone: \(chosen?.name ?? systemDefault?.name ?? "none")"
                    + " (system default \(systemDefault?.name ?? "none"))")
        if let device = chosen,
           device.deviceID != systemDefault?.deviceID,
           let unit = engine.inputNode.audioUnit {
            var id = device.deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let input = engine.inputNode
        guard let format = AudioRecorder.tapFormat(input), let resampler = AudioResampler(inputFormat: format) else {
            throw AudioRecorder.RecorderError.noInputDevice
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, when in
            guard let self, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            let at = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) - self.startSeconds : nil
            let arrived = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            let channel = copy.floatChannelData?[0]
            let sound = channel.map { data in (0..<Int(copy.frameLength)).contains { data[$0] != 0 } } ?? true
            DispatchQueue.main.async {
                self.lastMicrophoneBlock = arrived
                if sound {
                    self.lastMicrophoneSound = arrived
                    self.silentRestarts = 0
                }
            }
            self.queue.async {
                let converted = resampler.convert(copy)
                if let at {
                    self.microphone.add(converted, at: at)
                } else {
                    self.microphone.add(converted, at: Double(self.microphone.samples.count) / 16_000)
                }
                MicrophoneShare.shared.publish(converted)
                let level = AudioLevel.meterValue(rms: AudioLevel.rms(converted))
                DispatchQueue.main.async { self.onLevel?(level) }
            }
        }
        engine.prepare()
        try engine.start()
        return (engine, resampler)
    }

    /// Writes what both tracks gained since the last write. Runs on `queue`.
    private func writeSpool() {
        spool?.microphone.append(from: microphone.samples)
        spool?.system.append(from: system.samples)
    }

    /// The last `seconds` of both tracks while recording, for the live help.
    func recent(seconds: Double) -> Tracks {
        let count = Int(seconds * 16_000)
        return queue.sync {
            let total = max(microphone.samples.count, system.samples.count)
            let start = max(0, total - count)
            func tail(_ samples: [Float]) -> [Float] { samples.count > start ? Array(samples[start...]) : [] }
            return Tracks(microphone: tail(microphone.samples), system: tail(system.samples))
        }
    }

    /// Stops both sources and returns the two tracks, padded to the same length.
    func stop() async -> Tracks {
        recording = false
        pendingRestart?.cancel()
        pendingRestart = nil
        watchdog?.invalidate()
        watchdog = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        MicrophoneShare.shared.setOpen(false)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        let hasSystem = systemAudioAvailable
        spoolTimer?.cancel()
        spoolTimer = nil
        return queue.sync {
            if let resampler { microphone.add(resampler.flush(), at: Double(microphone.samples.count) / 16_000) }
            writeSpool()
            spool?.microphone.close()
            spool?.system.close()
            let length = max(microphone.samples.count, system.samples.count)
            microphone.pad(to: length)
            guard hasSystem else { return Tracks(microphone: microphone.samples, system: nil) }
            system.pad(to: length)
            return Tracks(microphone: microphone.samples, system: system.samples)
        }
    }

    /// Both tracks laid over each other, for listening back.
    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        AudioMix.mix(a, b)
    }

    /// System audio in the format ScreenCaptureKit delivers (usually 48 kHz), converted to
    /// 16 kHz mono and placed at its presentation time. Runs on `queue`.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        if systemFormat == nil {
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            systemFormat = format
            systemResampler = AudioResampler(inputFormat: format)
            AppLog.info("system audio format: \(Int(format.sampleRate)) Hz, \(format.channelCount) channels")
        }
        guard let format = systemFormat, let resampler = systemResampler else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let at = presentation.isValid ? CMTimeGetSeconds(presentation) - startSeconds : Double(system.samples.count) / 16_000
        let converted = resampler.convert(buffer)
        system.add(converted, at: at)
        let level = AudioLevel.meterValue(rms: AudioLevel.rms(converted))
        DispatchQueue.main.async { self.onSystemLevel?(level) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppLog.error("system audio stream stopped: \(error)")
    }
}

/// Starts and stops meeting recordings and turns them into transcripts and summaries.
final class NotetakerController: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var systemAudio = true
    /// Between stopping and having the recording saved ("Finishing up…").
    @Published private(set) var isFinishing = false
    /// How far the processing of a meeting is, 0 to 1, while it runs: speaker detection and
    /// transcription take the first 75%, the polishing pass up to 85%, the notes the rest.
    @Published private(set) var progress: [UUID: Double] = [:]

    var onRecordingChange: ((Bool) -> Void)?
    var onFinished: ((Meeting) -> Void)?

    private let store: MeetingStore
    private let transcriber: WhisperTranscriber
    /// The dictation controller's accurate model, reused for meetings so it is loaded only once.
    private let longTranscriber: WhisperTranscriber?
    /// Splits the other participants into speakers; its models load on the first meeting.
    private let diarizer = SpeakerDiarizer()
    private let settings: () -> DictationSettings
    private var recorder: MeetingRecorder?
    private var current: Meeting?
    private var started: Date?
    private var timer: Timer?

    init(transcriber: WhisperTranscriber, longTranscriber: WhisperTranscriber? = nil, directory: URL = AppPaths.meetingsDirectory,
         resumePending: Bool = true, settings: @escaping () -> DictationSettings) {
        self.transcriber = transcriber
        self.longTranscriber = longTranscriber
        self.settings = settings
        store = MeetingStore(directory: directory)
        meetings = store.load()
        // A meeting that was still processing when the app quit gets finished now. One still
        // "recording" never reached Stop: its audio comes from the files written while recording.
        guard resumePending else { return }
        for meeting in meetings where meeting.status == .transcribing || meeting.status == .summarizing {
            process(meeting)
        }
        for meeting in meetings where meeting.status == .recording {
            recover(meeting)
        }
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    /// A recording the app quit during: its audio up to the last second goes to the meeting's
    /// files and is processed as usual; without any audio the meeting is marked as lost.
    private func recover(_ meeting: Meeting) {
        do {
            if let recovered = try store.recoverInterrupted(meeting) {
                AppLog.info(String(format: "meeting recovered after an interruption: %.1f min", recovered.duration / 60))
                save(recovered)
                process(recovered)
                return
            }
        } catch {
            AppLog.error("interrupted meeting not recovered: \(error)")
        }
        if FileManager.default.fileExists(atPath: store.audioURL(for: meeting.id).path) {
            process(meeting)
            return
        }
        var lost = meeting
        lost.status = .failed
        lost.problem = "The app quit before any audio of this recording was written."
        save(lost)
        AppLog.error("interrupted meeting had no audio to recover")
    }

    /// The calendar meeting happening now, for a note started without one.
    var currentMeeting: (() -> CalendarService.Event?)?

    /// Starts a note for `event`, or for the calendar meeting happening now; `title` is used when
    /// there is no meeting.
    /// `matchCalendar` false keeps a quick note free of any calendar meeting.
    /// `continuing` nil asks whether to continue an interrupted recording of the same meeting;
    /// true or false decides without asking.
    func start(title: String = "", event: CalendarService.Event? = nil, matchCalendar: Bool = true, continuing: Bool? = nil) {
        guard !isRecording, !isFinishing else { return }
        let event = event ?? (title.isEmpty && matchCalendar ? currentMeeting?() : nil)
        let recorder = MeetingRecorder()
        recorder.preferredDeviceUID = settings().microphoneUID
        recorder.onLevel = { [weak self] level in self?.level = level }
        recorder.onSystemLevel = { [weak self] level in self?.systemLevel = level }
        self.recorder = recorder
        var meeting = Meeting(title: event?.title ?? title)
        if let event {
            meeting.participants = event.participants
            meeting.organizer = event.organizer
            meeting.scheduledStart = event.start
            meeting.scheduledEnd = event.end
            AppLog.info("note for a calendar meeting with \(event.participants.count) invited")
        }
        if continuing != false,
           let earlier = MeetingContinuation.candidate(in: meetings, title: meeting.title, scheduledStart: meeting.scheduledStart),
           continuing == true || Self.askToContinue(earlier) {
            meeting.continues = earlier.id
            AppLog.info("recording continues an interrupted one")
        }
        // Saved at once with the files the tracks are written to, so the app can recover the
        // audio if it quits before Stop.
        recorder.spool = (TrackSpool(url: store.microphonePartURL(for: meeting.id)), TrackSpool(url: store.systemPartURL(for: meeting.id)))
        save(meeting)
        current = meeting
        isRecording = true
        onRecordingChange?(true)
        started = Date()
        elapsed = 0
        let maximum = TimeInterval(max(1, settings().notetakerMaxMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let started = self.started else { return }
            self.elapsed = Date().timeIntervalSince(started)
            if self.elapsed >= maximum {
                AppLog.info("meeting reached the maximum length, stopping")
                self.stop()
            }
        }
        Task {
            do {
                try await recorder.start()
                await MainActor.run { self.systemAudio = recorder.systemAudioAvailable }
                AppLog.info("meeting recording started, system audio \(recorder.systemAudioAvailable ? "on" : "off")")
            } catch {
                AppLog.error("meeting recording failed to start: \(error)")
                await MainActor.run {
                    self.store.delete(meeting.id)
                    self.meetings.removeAll { $0.id == meeting.id }
                    self.reset()
                }
            }
        }
    }

    func stop() {
        guard isRecording, let recorder, var meeting = current else { return }
        timer?.invalidate()
        isRecording = false
        isFinishing = true
        onRecordingChange?(false)
        Task {
            var tracks = await recorder.stop()
            // A continuation is joined to the interrupted recording before it; both become this meeting.
            var replaced: Meeting?
            if let earlierID = meeting.continues, let earlier = self.meetings.first(where: { $0.id == earlierID }) {
                tracks = self.joined(earlier: earlier, with: tracks)
                meeting.date = earlier.date
                if meeting.participants.isEmpty { meeting.participants = earlier.participants }
                meeting.organizer = meeting.organizer ?? earlier.organizer
                meeting.scheduledStart = meeting.scheduledStart ?? earlier.scheduledStart
                meeting.scheduledEnd = meeting.scheduledEnd ?? earlier.scheduledEnd
                meeting.notes = [earlier.notes, meeting.notes].filter { !$0.isEmpty }.joined(separator: "\n\n")
                replaced = earlier
            }
            meeting.continues = nil
            meeting.duration = Double(tracks.microphone.count) / 16_000
            meeting.status = .transcribing
            do {
                // The two tracks keep who spoke apart; the mix is for listening back.
                try WAVFile.write(samples: tracks.microphone, sampleRate: 16_000, to: store.microphoneURL(for: meeting.id))
                if let system = tracks.system {
                    try WAVFile.write(samples: system, sampleRate: 16_000, to: store.systemURL(for: meeting.id))
                }
                try WAVFile.write(samples: MeetingRecorder.mix(tracks.microphone, tracks.system ?? []), sampleRate: 16_000,
                                  to: store.audioURL(for: meeting.id))
                // The audio files are complete, the files written while recording are not needed.
                store.removeParts(meeting.id)
                AppLog.info(String(format: "meeting saved: %.1f min, system audio %@%@", meeting.duration / 60,
                                   tracks.system == nil ? "missing" : "on its own track", replaced == nil ? "" : ", joined to the interrupted part"))
            } catch {
                AppLog.error("meeting audio not saved: \(error)")
            }
            if let replaced {
                await MainActor.run {
                    self.store.delete(replaced.id)
                    self.meetings.removeAll { $0.id == replaced.id }
                }
            }
            let finished = meeting
            await MainActor.run {
                self.isFinishing = false
                self.save(finished)
                self.reset()
                self.process(finished)
            }
        }
    }

    /// The interrupted recording's saved tracks, one second of silence, then the new ones.
    private func joined(earlier: Meeting, with tracks: MeetingRecorder.Tracks) -> MeetingRecorder.Tracks {
        let micURL = store.microphoneURL(for: earlier.id)
        let oldMic = (try? AudioFile.loadSamples(path: (FileManager.default.fileExists(atPath: micURL.path) ? micURL : store.audioURL(for: earlier.id)).path)) ?? []
        let oldSystem = (try? AudioFile.loadSamples(path: store.systemURL(for: earlier.id).path)) ?? []
        let microphone = AudioMix.joined(oldMic, tracks.microphone)
        guard tracks.system != nil || !oldSystem.isEmpty else { return MeetingRecorder.Tracks(microphone: microphone, system: nil) }
        let firstSystem = oldSystem.isEmpty ? [Float](repeating: 0, count: oldMic.count) : oldSystem + [Float](repeating: 0, count: max(0, oldMic.count - oldSystem.count))
        let secondSystem = tracks.system ?? [Float](repeating: 0, count: tracks.microphone.count)
        return MeetingRecorder.Tracks(microphone: microphone, system: AudioMix.joined(firstSystem, secondSystem))
    }

    /// Asks whether the new recording continues the interrupted one of the same meeting.
    /// Called from the UI and the hotkey, always on the main thread.
    private static func askToContinue(_ earlier: Meeting) -> Bool {
        MainActor.assumeIsolated { runContinueAlert(earlier) }
    }

    @MainActor private static func runContinueAlert(_ earlier: Meeting) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Continue „\(earlier.title)“?"
        let time = earlier.interruptedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        alert.informativeText = "The recording of this meeting was interrupted at \(time). Continue it, and both parts become one note with one transcript."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "New note")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What was said in the last `seconds` of the running recording, as "Ich:" and "Andere:"
    /// lines in order, transcribed with the fast model; nil when nothing is recording.
    func liveTranscript(seconds: Double = 120) async -> String? {
        guard isRecording, let recorder else { return nil }
        let tracks = recorder.recent(seconds: seconds)
        let languages = settings().languages.isEmpty ? ["de", "en"] : settings().languages
        let transcriber = self.transcriber
        var lines: [(start: Int, text: String)] = []
        for (label, samples) in [("Ich", tracks.microphone), ("Andere", tracks.system ?? [])] where !samples.isEmpty {
            for region in SpeechRegions.find(samples) {
                guard let result = try? await transcriber.transcribePiece(samples: Array(samples[region]), languages: languages, vocabulary: []),
                      !result.isUnreliable else { continue }
                let text = TextProcessing.cleanTranscript(result.text)
                if !text.isEmpty { lines.append((region.lowerBound, "\(label): \(text)")) }
            }
        }
        return lines.sorted { $0.start < $1.start }.map(\.text).joined(separator: "\n")
    }

    /// The settings as they are now, for views that need the AI engines.
    var currentSettings: DictationSettings { settings() }

    /// The first name of the Mac's user, shown for the microphone track.
    static var ownName: String {
        DemoMode.fullUserName.split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    /// Writes the transcript text again after speakers were renamed, so search, the summary and
    /// the vault note use the names.
    /// The notes and action items take the new name as well.
    func rename(speaker label: String, to name: String, in meeting: Meeting) {
        var meeting = meeting
        let old = meeting.name(for: label, ownName: Self.ownName)
        meeting.speakerNames[label] = name.trimmingCharacters(in: .whitespaces)
        let named = meeting
        meeting.transcript = MeetingTranscriber.lines(meeting.segments) { named.name(for: $0, ownName: Self.ownName) }
        let new = meeting.name(for: label, ownName: Self.ownName)
        if old != new, !old.isEmpty {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: old) + "\\b"
            let replace = { (text: String) in
                text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: new), options: .regularExpression)
            }
            meeting.notesMarkdown = replace(meeting.notesMarkdown)
            meeting.summary = replace(meeting.summary)
            meeting.actionItems = meeting.actionItems.map(replace)
            meeting.completedActions = meeting.completedActions.map(replace)
            meeting.aworkTasks = Dictionary(meeting.aworkTasks.map { (replace($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        save(meeting)
        exportToVault(meeting)
    }

    /// Writes a finished meeting into the vault, where the tl;dv sync keeps its meetings.
    func exportToVault(_ meeting: Meeting) {
        let path = settings().meetingVault.trimmingCharacters(in: .whitespaces)
        // Recordings started by the test control are test material, not meetings.
        guard !path.isEmpty, meeting.status == .done, meeting.title != "LocalDictation test recording" else { return }
        let vault = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: vault.path) else {
            AppLog.error("vault not found at \(vault.path), meeting not exported")
            return
        }
        let map = CustomerRouting.loadMap(from: CustomerRouting.mapFile)
        do {
            let result = try VaultMeetingExport(vault: vault, customerMap: map).write(meeting, ownName: Self.ownName)
            AppLog.info("meeting written to the vault: \(result.path) (customer: \(result.customerLink))")
        } catch {
            AppLog.error("meeting not written to the vault: \(error)")
        }
    }

    /// Transcribes and summarises a meeting from its saved recording.
    func process(_ meeting: Meeting) {
        var meeting = meeting
        let audio = store.audioURL(for: meeting.id)
        let settings = settings()
        Task {
            do {
                meeting.status = .transcribing
                let transcribing = meeting
                let id = meeting.id
                await MainActor.run {
                    self.progress[id] = 0.02
                    self.save(transcribing)
                }
                // Separate tracks keep "me" and the others apart; older recordings only have the mix.
                let microphoneFile = store.microphoneURL(for: meeting.id)
                let systemFile = store.systemURL(for: meeting.id)
                let hasTracks = FileManager.default.fileExists(atPath: microphoneFile.path)
                let microphone = try AudioFile.loadSamples(path: (hasTracks ? microphoneFile : audio).path)
                let system = hasTracks && FileManager.default.fileExists(atPath: systemFile.path)
                    ? try AudioFile.loadSamples(path: systemFile.path) : nil
                // A microphone track without a single audible sample while the others talked
                // means the microphone delivered nothing; the notes then only know the others.
                let micPeak = hasTracks ? microphone.reduce(Float(0)) { max($0, abs($1)) } : 1
                meeting.warning = micPeak < 0.001 && !(system.map { AudioLevel.isSilent($0) } ?? true)
                    ? "Your microphone recorded nothing in this meeting, so only the other participants are in the transcript and the notes."
                    : ""
                let languages = settings.languages.isEmpty ? ["de", "en"] : settings.languages
                let vocabulary = settings.vocabularyByPriority
                // Meetings use the more accurate model; dictation keeps the fast one.
                let transcriber = settings.asr.meetingModel == settings.asr.model ? self.transcriber
                    : self.longTranscriber?.modelName == settings.asr.meetingModel ? self.longTranscriber!
                    : WhisperTranscriber(modelName: settings.asr.meetingModel)
                let diarizer = self.diarizer
                let pipeline = MeetingTranscriber(
                    diarize: { try await diarizer.diarize($0) },
                    transcribe: { piece, main in
                        try await transcriber.transcribePiece(samples: piece, languages: languages, preferred: main, vocabulary: vocabulary)
                    })
                let started = Date()
                let matcher = VocabularyMatcher(vocabulary)
                meeting.segments = try await pipeline.transcribe(microphone: microphone, system: system,
                                                                    others: meeting.participants.count >= 2 ? meeting.participants.count - 1 : nil,
                                                                    progress: { value in
                                                                        DispatchQueue.main.async { self.progress[id] = 0.05 + value * 0.7 }
                                                                    }).map { segment in
                    var segment = segment
                    segment.text = matcher.correct(segment.text)
                    return segment
                }
                if settings.asr.polishMeetingTranscript, settings.llm.enabled, !meeting.segments.isEmpty {
                    let polishStarted = Date()
                    let client = settings.ai.completer(for: .meetings, llm: settings.llm) { error in
                        AppLog.error("Claude failed for the transcript, using the local model: \(error)")
                    }
                    let before = meeting.segments
                    await MainActor.run { self.progress[id] = 0.77 }
                    meeting.segments = await TranscriptPolisher(client: client)
                        .polish(meeting.segments, vocabulary: Array(vocabulary.prefix(80)))
                        .map { segment in
                            var segment = segment
                            segment.text = matcher.correct(segment.text)
                            return segment
                        }
                    let changed = zip(before, meeting.segments).filter { $0.text != $1.text }.count
                    AppLog.info(String(format: "meeting transcript polished in %.0f s: %d of %d lines corrected",
                                       Date().timeIntervalSince(polishStarted), changed, before.count))
                }
                let named = meeting
                meeting.transcript = MeetingTranscriber.lines(meeting.segments) { named.name(for: $0, ownName: Self.ownName) }
                AppLog.info(String(format: "meeting transcribed in %.0f s: %d segments, %d speakers, %d words, tracks %@",
                                   Date().timeIntervalSince(started), meeting.segments.count, meeting.speakers.count,
                                   meeting.transcript.split(whereSeparator: { $0.isWhitespace }).count,
                                   hasTracks ? (system == nil ? "microphone only" : "microphone and system") : "mixed"))
                meeting.status = .summarizing
                let summarizing = meeting
                await MainActor.run {
                    self.progress[id] = 0.86
                    self.save(summarizing)
                }

                if settings.llm.enabled, !meeting.segments.isEmpty {
                    let onClaude = settings.ai.meetings.engine.isCloud
                    let client = settings.ai.completer(for: .meetings, llm: settings.llm) { error in
                        AppLog.error("Claude failed for meeting notes, using the local model: \(error)")
                    }
                    meeting.nameTheOtherPerson(ownName: Self.ownName)
                    let named = meeting
                    meeting.transcript = MeetingTranscriber.lines(meeting.segments) { named.name(for: $0, ownName: Self.ownName) }
                    // Claude takes a whole meeting at once; the local model works through it in parts.
                    let writer = MeetingNotesWriter(client: client, wordsPerPart: onClaude ? 60_000 : 1_400)
                    let notesStarted = Date()
                    let notes = try await writer.write(lines: meeting.noteLines(ownName: Self.ownName),
                                                       participants: meeting.participantNames(ownName: Self.ownName),
                                                       me: Self.ownName,
                                                       language: MeetingTranscriber.mainLanguage(meeting.segments) ?? "de",
                                                       userNotes: meeting.notes,
                                                       date: meeting.scheduledStart ?? meeting.date)
                    AppLog.info(String(format: "meeting notes written in %.0f s: %d action items, %d topics (%@)",
                                       Date().timeIntervalSince(notesStarted), notes.actionItems.count, notes.topics.count,
                                       settings.ai.meetings.engine == .local ? "local model" : settings.ai.meetings.engine.rawValue.capitalized
                                       + (settings.ai.meetings.engine == .claude ? " " + settings.ai.meetings.model.rawValue : "")))
                    // A title from the calendar or typed by hand stays; the generated one fills a gap.
                    if meeting.title.trimmingCharacters(in: .whitespaces).isEmpty { meeting.title = notes.title }
                    meeting.notesMarkdown = notes.markdown
                    meeting.summary = notes.plainSummary
                    meeting.actionItems = notes.actionItems.map(\.sentence)
                }
                meeting.status = .done
                meeting.problem = ""
            } catch {
                meeting.status = .failed
                meeting.problem = String(describing: error)
                AppLog.error("meeting processing failed: \(error)")
            }
            let result = meeting
            await MainActor.run {
                self.progress[result.id] = nil
                self.save(result)
                self.exportToVault(result)
                self.onFinished?(result)
            }
        }
    }

    /// Saves edits from the page: title, notes, folder, ticked actions.
    func update(_ meeting: Meeting) {
        save(meeting)
    }

    var folders: [String] {
        Array(Set(meetings.map(\.folder).filter { !$0.isEmpty })).sorted()
    }

    func delete(_ meeting: Meeting) {
        store.delete(meeting.id)
        meetings.removeAll { $0.id == meeting.id }
    }

    func audioURL(for meeting: Meeting) -> URL { store.audioURL(for: meeting.id) }

    private func save(_ meeting: Meeting) {
        try? store.save(meeting)
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        current = nil
        started = nil
        level = 0
        if isRecording {
            isRecording = false
            onRecordingChange?(false)
        }
    }
}
