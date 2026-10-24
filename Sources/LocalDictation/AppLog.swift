import DictationCore
import Foundation
import os

/// Writes to the unified log and to `app.log` in Application Support, so the smoke test and
/// troubleshooting can read what happened. Dictated text is never logged, only lengths.
enum AppLog {
    private static let logger = Logger(subsystem: "local.dictation.LocalDictation", category: "app")
    private static let queue = DispatchQueue(label: "local.dictation.LocalDictation.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")
        let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
        queue.async {
            let url = AppPaths.logFile
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Starts a new log file and keeps the previous one as `app.log.1`.
    static func rotate() {
        let url = AppPaths.logFile
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }
}
