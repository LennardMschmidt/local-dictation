import AppKit
import DictationASR
import DictationCore

/// Connects the hotkey, the recorder, the pipeline and the paster.
///
/// Everything here runs on the main thread except the pipeline run, which is a task whose
/// result comes back to the main thread for pasting.
/// The class is only used on the main thread; it is marked Sendable so the hops back from
/// pipeline tasks to the main thread can capture it.
final class DictationController: @unchecked Sendable {
    enum Status: Equatable {
        case loadingModel
        case ready
        case recording
        case processing
        case failed(String)
    }

    var onStatusChange: ((Status) -> Void)?
    /// Called after a transform replaced text, with the original and the new text.
    var onTransformApplied: ((TransformChange) -> Void)?
    /// Called after a dictation was added to the history.
    var onHistoryChange: (() -> Void)?
    /// Asks the hotkey monitor to forget a press the controller did not turn into a recording.
    var resetHotkey: (() -> Void)?
    /// Tells the hotkey monitor whether an Fn press may start a recording right now.
    var setAcceptsRecordings: ((Bool) -> Void)?

    private(set) var status: Status = .loadingModel {
        didSet {
            setAcceptsRecordings?(status == .ready)
            onStatusChange?(status)
        }
    }

    private(set) var settings: DictationSettings
    private(set) var llmReady = false
    let transcriber: WhisperTranscriber
    /// Parakeet, when it is the chosen dictation engine and loaded.
    private var parakeet: ParakeetTranscriber?
    private var parakeetReady = false
    /// The more accurate model for longer dictations, also used for meetings when it is theirs.
    let longTranscriber: WhisperTranscriber?
    /// Set once `longTranscriber` is loaded; until then every dictation uses the fast model.
    private var longReady = false
    let history: HistoryStore
    private let recorder = AudioRecorder()
    let pill = DictationPill()
    private let paster = Paster()
    /// Finds words the user corrects after a dictation was pasted.
    let corrections = CorrectionWatcher()
    private var targetBundleId: String?
    /// The text pasted last, so a transform shortcut without a selection can replace it.
    private var lastInserted: (text: String, bundleId: String?, date: Date)?
    /// Set by the hotkey monitor right before `.startRecording` when ctrl was held with fn.
    private var nextRecordingIsCommand = false
    private var commandRecording = false
    /// The recording is a request for the assistant (⌥ pressed while fn was held).
    private var assistantRecording = false
    /// Receives the spoken assistant request and the app that was in front.
    var onAssistantRequest: ((String, String?) -> Void)?
    /// True while the assistant card waits for an answer; fn then talks to the assistant.
    var assistantTakesReplies: (() -> Bool)?
    private var commandSelection: String?
    private var debugRecordingCount = 0
    /// Recognition while speaking: stretches of the running dictation recognised so far.
    private var early = EarlyTranscript()
    private var earlyTimer: Timer?
    private var earlyWork: Task<Void, Never>?
    /// The sections of a long dictation cleaned while the user still speaks.
    private var earlyCleanup = EarlyCleanup()

    init(settings: DictationSettings) {
        self.settings = settings
        transcriber = WhisperTranscriber(modelName: settings.asr.model)
        let longModel = settings.asr.longDictationModel
        longTranscriber = longModel.isEmpty || longModel == settings.asr.model ? nil : WhisperTranscriber(modelName: longModel)
        history = HistoryStore(url: AppPaths.historyFile, limit: settings.historyLimit)
        Sounds.enabled = settings.playSounds
        recorder.onLevel = { [weak self] level in self?.pill.push(level: level) }
        recorder.onInterrupted = { [weak self] reason in self?.recordingInterrupted(reason) }
    }

    func updateSettings(_ settings: DictationSettings) {
        let engineChanged = settings.asr.dictationEngine != self.settings.asr.dictationEngine
        let localModelChanged = settings.llm.provider != self.settings.llm.provider || settings.llm.enabled != self.settings.llm.enabled
        self.settings = settings
        if engineChanged { prepareParakeet() } else { Task { await parakeet?.setAliases(Self.aliases(settings)) } }
        // Checked in any state, also while the speech model still loads; the status is sent
        // again so the settings page and the menu show the new model's state.
        if localModelChanged {
            Task {
                let ready = settings.llm.enabled ? await Self.prepareLocalModel(settings.llm) : false
                AppLog.info("local model \(settings.llm.provider) \(ready ? "ready" : "not available")")
                await MainActor.run {
                    self.llmReady = ready
                    self.onStatusChange?(self.status)
                }
            }
        }
        Sounds.enabled = settings.playSounds
    }

    /// Apple's model only needs to be available; LM Studio is started and the model loaded.
    static func prepareLocalModel(_ settings: LLMSettings) async -> Bool {
        settings.usesAppleModel ? AppleModelCleaner.isAvailable : await LMStudio.prepare(settings: settings)
    }

    /// Loads Whisper and prepares the local model in parallel, then warms both up.
    func prepare() {
        status = .loadingModel
        let llmSettings = settings.llm
        let warmupSettings = settings
        Task {
            async let llm = llmSettings.enabled ? Self.prepareLocalModel(llmSettings) : false
            let start = Date()
            do {
                try await transcriber.load()
                await Warmup.run(transcriber: transcriber, cleaner: nil, settings: warmupSettings)
                AppLog.info(String(format: "whisper model ready after %.1fs", Date().timeIntervalSince(start)))
            } catch {
                AppLog.error("whisper model failed to load: \(error)")
                await MainActor.run { self.status = .failed("Speech model failed to load") }
                return
            }
            // The local model may have been switched while the speech model loaded.
            let current = settings.llm
            let switched = current.provider != llmSettings.provider || current.enabled != llmSettings.enabled
            let ready = switched ? (current.enabled ? await Self.prepareLocalModel(current) : false) : await llm
            AppLog.info("cleanup model \(ready ? "ready" : "not available, raw transcripts will be used")")
            await MainActor.run {
                self.llmReady = ready
                self.status = .ready
                // The launch check sends a prompt without the user's tones; this one is the
                // prompt every dictation starts with.
                if ready { self.warmCleanupPrefix(force: true) }
            }
            await MainActor.run { self.prepareParakeet() }
            // Loaded after dictation is ready, so the first dictation does not wait for it.
            guard let long = self.longTranscriber else { return }
            do {
                let start = Date()
                try await long.load()
                _ = try? await long.transcribe(samples: [Float](repeating: 0, count: 16_000), language: "en", vocabulary: [])
                AppLog.info(String(format: "long dictation model ready after %.1fs", Date().timeIntervalSince(start)))
                await MainActor.run { self.longReady = true }
            } catch {
                AppLog.error("long dictation model failed to load: \(error)")
            }
        }
    }

    /// Loads Parakeet when it is the chosen engine, and drops it otherwise. Until it is ready,
    /// dictation keeps using Whisper.
    func prepareParakeet() {
        guard settings.asr.dictationEngine == "parakeet" else {
            parakeet = nil
            parakeetReady = false
            return
        }
        let engine = ParakeetTranscriber(variant: .ultra)
        parakeet = engine
        parakeetReady = false
        let aliases = Self.aliases(settings)
        Task {
            do {
                let started = Date()
                try await engine.load()
                await engine.setAliases(aliases)
                // The first call also loads the vocabulary spotter.
                _ = try? await engine.transcribe(samples: [Float](repeating: 0, count: 16_000), language: "de", vocabulary: ["Polarion"])
                await MainActor.run { if self.parakeet === engine { self.parakeetReady = true } }
                AppLog.info(String(format: "parakeet ready after %.1fs", Date().timeIntervalSince(started)))
            } catch {
                AppLog.error("parakeet failed to load: \(error)")
            }
        }
    }

    /// Each dictionary term with the misrecognitions its replacements name.
    static func aliases(_ settings: DictationSettings) -> [String: [String]] {
        Dictionary(grouping: settings.replacements, by: \.to).mapValues { $0.map(\.from) }
    }

    func setNextRecordingIsCommand(_ command: Bool) {
        nextRecordingIsCommand = command
    }

    func handle(_ action: HotkeyStateMachine.Action) {
        switch action {
        case .none: break
        case .startRecording: startRecording()
        case .enterHandsFree: if status == .recording { pill.show(.handsFree) }
        case .cancel: cancelRecording()
        case .stopAndProcess: stopAndProcess()
        }
    }

    /// The microphone button in the pill: starts a hands-free recording, or stops a running one.
    func toggleClickRecording() {
        switch status {
        case .ready:
            startRecording()
            if status == .recording { pill.show(.handsFree) }
        case .recording:
            stopAndProcess()
        default:
            break
        }
    }

    private var lastPrefixWarmup = Date.distantPast

    /// While the user speaks: loads the model again when LM Studio dropped it (a model it loads
    /// on demand is unloaded after an hour, and the first dictation then timed out with the raw
    /// text), and puts the cached prompt prefix back into memory. At most every two minutes;
    /// dictations closer together find both ready.
    private func warmCleanupPrefix(force: Bool = false) {
        let settings = settings
        guard settings.llm.enabled, settings.ai.cleanup.engine == .local, !settings.llm.usesAppleModel,
              force || Date().timeIntervalSince(lastPrefixWarmup) > 120 else { return }
        lastPrefixWarmup = Date()
        Task.detached {
            await LMStudio.loadIfDropped(settings.llm)
            await Warmup.cleanupPrefix(LocalModel.make(settings.llm), settings: settings)
        }
    }

    private func startRecording() {
        guard status == .ready else {
            // The hotkey monitor normally checks this itself; the status can still change
            // between its check and this call.
            resetHotkey?()
            AppLog.info("recording ignored, status \(status)")
            return
        }
        targetBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        commandRecording = nextRecordingIsCommand
        nextRecordingIsCommand = false
        assistantRecording = assistantTakesReplies?() ?? false
        if assistantRecording { commandRecording = false }
        commandSelection = nil
        if commandRecording {
            paster.copySelection { [weak self] text in self?.commandSelection = text }
        }
        recorder.preferredDeviceUID = settings.microphoneUID
        warmCleanupPrefix()
        do {
            try recorder.start()
        } catch {
            AppLog.error("recording failed to start: \(error)")
            resetHotkey?()
            Sounds.error()
            pill.flash("Microphone not available")
            return
        }
        status = .recording
        Sounds.start()
        if settings.muteAudioWhileDictating {
            // After the start sound, so it is still heard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard self?.status == .recording else { return }
                SystemAudio.muteForRecording()
            }
        }
        pill.show(assistantRecording ? .assistant : commandRecording ? .command : .recording)
        startEarlyRecognition()
        startSpeculation()
    }

    /// ctrl or ⌥ pressed during the recording: it keeps running and becomes an instruction or
    /// an assistant request; the bar shows which.
    func modifierPressed(_ modifier: HotkeyMonitor.RecordingModifier) {
        guard status == .recording, !assistantRecording else { return }
        switch modifier {
        case .option:
            assistantRecording = true
            commandRecording = false
            pill.show(.assistant)
        case .control:
            guard !commandRecording else { return }
            commandRecording = true
            paster.copySelection { [weak self] text in self?.commandSelection = text }
            pill.show(.command)
        }
    }

    /// Every 1.5 s of a dictation with Whisper, the finished stretch up to the last speech pause
    /// is recognised in the background, so after fn is released only the rest is left.
    private func startEarlyRecognition() {
        early = EarlyTranscript()
        earlyWork = nil
        let previous = earlyCleanup
        Task { await previous.cancel() }
        earlyCleanup = EarlyCleanup()
        let cleanup = earlyCleanup
        earlyTimer?.invalidate()
        guard settings.asr.dictationEngine != "parakeet" || !parakeetReady else { return }
        let bundleId = targetBundleId
        earlyTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status == .recording, !self.commandRecording, !self.assistantRecording,
                      self.earlyWork == nil else { return }
                let samples = self.recorder.snapshot()
                guard let cut = EarlyRecognition.cut(in: samples, from: self.early.end) else { return }
                let stretch = Array(samples[self.early.end..<cut])
                let settings = self.settings
                let pipeline = DictationPipeline(settings: settings, transcriber: self.transcriber,
                                                 longTranscriber: self.longReady ? self.longTranscriber : nil,
                                                 cleaner: settings.llm.enabled ? settings.ai.cleaner(llm: settings.llm) : nil)
                let language = self.early.language
                self.earlyWork = Task {
                    if let part = try? await pipeline.transcribeEarly(stretch, bundleId: bundleId, language: language) {
                        let (text, language) = await MainActor.run {
                            self.early.texts.append(part.text)
                            self.early.language = self.early.language ?? part.language
                            self.early.end = cut
                            return (self.early.texts.joined(separator: " "), self.early.language)
                        }
                        // Starts the cleanup of the finished sections and returns at once; the final
                        // run waits for this work item, so it finds every section started here.
                        await cleanup.update(text: text, language: language, bundleId: bundleId, pipeline: pipeline)
                    }
                    await MainActor.run { self.earlyWork = nil }
                }
            }
        }
    }

    private func stopEarlyRecognition() {
        earlyTimer?.invalidate()
        earlyTimer = nil
    }

    private func cancelRecording() {
        stopEarlyRecognition()
        stopSpeculation()
        speculation?.task.cancel()
        speculation = nil
        early = EarlyTranscript()
        let cleanup = earlyCleanup
        Task { await cleanup.cancel() }
        guard status == .recording else { return }
        SystemAudio.restoreAfterRecording()
        let samples = recorder.stop()
        status = .ready
        pill.hide()
        AppLog.info(String(format: "recording cancelled after %.1f s of audio, level %.3f", Double(samples.count) / 16_000,
                           AudioLevel.rms(samples)))
    }

    private func recordingInterrupted(_ reason: String) {
        guard status == .recording else { return }
        AppLog.info("recording ended early: \(reason)")
        resetHotkey?()
        stopAndProcess(tail: 0)
    }

    private func stopAndProcess(tail: TimeInterval = AudioRecorder.tailSeconds) {
        stopEarlyRecognition()
        stopSpeculation()
        guard status == .recording else { return }
        status = .processing
        SystemAudio.restoreAfterRecording()
        Sounds.stop()
        pill.show(.processing)
        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [weak self] in
            guard let self else { return }
            let samples = self.recorder.stop()
            if self.assistantRecording {
                self.processAssistant(samples: samples)
            } else if self.commandRecording {
                self.processCommand(samples: samples, selection: self.commandSelection)
            } else {
                self.process(samples: samples)
            }
        }
    }

    /// Assistant mode: the recording is a request; it is transcribed without the cleanup and
    /// handed to the assistant, which plans and asks before anything runs.
    private func processAssistant(samples: [Float]) {
        var requestSettings = settings
        requestSettings.llm.enabled = false
        requestSettings.appendTrailingSpace = false
        requestSettings.snippets = []
        requestSettings.vocabulary = settings.vocabulary + settings.places.flatMap { [$0.name] + $0.aliases }
        let pipeline = DictationPipeline(settings: requestSettings, transcriber: transcriber,
                                         longTranscriber: longReady ? longTranscriber : nil, cleaner: nil)
        let bundleId = targetBundleId
        Task {
            let spoken = ((try? await pipeline.run(samples: samples, bundleId: nil))?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                self.status = .ready
                if spoken.isEmpty {
                    self.pill.flash("Nothing heard", seconds: 1.5)
                } else {
                    self.pill.hide()
                    AppLog.info("assistant request, \(spoken.count) characters")
                    self.onAssistantRequest?(spoken, bundleId)
                }
            }
        }
    }

    /// Command mode: the recording is an instruction for the selected text, or for new text
    /// when nothing was selected. The result replaces the selection.
    private func processCommand(samples: [Float], selection: String?) {
        var instructionSettings = settings
        instructionSettings.llm.enabled = false
        instructionSettings.appendTrailingSpace = false
        instructionSettings.snippets = []
        // Transform names as recognition hints: a single spoken word has no context otherwise.
        instructionSettings.vocabulary = settings.transforms.map(\.name).filter { !$0.isEmpty }
        let pipeline = DictationPipeline(settings: instructionSettings, transcriber: transcriber, cleaner: nil)
        let settings = self.settings
        let bundleId = targetBundleId
        let started = Date()
        Task {
            do {
                var result = try await pipeline.run(samples: samples, bundleId: bundleId)
                let spoken = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !spoken.isEmpty else {
                    await MainActor.run {
                        self.status = .ready
                        self.pill.flash("No instruction heard", seconds: 1.5)
                    }
                    return
                }
                let transform = Transform.matching(spoken, in: settings.transforms)
                let instruction = transform?.instruction ?? spoken
                let input = selection ?? ""
                let client = self.completer(for: .transforms)
                let output = try await withTimeout(seconds: 20 + Double(input.count) / 50
                                                   + AITask.transforms.extraSeconds(for: settings.ai.transforms)) {
                    try await client.transform(input, instruction: input.isEmpty ? "Write the following. \(instruction)" : instruction)
                }
                result.text = output
                result.rawTranscript = spoken
                let seconds = Date().timeIntervalSince(started)
                AppLog.info(String(format: "command %@ selection %d chars output %d chars total %.2fs",
                                   transform?.name ?? "free", input.count, output.count, seconds))
                let finished = result
                await MainActor.run { self.finish(finished, bundleId: bundleId, audioSeconds: finished.audioSeconds, started: started) }
            } catch {
                AppLog.error("command failed: \(error)")
                await MainActor.run {
                    Sounds.error()
                    self.pill.flash("Transform failed: no model answered", seconds: 2.5)
                    self.status = .ready
                }
            }
        }
    }

    /// The pipeline a dictation runs through, and whether it uses Parakeet.
    private func dictationPipeline() -> (DictationPipeline, parakeet: Bool) {
        let useParakeet = parakeetReady && parakeet != nil
        let pipeline = DictationPipeline(
            settings: settings,
            transcriber: useParakeet ? parakeet! : transcriber,
            longTranscriber: useParakeet ? nil : (longReady ? longTranscriber : nil),
            cleaner: settings.llm.enabled ? settings.ai.cleaner(llm: settings.llm, onFallback: Self.logFallback(.cleanup)) : nil
        )
        return (pipeline, useParakeet)
    }

    /// Recognition and cleanup of everything said so far, started at a speech pause.
    private var speculation: (cut: Int, task: Task<DictationResult, Error>)?
    private var speculationTimer: Timer?

    /// Every 0.25 s of a dictation: at a new speech pause the whole dictation so far is
    /// recognised and cleaned, replacing the run started at an earlier pause. When the user
    /// releases the key without saying anything after the pause, that result is pasted.
    private func startSpeculation() {
        stopSpeculation()
        let bundleId = targetBundleId
        speculationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status == .recording, !self.commandRecording, !self.assistantRecording else { return }
                let samples = self.recorder.snapshot()
                guard SpeechPause.endsInPause(samples) else { return }
                if let previous = self.speculation, SpeechPause.nothingSaid(in: samples, after: previous.cut) { return }
                self.speculation?.task.cancel()
                let (pipeline, useParakeet) = self.dictationPipeline()
                let (early, cleanup) = (self.early, self.earlyCleanup)
                self.speculation = (samples.count, Task {
                    useParakeet || early.texts.isEmpty ? try await pipeline.run(samples: samples, bundleId: bundleId)
                        : try await pipeline.run(samples: samples, bundleId: bundleId, early: early, cleanup: cleanup)
                })
            }
        }
    }

    private func stopSpeculation() {
        speculationTimer?.invalidate()
        speculationTimer = nil
    }

    private func process(samples: [Float]) {
        let seconds = Double(samples.count) / 16_000
        if settings.testControl { saveDebugRecording(samples) }
        let bundleId = targetBundleId
        let (pipeline, useParakeet) = dictationPipeline()
        // The run started at the last speech pause holds everything that was said.
        let ready = speculation.flatMap { SpeechPause.nothingSaid(in: samples, after: $0.cut) ? $0.task : nil }
        if ready == nil { speculation?.task.cancel() }
        speculation = nil
        let started = Date()
        Task {
            do {
                var result: DictationResult
                if let ready, let speculative = try? await ready.value {
                    AppLog.info(String(format: "used the run started at the last speech pause, ready %.2fs after release",
                                       Date().timeIntervalSince(started)))
                    result = speculative
                } else {
                    // A stretch still being recognised is waited for; then only the rest is left.
                    await self.earlyWork?.value
                    let (early, cleanup) = await MainActor.run { (self.early, self.earlyCleanup) }
                    if !early.texts.isEmpty { AppLog.info("\(early.texts.count) stretches recognised while speaking") }
                    result = useParakeet || early.texts.isEmpty ? try await pipeline.run(samples: samples, bundleId: bundleId)
                        : try await pipeline.run(samples: samples, bundleId: bundleId, early: early, cleanup: cleanup)
                }
                if let transform = pipeline.settings.autoTransform, result.cleanup != .snippet, !result.isEmpty {
                    let client = self.completer(for: .transforms)
                    let original = result.text
                    if let output = try? await withTimeout(seconds: 20 + Double(original.count) / 50
                                                           + AITask.transforms.extraSeconds(for: pipeline.settings.ai.transforms), operation: {
                        try await client.transform(original.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   instruction: transform.instruction)
                    }) {
                        result.text = pipeline.settings.appendTrailingSpace && result.style != .code ? output + " " : output
                        let change = TransformChange(name: transform.name, original: original, result: output)
                        await MainActor.run { self.onTransformApplied?(change) }
                    }
                }
                let finished = result
                await MainActor.run { self.finish(finished, bundleId: bundleId, audioSeconds: seconds, started: started) }
            } catch {
                AppLog.error("dictation failed: \(error)")
                await MainActor.run {
                    Sounds.error()
                    self.pill.flash("Dictation failed")
                    self.status = .ready
                }
            }
        }
    }

    private func finish(_ result: DictationResult, bundleId: String?, audioSeconds: Double, started: Date) {
        status = .ready
        let elapsed = Date().timeIntervalSince(started)
        AppLog.info(String(format: "dictation audio %.1fs asr %.2fs cleanup %.2fs total %.2fs chars %d lang %@ style %@ cleanup %@ sections %d early %d by-rule %d fallbacks %d echo-retry %@",
                           audioSeconds, result.transcriptionSeconds, result.cleanupSeconds, elapsed,
                           result.text.count, result.language, result.style.rawValue, String(describing: result.cleanup),
                           result.sections, result.sectionsCleanedEarly, result.sectionsByRule,
                           result.transcriptionFallbacks, result.promptEchoRetried ? "yes" : "no"))
        guard !result.isEmpty else {
            pill.flash("Nothing recognised", seconds: 1.2)
            return
        }
        do {
            try history.append(HistoryEntry(date: Date(), bundleId: bundleId, result: result))
            onHistoryChange?()
        } catch {
            AppLog.error("history not written: \(error)")
        }

        // Pasting into another app than the one the user dictated into would put the text in
        // the wrong place, so it only goes to the clipboard then.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmost != bundleId {
            paster.copy(result.text)
            pill.flash("App changed: text copied, paste with Cmd+V", seconds: 3)
            AppLog.info("frontmost app changed during processing, copied instead of pasted")
            return
        }
        pill.hide()
        // A snippet with formatting goes in formatted where the app supports it.
        let formatted = result.cleanup == .snippet && RichSnippet.hasFormatting(result.text)
        let pasted = formatted ? RichSnippet.plain(result.text) : result.text
        switch paster.insert(pasted, rtf: formatted ? RichSnippet.rtf(result.text) : nil) {
        case .pasted:
            lastInserted = (result.text, bundleId, Date())
            corrections.watch(pasted: pasted, bundleId: bundleId)
        case .copiedOnly: pill.flash("Secure input is on: text copied, paste with Cmd+V", seconds: 3)
        }
    }

    // MARK: Transforms

    /// ⌥1 to ⌥9: applies the transform at `index` to the selected text. Without a selection it
    /// replaces the last dictation, when that went to the same app in the last ten minutes:
    /// Cmd+Z takes the pasted text back out, then the transformed text is pasted.
    ///
    /// The Transform button in the pill calls this with `fromShortcut` false; it works even while
    /// the shortcuts are switched off.
    func applyTransform(at index: Int, fromShortcut: Bool = true) {
        guard status == .ready, !fromShortcut || settings.transformsEnabled,
              settings.transforms.indices.contains(index) else { return }
        let transform = settings.transforms[index]
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        status = .processing
        pill.show(.processing)
        paster.copySelection { [weak self] selection in
            guard let self else { return }
            if let selection {
                // A terminal cannot replace a selection by pasting, so the result goes to the clipboard.
                self.runTransform(transform, on: selection, undoFirst: false, bundleId: frontmost,
                                  copyOnly: Paster.terminals.contains(frontmost ?? ""))
            } else if let last = self.lastInserted, last.bundleId == frontmost, Date().timeIntervalSince(last.date) < 600 {
                self.runTransform(transform, on: last.text, undoFirst: true, bundleId: frontmost)
            } else {
                self.status = .ready
                self.pill.flash(fromShortcut ? "Select text first, then press ⌥\(index + 1)"
                                             : "Select text first, then choose a transform", seconds: 2)
            }
        }
    }

    /// The model for `task` from the current settings; Claude falls back to the local model.
    func completer(for task: AITask) -> ChatCompleter {
        settings.ai.completer(for: task, llm: settings.llm, onFallback: Self.logFallback(task))
    }

    static func logFallback(_ task: AITask) -> @Sendable (Error) -> Void {
        { error in AppLog.error("Claude failed for \(task.rawValue), using the local model: \(error)") }
    }

    private func runTransform(_ transform: Transform, on text: String, undoFirst: Bool, bundleId: String?, copyOnly: Bool = false) {
        let client = completer(for: .transforms)
        let started = Date()
        Task {
            do {
                let result = try await withTimeout(seconds: 20 + Double(text.count) / 50
                                                   + AITask.transforms.extraSeconds(for: self.settings.ai.transforms)) {
                    try await client.transform(text, instruction: transform.instruction)
                }
                let output = Transform.withoutOriginal(result, original: text)
                await MainActor.run {
                    self.status = .ready
                    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId else {
                        self.paster.copy(output)
                        self.pill.flash("App changed: result copied, paste with Cmd+V", seconds: 3)
                        return
                    }
                    if copyOnly {
                        self.paster.copy(output)
                        self.pill.flash("Result copied: a terminal cannot replace the selection, paste with Cmd+V", seconds: 3)
                        return
                    }
                    // Terminals ignore Cmd+Z, so the last dictation is deleted character by character.
                    let terminal = Paster.terminals.contains(bundleId ?? "")
                    if undoFirst {
                        if terminal { Paster.pressBackspace(times: text.count) } else { Paster.press(keyCode: Paster.keyCode(for: "z")) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (undoFirst ? (terminal ? 0.15 + Double(text.count) * 0.002 : 0.15) : 0)) {
                        self.pill.hide()
                        if self.paster.insert(output) == .pasted { self.lastInserted = (output, bundleId, Date()) }
                        self.onTransformApplied?(TransformChange(name: transform.name, original: text, result: output))
                        AppLog.info(String(format: "transform %@ %d chars to %d chars in %.2fs",
                                           transform.name, text.count, output.count, Date().timeIntervalSince(started)))
                    }
                }
            } catch {
                AppLog.error("transform failed: \(error)")
                await MainActor.run {
                    self.status = .ready
                    Sounds.error()
                    self.pill.flash("Transform failed: is LM Studio running?", seconds: 2.5)
                }
            }
        }
    }

    /// Keeps the recordings of this run as `recordings/NNN.wav` while test control is on, so a
    /// live result can be replayed with the dictate command line tool.
    private func saveDebugRecording(_ samples: [Float]) {
        debugRecordingCount += 1
        let url = AppPaths.supportDirectory.appendingPathComponent(
            String(format: "recordings/%03d.wav", debugRecordingCount))
        do {
            try WAVFile.write(samples: samples, sampleRate: 16_000, to: url)
        } catch {
            AppLog.error("debug recording not saved: \(error)")
        }
    }

    /// Text before and after a transform, for the "view changes" window.
    struct TransformChange: Equatable {
        var name: String
        var original: String
        var result: String
    }

    func pasteLast() {
        guard let entry = history.last() else { return }
        _ = paster.insert(entry.text)
    }

    func copyLast() {
        guard let entry = history.last() else { return }
        paster.copy(entry.text)
    }
}
