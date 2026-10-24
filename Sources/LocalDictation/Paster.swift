import AppKit
import Carbon.HIToolbox
import CoreGraphics
import DictationCore

/// Inserts text into the focused app: put it on the pasteboard, press Cmd+V, put the previous
/// pasteboard contents back.
final class Paster {
    enum Outcome: Equatable {
        case pasted
        /// Secure input is on (a password field has focus), so the text stays on the pasteboard.
        case copiedOnly
    }

    /// Time the target app gets to read the pasteboard before the old contents return.
    static let restoreDelay: TimeInterval = 0.6

    /// Pastes `text`. With `rtf`, apps that take formatted text get that, all others `text`.
    func insert(_ text: String, rtf: Data? = nil) -> Outcome {
        if IsSecureEventInputEnabled() {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
            return .copiedOnly
        }
        let snapshot = PasteboardSnapshot()
        snapshot.save()
        snapshot.write(text, rtf: rtf)
        Self.pressCommandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) {
            if !snapshot.restore() { AppLog.info("pasteboard changed meanwhile, not restored") }
        }
        return .pasted
    }

    /// Reads the selected text of the focused app by pressing Cmd+C, then puts the previous
    /// pasteboard contents back. Calls `completion` with nil when nothing was selected.
    func copySelection(completion: @escaping (String?) -> Void) {
        let snapshot = PasteboardSnapshot()
        snapshot.save()
        let before = snapshot.changeCount
        Self.press(keyCode: Self.keyCode(for: "c"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let text = snapshot.changeCount != before ? snapshot.string : nil
            snapshot.restoreAlways()
            completion(text?.isEmpty == true ? nil : text)
        }
    }

    /// Copies text to the pasteboard and leaves it there.
    func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// Posts Cmd+V from a private event source, so modifier keys the user still holds do not
    /// mix into the shortcut.
    static func pressCommandV() {
        press(keyCode: keyCode(for: "v"))
    }

    /// Marks the app's own key events, so its event tap lets them pass instead of reading a
    /// Cmd+C during a recording as an Fn shortcut.
    static let syntheticMarker: Int64 = 0x4C44_4943

    /// Terminals, where Cmd+Z does not take pasted text back out and a selection cannot be
    /// replaced by pasting.
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                                         "com.cmuxterm.app", "com.termius-dmg.mac", "dev.warp.Warp-Stable"]

    /// Deletes `count` characters before the cursor, one Backspace each.
    static func pressBackspace(times count: Int) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<count {
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: isDown)
                event?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    static func press(keyCode: Int) {
        let source = CGEventSource(stateID: .privateState)
        let key = CGKeyCode(keyCode)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// The key code that produces `character` in the current keyboard layout. On most layouts
    /// this is the ANSI position, on Dvorak and similar layouts it is elsewhere.
    static func keyCode(for character: Unicode.Scalar) -> Int {
        let fallback = character == "c" ? kVK_ANSI_C : kVK_ANSI_V
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallback
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> Int in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            for keyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState, chars.count, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(character.value) {
                    return keyCode
                }
            }
            return fallback
        }
    }
}
