import AppKit
import DictationCore
import SwiftUI

/// The Scratchpad page, laid out like Wispr Flow's: the switch for the bar button, the banner
/// and the recent notes. Notes open in the floating scratchpad window.
struct ScratchpadView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var notes: ScratchpadModel
    @State private var query = ""
    @State private var searching = false

    init(model: AppModel) {
        self.model = model
        notes = model.scratchpad
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                banner
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 18) {
                        Text("Recents").font(.system(size: 17, weight: .medium))
                        Spacer()
                        if searching {
                            TextField("Search notes", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                        }
                        iconButton(searching ? "xmark" : "magnifyingglass", help: "Search") {
                            searching.toggle()
                            if !searching { query = "" }
                        }
                        iconButton("plus", help: "New note") { model.openScratchpad?(nil) }
                    }
                    .padding(.bottom, 12)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

                    let list = notes.matching(query)
                    if list.isEmpty {
                        Text(query.isEmpty ? "No notes yet. Start one above or with the scratchpad button on the bar."
                                           : "No note matches \"\(query)\".")
                            .font(.system(size: 14)).foregroundStyle(Theme.secondary).padding(.vertical, 20)
                    }
                    ForEach(list) { note in
                        NoteCard(note: note,
                                 open: { model.openScratchpad?(note.id) },
                                 pin: { notes.togglePin(note.id) },
                                 delete: { notes.delete(note.id) })
                    }
                }
            }
            .pageLayout()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Scratchpad").font(.system(size: 26, weight: .medium)).lineLimit(1).fixedSize()
            Text("Beta").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.panel)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.text))
            Spacer()
            Text("Add to bar").font(.system(size: 15))
            InfoButton("Shows the scratchpad button on the bar at the bottom of the screen. ⌥⇧S opens a new note from anywhere.")
            Toggle("", isOn: $model.settings.scratchpadOnBar).labelsHidden().toggleStyle(.switch).tint(Theme.text)
            HStack(spacing: 4) {
                KeyCapView(label: "⌥")
                KeyCapView(label: "⇧")
                KeyCapView(label: "S")
                Text("new note").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.border))
        }
    }

    private var banner: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.30, blue: 0.16), Color(red: 0.24, green: 0.16, blue: 0.10),
                                              Color(red: 0.32, green: 0.20, blue: 0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack {
                Spacer()
                Image(systemName: "note.text")
                    .font(.system(size: 120, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(0.1))
                    .padding(.trailing, 40)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("For quick thoughts you want to come back to")
                    .font(.system(size: 30, design: .serif))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Drop a to-do list, polish a message before you send it, brain dump an idea. Scratchpad is your safe space to save, create, and explore.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.openScratchpad?(nil) } label: {
                    Text("Start new note")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.95)))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.secondary).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct NoteCard: View {
    let note: ScratchNote
    let open: () -> Void
    let pin: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if note.pinned { Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                Text(note.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            }
            if !note.preview.isEmpty {
                Text(note.preview).font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            HStack {
                Text(note.updated.formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(note.updated.formatted(date: .omitted, time: .shortened)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Theme.cardHover : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 0) {
                    action("pencil", help: "Edit", open)
                    Divider().frame(height: 22)
                    action(note.pinned ? "pin.slash" : "pin", help: note.pinned ? "Unpin" : "Pin", pin)
                    Divider().frame(height: 22)
                    action("trash.fill", help: "Delete", delete).foregroundStyle(.red.opacity(0.8))
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel).shadow(color: .black.opacity(0.08), radius: 4, y: 1))
                .padding(10)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }

    private func action(_ symbol: String, help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 36, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
