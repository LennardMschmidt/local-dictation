import AppKit
import DictationCore
import SwiftUI

/// The pill at the bottom centre of the screen.
///
/// Idle it is a small bar that shows the app is running. Under the mouse it opens into a
/// toolbar (language, microphone, open the app). While dictating it shows the level meter,
/// then progress or a short message. One capsule morphs between these states, and the side
/// buttons slide out of it, like Wispr Flow's bar.
///
/// The panel keeps one fixed size so SwiftUI can animate inside it. Its transparent parts let
/// clicks through to the windows below, and the mouse is only tracked over the visible part.
/// The panel never becomes key, so the app being dictated into keeps keyboard focus.
final class DictationPill {
    typealias Mode = PillModel.Mode

    static let panelSize = NSSize(width: 600, height: 120)

    let model = PillModel()
    private let panel: PillPanel
    private let hostingView: PillHostingView
    private var generation = 0
    private var collapseWork: DispatchWorkItem?

    /// Shows the idle bar when nothing else is displayed.
    var idleVisible = true {
        didSet { apply() }
    }

    /// Keeps the pill out of screenshots and screen sharing.
    var hiddenInScreenShare = false {
        didSet { panel.sharingType = hiddenInScreenShare ? .none : .readOnly }
    }

    init() {
        hostingView = PillHostingView(rootView: PillView(model: model))
        panel = PillPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                          styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hostingView
        hostingView.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
        model.onIdleClick = { [weak self] in self?.idleClicked() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.apply() }
        // The Dock appears and disappears with full-screen apps and space switches.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.apply() }
            }
        }
        placementTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let upcoming = self.model.upcomingMeeting, upcoming.start <= Date() { self.model.upcomingMeeting = nil }
            self.apply()
        }
    }

    private var placementTimer: Timer?
    private var expandWork: DispatchWorkItem?
    /// Called when the bar moved, such as from the screen edge to above the Dock after leaving
    /// a full-screen app, so cards anchored to it can follow.
    var onMove: (() -> Void)?
    private var lastPlacementAtEdge: Bool?

    func show(_ mode: Mode) {
        generation += 1
        if case .recording = mode { model.levels = Array(repeating: 0, count: PillModel.barCount) }
        model.hoveredButton = nil
        model.mode = mode
        apply()
    }

    private let card = BarCard()

    /// Opens a card above the toolbar, such as the transforms or today's meetings. The bar stays
    /// open and in place while the card is shown; moving or collapsing it would pull the card
    /// away from under the mouse.
    func showCard(_ content: AnyView, name: String) {
        // An open card closes first, so its closing does not release the bar for the new one.
        card.close()
        menuOpen = true
        collapseWork?.cancel()
        model.hoveredButton = nil
        AppLog.info("\(name) card opened")
        card.show(content, centerX: panel.frame.midX, bottom: panel.frame.minY + PillView.buttonSize + 16) { [weak self] in
            guard let self else { return }
            AppLog.info("\(name) card closed")
            self.menuOpen = false
            self.model.arrowFor = nil
            self.hoverChanged(self.hostingView.mouseIsInside)
        }
    }

    func closeCard() {
        card.close()
    }

    /// Where cards open: centred on the bar, their bottom edge just above it.
    var cardAnchor: (centerX: CGFloat, bottom: CGFloat) {
        (panel.frame.midX, panel.frame.minY + PillView.buttonSize + 16)
    }

    private var menuOpen = false

    /// Returns to the idle bar, or hides the pill when the idle bar is off.
    func hide() {
        generation += 1
        model.mode = .idle
        apply()
    }

    /// Shows a message for a moment, then returns to idle.
    func flash(_ text: String, seconds: TimeInterval = 2) {
        show(.message(text))
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == shown else { return }
            self.hide()
        }
    }

    func push(level: Float) {
        model.levels.removeFirst()
        model.levels.append(CGFloat(level))
    }

    /// A meeting starts soon: its title for a few seconds when the bar is idle (not during a
    /// dictation), then a blue dot until it begins.
    func remind(title: String, start: Date) {
        model.upcomingMeeting = (title, start)
        let minutes = max(1, Int((start.timeIntervalSinceNow / 60).rounded()))
        if model.mode == .idle { flash("\(title) in \(minutes) min", seconds: 4) }
        AppLog.info("meeting reminder shown, starts in \(minutes) min")
    }

    /// A click on the idle bar opens the toolbar.
    private func idleClicked() {
        guard !menuOpen, model.mode == .idle else { return }
        collapseWork?.cancel()
        expandWork?.cancel()
        model.mode = .expanded
        apply()
    }

    private func hoverChanged(_ hovering: Bool) {
        guard !menuOpen else { return }
        collapseWork?.cancel()
        expandWork?.cancel()
        // The idle bar opens on a click at once, or when the mouse rests on the bar itself for
        // half a second; passing over it, or coming near it, does nothing.
        if hovering, model.mode == .idle {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.mode == .idle, self.hostingView.mouseIsInside else { return }
                self.model.mode = .expanded
                self.apply()
            }
            expandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else if !hovering, model.mode == .expanded {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.mode == .expanded else { return }
                self.model.hoveredButton = nil
                self.model.mode = .idle
                self.apply()
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// Places the panel above the Dock while it is shown, or at the bottom edge of the screen
    /// while it is hidden, and limits mouse tracking to the visible part of the current mode.
    private func apply() {
        guard !menuOpen else { return }
        if model.mode == .idle && !idleVisible {
            panel.orderOut(nil)
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let bottom = DockPlacement.bottom(of: screen)
        let atEdge = bottom == screen.frame.minY
        if atEdge != lastPlacementAtEdge {
            lastPlacementAtEdge = atEdge
            AppLog.info("pill placement \(atEdge ? "screen edge" : "above the Dock"), front app "
                        + "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        }
        let origin = NSPoint(x: (screen.frame.midX - Self.panelSize.width / 2).rounded(), y: bottom)
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
            onMove?()
        }
        hostingView.activeRect = model.activeRect(in: Self.panelSize)
        panel.orderFrontRegardless()
    }
}

final class PillModel: ObservableObject {
    enum Mode: Equatable {
        case idle
        case expanded
        case recording
        case handsFree
        /// Recording an instruction for selected text (ctrl + fn).
        case command
        /// Recording a request for the assistant (⌥ + fn).
        case assistant
        case processing
        case message(String)
    }

    enum Button: Equatable {
        case language
        case languageMenu
        case mic
        case notetaker
        case scratchpad
        case transform
        case transformMenu
        case notetakerMenu
        case cancel
        case finish
    }

    static let barCount = 14

    @Published var mode: Mode = .idle
    @Published var levels: [CGFloat] = Array(repeating: 0, count: barCount)
    @Published var language = "auto"
    @Published var hoveredButton: Button?
    /// A Notetaker recording is running; the bar and the button show a red dot.
    @Published var meetingActive = false
    /// The next meeting with other people while it starts within minutes; the bar shows a dot.
    @Published var upcomingMeeting: (title: String, start: Date)?

    var onMic: (() -> Void)?
    /// A click on the idle bar.
    var onIdleClick: (() -> Void)?
    /// Cancels the recording (the × on the recording pill).
    var onCancel: (() -> Void)?
    var onLanguage: (() -> Void)?
    var onLanguageMenu: (() -> Void)?
    var onNotetaker: (() -> Void)?
    var onScratchpad: (() -> Void)?
    var onTransform: (() -> Void)?
    var onTransformMenu: (() -> Void)?
    /// Name of the transform the Transform button applies, for its tooltip.
    @Published var transformName = ""
    var onNotetakerMenu: (() -> Void)?
    /// The scratchpad button is on the bar ("Add to bar" on the Scratchpad page).
    @Published var showScratchpad = true
    /// The button whose arrow is out because the mouse is on it or on the arrow.
    @Published var arrowFor: Button?

    /// A copy in another mode, for checks.
    func with(mode: Mode) -> PillModel {
        let copy = PillModel()
        copy.mode = mode
        return copy
    }

    /// The area that reacts to the mouse, in panel coordinates (origin bottom left). Everything
    /// outside it is transparent and ignored, so it does not open the toolbar from afar.
    func activeRect(in size: NSSize) -> NSRect {
        let width: CGFloat
        let height: CGFloat
        switch mode {
        case .idle:
            // The visible bar (4 to 12 points above the panel's bottom) with 2 points around it,
            // so hovering counts only on the bar itself.
            return NSRect(x: (size.width - PillView.idleSize.width - 4) / 2, y: 2,
                          width: PillView.idleSize.width + 4, height: PillView.idleSize.height + 4)
        case .expanded: (width, height) = (PillView.toolbarWidth + PillView.arrowWidth * 2 + 12, 42)
        case .recording, .handsFree, .command, .assistant: (width, height) = (PillView.recordingWidth + 16, 40)
        case .processing, .message: return .zero
        }
        return NSRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
    }

    var tooltip: String? {
        switch hoveredButton {
        case .mic: return "Dictate  fn"
        case .language:
            switch language {
            case "de": return "German"
            case "en": return "English"
            default: return "Automatic language detection"
            }
        case .languageMenu: return "Choose a language"
        case .notetaker: return meetingActive ? "Stop Notetaker  ⌥M" : "Start Notetaker  ⌥M"
        case .scratchpad: return "Scratchpad"
        case .transform: return transformName.isEmpty ? "Transform selected text" : "Transform: \(transformName)"
        case .transformMenu: return "Choose a transform"
        case .notetakerMenu: return "Today's meetings"
        case .cancel: return "Cancel  esc"
        case .finish: return "Finish and paste"
        case nil: return nil
        }
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel
    @Namespace private var namespace

    /// A spring with a little overshoot, like the bar of Wispr Flow.
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.64)
    /// The recording pill: × and ✓ in circles left and right of the waveform.
    static let recordingWidth: CGFloat = 104
    static let controlSize: CGFloat = 20

    static let spacing: CGFloat = 5
    static let buttonSize: CGFloat = 28
    static let micWidth: CGFloat = 56
    /// The arrow that slides out of the Transform button on hover.
    static let arrowWidth: CGFloat = 22
    /// The three buttons right of the microphone and their gaps; the left side gets the same
    /// width, so the microphone stays in the middle.
    static let sideWidth: CGFloat = buttonSize * 3 + spacing * 2
    /// A muted red for the bar while a meeting is recorded.
    static let meetingRed = Color(red: 0.86, green: 0.38, blue: 0.36)
    /// The dot of a running Notetaker recording, a muted record-button red.
    static let recordingRed = Color(red: 0.88, green: 0.36, blue: 0.33)
    /// The dot of a meeting that starts within minutes, as muted as the red one.
    static let upcomingBlue = Color(red: 0.42, green: 0.62, blue: 0.9)
    /// Diameter of the dots in the idle bar. With the 8-point bar, the 3-point inset and 2 points
    /// between them, every dot starts on a whole point, so both are drawn equally sharp.
    static let dotSize: CGFloat = 3

    /// Size of the idle bar.
    static let idleSize = CGSize(width: 38, height: 8)

    /// Total width of the open toolbar.
    static let toolbarWidth: CGFloat = sideWidth * 2 + micWidth + spacing * 2

    /// Horizontal distance from the microphone's centre to the centre of a button, so the
    /// tooltip stands above the button under the mouse. The language button sits left of the
    /// microphone, so its arrow pushes it further left while it is out.
    static func tooltipOffset(_ button: PillModel.Button?, arrowFor: PillModel.Button? = nil) -> CGFloat {
        let step = micWidth / 2 + spacing + buttonSize / 2
        switch button {
        case .language: return -step - (arrowFor == .language ? arrowWidth : 0)
        case .languageMenu: return -(micWidth / 2 + spacing + arrowWidth / 2)
        case .notetaker: return step
        case .scratchpad: return step + buttonSize + spacing
        case .transform: return step + (buttonSize + spacing) * 2
        case .transformMenu: return step + (buttonSize + spacing) * 2 + buttonSize / 2 + arrowWidth / 2
        case .notetakerMenu: return step + buttonSize / 2 + arrowWidth / 2
        case .cancel: return -(recordingWidth / 2 - controlSize / 2 - 4)
        case .finish: return recordingWidth / 2 - controlSize / 2 - 4
        case .mic, nil: return 0
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            VStack(spacing: 8) {
                if let tooltip = model.tooltip, model.mode != .idle {
                    Tooltip(text: tooltip)
                        .offset(x: Self.tooltipOffset(model.hoveredButton, arrowFor: model.arrowFor))
                        .transition(.opacity.combined(with: .offset(y: 4)))
                        .id(tooltip)
                }
                body(for: model.mode)
            }
            .padding(.bottom, 4)
        }
        .animation(Self.spring, value: model.mode)
        .animation(.easeOut(duration: 0.12), value: model.hoveredButton)
    }

    @ViewBuilder private func body(for mode: PillModel.Mode) -> some View {
        switch mode {
        case .idle:
            Capsule()
                .fill(Color.black.opacity(0.4))
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(alignment: .leading) {
                    // A red recording dot while the Notetaker records, a blue one while a
                    // meeting starts within minutes; both are independent of each other.
                    HStack(spacing: 2) {
                        if model.meetingActive { Circle().fill(PillView.recordingRed).frame(width: PillView.dotSize, height: PillView.dotSize) }
                        if model.upcomingMeeting != nil { Circle().fill(PillView.upcomingBlue).frame(width: PillView.dotSize, height: PillView.dotSize) }
                    }
                    .padding(.leading, 3)
                }
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .matchedGeometryEffect(id: "body", in: namespace)
                .frame(width: PillView.idleSize.width, height: PillView.idleSize.height)
                // A click on the bar, with a few points beside and above it, opens the toolbar;
                // hovering does nothing, like Wispr Flow's bar. No margin below, so the bar stays
                // where it was.
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .contentShape(Rectangle())
                .onTapGesture { model.onIdleClick?() }

        case .expanded:
            // Both sides are equally wide, so the microphone sits exactly where the bar was.
            HStack(spacing: Self.spacing) {
                HStack(spacing: Self.spacing) {
                    withArrow(.language, menu: .languageMenu, open: { model.onLanguageMenu?() }) {
                        SideButton(hovered: model.hoveredButton == .language, action: { model.onLanguage?() }) {
                            if model.language == "auto" {
                                Image(systemName: "globe")
                            } else {
                                Text(model.language.uppercased()).font(.system(size: 11, weight: .bold))
                            }
                        }
                        .onHover { model.hoveredButton = $0 ? .language : nil }
                    }
                    .transition(Self.slide(fromX: 40))
                }
                .frame(width: Self.sideWidth, alignment: .trailing)

                Button { model.onMic?() } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: Self.micWidth, height: Self.buttonSize)
                        .background(
                            Capsule()
                                .fill(Color(white: model.hoveredButton == .mic ? 0.24 : 0.14)))
                }
                .buttonStyle(.plain)
                .onHover { model.hoveredButton = $0 ? .mic : nil }

                HStack(spacing: Self.spacing) {
                    withArrow(.notetaker, menu: .notetakerMenu, open: { model.onNotetakerMenu?() }) {
                        SideButton(hovered: model.hoveredButton == .notetaker, action: { model.onNotetaker?() }) {
                            Image(systemName: model.meetingActive ? "stop.circle" : "record.circle")
                                .overlay(alignment: .topTrailing) {
                                    if model.meetingActive {
                                        Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: 5, y: -5)
                                    }
                                }
                        }
                        .onHover { model.hoveredButton = $0 ? .notetaker : nil }
                    }
                    .transition(Self.slide(fromX: -40))

                    if model.showScratchpad {
                        SideButton(hovered: model.hoveredButton == .scratchpad, action: { model.onScratchpad?() }) {
                            Image(systemName: "note.text")
                        }
                        .onHover { model.hoveredButton = $0 ? .scratchpad : nil }
                        .transition(Self.slide(fromX: -66))
                    }

                    withArrow(.transform, menu: .transformMenu, open: { model.onTransformMenu?() }) {
                        SideButton(hovered: model.hoveredButton == .transform, action: { model.onTransform?() }) {
                            Image(systemName: "wand.and.stars")
                        }
                        .onHover { model.hoveredButton = $0 ? .transform : nil }
                    }
                    .transition(Self.slide(fromX: -99))
                }
                .frame(width: Self.sideWidth, alignment: .leading)
            }
            // The toolbar pops out of the bar with a little overshoot.
            .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))

        case .recording, .handsFree, .command, .assistant:
            RecordingContent(model: model, command: mode == .command, assistant: mode == .assistant)
                .frame(height: Self.buttonSize)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.92))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
                        .matchedGeometryEffect(id: "body", in: namespace))
                .transition(.scale(scale: 0.6).combined(with: .opacity))

        case .processing:
            TimelineView(.animation) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate * 4) % 3
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in
                        Circle().fill(Color.white.opacity(index == phase ? 1 : 0.35)).frame(width: 4, height: 4)
                    }
                }
            }
            .frame(width: 48, height: 22)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.92))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
                    .matchedGeometryEffect(id: "body", in: namespace))
            .transition(.scale(scale: 0.7).combined(with: .opacity))

        case .message(let text):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.9))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
                        .matchedGeometryEffect(id: "body", in: namespace))
                .transition(.opacity)
        }
    }

    /// Side buttons come out of the centre: they start shifted towards the microphone,
    /// smaller and transparent.
    /// Like Wispr's buttons with options: on hover an arrow slides out to the right of the button
    /// and opens a card; the button itself keeps its own action.
    private func withArrow<Content: View>(_ owner: PillModel.Button, menu: PillModel.Button,
                                          open: @escaping () -> Void, @ViewBuilder button: () -> Content) -> some View {
        let out = model.arrowFor == owner
        return HStack(spacing: 0) {
            button()
            if out {
                Button(action: open) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(model.hoveredButton == menu ? 1 : 0.75))
                        .frame(width: Self.arrowWidth, height: Self.buttonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { model.hoveredButton = $0 ? menu : nil }
                .transition(.opacity.combined(with: .offset(x: -8)))
            }
        }
        .background(Capsule().fill(Color(white: 0.1)).opacity(out ? 1 : 0))
        .overlay(Capsule().strokeBorder(Color.white.opacity(out ? 0.25 : 0)))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) {
                if inside {
                    model.arrowFor = owner
                } else if model.arrowFor == owner {
                    model.arrowFor = nil
                }
            }
        }
    }

    private static func slide(fromX offset: CGFloat) -> AnyTransition {
        .offset(x: offset).combined(with: .scale(scale: 0.4)).combined(with: .opacity)
    }
}

private struct Tooltip: View {
    let text: String

    var body: some View {
        let parts = text.components(separatedBy: "  ")
        let label = parts.count == 2
            ? Text(parts[0] + " ").font(.system(size: 13, weight: .medium)) + Text(parts[1]).font(.system(size: 13, weight: .bold))
            : Text(text).font(.system(size: 13, weight: .medium))
        return label
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.92)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }
}

private struct SideButton<Label: View>: View {
    let hovered: Bool
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: PillView.buttonSize, height: PillView.buttonSize)
                .background(Circle().fill(Color(white: hovered ? 0.26 : 0.1)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
                .scaleEffect(hovered ? 1.06 : 1)
        }
        .buttonStyle(.plain)
    }
}

/// The recording pill like Wispr Flow's: it opens narrow with the waveform, then springs open
/// with × (cancel) on the left and ✓ (finish and paste) on the right.
private struct RecordingContent: View {
    @ObservedObject var model: PillModel
    let command: Bool
    var assistant = false
    @State private var open = Snapshots.isRendering

    /// White while dictating, teal for an instruction, violet for the assistant.
    private var tint: Color {
        assistant ? Color(red: 0.74, green: 0.62, blue: 1.0) : command ? Color(red: 0.56, green: 0.81, blue: 0.78) : .white
    }

    var body: some View {
        HStack(spacing: 6) {
            if open {
                control(.cancel, symbol: "xmark", filled: false) { model.onCancel?() }
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            if assistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            HStack(spacing: 2) {
                ForEach(model.levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(tint)
                        .frame(width: 2, height: max(2, min(14, 2 + model.levels[index] * 14)))
                }
            }
            .frame(height: 16)
            .animation(.linear(duration: 0.05), value: model.levels)
            if open {
                control(.finish, symbol: "checkmark", filled: true) { model.onMic?() }
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .padding(.horizontal, open ? 4 : 12)
        .onAppear {
            withAnimation(PillView.spring.delay(0.08)) { open = true }
        }
    }

    private func control(_ button: PillModel.Button, symbol: String, filled: Bool, action: @escaping () -> Void) -> some View {
        let hovered = model.hoveredButton == button
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(filled ? Color.black : Color.white)
                .frame(width: PillView.controlSize, height: PillView.controlSize)
                .background(Circle().fill(filled ? Color.white : Color.white.opacity(hovered ? 0.36 : 0.24)))
                .scaleEffect(hovered ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { model.hoveredButton = $0 ? button : nil }
    }
}

/// A panel that never becomes key, so clicks on the pill leave focus where it was.
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the first click and tracks the mouse only over `activeRect`,
/// even though its window is never key.
final class PillHostingView: NSHostingView<PillView> {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var inside = false

    /// Whether the mouse is over the visible part of the pill right now.
    var mouseIsInside: Bool {
        guard let window else { return false }
        return localActiveRect.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    /// The visible part of the pill, measured from the bottom of the panel.
    var activeRect: NSRect = .zero {
        didSet { if activeRect != oldValue { updateTrackingAreas() } }
    }

    /// `activeRect` in this view's own coordinates. SwiftUI hosting views are flipped (y grows
    /// downwards), so the rect measured from the bottom has to be mirrored.
    private var localActiveRect: NSRect {
        guard isFlipped else { return activeRect }
        return NSRect(x: activeRect.minX, y: bounds.height - activeRect.maxY,
                      width: activeRect.width, height: activeRect.height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks outside the visible part are not taken, so they fall through to the window below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return localActiveRect.insetBy(dx: -4, dy: -4).contains(local) ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard activeRect != .zero, let window else { return }
        let rect = localActiveRect
        let mouse = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let isInside = rect.contains(mouse)
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways]
        if isInside { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: rect, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        if isInside != inside {
            inside = isInside
            onHoverChange?(isInside)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        inside = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        inside = false
        onHoverChange?(false)
    }
}
