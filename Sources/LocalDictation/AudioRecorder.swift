import AVFoundation
import AudioToolbox
import CoreAudio
import DictationCore
import Foundation

/// Records the default microphone into 16 kHz mono samples.
///
/// The engine only runs between `start()` and `stop()`, so the microphone indicator in the menu
/// bar is only on while dictating. Conversion runs on a serial queue off the audio thread.
final class AudioRecorder {
    /// Called on the main thread with a 0...1 level for the meter, about 20 times per second.
    var onLevel: ((Float) -> Void)?
    /// Called on the main thread when the recording ends on its own: the input device changed
    /// or the length limit was reached. The samples recorded so far are still available from `stop()`.
    var onInterrupted: ((String) -> Void)?

    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "local.dictation.LocalDictation.audio")
    private var resampler: AudioResampler?
    private var samples: [Float] = []
    private var running = false
    private var limitReported = false
    private var configurationObserver: NSObjectProtocol?
    private var lastDeviceID: AudioDeviceID?
    private var lastRestart: Date?
    private var startedAt: Date?
    /// The recording listens to a running meeting recording instead of its own engine.
    private var sharing = false

    /// UID of the microphone to use; empty means the system default at the time of recording.
    var preferredDeviceUID = ""

    /// Name of the microphone the last recording used, for the settings page.
    private(set) var lastDeviceName: String?

    /// Hard limit so a forgotten hands-free recording does not grow without end (10 minutes).
    static let maximumSamples = 16_000 * 600

    /// Recording continues this long after the key is released. People often let go during the
    /// last syllable, and the tap delivers audio in buffers of about 40 ms.
    static let tailSeconds: TimeInterval = 0.2

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, self.running, !self.sharing, (notification.object as? AVAudioEngine) === self.engine else { return }
            self.configurationChanged()
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    var isRunning: Bool { running }

    /// Starts recording from the chosen microphone, or from the current system default. When
    /// the device differs from the last recording (headphones connected, for example), a fresh
    /// engine is used, because an engine keeps the device it was created with. If the engine
    /// still fails to start, a fresh one is tried once.
    func start() throws {
        guard !running else { return }
        if MicrophoneShare.shared.isOpen {
            startSharing()
            return
        }
        let device = AudioDevices.resolve(uid: preferredDeviceUID)
        if let device, device.deviceID != lastDeviceID {
            if lastDeviceID != nil { AppLog.info("microphone changed to \(device.name)") }
            engine = AVAudioEngine()
        }
        do {
            try startEngine(device: device)
        } catch {
            AppLog.error("audio engine failed to start (\(error)), retrying with a new engine")
            engine = AVAudioEngine()
            try startEngine(device: device)
        }
        lastDeviceID = device?.deviceID
        lastDeviceName = device?.name
    }

    /// macOS stops the engine when the audio setup changes, also right after the first start of
    /// the day, when a Bluetooth headset negotiates while the built-in microphone is selected.
    /// While the microphone is still there, the recording continues on a fresh engine and keeps
    /// what it has; only a microphone that went away ends it.
    private func configurationChanged() {
        // Many of these notices leave the engine running; only a stopped engine needs a restart,
        // and a restart may itself cause one more notice.
        guard !engine.isRunning else { return }
        if let lastRestart, Date().timeIntervalSince(lastRestart) < 0.5 { return }
        lastRestart = Date()
        let device = AudioDevices.resolve(uid: preferredDeviceUID)
        guard let device, device.deviceID == lastDeviceID else {
            AppLog.error("audio device changed during recording")
            onInterrupted?("Microphone changed")
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let resampler { queue.sync { samples.append(contentsOf: resampler.flush()) } }
        engine = AVAudioEngine()
        do {
            try startEngine(device: device, keepSamples: true)
            AppLog.info("audio configuration changed during recording, microphone continued")
        } catch {
            AppLog.error("microphone could not continue after an audio change: \(error)")
            onInterrupted?("Microphone changed")
        }
    }

    /// The format to tap the microphone with: the hardware format of the device the input node
    /// now uses. After another microphone was selected, the node's output format can still be
    /// the one of the device before (AirPods in a call run at 16 or 24 kHz), and a tap whose
    /// rate differs from the hardware makes AVAudioEngine raise an exception that ends the app.
    /// Nil while the device reports no channels or no rate, as during a switch.
    static func tapFormat(_ input: AVAudioInputNode) -> AVAudioFormat? {
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate,
                             channels: hardware.channelCount, interleaved: false)
    }

    private func startEngine(device: AudioDevices.Device?, keepSamples: Bool = false) throws {
        if !keepSamples { startedAt = Date() }
        // A fresh engine already uses the system default; the device is only set when another
        // microphone is to be used.
        if let device, device.deviceID != AudioDevices.defaultInput()?.deviceID,
           let unit = engine.inputNode.audioUnit {
            var id = device.deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { AppLog.error("could not select microphone \(device.name): \(status)") }
        }
        let input = engine.inputNode
        guard let format = Self.tapFormat(input), let resampler = AudioResampler(inputFormat: format) else {
            throw RecorderError.noInputDevice
        }
        self.resampler = resampler
        if !keepSamples {
            queue.sync {
                samples.removeAll(keepingCapacity: true)
                limitReported = false
            }
        }

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            guard let self, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            self.queue.async {
                guard self.samples.count < Self.maximumSamples else {
                    if !self.limitReported {
                        self.limitReported = true
                        DispatchQueue.main.async { self.onInterrupted?("Recording limit of 10 minutes reached") }
                    }
                    return
                }
                let converted = resampler.convert(copy)
                self.samples.append(contentsOf: converted)
                let level = AudioLevel.meterValue(rms: AudioLevel.rms(converted))
                DispatchQueue.main.async { self.onLevel?(level) }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    /// Takes the microphone audio of the running meeting recording, which already has the
    /// microphone open; a second engine on it would receive nothing.
    private func startSharing() {
        startedAt = Date()
        queue.sync {
            samples.removeAll(keepingCapacity: true)
            limitReported = false
        }
        MicrophoneShare.shared.listen { [weak self] block in
            guard let self else { return }
            self.queue.async {
                guard self.samples.count < Self.maximumSamples else { return }
                self.samples.append(contentsOf: block)
                let level = AudioLevel.meterValue(rms: AudioLevel.rms(block))
                DispatchQueue.main.async { self.onLevel?(level) }
            }
        }
        sharing = true
        running = true
        AppLog.info("dictation uses the microphone of the running meeting recording")
    }

    /// Stops recording and returns everything recorded since `start()`.
    /// The samples recorded so far, while the recording runs.
    func snapshot() -> [Float] {
        queue.sync { samples }
    }

    func stop() -> [Float] {
        guard running else { return [] }
        running = false
        if sharing {
            sharing = false
            MicrophoneShare.shared.stopListening()
            return queue.sync {
                let result = samples
                samples.removeAll(keepingCapacity: true)
                return result
            }
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return queue.sync {
            if let resampler { samples.append(contentsOf: resampler.flush()) }
            let result = samples
            samples.removeAll(keepingCapacity: true)
            return result
        }
    }

    enum RecorderError: Error, CustomStringConvertible {
        case noInputDevice
        var description: String { "no microphone input available" }
    }
}
