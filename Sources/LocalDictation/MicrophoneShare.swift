import Foundation

/// The microphone audio of a running meeting recording, for dictation at the same time.
///
/// A second audio engine on a microphone the Notetaker already has open receives no audio. So
/// while a meeting is recorded, its recorder publishes the converted 16 kHz samples here and a
/// dictation listens to them instead of opening the microphone itself.
final class MicrophoneShare: @unchecked Sendable {
    static let shared = MicrophoneShare()

    private let lock = NSLock()
    private var open = false
    private var listener: (([Float]) -> Void)?

    /// True while a meeting recording publishes its microphone audio.
    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func setOpen(_ value: Bool) {
        lock.lock()
        open = value
        if !value { listener = nil }
        lock.unlock()
    }

    /// Called by the meeting recorder with every converted block of microphone samples.
    func publish(_ samples: [Float]) {
        lock.lock()
        let listener = self.listener
        lock.unlock()
        listener?(samples)
    }

    func listen(_ listener: @escaping ([Float]) -> Void) {
        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    func stopListening() {
        lock.lock()
        listener = nil
        lock.unlock()
    }
}
