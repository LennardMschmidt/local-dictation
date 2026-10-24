import Carbon.HIToolbox
import CoreGraphics
import DictationCore
import Foundation

/// Watches the keyboard through a session event tap and turns Fn, Space and Esc presses into
/// recording actions with `HotkeyStateMachine`.
///
/// The tap is a filtering tap, so every key event of every app waits for its callback. It
/// therefore runs on its own thread with its own run loop; the main thread can be busy starting
/// the microphone without slowing down typing. The state machine lives on that thread too.
/// Actions go to `onAction` on the main thread.
final class HotkeyMonitor {
    var onAction: ((HotkeyStateMachine.Action) -> Void)?
    /// Tells the controller, before `.startRecording` arrives, whether ctrl was held with fn.
    var onCommandModifier: ((Bool) -> Void)?
    /// ctrl or ⌥ pressed while fn is held, at any moment of the recording: the recording becomes
    /// an instruction (ctrl) or an assistant request (⌥). The recording itself started with fn.
    var onModifierDuringRecording: ((RecordingModifier) -> Void)?
    /// Return or Esc while the assistant waits for a confirmation; the key goes only to the app.
    var onConfirmationKey: ((ConfirmationKey) -> Void)?

    enum RecordingModifier { case control, option }
    enum ConfirmationKey { case confirm, cancel }

    /// Whether Return and Esc are taken for a confirmation. Set from the main thread, read on
    /// the tap thread.
    var awaitsConfirmation: Bool {
        get { acceptingLock.lock(); defer { acceptingLock.unlock() }; return confirming }
        set { acceptingLock.lock(); confirming = newValue; acceptingLock.unlock() }
    }
    private var confirming = false
    /// The modifiers already reported for the running recording, so each is sent once.
    private var reportedModifiers: Set<CGEventFlags.RawValue> = []
    /// ⌥M, the Notetaker shortcut.
    var onNotetakerShortcut: (() -> Void)?
    /// ⌥1 to ⌥9 with the transform index 0 to 8, ⌥O, ⌥⇧V, ⌥⇧C and ⌥⇧S.
    var onTransformShortcut: ((Int) -> Void)?
    var onViewChanges: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onCopyLast: (() -> Void)?
    var onOpenScratchpad: (() -> Void)?

    /// How many transforms have a ⌥ number shortcut right now; 0 when transforms are off.
    /// Set from the main thread, read on the tap thread.
    var transformShortcutCount: Int {
        get { acceptingLock.lock(); defer { acceptingLock.unlock() }; return transformCount }
        set { acceptingLock.lock(); transformCount = newValue; acceptingLock.unlock() }
    }
    private var transformCount = 0

    private static let digitKeyCodes: [Int64] = [
        Int64(kVK_ANSI_1), Int64(kVK_ANSI_2), Int64(kVK_ANSI_3), Int64(kVK_ANSI_4), Int64(kVK_ANSI_5),
        Int64(kVK_ANSI_6), Int64(kVK_ANSI_7), Int64(kVK_ANSI_8), Int64(kVK_ANSI_9),
    ]

    // Only touched on the tap thread.
    private var machine: HotkeyStateMachine
    private var fnIsDown = false
    private var swallowedKeyCodes: Set<Int64> = []

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let acceptingLock = NSLock()
    private var accepting = false

    init(minimumPress: Double) {
        machine = HotkeyStateMachine(minimumPress: minimumPress)
    }

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Whether a new recording may start. The controller sets this from the main thread; the
    /// tap reads it before it lets an Fn press start anything, so the two never disagree.
    var acceptsRecordings: Bool {
        get { acceptingLock.lock(); defer { acceptingLock.unlock() }; return accepting }
        set { acceptingLock.lock(); accepting = newValue; acceptingLock.unlock() }
    }

    /// Installs the tap on its own thread. Fails without the Accessibility and Input Monitoring
    /// permissions.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            AppLog.error("event tap could not be created; Accessibility or Input Monitoring missing")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "LocalDictation event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.thread = thread
        AppLog.info("event tap installed")
        return true
    }

    /// Returns the state machine to idle, for example after the microphone failed to start.
    func reset() {
        perform { $0.machine.reset() }
    }

    func setMinimumPress(_ seconds: Double) {
        perform { $0.machine.minimumPress = seconds }
    }

    private func perform(_ block: @escaping (HotkeyMonitor) -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            if let self { block(self) }
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func send(_ action: HotkeyStateMachine.Action) {
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Paster.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system turns a tap off when a callback was too slow or on secure input.
            // Turning it back on is the documented reaction; a running recording is cancelled
            // because key releases may have been missed.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            AppLog.error("event tap was disabled by the system and re-enabled")
            if machine.isRecording { send(.cancel) }
            machine.reset()
            fnIsDown = false
            swallowedKeyCodes.removeAll()
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode != kVK_Function {
                if machine.isRecording {
                    for (flag, modifier) in [(CGEventFlags.maskControl, RecordingModifier.control), (.maskAlternate, .option)]
                    where event.flags.contains(flag) && !reportedModifiers.contains(flag.rawValue) {
                        reportedModifiers.insert(flag.rawValue)
                        DispatchQueue.main.async { [weak self] in self?.onModifierDuringRecording?(modifier) }
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            let down = event.flags.contains(.maskSecondaryFn)
            guard down != fnIsDown else { return Unmanaged.passUnretained(event) }
            fnIsDown = down
            if down, machine.state == .idle, !acceptsRecordings {
                return Unmanaged.passUnretained(event)
            }
            if down, machine.state == .idle {
                reportedModifiers = []
                if event.flags.contains(.maskAlternate) {
                    reportedModifiers.insert(CGEventFlags.maskAlternate.rawValue)
                    DispatchQueue.main.async { [weak self] in self?.onModifierDuringRecording?(.option) }
                }
                let command = event.flags.contains(.maskControl)
                DispatchQueue.main.async { [weak self] in self?.onCommandModifier?(command) }
            }
            let now = ProcessInfo.processInfo.systemUptime
            return apply(machine.handle(down ? .fnDown(now) : .fnUp(now)), event: event, keyCode: nil)

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // The app never saw the key going down, so it must not see it going up either.
            if swallowedKeyCodes.remove(keyCode) != nil { return nil }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if swallowedKeyCodes.contains(keyCode) { return nil }
            if !fnIsDown, awaitsConfirmation, keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter || keyCode == kVK_Escape {
                swallowedKeyCodes.insert(keyCode)
                let key: ConfirmationKey = keyCode == kVK_Escape ? .cancel : .confirm
                DispatchQueue.main.async { [weak self] in self?.onConfirmationKey?(key) }
                return nil
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, let action = shortcutAction(keyCode: keyCode, flags: event.flags) {
                swallowedKeyCodes.insert(keyCode)
                DispatchQueue.main.async(execute: action)
                return nil
            }
            guard machine.state != .idle else { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return Unmanaged.passUnretained(event)
            }
            let now = ProcessInfo.processInfo.systemUptime
            let input: HotkeyStateMachine.Event
            switch Int(keyCode) {
            case kVK_Space: input = .spaceDown(now)
            case kVK_Escape: input = .escapeDown(now)
            default: input = .otherKeyDown(now)
            }
            return apply(machine.handle(input), event: event, keyCode: keyCode)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// The action of an ⌥ shortcut, or nil when the key press is not one (then it reaches the
    /// focused app unchanged, so ⌥1 still types "¡" with transforms off).
    private func shortcutAction(keyCode: Int64, flags: CGEventFlags) -> (() -> Void)? {
        if Self.isOptionOnly(flags) {
            if keyCode == kVK_ANSI_M { return { [weak self] in self?.onNotetakerShortcut?() } }
            let count = transformShortcutCount
            if keyCode == kVK_ANSI_O, count > 0 { return { [weak self] in self?.onViewChanges?() } }
            if let index = Self.digitKeyCodes.firstIndex(of: keyCode), index < count {
                return { [weak self] in self?.onTransformShortcut?(index) }
            }
        }
        if Self.isOptionShiftOnly(flags) {
            switch Int(keyCode) {
            case kVK_ANSI_V: return { [weak self] in self?.onPasteLast?() }
            case kVK_ANSI_C: return { [weak self] in self?.onCopyLast?() }
            case kVK_ANSI_S: return { [weak self] in self?.onOpenScratchpad?() }
            default: break
            }
        }
        return nil
    }

    static func isOptionShiftOnly(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate) && flags.contains(.maskShift)
            && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
    }

    static func isOptionOnly(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand) && !flags.contains(.maskControl) && !flags.contains(.maskShift)
    }

    /// The swallow decision is needed right away; the action itself (starting the microphone,
    /// for example) runs on the main thread after the callback has returned.
    private func apply(_ decision: HotkeyStateMachine.Decision, event: CGEvent, keyCode: Int64?) -> Unmanaged<CGEvent>? {
        if decision.action != .none { send(decision.action) }
        guard decision.swallow else { return Unmanaged.passUnretained(event) }
        if let keyCode { swallowedKeyCodes.insert(keyCode) }
        return nil
    }
}
