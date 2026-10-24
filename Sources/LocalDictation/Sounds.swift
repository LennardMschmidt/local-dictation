import AppKit

/// Short system sounds as feedback, quiet enough not to end up in the recording.
enum Sounds {
    static var enabled = true

    static func start() { play("Tink") }
    static func stop() { play("Pop") }
    static func error() { play("Basso") }

    private static func play(_ name: String) {
        guard enabled, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.25
        sound.play()
    }
}
