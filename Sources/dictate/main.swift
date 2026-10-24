import DictationASR
import DictationCore
import Foundation

// Runs the dictation pipeline on audio files and prints one JSON object per file.
//
//   dictate [--app <bundle id>] [--no-cleanup] [--settings <file>] [--llm-url <url>] [--local-model lmstudio|apple] file.wav [more.wav ...]
//
// The model loads once for all files. Settings come from the app's settings file unless
// --settings names another one; a missing file means defaults.

struct Options {
    var meeting = false
    var bundleId: String?
    var cleanup = true
    var settingsPath: String?
    var llmURL: String?
    /// "lmstudio" or "apple", in place of the provider in the settings.
    var localModel: String?
    /// Meeting mode: a fixed recognition language ("auto" detects it).
    var language: String?
    var vocabulary = true
    var summary = true
    /// Meeting mode: cut the audio into short pieces at pauses and transcribe each on its own.
    var pieces = false
    /// Meeting mode: the new pipeline with speaker detection and a language per piece.
    var speakers = false
    /// Meeting mode with speakers: the system audio track; the main file is then the microphone.
    var systemTrack: String?
    /// "whisper" (default), "parakeet-v3" or "parakeet-ultra".
    var engine = "whisper"
    /// Simulates recognition while speaking: stretches cut at pauses as the recording grows.
    var early = false
    /// With --early: the recording grows at the speed of the audio, so the cleanup of finished
    /// sections gets the same head start as in the app.
    var realtime = false
    /// With --realtime: recognises and cleans the dictation so far at every speech pause, as the
    /// app does, and takes that result when nothing was said after the pause.
    var speculate = false
    /// Skips the warm-up at start, to measure a cold prompt cache.
    var warmup = true
    /// Warms the prompt prefix before each file and waits 2 s, as a recording start does.
    var warmPrefix = false
    /// Uses the settings' long dictation model for long dictations and stretches, as the app
    /// does once it is loaded; --no-long uses the dictation model for everything.
    var longModel = true
    var files: [String] = []
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--app": options.bundleId = iterator.next()
        case "--no-cleanup": options.cleanup = false
        case "--meeting": options.meeting = true
        case "--settings": options.settingsPath = iterator.next()
        case "--llm-url": options.llmURL = iterator.next()
        case "--local-model": options.localModel = iterator.next()
        case "--language": options.language = iterator.next()
        case "--no-vocabulary": options.vocabulary = false
        case "--no-summary": options.summary = false
        case "--pieces": options.pieces = true
        case "--speakers": options.speakers = true
        case "--system": options.systemTrack = iterator.next()
        case "--engine": options.engine = iterator.next() ?? "whisper"
        case "--early": options.early = true
        case "--realtime": options.realtime = true
        case "--speculate": options.speculate = true
        case "--no-warmup": options.warmup = false
        case "--warm-prefix": options.warmPrefix = true
        case "--no-long": options.longModel = false
        case "-h", "--help":
            print("usage: dictate [--app <bundle id>] [--no-cleanup] [--settings <file>] [--llm-url <url>] file.wav ...")
            exit(0)
        default: options.files.append(argument)
        }
    }
    return options
}

func loadSettings(_ options: Options) throws -> DictationSettings {
    var settings: DictationSettings
    if let path = options.settingsPath {
        let url = URL(fileURLWithPath: path)
        settings = FileManager.default.fileExists(atPath: path)
            ? try JSONDecoder().decode(DictationSettings.self, from: Data(contentsOf: url))
            : DictationSettings()
    } else if FileManager.default.fileExists(atPath: AppPaths.settingsFile.path) {
        settings = try SettingsStore(url: AppPaths.settingsFile).load()
    } else {
        settings = DictationSettings()
    }
    if !options.cleanup { settings.llm.enabled = false }
    if let url = options.llmURL { settings.llm.baseURL = url }
    if let provider = options.localModel { settings.llm.provider = provider }
    return settings
}

func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

// Notes mode: `dictate --notes <meeting.json> --participants "Jonas Weber,Paul" [--claude]`
// writes the meeting notes from a saved meeting's transcript, to compare engines.
// Assistant mode: `dictate --assistant "wie wird das Wetter morgen in Hamburg"` plans the request
// like the app (fn + option) and then runs its agent steps with Claude Code, as Return would.
if let index = CommandLine.arguments.firstIndex(of: "--assistant"), index + 1 < CommandLine.arguments.count {
    let request = CommandLine.arguments[index + 1]
    let settings = try loadSettings(options)
    let local = LocalModel.make(settings.llm)
    let planner: ChatCompleter = settings.ai.cloud(settings.assistant.planner, timeout: 90).map { FallbackCompleter(primary: $0, fallback: local) } ?? local
    let context = AssistantContext(places: settings.places, frontApp: "Terminal", agentTools: settings.assistant.agentTools,
                                   userName: NSFullUserName())
    var started = Date()
    let plan = try await AssistantPlanner(completer: planner).plan(request, context: context)
    let planSeconds = Date().timeIntervalSince(started)
    var record: [String: Any] = [
        "request": request, "plan_seconds": planSeconds, "summary": plan.summary,
        "actions": plan.actions.map { ["type": $0.type, "title": $0.title, "url": $0.url, "app": $0.app, "note": $0.note,
                                       "prompt": $0.prompt, "answer": $0.answer, "project": $0.projectName, "task": $0.taskName] },
        "runs_without_return": plan.isOnlyQuestions || plan.isOnlyAnswer,
    ]
    // Only questions run here, as Return would run them; steps that open, create or change
    // something are only shown.
    var runs: [[String: Any]] = []
    for action in plan.actions where action.kind == .agent {
        guard let path = ClaudeCLI.locate(custom: settings.ai.claudePath) else { print("claude not found"); exit(1) }
        var agent = ClaudeAgent(path: path, model: CommandLine.arguments.contains("--sonnet") ? .sonnet : ClaudeAgent.questionModel,
                                tools: settings.assistant.agentTools)
        agent.builtinTools = ClaudeAgent.webTools
        if !CommandLine.arguments.contains("--full-setup") { agent.serverScope = .user }
        started = Date()
        do {
            let (answer, tools) = try await agent.runTraced(action.prompt)
            runs.append(["answer": answer, "tools": tools, "seconds": Date().timeIntervalSince(started)])
        } catch {
            runs.append(["error": String(describing: error), "seconds": Date().timeIntervalSince(started)])
        }
    }
    record["agent"] = runs
    print(jsonLine(record))
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--notes"), index + 1 < CommandLine.arguments.count {
    let arguments = CommandLine.arguments
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let meeting = try decoder.decode(Meeting.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))
    let participants = arguments.firstIndex(of: "--participants").map { arguments[$0 + 1].split(separator: ",").map(String.init) } ?? []
    let me = participants.first ?? "Me"
    // `--filter` drops the pieces the transcription filter now leaves out, to compare a meeting
    // transcribed before the filter existed.
    var segments = meeting.segments
    if arguments.contains("--filter") {
        segments = segments.filter { segment in
            let others = meeting.segments.filter { $0.speaker != MeetingSpeakers.me }
                .reduce(0.0) { $0 + max(0, min(segment.end, $1.end) - max(segment.start, $1.start)) }
            let echo = segment.speaker == MeetingSpeakers.me && TextProcessing.isEchoThanks(segment.text)
                && others >= (segment.end - segment.start) / 2
            let drop = TextProcessing.isForeignShortPiece(segment.text) || echo
            if drop { FileHandle.standardError.write(Data("filtered: \(segment.speaker) \(segment.text)\n".utf8)) }
            return !drop
        }
    }
    // With one other person, the speaker with the most words on the system track is that person.
    var names: [String: String] = [MeetingSpeakers.me: me]
    let others = participants.dropFirst()
    if others.count == 1 {
        var words: [String: Int] = [:]
        for segment in segments where segment.speaker != MeetingSpeakers.me {
            words[segment.speaker, default: 0] += segment.text.split(separator: " ").count
        }
        if let top = words.max(by: { $0.value < $1.value })?.key { names[top] = others.first! }
    }
    let lines = segments.map {
        MeetingNotesWriter.Line(time: $0.start, speaker: names[$0.speaker] ?? MeetingSpeakers.defaultName(for: $0.speaker, ownName: me),
                                text: $0.text)
    }
    let useClaude = arguments.contains("--claude")
    // `--model opus` compares the notes of another Claude model; Sonnet as in the app by default.
    let notesModel = arguments.firstIndex(of: "--model").flatMap { ClaudeModel(rawValue: arguments[$0 + 1]) } ?? .sonnet
    let client: ChatCompleter = useClaude
        ? ClaudeCLI(path: ClaudeCLI.locate() ?? "claude", model: notesModel, effort: .medium, timeout: 900)
        : OpenAICompatibleCleaner(settings: LLMSettings())
    let started = Date()
    // Every model answer goes to stderr, so the extracted and verified items can be compared.
    struct Logged: ChatCompleter {
        let inner: ChatCompleter
        func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String {
            let reply = try await inner.complete(messages: messages, maxTokens: maxTokens, schema: schema)
            FileHandle.standardError.write(Data("model answer: \(reply)\n".utf8))
            return reply
        }
    }
    let notes = try await MeetingNotesWriter(client: Logged(inner: client), wordsPerPart: useClaude ? 60_000 : 1_400)
        .write(lines: lines, participants: participants, me: me, language: MeetingTranscriber.mainLanguage(meeting.segments) ?? "de",
               date: meeting.scheduledStart ?? meeting.date)
    print(String(format: "# %@ (%@, %.0f s)\n", notes.title, useClaude ? "Claude \(notesModel.rawValue) medium" : "local model", Date().timeIntervalSince(started)))
    print(notes.markdown)
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--transform"), index + 2 < CommandLine.arguments.count {
    // `--transform <name> <text file>` runs a built-in transform as the app does and prints the result.
    let name = CommandLine.arguments[index + 1]
    let text = try String(contentsOfFile: CommandLine.arguments[index + 2], encoding: .utf8)
    guard let transform = Transform.presets.first(where: { $0.name.lowercased() == name.lowercased() }) else {
        FileHandle.standardError.write(Data("dictate: no transform named \(name)\n".utf8))
        exit(2)
    }
    let settings = try loadSettings(options)
    let client = settings.ai.completer(for: .transforms, llm: settings.llm)
    let started = Date()
    let raw = try await client.transform(text, instruction: transform.instruction)
    FileHandle.standardError.write(Data(String(format: "%@ in %.1f s, original repeated: %@\n", transform.name,
                                               Date().timeIntervalSince(started), Transform.withoutOriginal(raw, original: text) == raw ? "no" : "yes").utf8))
    print(Transform.withoutOriginal(raw, original: text))
    exit(0)
}
guard !options.files.isEmpty else {
    FileHandle.standardError.write(Data("dictate: no audio file given\n".utf8))
    exit(2)
}

do {
    let settings = try loadSettings(options)
    let transcriber = WhisperTranscriber(modelName: settings.asr.model)
    let loadStart = ProcessInfo.processInfo.systemUptime
    let parakeet: ParakeetTranscriber? = options.engine.hasPrefix("parakeet")
        ? ParakeetTranscriber(variant: options.engine.contains("ultra") ? .ultra : .v3) : nil
    if let parakeet {
        try await parakeet.load()
        await parakeet.setAliases(Dictionary(grouping: settings.replacements, by: \.to).mapValues { $0.map(\.from) })
        if !options.engine.contains("boost") { await parakeet.setBoosting(false) }
    } else {
        try await transcriber.load()
    }
    FileHandle.standardError.write(Data(String(format: "model loaded in %.1fs\n",
                                               ProcessInfo.processInfo.systemUptime - loadStart).utf8))

    let cleaner = LocalModel.make(settings.llm)
    // The app warms both models up at launch; doing the same here keeps the timings comparable.
    let active: Transcriber = parakeet ?? transcriber
    if options.warmup {
        await Warmup.run(transcriber: active, cleaner: settings.llm.enabled ? cleaner : nil, settings: settings)
    }
    let longName = settings.asr.longDictationModel
    let long = parakeet == nil && options.longModel && !longName.isEmpty && longName != settings.asr.model
        ? WhisperTranscriber(modelName: longName) : nil
    if let long {
        try await long.load()
        _ = try? await long.transcribe(samples: [Float](repeating: 0, count: 16_000), language: "en", vocabulary: [])
    }
    let pipeline = DictationPipeline(settings: settings, transcriber: active, longTranscriber: long, cleaner: cleaner)
    if options.meeting {
        // Meeting mode: transcribe each file completely and summarise it like the Notetaker does.
        for file in options.files {
            let samples = try AudioFile.loadSamples(path: file)
            let start = ProcessInfo.processInfo.systemUptime
            let language = options.language.map { $0 == "auto" ? nil : $0 } ?? settings.recognitionLanguage
            var transcript: Transcript
            if options.speakers {
                let diarizer = SpeakerDiarizer()
                let languages = settings.languages.isEmpty ? ["de", "en"] : settings.languages
                let vocabulary = options.vocabulary ? settings.vocabularyByPriority : []
                let pipeline = MeetingTranscriber(
                    diarize: { try await diarizer.diarize($0) },
                    transcribe: { piece, main in
                        let result = try await transcriber.transcribePiece(samples: piece, languages: languages, preferred: main, vocabulary: vocabulary)
                        FileHandle.standardError.write(Data(String(format: "piece %.1f s, %@, log prob %.2f, no speech %.2f: %@\n",
                                                                   Double(piece.count) / 16_000, result.language, result.logProb, result.noSpeech,
                                                                   String(result.text.prefix(90))).utf8))
                        return result
                    })
                let system = try options.systemTrack.map { try AudioFile.loadSamples(path: $0) }
                let segments = try await pipeline.transcribe(microphone: samples, system: system, skipped: { text in
                    FileHandle.standardError.write(Data("skipped (unsure): \(text)\n".utf8))
                })
                var counts: [String: Int] = [:]
                for segment in segments { counts[segment.language, default: 0] += segment.text.split(separator: " ").count }
                FileHandle.standardError.write(Data("segments \(segments.count), speakers \(Set(segments.map(\.speaker)).sorted()), words by language \(counts)\n".utf8))
                for segment in segments {
                    FileHandle.standardError.write(Data(String(format: "%5.1f-%5.1f %@ %@: %@\n", segment.start, segment.end, segment.language,
                                                               MeetingSpeakers.defaultName(for: segment.speaker, ownName: "Me"), segment.text).utf8))
                }
                transcript = Transcript(text: MeetingTranscriber.lines(segments) { MeetingSpeakers.defaultName(for: $0, ownName: "Me") },
                                        language: counts.keys.sorted().joined(separator: ","))
            } else if options.pieces {
                var texts: [String] = []
                var languages: [String: Int] = [:]
                for range in AudioSegmenter.pieces(samples) {
                    let part = try await transcriber.transcribe(samples: Array(samples[range]), language: language,
                                                                vocabulary: options.vocabulary ? settings.vocabulary : [])
                    texts.append(part.text)
                    languages[part.language, default: 0] += 1
                }
                transcript = Transcript(text: texts.joined(separator: " "),
                                        language: languages.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ","))
            } else {
                transcript = try await transcriber.transcribe(samples: samples, language: language,
                                                              vocabulary: options.vocabulary ? settings.vocabulary : [])
            }
            let asrSeconds = ProcessInfo.processInfo.systemUptime - start
            let text = TextProcessing.cleanTranscript(transcript.text)
            let summary = options.summary ? try await MeetingSummarizer(client: cleaner).summarize(text)
                : MeetingSummarizer.Result(title: "", summary: "", actionItems: [])
            print(jsonLine([
                "file": file,
                "audio_seconds": Double(samples.count) / 16_000,
                "transcription_seconds": asrSeconds,
                "summary_seconds": ProcessInfo.processInfo.systemUptime - start - asrSeconds,
                "transcript": text,
                "words": text.split(whereSeparator: { $0.isWhitespace }).count,
                "language": transcript.language,
                "title": summary.title,
                "summary": summary.summary,
                "action_items": summary.actionItems,
            ]))
        }
        exit(0)
    }
    for file in options.files {
        let samples = try AudioFile.loadSamples(path: file)
        if options.warmPrefix {
            Task { await Warmup.cleanupPrefix(cleaner, settings: settings) }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let earlyCleanup = EarlyCleanup()
        let box = EarlyBox()
        let recordingStart = Date()
        var speculation: (cut: Int, task: Task<DictationResult, Error>)?
        if options.early || options.speculate {
            // As in the app: every 0.25 s the recording so far is looked at; every 1.5 s a finished
            // stretch is recognised in the background, and at a speech pause the whole dictation
            // so far is recognised and cleaned.
            var available = 4_000
            while available < samples.count {
                if options.realtime {
                    let ahead = Double(available) / 16_000 - Date().timeIntervalSince(recordingStart)
                    if ahead > 0 { try await Task.sleep(nanoseconds: UInt64(ahead * 1_000_000_000)) }
                }
                let soFar = Array(samples[..<available])
                if options.early, available % 24_000 < 4_000, await !box.busy,
                   let cut = EarlyRecognition.cut(in: soFar, from: await box.value.end) {
                    let (start, language) = await (box.value.end, box.value.language)
                    await box.setBusy(true)
                    Task {
                        if let part = try? await pipeline.transcribeEarly(Array(samples[start..<cut]), bundleId: options.bundleId,
                                                                          language: language) {
                            let early = await box.append(part, end: cut)
                            await earlyCleanup.update(text: early.texts.joined(separator: " "), language: early.language,
                                                      bundleId: options.bundleId, pipeline: pipeline)
                        }
                        await box.setBusy(false)
                    }
                }
                if options.speculate, SpeechPause.endsInPause(soFar),
                   !(speculation.map { SpeechPause.nothingSaid(in: soFar, after: $0.cut) } ?? false) {
                    speculation?.task.cancel()
                    let early = await box.value
                    speculation = (available, Task {
                        early.texts.isEmpty ? try await pipeline.run(samples: soFar, bundleId: options.bundleId)
                            : try await pipeline.run(samples: soFar, bundleId: options.bundleId, early: early, cleanup: earlyCleanup)
                    })
                }
                available += 4_000
            }
        }
        // The key is released when the audio ends, not earlier.
        if options.realtime {
            let ahead = Double(samples.count) / 16_000 - Date().timeIntervalSince(recordingStart)
            if ahead > 0 { try await Task.sleep(nanoseconds: UInt64(ahead * 1_000_000_000)) }
        }
        let released = Date()
        var usedSpeculation = false
        var result: DictationResult
        if let speculation, SpeechPause.nothingSaid(in: samples, after: speculation.cut), let ready = try? await speculation.task.value {
            result = ready
            usedSpeculation = true
        } else {
            speculation?.task.cancel()
            while await box.busy { try await Task.sleep(nanoseconds: 20_000_000) }
            let early = await box.value
            result = early.texts.isEmpty ? try await pipeline.run(samples: samples, bundleId: options.bundleId)
                : try await pipeline.run(samples: samples, bundleId: options.bundleId, early: early, cleanup: earlyCleanup)
        }
        let afterRelease = Date().timeIntervalSince(released)
        let early = await box.value
        let cleanup: String
        switch result.cleanup {
        case .cleaned: cleanup = "cleaned"
        case .disabled: cleanup = "disabled"
        case .snippet: cleanup = "snippet"
        case .short: cleanup = "short"
        case .failed(let reason): cleanup = "failed: \(reason)"
        }
        print(jsonLine([
            "file": file,
            "audio_seconds": Double(samples.count) / 16_000,
            "raw": result.rawTranscript,
            "text": result.text,
            "language": result.language,
            "style": result.style.rawValue,
            "cleanup": cleanup,
            "transcription_seconds": result.transcriptionSeconds,
            "cleanup_seconds": result.cleanupSeconds,
            "fallbacks": result.transcriptionFallbacks,
            "prompt_echo_retried": result.promptEchoRetried,
            "sections": result.sections,
            "sections_early": result.sectionsCleanedEarly,
            "sections_by_rule": result.sectionsByRule,
            "early_stretches": early.texts.count,
            "after_release_seconds": afterRelease,
            "speculation_used": usedSpeculation,
        ]))
        fflush(stdout)
    }
} catch {
    FileHandle.standardError.write(Data("dictate: \(error)\n".utf8))
    exit(1)
}

/// The stretches recognised during a simulated recording, shared with the background work.
actor EarlyBox {
    var value = EarlyTranscript()
    var busy = false

    func setBusy(_ busy: Bool) { self.busy = busy }

    func append(_ part: Transcript, end: Int) -> EarlyTranscript {
        value.texts.append(part.text)
        value.language = value.language ?? part.language
        value.end = end
        return value
    }
}
