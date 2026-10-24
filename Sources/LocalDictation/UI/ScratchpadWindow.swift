import AppKit
import DictationCore
import SwiftUI

/// The floating scratchpad, like Wispr Flow's: opens straight onto a new note from the bar or
/// ⌥⇧S, keeps open notes as tabs and writes every change into the same notes the Scratchpad
/// page shows.
final class ScratchpadWindowController {
    private var panel: ScratchpadPanel?
    private let state: ScratchpadWindowState
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        state = ScratchpadWindowState(notes: model.scratchpad)
    }

    /// Shows the window with `note`, or with a new note when nil.
    func open(_ note: UUID? = nil) {
        let id = note ?? model.scratchpad.newNote()
        state.open(id)
        if panel == nil { makePanel() }
        guard let panel else { return }
        moveToScreenWithMouse(panel)
        // The panel joins every Space. Shown before the app activates, it is already on the current
        // Space, so macOS stays there instead of switching to the Space of the main window.
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Centres the panel at the bottom of the screen with the mouse pointer when it is on another screen.
    private func moveToScreenWithMouse(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              panel.screen != screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 80))
    }

    private func makePanel() {
        let size = ScratchpadWindowState.compactSize
        let panel = ScratchpadPanel(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.borderless, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 420, height: 320)
        let view = ScratchpadFloatingView(state: state, model: model,
                                          close: { [weak self] in self?.close() },
                                          toggleSize: { [weak self] in self?.toggleSize() })
        panel.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 80))
        }
        self.panel = panel
    }

    private func toggleSize() {
        guard let panel else { return }
        let compact = panel.frame.width < ScratchpadWindowState.expandedSize.width - 10
        let size = compact ? ScratchpadWindowState.expandedSize : ScratchpadWindowState.compactSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.origin.x += (frame.width - size.width) / 2
        frame.size = size
        panel.setFrame(frame, display: true, animate: true)
        state.expanded = compact
    }

    private func close() {
        state.closeAll()
        panel?.orderOut(nil)
    }
}

/// Borderless, but takes the keyboard, so notes can be typed and dictated into.
private final class ScratchpadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Open tabs, the selected note and the window's view options.
final class ScratchpadWindowState: ObservableObject {
    static let compactSize = NSSize(width: 520, height: 420)
    static let expandedSize = NSSize(width: 900, height: 640)

    let notes: ScratchpadModel
    @Published var tabs: [UUID] = []
    @Published var selected: UUID?
    @Published var showList = false
    @Published var expanded = false
    @Published var fontSize: CGFloat = 16

    init(notes: ScratchpadModel) {
        self.notes = notes
    }

    func open(_ id: UUID) {
        if !tabs.contains(id) { tabs.append(id) }
        selected = id
    }

    func closeTab(_ id: UUID) {
        notes.removeIfEmpty(id)
        tabs.removeAll { $0 == id }
        if selected == id { selected = tabs.last }
        if tabs.isEmpty { open(notes.newNote()) }
    }

    func closeAll() {
        tabs.forEach(notes.removeIfEmpty)
        tabs = []
        selected = nil
    }
}

struct ScratchpadFloatingView: View {
    @ObservedObject var state: ScratchpadWindowState
    @ObservedObject var notes: ScratchpadModel
    @ObservedObject var model: AppModel
    let close: () -> Void
    let toggleSize: () -> Void
    @State private var query = ""
    @State private var copied = false
    @State private var transforming = false

    init(state: ScratchpadWindowState, model: AppModel, close: @escaping () -> Void, toggleSize: @escaping () -> Void) {
        self.state = state
        notes = state.notes
        self.model = model
        self.close = close
        self.toggleSize = toggleSize
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                rail
                editor.padding(.trailing, 12).padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 22).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform").font(.system(size: 17, weight: .bold)).padding(.leading, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(state.tabs, id: \.self) { id in
                        let selected = state.selected == id
                        HStack(spacing: 8) {
                            Text(notes.note(id)?.title ?? "Untitled")
                                .font(.system(size: 14, weight: selected ? .medium : .regular))
                                .lineLimit(1)
                                .frame(maxWidth: 140, alignment: .leading)
                            Button { state.closeTab(id) } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.panel : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { state.selected = id }
                    }
                    Button { state.open(notes.newNote()) } label: {
                        Image(systemName: "plus").font(.system(size: 15)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("New note")
                }
            }
            Spacer(minLength: 8)
            Button(action: toggleSize) {
                Image(systemName: state.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help(state.expanded ? "Smaller" : "Larger")
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 15)) }
                .buttonStyle(.plain)
                .help("Close")
                .padding(.trailing, 18)
        }
        .frame(height: 54)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            railButton(state.showList ? "Collapse Notes" : "Show Notes", icon: "sidebar.left") {
                withAnimation(.easeOut(duration: 0.15)) { state.showList.toggle() }
            }
            railButton("New note", icon: "square.and.pencil") { state.open(notes.newNote()) }
            if state.showList {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                    TextField("Search notes...", text: $query).textFieldStyle(.plain)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 34)
                Divider().overlay(Theme.border).padding(.horizontal, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        let list = notes.matching(query)
                        if list.isEmpty {
                            Text("No notes yet").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 16)
                        }
                        ForEach(list) { note in
                            Button { state.open(note.id) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(note.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(note.updated.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(state.selected == note.id ? Theme.selection : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                railButton("Search", icon: "magnifyingglass") { withAnimation { state.showList = true } }
                Spacer()
            }
            transformsMenu
            Menu {
                ForEach([("Small", CGFloat(14)), ("Medium", 16), ("Large", 19)], id: \.0) { name, size in
                    Button { state.fontSize = size } label: {
                        if state.fontSize == size { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: { railLabel("Formatting", icon: "textformat.size") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 8)
        .frame(width: state.showList ? 190 : 52, alignment: .leading)
    }

    private var transformsMenu: some View {
        Menu {
            ForEach(model.settings.transforms) { transform in
                Button(transform.name.isEmpty ? "Unnamed" : transform.name) { apply(transform) }
            }
        } label: { railLabel(transforming ? "Working…" : "Transforms", icon: "wand.and.stars") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .disabled(transforming || currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Apply a transform to this note")
    }

    private func railButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { railLabel(title, icon: icon) }.buttonStyle(.plain).help(title)
    }

    private func railLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).frame(width: 22)
            if state.showList { Text(title).font(.system(size: 14)).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(height: 36)
        .contentShape(Rectangle())
    }

    private var currentText: String { state.selected.flatMap { notes.note($0)?.text } ?? "" }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16).fill(Theme.panel)
            if let id = state.selected {
                TextEditor(text: Binding(get: { notes.note(id)?.text ?? "" }, set: { notes.setText($0, of: id) }))
                    .font(.system(size: state.fontSize))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 64)
                if currentText.isEmpty {
                    HStack(spacing: 8) {
                        Text("fn").font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.card))
                        Text("to dictate").font(.system(size: state.fontSize + 2))
                    }
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .allowsHitTesting(false)
                }
            }
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Spacer()
                    if let id = state.selected {
                        Button { notes.delete(id); state.closeTab(id) } label: {
                            Image(systemName: "trash").font(.system(size: 15))
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Theme.panel))
                                .overlay(Circle().strokeBorder(Theme.border))
                        }
                        .buttonStyle(.plain)
                        .help("Delete note")
                    }
                    Button { copy() } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.panel)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(Capsule().fill(Theme.text))
                    }
                    .buttonStyle(.plain)
                    .disabled(currentText.isEmpty)
                }
                .padding(16)
            }
        }
    }

    private func copy() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(currentText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private func apply(_ transform: Transform) {
        guard let id = state.selected, let run = model.runTransform else { return }
        let text = currentText
        transforming = true
        Task {
            let result = try? await run(text, transform.instruction)
            await MainActor.run {
                if let result, !result.isEmpty { notes.setText(result, of: id) }
                transforming = false
            }
        }
    }
}
