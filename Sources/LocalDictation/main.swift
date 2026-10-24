import AppKit
import DictationCore

let app = NSApplication.shared
let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--render-snapshots"), index + 1 < arguments.count {
    // SwiftUI split views and lists only draw inside a running application, so the rendering
    // starts from the event loop.
    let directory = URL(fileURLWithPath: arguments[index + 1])
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        do {
            try Snapshots.render(to: directory)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot rendering failed: \(error)\n".utf8))
            exit(1)
        }
    }
    app.run()
}

if let index = arguments.firstIndex(of: "--render-card"), index + 2 < arguments.count {
    // One assistant card from a `dictate --assistant` record, as an image.
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        do {
            try Snapshots.renderCard(record: URL(fileURLWithPath: arguments[index + 1]), to: URL(fileURLWithPath: arguments[index + 2]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("card rendering failed: \(error)\n".utf8))
            exit(1)
        }
    }
    app.run()
}

if arguments.contains("--mic-restart-test") {
    // Records for about 20 s with the Notetaker's recorder and restarts the microphone five
    // times in a row, as a headset switching profiles does. Reports how long the main thread was
    // blocked at most and how much audio both tracks hold; nothing is saved.
    app.setActivationPolicy(.accessory)
    let recorder = MeetingRecorder()
    var longestStall = 0.0
    var lastBeat = Date()
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        longestStall = max(longestStall, Date().timeIntervalSince(lastBeat) - 0.05)
        lastBeat = Date()
    }
    Task { @MainActor in
        do {
            try await recorder.start()
            let started = Date()
            for round in 1...5 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                recorder.forceMicrophoneRestart(reason: "test restart \(round)")
            }
            try await Task.sleep(nanoseconds: 4_000_000_000)
            let tracks = await recorder.stop()
            let seconds = Date().timeIntervalSince(started)
            let microphone = Double(tracks.microphone.count) / 16_000
            let system = tracks.system.map { Double($0.count) / 16_000 }
            print(String(format: "recorded %.1f s: microphone track %.1f s, system track %@, longest main-thread stall %.0f ms",
                         seconds, microphone, system.map { String(format: "%.1f s", $0) } ?? "none", longestStall * 1000))
            exit(0)
        } catch {
            print("mic restart test failed: \(error)")
            exit(1)
        }
    }
    app.run()
}

if let index = arguments.firstIndex(of: "--connector-test"), index + 1 < arguments.count {
    // Reads through a connector as the app does: "awork-mcp", "awork-direct" or "polarion".
    // Only reads; nothing is created or changed.
    let which = arguments[index + 1]
    Task {
        var settings = (try? SettingsStore(url: AppPaths.settingsFile).load()) ?? DictationSettings()
        let started = Date()
        do {
            switch which {
            case "awork-mcp", "awork-direct":
                settings.connectors.aworkViaMCP = which == "awork-mcp"
                await Connectors.applyAwork(settings)
                let projects = try await AworkClient.shared.projects()
                let users = try await AworkClient.shared.users()
                let me = try await AworkClient.shared.me()
                print(String(format: "%@: %d open projects, %d users, me %@, %.1f s", which, projects.count, users.count,
                             me.firstName, Date().timeIntervalSince(started)))
            default:
                if let path = ClaudeCLI.locate(custom: settings.ai.claudePath) { await Connectors.detectClaudeCodePolarionServer(claudePath: path) }
                let connection = try Connectors.polarion(settings.connectors)
                guard let agent = await AgentFactory.make(settings, tools: [connection.projectsTool], model: .haiku, timeout: 180,
                                                          mcpConfig: connection.mcpConfig) else { throw ConnectorError.missing("Claude Code") }
                let projects = try await PolarionBacklog.projects(agent: agent, connection: connection)
                print(String(format: "polarion via %@ on %@: %d projects, %.1f s", connection.serverName, connection.host,
                             projects.count, Date().timeIntervalSince(started)))
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(which) failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

if arguments.contains("--calendar") {
    // Today's and tomorrow's entries from Microsoft 365 as the app reads them, one per line.
    let start = Calendar.current.startOfDay(for: Date())
    Task {
        do {
            for event in try await GraphCalendar().events(from: start, to: start.addingTimeInterval(2 * 86_400)) {
                let flags = [event.isMeeting ? "meeting" : "info", event.joinURL == nil ? "" : "join"].filter { !$0.isEmpty }
                print(event.start.formatted(date: .abbreviated, time: .shortened), "[\(flags.joined(separator: ","))]",
                      event.participants.count, event.title,
                      arguments.contains("--names") ? "| " + event.participants.map(\.name).joined(separator: ",") : "")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("calendar failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

if arguments.contains("--claude-check") {
    // Runs one transform and one meeting summary through Claude Code with sample text and
    // prints the answers and times, to check the Claude setup without the app's window.
    Task {
        guard let path = ClaudeCLI.locate() else {
            print("claude not found")
            exit(1)
        }
        let transcript = """
        Okay, kurz zum Release 2.4. Mia, du machst bitte die Regressionstests bis Donnerstag. \
        Paul kümmert sich um das Deployment auf den Demo Server am Freitag. \
        Wir haben entschieden, das Feature für den Export erst in 2.5 zu bringen, weil die Tests noch fehlen. \
        Ich schreibe die Release Notes und schicke sie am Mittwoch rum.
        """
        for (task, model, effort) in [(AITask.transforms, ClaudeModel.sonnet, ClaudeEffort.low),
                                      (AITask.meetings, ClaudeModel.sonnet, ClaudeEffort.medium)] {
            let claude = ClaudeCLI(path: path, model: model, effort: effort, timeout: task.claudeTimeout)
            let started = Date()
            do {
                if task == .transforms {
                    let text = try await claude.transform("hey kannst du mir bis freitag die zahlen schicken brauch die fürs board",
                                                          instruction: Transform.presets[2].instruction)
                    print(String(format: "transform (Formal, %@ %@) %.1f s: %@", model.rawValue, effort.rawValue,
                                 Date().timeIntervalSince(started), text))
                } else {
                    let result = try await MeetingSummarizer(client: claude, wordsPerChunk: 60_000).summarize(transcript)
                    print(String(format: "meeting (%@ %@) %.1f s", model.rawValue, effort.rawValue, Date().timeIntervalSince(started)))
                    print("  title: \(result.title)\n  summary: \(result.summary)")
                    result.actionItems.forEach { print("  - \($0)") }
                }
            } catch {
                print("\(task.rawValue) failed: \(error)")
            }
        }
        let started = Date()
        if let local = try? await MeetingSummarizer(client: OpenAICompatibleCleaner(settings: LLMSettings())).summarize(transcript) {
            print(String(format: "meeting (local model) %.1f s", Date().timeIntervalSince(started)))
            print("  title: \(local.title)\n  summary: \(local.summary)")
            local.actionItems.forEach { print("  - \($0)") }
        } else {
            print("local model did not answer")
        }
        exit(0)
    }
    app.run()
}

if DemoMode.isOn {
    // Invented settings, history, meetings and vault in a folder of their own.
    DemoSeed.prepare(reset: arguments.contains("--demo-reset"))
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
