import AppKit
import DictationCore
import SwiftUI

/// The card that opens shortly before a calendar meeting, above the bar, in the style of the
/// assistant card. It stays until it is closed or the note for the meeting starts; it never takes
/// the keyboard, so it does not get in the way of what you are doing.
final class BriefingCard {
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?

    var isOpen: Bool { panel != nil }

    func show(_ view: AnyView, at anchor: (centerX: CGFloat, bottom: CGFloat)) {
        if let hosting, let panel {
            hosting.rootView = view
            let size = hosting.fittingSize
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().setFrame(NSRect(x: (anchor.centerX - size.width / 2).rounded(), y: anchor.bottom,
                                                 width: size.width, height: size.height), display: true)
            }
            return
        }
        let hosting = BriefingHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = BriefingPanel(contentRect: NSRect(x: (anchor.centerX - size.width / 2).rounded(), y: anchor.bottom,
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
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        self.hosting = hosting
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        hosting = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

private final class BriefingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BriefingHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct BriefingCardView: View {
    let briefing: Briefing
    let loadingTasks: Bool
    let startNote: () -> Void
    let openNote: (String) -> Void
    let close: () -> Void

    private static let cream = Color(red: 1, green: 0.99, blue: 0.91)
    private static var maxContentHeight: CGFloat {
        min(420, max(240, (NSScreen.main?.visibleFrame.height ?? 900) - 360))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(startsIn.uppercased())
                        .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(AssistantCardView.violet)
                    Text(briefing.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if let customer = briefing.customer {
                        Text(customer).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }

            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            if briefing.previous.isEmpty {
                Text("Keine früheren Meetings mit diesen Teilnehmern im Vault.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
            }
            ForEach(Array(briefing.previous.enumerated()), id: \.offset) { _, meeting in
                VStack(alignment: .leading, spacing: 6) {
                    Button { openNote(meeting.note) } label: {
                        HStack(spacing: 6) {
                            Text(label(for: meeting)).font(.system(size: 11, weight: .semibold)).tracking(0.6)
                                .foregroundStyle(.white.opacity(0.5))
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Notiz öffnen")
                    ForEach(meeting.points, id: \.self) { point in
                        row(symbol: "circle.fill", size: 4, color: AssistantCardView.violet, text: point)
                    }
                    ForEach(meeting.openItems, id: \.self) { item in
                        row(symbol: "square", size: 10, color: .white.opacity(0.6), text: item)
                    }
                }
            }

            if loadingTasks || !briefing.openTasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OFFEN IN AWORK").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.white.opacity(0.5))
                    if loadingTasks && briefing.openTasks.isEmpty {
                        Text("Lade …").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    }
                    ForEach(briefing.openTasks, id: \.self) { task in
                        row(symbol: "checklist", size: 10, color: .white.opacity(0.6), text: task)
                    }
                }
            }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Long briefings scroll, so the card never grows past the screen and its buttons.
            .frame(maxHeight: Self.maxContentHeight)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                pill("Schließen", filled: false, action: close)
                if let customer = briefing.customer {
                    pill("Kundennotiz", filled: false) { openNote("02 Kunden/\(customer)") }
                }
                Spacer()
                pill("Notiz starten", filled: true, action: startNote)
            }
        }
        .padding(18)
        .frame(width: 400, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.12)))
        .padding(1)
    }

    private var startsIn: String {
        let minutes = Int((briefing.start.timeIntervalSinceNow / 60).rounded())
        if minutes <= 0 { return "Jetzt" }
        return "In \(minutes) min · \(briefing.start.formatted(date: .omitted, time: .shortened))"
    }

    private func label(for meeting: Briefing.PastMeeting) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: meeting.date),
                                                    to: Calendar.current.startOfDay(for: Date())).day ?? 0
        let when = days == 1 ? "Gestern" : days < 7 ? "Vor \(days) Tagen" : meeting.date.formatted(date: .abbreviated, time: .omitted)
        return "\(when) · \(meeting.title)".uppercased()
    }

    private func row(symbol: String, size: CGFloat, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Group {
                if symbol == "circle.fill" {
                    Text("•").font(.system(size: 15, weight: .bold))
                } else {
                    Image(systemName: symbol).font(.system(size: size))
                }
            }
            .foregroundStyle(color)
            .frame(width: 12)
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(filled ? Color.black : Color.white)
                .padding(.horizontal, 12).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(filled ? Self.cream : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
