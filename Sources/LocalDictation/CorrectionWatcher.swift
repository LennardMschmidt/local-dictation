import AppKit
import ApplicationServices
import DictationCore

/// Looks at the text field a dictation went into, 20 and 60 seconds after pasting, and passes
/// on the words the user corrected there. It only reads, through the Accessibility API, and only
/// the field that had focus when the text was pasted. Apps that do not expose their text (many
/// Electron apps, terminals) give nothing, which is fine.
final class CorrectionWatcher {
    var onCorrections: (([Replacement]) -> Void)?
    private var generation = 0

    func watch(pasted: String, bundleId: String?) {
        generation += 1
        let current = generation
        guard pasted.split(separator: " ").count >= 2,
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleId else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return }
        let field = element as! AXUIElement
        var reported = Set<String>()
        for delay in [20.0, 60.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == current, let text = Self.value(of: field) else { return }
                let found = CorrectionLearner.corrections(pasted: pasted, field: text)
                    .filter { reported.insert("\($0.from)→\($0.to)").inserted }
                if !found.isEmpty {
                    AppLog.info("\(found.count) corrections after a dictation")
                    self.onCorrections?(found)
                }
            }
        }
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
