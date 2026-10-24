import AppKit
import DictationCore
import SwiftUI

/// The ⌥O window: the last transform's original and result side by side, with removed words
/// struck through and added words highlighted.
final class TransformDiffWindow {
    private var panel: NSPanel?
    private(set) var lastChange: DictationController.TransformChange?

    func record(_ change: DictationController.TransformChange) {
        lastChange = change
        if panel?.isVisible == true { show() }
    }

    func toggle() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        let view = TransformDiffView(change: lastChange) { [weak self] in self?.panel?.orderOut(nil) }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 645, height: 315),
                                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        panel?.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main?.visibleFrame, let panel {
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + 90))
        }
        panel?.orderFrontRegardless()
    }
}

struct TransformDiffView: View {
    let change: DictationController.TransformChange?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("See changes in diff").font(.system(size: 22, design: .serif))
                    Text("Press ⌥O to see changes in text transforms").foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            if let change {
                HStack(alignment: .top, spacing: 12) {
                    column(title: "Original", text: diffText(change, showRemoved: true), copy: change.original)
                    column(title: "\(change.name) 🪄", text: diffText(change, showRemoved: false), copy: change.result)
                }
            } else {
                Text("No transform yet. Select text and press ⌥1.").foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
        .padding(21)
        .frame(width: 645, height: 315, alignment: .topLeading)
        .background(Theme.panel)
    }

    private func column(title: String, text: Text, copy: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Theme.sectionLabel(title)
                Spacer()
                Button {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(copy, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .help("Copy")
            }
            ScrollView {
                text.font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        }
    }

    /// The original with removed words struck through, or the result with added words marked.
    private func diffText(_ change: DictationController.TransformChange, showRemoved: Bool) -> Text {
        WordDiff.diff(change.original, change.result).reduce(Text("")) { text, part in
            switch part.kind {
            case .same: return text + Text(part.text)
            case .removed: return showRemoved ? text + Text(part.text).strikethrough().foregroundColor(.red.opacity(0.8)) : text
            case .added: return showRemoved ? text : text + Text(part.text).foregroundColor(Theme.tealDark).bold()
            }
        }
    }
}
