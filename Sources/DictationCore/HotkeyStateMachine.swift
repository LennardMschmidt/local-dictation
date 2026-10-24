import Foundation

/// Decides what a key event means for recording. The event tap feeds every relevant event in
/// and carries out the returned action. No timers: times come in with the events.
///
/// - Holding Fn records, releasing Fn processes.
/// - Space while Fn is held switches to hands-free; the next Fn press stops.
/// - Any other key while Fn is held is an Fn shortcut (Fn+F for fullscreen and so on) and
///   cancels the recording.
/// - Esc cancels a running recording.
/// - Presses shorter than `minimumPress` are cancelled, so tapping Fn by accident does nothing.
public struct HotkeyStateMachine: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case fnDown(Double)
        case fnUp(Double)
        case spaceDown(Double)
        case escapeDown(Double)
        case otherKeyDown(Double)
    }

    public enum Action: Equatable, Sendable {
        case none
        case startRecording
        case enterHandsFree
        case stopAndProcess
        case cancel
    }

    public struct Decision: Equatable, Sendable {
        public var action: Action
        /// True when the event tap should drop the event so the focused app never sees it.
        public var swallow: Bool

        public init(_ action: Action, swallow: Bool = false) {
            self.action = action
            self.swallow = swallow
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case holding(since: Double)
        case handsFree
        /// Waits for Fn to be released after a cancel or a stop, so the release does not start anything.
        case waitingForRelease
    }

    public private(set) var state: State = .idle
    public var minimumPress: Double

    public init(minimumPress: Double = 0.25) {
        self.minimumPress = minimumPress
    }

    public var isRecording: Bool {
        switch state {
        case .holding, .handsFree: return true
        case .idle, .waitingForRelease: return false
        }
    }

    public mutating func handle(_ event: Event) -> Decision {
        switch (state, event) {
        case (.idle, .fnDown(let t)):
            state = .holding(since: t)
            return Decision(.startRecording)

        case (.holding, .spaceDown):
            state = .handsFree
            return Decision(.enterHandsFree, swallow: true)

        case (.holding(let since), .fnUp(let t)):
            state = .idle
            return Decision(t - since < minimumPress ? .cancel : .stopAndProcess)

        case (.holding, .escapeDown):
            state = .waitingForRelease
            return Decision(.cancel, swallow: true)

        case (.holding, .otherKeyDown):
            state = .waitingForRelease
            return Decision(.cancel)

        case (.handsFree, .fnUp):
            // The release of the press that started hands-free mode.
            return Decision(.none)

        case (.handsFree, .fnDown):
            state = .waitingForRelease
            return Decision(.stopAndProcess)

        case (.handsFree, .escapeDown):
            state = .idle
            return Decision(.cancel, swallow: true)

        case (.waitingForRelease, .fnUp):
            state = .idle
            return Decision(.none)

        default:
            return Decision(.none)
        }
    }

    /// Puts the machine back to idle, for example after an error while recording.
    public mutating func reset() {
        state = .idle
    }
}
