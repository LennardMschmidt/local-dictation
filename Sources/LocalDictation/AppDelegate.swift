import AppKit
import DictationCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore(url: AppPaths.settingsFile)
    private var controller: DictationController!
    private var hotkey: HotkeyMonitor!
    private var assistant: AssistantController!
    private var briefing: BriefingController?
    private var menu: StatusMenu!
    private var model: AppModel!
    private var mainWindow: MainWindowController!
    private var scratchpadWindow: ScratchpadWindowController?
    private var systemTimer: Timer?
    private var tapFailures = 0
    private var notetaker: NotetakerController!
    private let diffWindow = TransformDiffWindow()
    private var reportedLLMState: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.rotate()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        AppLog.info("launched version \(version), pid \(ProcessInfo.processInfo.processIdentifier)")

        let settings: DictationSettings
        do {
            settings = try settingsStore.load()
        } catch {
            AppLog.error("settings file unreadable, using defaults: \(error)")
            settings = DictationSettings()
        }

        controller = DictationController(settings: settings)
        hotkey = HotkeyMonitor(minimumPress: settings.minimumPressSeconds)
        menu = StatusMenu()
        model = AppModel(settings: settings, historyStore: controller.history)
        notetaker = NotetakerController(transcriber: controller.transcriber, longTranscriber: controller.longTranscriber) { [weak self] in
            self?.model.settings ?? DictationSettings()
        }
        model.notetaker = notetaker
        let calendar = CalendarService()
        calendar.excluded = { [weak self] in self?.model.settings.excludedCalendars ?? [] }
        model.calendar = calendar
        notetaker.currentMeeting = { calendar.currentMeeting() }
        let briefingPill = controller.pill
        briefing = BriefingController(calendar: calendar, notetaker: notetaker,
                                      settings: { [weak self] in self?.model.settings ?? DictationSettings() },
                                      anchor: { briefingPill.cardAnchor })
        briefing?.onUpcoming = { title, start in briefingPill.remind(title: title, start: start) }
        briefing?.start()
        model.runTransform = { [weak self] text, instruction in
            let settings = self?.model.settings ?? DictationSettings()
            let client = settings.ai.completer(for: .transforms, llm: settings.llm, onFallback: DictationController.logFallback(.transforms))
            return try await client.transform(text, instruction: instruction)
        }
        NSApp.appearance = model.appearanceMode.nsAppearance
        mainWindow = MainWindowController(model: model)
        let scratchpadWindow = ScratchpadWindowController(model: model)
        self.scratchpadWindow = scratchpadWindow
        model.openScratchpad = { scratchpadWindow.open($0) }
        NSApp.mainMenu = Self.makeMainMenu(target: self)

        hotkey.onAction = { [weak self] action in self?.controller.handle(action) }
        hotkey.onCommandModifier = { [weak self] command in self?.controller.setNextRecordingIsCommand(command) }
        hotkey.onModifierDuringRecording = { [weak self] modifier in self?.controller.modifierPressed(modifier) }
        let barPill = controller.pill
        assistant = AssistantController(settings: { [weak self] in self?.model.settings ?? DictationSettings() },
                                        anchor: { barPill.cardAnchor })
        assistant.setAwaitsConfirmation = { [weak self] waiting in self?.hotkey.awaitsConfirmation = waiting }
        barPill.onMove = { [weak self] in self?.assistant.followBar() }
        assistant.liveMeeting = { [weak self] in await self?.notetaker.liveTranscript() }
        // After the speech models, so the start of the app stays quick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.assistant.prepareSpares() }
        hotkey.onConfirmationKey = { [weak self] key in self?.assistant.key(key) }
        // Corrections the user makes after a dictation become dictionary suggestions, unless
        // the dictionary already has them or they were dismissed once.
        controller.corrections.onCorrections = { [weak self] found in
            guard let self else { return }
            var settings = self.model.settings
            for item in found {
                let key = "\(item.from)→\(item.to)"
                guard !settings.dismissedSuggestions.contains(key), !settings.replacements.contains(item),
                      !settings.dictionarySuggestions.contains(item) else { continue }
                settings.dictionarySuggestions.append(item)
            }
            self.model.settings = settings
        }
        controller.assistantTakesReplies = { [weak self] in self?.assistant.takesReplies ?? false }
        controller.onAssistantRequest = { [weak self] request, bundleId in self?.assistant.handle(request: request, frontApp: bundleId) }
        hotkey.onNotetakerShortcut = { [weak self] in self?.notetaker.toggle() }
        hotkey.onTransformShortcut = { [weak self] index in self?.controller.applyTransform(at: index) }
        hotkey.onViewChanges = { [weak self] in self?.diffWindow.toggle() }
        hotkey.onPasteLast = { [weak self] in self?.controller.pasteLast() }
        hotkey.onCopyLast = { [weak self] in
            self?.controller.copyLast()
            self?.controller.pill.flash("Last dictation copied", seconds: 1.2)
        }
        hotkey.onOpenScratchpad = { [weak self] in self?.scratchpadWindow?.open() }
        controller.onTransformApplied = { [weak self] change in self?.diffWindow.record(change) }
        hotkey.transformShortcutCount = settings.transformsEnabled ? min(9, settings.transforms.count) : 0
        controller.pill.hiddenInScreenShare = settings.hideInScreenShare
        controller.resetHotkey = { [weak self] in self?.hotkey.reset() }
        controller.setAcceptsRecordings = { [weak self] accepts in self?.hotkey.acceptsRecordings = accepts }
        controller.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.model.status = status
            self.model.llmReady = self.controller.llmReady
            if status == .ready, self.reportedLLMState != self.controller.llmReady {
                self.reportedLLMState = self.controller.llmReady
                if !self.controller.llmReady {
                    let reason = self.controller.settings.llm.usesAppleModel
                        ? AppleModelCleaner.unavailableReason ?? "Apple Intelligence did not answer." : "LM Studio did not answer."
                    self.model.notify("Cleanup is offline", "\(reason) Dictation works, but the raw transcript is pasted.")
                }
            }
            if case .failed(let message) = status { self.model.notify("Dictation stopped", message) }
            self.refreshMenu()
        }
        notetaker.onRecordingChange = { [weak self] recording in
            self?.controller.pill.model.meetingActive = recording
            if recording { self?.controller.pill.flash("Notetaker is recording", seconds: 1.5) }
        }
        notetaker.onFinished = { [weak self] meeting in
            if meeting.status == .done {
                self?.model.notify("Meeting notes ready", meeting.displayTitle)
            } else {
                self?.model.notify("Meeting could not be processed", meeting.problem)
            }
        }
        controller.onHistoryChange = { [weak self] in self?.model.reloadHistory() }
        model.onSettingsChange = { [weak self] settings in self?.apply(settings) }
        _Concurrency.Task {
            await Connectors.applyAwork(settings)
            if let path = ClaudeCLI.locate(custom: settings.ai.claudePath) { await Connectors.detectClaudeCodePolarionServer(claudePath: path) }
        }

        let pill = controller.pill
        pill.model.language = settings.asr.language
        pill.model.transformName = settings.barTransformIndex.map { settings.transforms[$0].name } ?? ""
        pill.model.onMic = { [weak self] in self?.controller.toggleClickRecording() }
        pill.model.onCancel = { [weak self] in self?.controller.handle(.cancel) }
        pill.model.onLanguage = { [weak self] in self?.cycleLanguage() }
        pill.model.onLanguageMenu = { [weak self] in self?.showLanguageMenu() }
        pill.model.onNotetaker = { [weak self] in self?.notetaker.toggle() }
        pill.model.onScratchpad = { [weak self] in self?.scratchpadWindow?.open() }
        pill.model.showScratchpad = settings.scratchpadOnBar
        pill.model.onTransform = { [weak self] in
            guard let self, let index = self.model.settings.barTransformIndex else { return }
            AppLog.info("bar transform button: \(self.model.settings.transforms[index].name)")
            self.controller.applyTransform(at: index, fromShortcut: false)
        }
        pill.model.onTransformMenu = { [weak self] in self?.showTransformMenu() }
        pill.model.onNotetakerMenu = { [weak self] in self?.showMeetingMenu() }
        pill.idleVisible = settings.showIdlePill

        menu.onOpenApp = { [weak self] in self?.mainWindow.show() }
        menu.onToggleCleanup = { [weak self] in self?.model.settings.llm.enabled.toggle() }
        menu.onPasteLast = { [weak self] in
            // The menu closes first, so the focused app is back in front when Cmd+V arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.controller.pasteLast() }
        }
        menu.onCopyLast = { [weak self] in self?.controller.copyLast() }
        menu.onReloadSettings = { [weak self] in self?.reloadSettings() }
        menu.onShowPermissions = { [weak self] in self?.mainWindow.show(section: .settings) }

        controller.prepare()
        if settings.testControl { installTestControl() }
        if Permission.allGranted {
            mainWindow.show(section: .home)
        } else {
            AppLog.info("missing permissions: \(Permission.missing.map(\.title).joined(separator: ", "))")
            model.notify("Permissions missing", Permission.missing.map(\.title).joined(separator: ", "))
            mainWindow.show(section: .settings)
            // Asking puts the app into the lists in System Settings and shows the system dialogs,
            // so the user does not have to add it there by hand.
            for permission in Permission.missing { permission.request() }
        }
        startHotkeyIfPossible()
        // Permissions can be granted at any time in System Settings, and macOS may refuse the
        // tap for a moment right after granting. A light check every 2 seconds covers both and
        // keeps the permission display in the window current.
        systemTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.model.refreshSystemState()
            self?.startHotkeyIfPossible()
        }
        refreshMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func startHotkeyIfPossible() {
        guard !hotkey.isRunning, Permission.allGranted else { return }
        if hotkey.start() {
            AppLog.info("ready for dictation")
        } else {
            tapFailures += 1
            if tapFailures == 30 {
                AppLog.error("event tap still refused; quit and reopen LocalDictation")
            }
        }
        refreshMenu()
    }

    private func refreshMenu() {
        menu.update(status: controller.status, cleanupEnabled: controller.settings.llm.enabled,
                    llmReady: controller.llmReady)
    }

    /// Saves changed settings and applies them to the running parts.
    private func apply(_ settings: DictationSettings) {
        controller.updateSettings(settings)
        _Concurrency.Task { await Connectors.applyAwork(settings) }
        NSApp.appearance = AppearanceMode(rawValue: settings.appearance)?.nsAppearance
        hotkey.setMinimumPress(settings.minimumPressSeconds)
        controller.pill.idleVisible = settings.showIdlePill
        controller.pill.model.language = settings.asr.language
        controller.pill.model.showScratchpad = settings.scratchpadOnBar
        controller.pill.model.transformName = settings.barTransformIndex.map { settings.transforms[$0].name } ?? ""
        controller.pill.hiddenInScreenShare = settings.hideInScreenShare
        hotkey.transformShortcutCount = settings.transformsEnabled ? min(9, settings.transforms.count) : 0
        do {
            try settingsStore.save(settings)
        } catch {
            AppLog.error("settings not saved: \(error)")
        }
        refreshMenu()
    }

    /// The arrow next to the bar's Transform button: a card with the transforms above the bar.
    /// The app in front keeps focus, so the chosen transform works on its selected text, and the
    /// button applies it on the next click.
    private func showTransformMenu() {
        let transforms = model.settings.transforms
        let pill = controller.pill
        let card = TransformPickerView(transforms: transforms, current: model.settings.barTransformIndex) { [weak self] index in
            pill.closeCard()
            guard let self, transforms.indices.contains(index) else { return }
            self.model.settings.barTransformID = transforms[index].id.uuidString
            AppLog.info("bar transform chosen: \(transforms[index].name)")
            // Gives the card time to close before the selection is copied.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.controller.applyTransform(at: index, fromShortcut: false)
            }
        } edit: { [weak self] in
            pill.closeCard()
            self?.mainWindow.show(section: .transforms)
        }
        pill.showCard(AnyView(card), name: "transform")
    }

    /// The arrow next to the bar's Notetaker button: today's meetings from the calendar, each
    /// with Start note, or Stop while a recording runs.
    private func showMeetingMenu() {
        let pill = controller.pill
        let calendar = model.calendar
        calendar?.refresh()
        let meetings = (calendar?.remainingToday ?? []).map {
            MeetingCardView.Meeting(id: $0.id, title: $0.title, start: $0.start, end: $0.end)
        }
        let card = MeetingCardView(
            meetings: meetings, calendarConnected: calendar?.authorized ?? false, recording: notetaker.isRecording,
            start: { [weak self] id in
                pill.closeCard()
                AppLog.info("note started from the bar card\(id == nil ? "" : " for a calendar meeting")")
                if let id, let event = calendar?.event(id: id) {
                    self?.notetaker.start(event: event)
                } else {
                    self?.notetaker.start(matchCalendar: false)
                }
            },
            stop: { [weak self] in
                pill.closeCard()
                self?.notetaker.stop()
            },
            connectCalendar: { [weak self] in
                pill.closeCard()
                calendar?.connect()
                self?.mainWindow.show(section: .notetaker)
            },
            close: { pill.closeCard() },
            ask: { [weak self] question in
                pill.closeCard()
                MainActor.assumeIsolated {
                    self?.assistant.handle(request: question, frontApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
                }
            })
        pill.showCard(AnyView(card), name: "meetings")
    }

    /// The arrow next to the bar's language button: picks the language directly instead of cycling.
    private func showLanguageMenu() {
        let pill = controller.pill
        let card = LanguagePickerView(current: model.settings.asr.language) { [weak self] code in
            pill.closeCard()
            guard let self else { return }
            self.model.settings.asr.language = code
            AppLog.info("language \(code) from the bar card")
        }
        pill.showCard(AnyView(card), name: "language")
    }

    private func cycleLanguage() {
        let order = ["auto", "de", "en"]
        let current = order.firstIndex(of: model.settings.asr.language) ?? 0
        model.settings.asr.language = order[(current + 1) % order.count]
        controller.pill.flash(Self.languageName(model.settings.asr.language), seconds: 1)
        AppLog.info("language \(model.settings.asr.language)")
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "de": return "German"
        case "en": return "English"
        default: return "Detect language automatically"
        }
    }

    private func reloadSettings() {
        do {
            model.settings = try settingsStore.load()
            AppLog.info("settings reloaded")
        } catch {
            AppLog.error("settings reload failed: \(error)")
            NSSound.beep()
        }
    }

    /// Recording control for automated live tests: `local.dictation.LocalDictation.test.start`,
    /// `.stop` and `.cancel` act like pressing and releasing Fn and pressing Esc, `.click`
    /// like the microphone button in the pill. Only installed when `testControl` is on.
    private func installTestControl() {
        let center = DistributedNotificationCenter.default()
        let actions: [(String, () -> Void)] = [
            ("start", { [weak self] in self?.controller.handle(.startRecording) }),
            ("stop", { [weak self] in self?.controller.handle(.stopAndProcess) }),
            ("cancel", { [weak self] in self?.controller.handle(.cancel) }),
            ("click", { [weak self] in self?.controller.toggleClickRecording() }),
            ("command", { [weak self] in
                self?.controller.setNextRecordingIsCommand(true)
                self?.controller.handle(.startRecording)
            }),
            ("selectAll", { Paster.press(keyCode: Paster.keyCode(for: "a")) }),
            ("transform", { [weak self] in self?.controller.pill.model.onTransform?() }),
            ("transformMenu", { [weak self] in self?.controller.pill.model.onTransformMenu?() }),
            ("meetingMenu", { [weak self] in self?.controller.pill.model.onNotetakerMenu?() }),
            ("meetingStart", { [weak self] in self?.notetaker.start(title: "LocalDictation test recording", continuing: false) }),
            ("meetingContinue", { [weak self] in self?.notetaker.start(title: "LocalDictation test recording", continuing: true) }),
            ("meetingStop", { [weak self] in self?.notetaker.stop() }),
        ]
        // Transcribes and summarises a saved meeting again; the notification's object is its id.
        center.addObserver(forName: Notification.Name("local.dictation.LocalDictation.test.reprocess"), object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? String,
                  let meeting = self.notetaker.meetings.first(where: { $0.id.uuidString == id }) else { return }
            AppLog.info("test control: reprocess \(id)")
            self.notetaker.process(meeting)
        }
        // The briefing for the next meeting with other people, whenever it is.
        center.addObserver(forName: Notification.Name("local.dictation.LocalDictation.test.briefing"), object: nil, queue: .main) { [weak self] note in
            AppLog.info("test control: briefing")
            self?.briefing?.show(titled: note.object as? String)
        }
        // An assistant request as if spoken; the notification's object is the text. "confirm"
        // and "cancel" press Return and Esc on the card.
        center.addObserver(forName: Notification.Name("local.dictation.LocalDictation.test.assistant"), object: nil, queue: .main) { [weak self] note in
            guard let self, let text = note.object as? String else { return }
            AppLog.info("test control: assistant")
            switch text {
            case "confirm": self.assistant.key(.confirm)
            case "cancel": self.assistant.key(.cancel)
            default: self.assistant.handle(request: text, frontApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            }
        }
        for (name, action) in actions {
            center.addObserver(forName: Notification.Name("local.dictation.LocalDictation.test.\(name)"),
                               object: nil, queue: .main) { _ in
                AppLog.info("test control: \(name)")
                action()
            }
        }
        AppLog.info("test control enabled")
    }

    @objc func showSettings() { mainWindow.show(section: .settings) }
    @objc func showMainWindow() { mainWindow.show() }

    /// App, Edit and Window menus. The Edit menu is what makes Cmd+C, Cmd+V and Cmd+A work in
    /// the text fields of the window.
    static func makeMainMenu(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LocalDictation", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide LocalDictation", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit LocalDictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let open = windowMenu.addItem(withTitle: "LocalDictation", action: #selector(showMainWindow), keyEquivalent: "0")
        open.target = target
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}
