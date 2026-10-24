import Foundation

/// Mutes the system output while dictating and puts the previous state back afterwards.
/// Uses the Standard Additions volume commands, which need no extra permission.
enum SystemAudio {
    private static var mutedByUs = false

    static func muteForRecording() {
        guard !mutedByUs, run("output muted of (get volume settings)") == "false" else { return }
        _ = run("set volume with output muted")
        mutedByUs = true
    }

    static func restoreAfterRecording() {
        guard mutedByUs else { return }
        _ = run("set volume without output muted")
        mutedByUs = false
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { AppLog.error("volume script failed: \(error)") }
        return result?.stringValue
    }
}
