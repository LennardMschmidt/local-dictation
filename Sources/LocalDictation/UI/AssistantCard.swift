import AppKit
import Combine
import DictationCore
import SwiftUI

/// What the assistant card shows. It moves from thinking to the proposal, then to running and
/// the result, in one card that changes its size softly.
final class AssistantCardModel: ObservableObject {
    enum Phase: Equatable {
        case thinking
        case proposal(AssistantPlan)
        case running(AssistantPlan)
        case done(String, link: URL?)
        case answer(String)
        case failed(String)
    }

    @Published var request = ""
    /// What the thinking phase says it is doing.
    @Published var status = "Thinking …"
    @Published var phase = Phase.thinking

    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: ((String) -> Void)?
    var onInsert: ((String) -> Void)?
    var onOpen: ((URL) -> Void)?
    /// The card is dragged: how far the mouse is from where the drag began on the card.
    var onDrag: ((CGSize) -> Void)?
}

/// The card above the bar, in the dark style of the transform card. Its panel never becomes key,
/// so the app in front keeps its focus; Return and Esc reach it through the hotkey monitor.
final class AssistantCard {
    let model = AssistantCardModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var anchor: (centerX: CGFloat, bottom: CGFloat) = (0, 0)
    private var changes: AnyCancellable?
    private var moveObserver: Any?
    /// Set when the user dragged the card; it then stays where it was put until the next request.
    private var placedByUser = false

    var isOpen: Bool { panel != nil }

    /// Shows the card above the bar. Every new request starts there again, also when the card
    /// was dragged during the last one.
    func show(at anchor: (centerX: CGFloat, bottom: CGFloat)) {
        self.anchor = anchor
        placedByUser = false
        model.onDrag = { [weak self] translation in self?.drag(translation) }
        if panel == nil {
            let hosting = AssistantHostingView(rootView: AnyView(AssistantCardView(model: model)))
            let panel = AssistantPanel(contentRect: frame(for: hosting.fittingSize), styleMask: [.nonactivatingPanel, .borderless],
                                       backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            // Dragged by its background, so a long answer can be moved out of the way.
            panel.isMovableByWindowBackground = true
            panel.contentView = hosting
            // Only a drag by the user posts this; frames set by the app do not.
            moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.willMoveNotification, object: panel,
                                                                  queue: .main) { [weak self] _ in self?.placedByUser = true }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
            self.panel = panel
            self.hosting = hosting
            // The card follows its content: after every change it takes the new size, growing
            // upwards from the bar.
            changes = model.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.fit() }
            }
        }
        fit()
    }

    /// Moves the card by the distance between the mouse and the point on the card where the drag
    /// began. After the move that point is under the mouse again, so the next distance is only
    /// what the mouse moved since; the card follows the mouse exactly.
    private func drag(_ translation: CGSize) {
        guard let panel else { return }
        placedByUser = true
        let origin = panel.frame.origin
        // SwiftUI counts y downwards, the screen upwards.
        panel.setFrameOrigin(NSPoint(x: origin.x + translation.width, y: origin.y - translation.height))
    }

    /// Moves the card to a new anchor when the bar moved, unless the user placed it.
    func follow(_ anchor: (centerX: CGFloat, bottom: CGFloat)) {
        guard panel != nil, !placedByUser else { return }
        self.anchor = anchor
        fit()
    }

    private func frame(for size: NSSize) -> NSRect {
        NSRect(x: (anchor.centerX - size.width / 2).rounded(), y: anchor.bottom, width: size.width, height: size.height)
    }

    private func fit() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        // A card the user placed keeps its top edge and grows downwards; otherwise it grows
        // upwards from the bar.
        let target = placedByUser
            ? NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
            : frame(for: size)
        guard target != panel.frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.05)
            panel.animator().setFrame(target, display: true)
        }
    }

    func close() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        changes = nil
        guard let panel else { return }
        self.panel = nil
        hosting = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

private final class AssistantPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class AssistantHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

struct AssistantCardView: View {
    @ObservedObject var model: AssistantCardModel

    static let violet = Color(red: 0.74, green: 0.62, blue: 1.0)
    private static let cream = Color(red: 1, green: 0.99, blue: 0.91)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            if replyHint {
                HStack(spacing: 5) {
                    Text("fn").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).frame(height: 16)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.14)))
                    Text("hold to reply").font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.45))
                .transition(.opacity)
            }
        }
        .padding(18)
        .frame(width: isAnswer ? 430 : 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.12)))
        .padding(1)
        // Dragged anywhere on the card; a click on a button stays a click, because a drag starts
        // only after the mouse moved a few points.
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .gesture(DragGesture(minimumDistance: 3).onChanged { model.onDrag?($0.translation) })
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: model.phase)
    }

    private var isAnswer: Bool {
        if case .answer = model.phase { return true }
        return false
    }

    /// Shown while fn answers the assistant.
    private var replyHint: Bool {
        switch model.phase {
        case .proposal, .answer, .failed: return true
        case .thinking, .running, .done: return false
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Self.violet)
                .padding(.top, 2)
            Text("„\(model.request)“")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { model.onCancel?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Close  esc")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .thinking:
            HStack(spacing: 10) {
                Spinner()
                Text(model.status).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
            }
            .transition(.opacity)
        case .proposal(let plan):
            planView(plan)
            HStack(spacing: 8) {
                Spacer()
                keyButton("Cancel", key: "esc", filled: false) { model.onCancel?() }
                keyButton("Run", key: "⏎", filled: true) { model.onConfirm?() }
            }
            .transition(.opacity)
        case .running(let plan):
            planView(plan)
            HStack(spacing: 10) {
                Spinner()
                Text(plan.actions.contains { $0.kind == .agent } ? "Working …" : "Running …")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
        case .done(let message, let link):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.teal)
                Text(message).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let link {
                    keyButton("Open", key: nil, filled: false) { model.onOpen?(link) }
                }
            }
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        case .answer(let text):
            ScrollView {
                AnswerView(blocks: MarkdownBlock.parse(text))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                keyButton("Copy", key: nil, filled: false) { model.onCopy?(text) }
                keyButton("Paste", key: "⏎", filled: true) { model.onInsert?(text) }
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func planView(_ plan: AssistantPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan.summary).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(plan.actions.enumerated()), id: \.offset) { _, action in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: action))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Self.violet)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(action.title).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        if action.kind == .aworkCall {
                            // The exact call, small, so it can be checked before Return.
                            Text("\(action.method) \(action.path)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .transition(.opacity)
    }

    private func symbol(for action: AssistantAction) -> String {
        switch action.kind {
        case .openURL: return "globe"
        case .openApp: return "app"
        case .openNote: return "doc.text"
        case .aworkTask: return "checklist"
        case .agent: return "magnifyingglass"
        case .aworkChange, .aworkCall: return "pencil.line"
        case .answer, .none: return "text.bubble"
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func keyButton(_ title: String, key: String?, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let key {
                    Text(key).font(.system(size: 11, weight: .medium))
                        .opacity(0.6)
                }
            }
            .foregroundStyle(filled ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(filled ? Self.cream : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// A thin violet arc that turns.
private struct Spinner: View {
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(AssistantCardView.violet, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// An answer laid out for the card: small section labels, list items with a violet dot, table
/// rows as two-line entries (the longest column as the title, the others below it), paragraphs.
private struct AnswerView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let text):
                    Text(inline(text).uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, index == 0 ? 0 : 6)
                case .bullet(let text):
                    item(marker: AnyView(Circle().fill(AssistantCardView.violet).frame(width: 5, height: 5).padding(.top, 7)), text: text)
                case .numbered(let number, let text):
                    item(marker: AnyView(Text("\(number)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(AssistantCardView.violet).frame(width: 14, alignment: .trailing)), text: text)
                case .fields(let rows):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            (Text(inline(row.first ?? "") + ": ").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                                + Text(markdown(row.count > 1 ? row[1] : "")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.92)))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .table(let header, let rows, let title, let key):
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                            if rowIndex > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                            VStack(alignment: .leading, spacing: 3) {
                                headline(row, title: title, key: key)
                                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(details(row, header: header, skipping: [title, key].compactMap { $0 }))
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                case .paragraph(let text):
                    Text(markdown(text)).font(.system(size: 14)).foregroundStyle(.white.opacity(0.9))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func item(marker: AnyView, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            marker
            Text(markdown(text)).font(.system(size: 14)).foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The title of a table row, with the ticket number or id in front when there is one.
    private func headline(_ row: [String], title: Int, key: Int?) -> Text {
        let titleText = Text(markdown(row.indices.contains(title) ? row[title] : ""))
        guard let key, row.indices.contains(key), !row[key].isEmpty else { return titleText }
        return Text(markdown(row[key])) + Text("  ").foregroundStyle(.white.opacity(0.4)) + titleText
    }

    /// The other cells of a table row, "Fällig 28.08. · HAM · To Do" style: short cells by
    /// themselves, a cell whose header says more ("Fällig") with its header.
    private func details(_ row: [String], header: [String], skipping shown: [Int]) -> String {
        row.indices.filter { !shown.contains($0) && !row[$0].isEmpty }.map { index in
            let label = header.indices.contains(index) ? header[index] : ""
            let cell = inline(row[index])
            return label.count <= 8 && !label.isEmpty && cell.first?.isNumber == true ? "\(label) \(cell)" : cell
        }.joined(separator: " · ")
    }

    private func inline(_ text: String) -> String {
        String(markdown(text).characters)
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
