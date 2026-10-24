import AppKit
import DictationCore
import SwiftUI

/// A dark card that opens above the bar from a button's arrow, like Wispr Flow's pop-ups on
/// the bar: the transforms, or today's meetings.
///
/// The panel never becomes key or active, so the app in front keeps its focus and selection. A
/// click anywhere else or Esc closes it.
final class BarCard {
    private var panel: PickerPanel?
    private var monitors: [Any] = []
    private var onClose: (() -> Void)?

    var isOpen: Bool { panel != nil }

    /// Opens `content` with its bottom edge at `bottom`, centred on `centerX` (screen coordinates).
    func show(_ content: AnyView, centerX: CGFloat, bottom: CGFloat, closed: @escaping () -> Void) {
        close()
        onClose = closed
        let hosting = FirstClickHostingView(rootView: content)
        let size = hosting.fittingSize
        let panel = PickerPanel(contentRect: NSRect(x: (centerX - size.width / 2).rounded(), y: bottom,
                                                    width: size.width, height: size.height),
                                styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel

        // Clicks in other apps close the card; clicks inside it reach its buttons.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.close()
        }) {
            monitors.append(global)
        }
        if let escape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.close() }
        }) {
            monitors.append(escape)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            if event.window !== self?.panel { self?.close() }
            return event
        }) {
            monitors.append(local)
        }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        let closed = onClose
        onClose = nil
        closed?()
    }
}

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click, although its window never becomes key.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct TransformPickerView: View {
    let transforms: [Transform]
    let current: Int?
    let choose: (Int) -> Void
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transform selected text")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text("Applies to the text you selected, or to your last dictation.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 4)
                .padding(.bottom, 12)
            if transforms.isEmpty {
                Text("No transforms yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.vertical, 8)
            }
            ForEach(Array(transforms.enumerated()), id: \.element.id) { index, transform in
                PickerRow(name: transform.name.isEmpty ? "Unnamed" : transform.name, summary: transform.summary,
                          shortcut: index < 9 ? "⌥\(index + 1)" : nil, current: index == current) { choose(index) }
            }
            HStack {
                Spacer()
                Button(action: edit) {
                    Text("Edit transforms")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 1, green: 0.99, blue: 0.91)))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.12)))
        .padding(1)
    }
}

/// The card behind the arrow of the bar's language button: automatic detection, German or English.
struct LanguagePickerView: View {
    static let options: [(code: String, name: String, summary: String)] = [
        ("auto", "Automatic", "Detects German or English"),
        ("de", "Deutsch", "Always recognises German"),
        ("en", "English", "Always recognises English"),
    ]

    let current: String
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Dictation language")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 12)
            ForEach(Self.options, id: \.code) { option in
                PickerRow(name: option.name, summary: option.summary, shortcut: nil, current: option.code == current) {
                    choose(option.code)
                }
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.12)))
        .padding(1)
    }
}

private struct PickerRow: View {
    let name: String
    let summary: String
    let shortcut: String?
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(current ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    if !summary.isEmpty {
                        Text(summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovering ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Today's meetings from the calendar, from the arrow next to the bar's Notetaker button.
struct MeetingCardView: View {
    struct Meeting: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
    }

    let meetings: [Meeting]
    let calendarConnected: Bool
    let recording: Bool
    /// Starts a note for the meeting with this id, or a quick note for nil.
    let start: (String?) -> Void
    let stop: () -> Void
    let connectCalendar: () -> Void
    let close: () -> Void
    /// Asks the assistant about the running meeting.
    var ask: (String) -> Void = { _ in }

    private static let cream = Color(red: 1, green: 0.99, blue: 0.91)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recording {
                Text("Notetaker is recording").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text("Stop it to get the transcript, summary and tasks.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    MeetingRow(time: "Live", title: "Was wurde gerade gesagt?", detail: "Die letzten zwei Minuten kurz zusammengefasst", live: true) {
                        ask("Was wurde in den letzten Minuten gesagt? Fass es kurz zusammen.")
                    }
                    MeetingRow(time: "Live", title: "Antwort-Vorschlag", detail: "Was ich auf das zuletzt Gesagte antworten könnte", live: true) {
                        ask("Was könnte ich auf das zuletzt Gesagte antworten? Schlag mir eine kurze Antwort vor.")
                    }
                }
                .padding(.top, 12)
                HStack {
                    Spacer()
                    creamButton("Stop Notetaker", icon: "stop.fill", action: stop)
                }
                .padding(.top, 14)
            } else if !calendarConnected {
                Text("Connect your calendar").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text("See your meetings of the day here and start a note for one with a click.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Spacer()
                    Button("Not now", action: close).buttonStyle(.plain).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    creamButton("Connect calendar", icon: "calendar", action: connectCalendar)
                }
                .padding(.top, 14)
            } else {
                Text("Today's meetings").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text("Start a note and it gets the meeting's title.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).padding(.top, 4).padding(.bottom, 10)
                MeetingRow(time: "Now", title: "Quick note", detail: "Without a calendar entry", live: false) { start(nil) }
                if meetings.isEmpty {
                    Text("No more meetings today.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).padding(.vertical, 8).padding(.horizontal, 8)
                }
                ForEach(meetings) { meeting in
                    let now = Date()
                    MeetingRow(time: meeting.start.formatted(date: .omitted, time: .shortened), title: meeting.title,
                               detail: "until \(meeting.end.formatted(date: .omitted, time: .shortened))",
                               live: meeting.start <= now && now < meeting.end) { start(meeting.id) }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.12)))
        .padding(1)
    }

    private func creamButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Self.cream))
        }
        .buttonStyle(.plain)
    }
}

private struct MeetingRow: View {
    let time: String
    let title: String
    let detail: String
    let live: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(time)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if live {
                            Text("Now")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color(red: 0.56, green: 0.81, blue: 0.78)))
                        }
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text("Start note")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? .black : .white.opacity(0.75))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? Color(red: 1, green: 0.99, blue: 0.91) : Color.white.opacity(0.1)))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
