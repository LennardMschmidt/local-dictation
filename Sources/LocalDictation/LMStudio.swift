import DictationCore
import Foundation

/// Makes sure the LM Studio server runs and the cleanup model answers.
///
/// LM Studio loads a model on the first request that names it, as long as just-in-time loading
/// is on (the default). When the server is not running, the `lms` command line tool starts it.
/// When the first request still fails, `lms load` loads the model explicitly.
enum LMStudio {
    static var cliPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/bin/lms").path
    }

    static func isServerReachable(baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/models") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Returns true when the cleanup model answered a warm-up request.
    static func prepare(settings: LLMSettings) async -> Bool {
        let isLocal = settings.baseURL.contains("localhost") || settings.baseURL.contains("127.0.0.1")
        if !(await isServerReachable(baseURL: settings.baseURL)) {
            guard isLocal, FileManager.default.isExecutableFile(atPath: cliPath) else {
                AppLog.error("LLM server not reachable at \(settings.baseURL)")
                return false
            }
            AppLog.info("starting LM Studio server")
            _ = await run(["server", "start"], timeout: 30)
            var attempts = 0
            while attempts < 20, !(await isServerReachable(baseURL: settings.baseURL)) {
                attempts += 1
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // A model LM Studio loads on demand is unloaded again after an idle time (60 minutes by
        // default), and the next dictation would wait for the reload. An explicitly loaded model
        // stays, so the app loads it itself when it is not loaded yet.
        if isLocal, FileManager.default.isExecutableFile(atPath: cliPath), await !isLoaded(settings.model) {
            AppLog.info("loading \(settings.model) with lms")
            let loaded = await run(["load", settings.model, "-y"], timeout: 120)
            // On a Mac where LM Studio is installed but the model was never downloaded, the app
            // fetches it once (about 2.5 GB) and loads it then.
            if loaded?.status != 0, await !isLoaded(settings.model) {
                AppLog.info("\(settings.model) not downloaded yet, downloading it with lms")
                let fetched = await run(["get", settings.model, "-y"], timeout: 1_800)
                AppLog.info("download of \(settings.model) \(fetched?.status == 0 ? "finished" : "failed")")
                _ = await run(["load", settings.model, "-y"], timeout: 120)
            }
        }

        var warmup = settings
        warmup.timeoutSeconds = 90
        return await answers(warmup)
    }

    /// Loads the model explicitly, so it stays loaded, when LM Studio runs locally and the model
    /// is not loaded any more.
    static func loadIfDropped(_ settings: LLMSettings) async {
        let isLocal = settings.baseURL.contains("localhost") || settings.baseURL.contains("127.0.0.1")
        guard isLocal, FileManager.default.isExecutableFile(atPath: cliPath), await !isLoaded(settings.model) else { return }
        AppLog.info("\(settings.model) was unloaded, loading it again with lms")
        _ = await run(["load", settings.model, "-y"], timeout: 120)
    }

    /// True when `lms ps` lists the model as loaded.
    static func isLoaded(_ model: String) async -> Bool {
        guard let output = await run(["ps", "--json"], timeout: 15, captureOutput: true)?.output,
              let entries = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]] else { return false }
        return entries.contains { ($0["modelKey"] as? String) == model || ($0["identifier"] as? String) == model }
    }

    private static func answers(_ settings: LLMSettings) async -> Bool {
        let cleaner = OpenAICompatibleCleaner(settings: settings)
        let request = CleanupRequest(transcript: "this is a warm up", language: "en", style: .plain, vocabulary: [])
        do {
            _ = try await cleaner.clean(request)
            return true
        } catch {
            AppLog.error("cleanup model did not answer: \(error)")
            return false
        }
    }

    /// Runs `lms` with the arguments and returns its exit status (and stdout when asked), or nil
    /// after the timeout. Waits with `Task.sleep`, so no thread of the shared pool is blocked.
    @discardableResult
    private static func run(_ arguments: [String], timeout: TimeInterval,
                            captureOutput: Bool = false) async -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = captureOutput ? pipe : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let command = "lms \(arguments.joined(separator: " "))"
        do {
            try process.run()
        } catch {
            AppLog.error("\(command) failed to start: \(error)")
            return nil
        }
        // Reading while the process runs keeps a full pipe buffer from blocking it.
        var output = Data()
        let reader = captureOutput ? Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() } : nil
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if process.isRunning {
            process.terminate()
            AppLog.error("\(command) timed out")
            return nil
        }
        if let reader { output = await reader.value }
        AppLog.info("\(command) exited with \(process.terminationStatus)")
        return (process.terminationStatus, output)
    }
}
