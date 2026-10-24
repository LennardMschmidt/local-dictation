import AppKit
import ApplicationServices

/// Where the bottom edge of the usable screen is for the pill, like Wispr Flow's bar: above the
/// Dock while the Dock is shown, at the screen edge while it is hidden.
///
/// The visible frame of a screen always leaves room for a Dock that is not set to hide, even
/// while a full-screen app hides it. So the frontmost app is asked through the Accessibility API
/// whether its focused window is in full-screen mode; the app has that permission for pasting
/// anyway. Without an answer, a window covering the whole screen counts as full screen.
enum DockPlacement {
    static func bottom(of screen: NSScreen) -> CGFloat {
        let dockSpace = screen.visibleFrame.minY - screen.frame.minY
        guard dockSpace > 10 else { return screen.frame.minY }
        return frontmostAppIsFullScreen(on: screen) ? screen.frame.minY : screen.visibleFrame.minY
    }

    static func frontmostAppIsFullScreen(on screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if let fullScreen = accessibilityFullScreen(pid: app.processIdentifier) { return fullScreen }
        return hasScreenSizedWindow(pid: app.processIdentifier, screen: screen)
    }

    /// The `AXFullScreen` attribute of the app's focused window, nil when it cannot be read.
    static func accessibilityFullScreen(pid: pid_t) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    static func hasScreenSizedWindow(pid: pid_t, screen: NSScreen) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let size = screen.frame.size
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return false }
            return abs(bounds.width - size.width) < 1 && abs(bounds.height - size.height) < 1
        }
    }
}
