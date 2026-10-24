import AppKit
import DictationCore
import ServiceManagement

/// The menu bar icon and its menu.
final class StatusMenu: NSObject, NSMenuDelegate {
    var onOpenApp: (() -> Void)?
    var onToggleCleanup: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onCopyLast: (() -> Void)?
    var onReloadSettings: (() -> Void)?
    var onShowPermissions: (() -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cleanupItem = NSMenuItem(title: "Clean up text with local LLM", action: nil, keyEquivalent: "")
    private let permissionsItem = NSMenuItem(title: "Permissions…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at login", action: nil, keyEquivalent: "")
    private var cleanupEnabled = true
    private var llmReady = false

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(item("Open LocalDictation", #selector(openApp)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hold Fn to dictate, Fn+Space for hands-free, Esc cancels", action: nil, keyEquivalent: "")
            .isEnabled = false
        menu.addItem(.separator())
        cleanupItem.target = self
        cleanupItem.action = #selector(toggleCleanup)
        menu.addItem(cleanupItem)
        menu.addItem(item("Paste last dictation", #selector(pasteLast)))
        menu.addItem(item("Copy last dictation", #selector(copyLast)))
        menu.addItem(.separator())
        menu.addItem(item("Open history", #selector(openHistory)))
        menu.addItem(item("Open settings file", #selector(openSettings)))
        menu.addItem(item("Reload settings", #selector(reloadSettings)))
        menu.addItem(item("Open log", #selector(openLog)))
        permissionsItem.target = self
        permissionsItem.action = #selector(showPermissions)
        menu.addItem(permissionsItem)
        loginItem.target = self
        loginItem.action = #selector(toggleLoginItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit LocalDictation", #selector(quit), key: "q"))
        self.item.menu = menu
        self.item.button?.toolTip = "LocalDictation"
        update(status: .loadingModel, cleanupEnabled: true, llmReady: false)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func update(status: DictationController.Status, cleanupEnabled: Bool, llmReady: Bool) {
        self.cleanupEnabled = cleanupEnabled
        self.llmReady = llmReady
        let symbol: String
        switch status {
        case .loadingModel:
            symbol = "hourglass"
            statusLine.title = "Loading speech model…"
        case .ready:
            symbol = "waveform"
            statusLine.title = Permission.allGranted ? "Ready" : "Waiting for permissions"
        case .recording:
            symbol = "waveform.circle.fill"
            statusLine.title = "Recording"
        case .processing:
            symbol = "ellipsis.circle"
            statusLine.title = "Transcribing"
        case .failed(let message):
            symbol = "exclamationmark.triangle"
            statusLine.title = message
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusLine.title)
        image?.isTemplate = true
        item.button?.image = image
        refreshItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshItems()
    }

    private func refreshItems() {
        cleanupItem.state = cleanupEnabled ? .on : .off
        cleanupItem.title = cleanupEnabled && !llmReady
            ? "Clean up text with local LLM (LM Studio not reachable)"
            : "Clean up text with local LLM"
        let missing = Permission.missing
        permissionsItem.title = missing.isEmpty ? "Permissions (all granted)" : "Permissions… (\(missing.count) missing)"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Adds or removes the app from the login items (System Settings > General > Login Items).
    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                AppLog.info("start at login off")
            } else {
                try SMAppService.mainApp.register()
                AppLog.info("start at login on")
            }
        } catch {
            AppLog.error("login item change failed: \(error)")
            NSSound.beep()
        }
        refreshItems()
    }

    @objc private func openApp() { onOpenApp?() }
    @objc private func toggleCleanup() { onToggleCleanup?() }
    @objc private func pasteLast() { onPasteLast?() }
    @objc private func copyLast() { onCopyLast?() }
    @objc private func reloadSettings() { onReloadSettings?() }
    @objc private func showPermissions() { onShowPermissions?() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openHistory() { open(AppPaths.historyFile) }
    @objc private func openSettings() { open(AppPaths.settingsFile) }
    @objc private func openLog() { open(AppPaths.logFile) }

    private func open(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
