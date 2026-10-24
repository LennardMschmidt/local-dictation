@testable import DictationCore
import Testing

struct HotkeyStateMachineTests {
    @Test func holdAndReleaseRecordsAndProcesses() {
        var machine = HotkeyStateMachine(minimumPress: 0.25)
        #expect(machine.handle(.fnDown(0)).action == .startRecording)
        #expect(machine.isRecording)
        #expect(machine.handle(.fnUp(1.0)).action == .stopAndProcess)
        #expect(machine.state == .idle)
    }

    @Test func shortTapIsCancelled() {
        var machine = HotkeyStateMachine(minimumPress: 0.25)
        _ = machine.handle(.fnDown(0))
        #expect(machine.handle(.fnUp(0.1)).action == .cancel)
        #expect(machine.state == .idle)
    }

    @Test func fnShortcutCancelsAndIgnoresRelease() {
        var machine = HotkeyStateMachine()
        _ = machine.handle(.fnDown(0))
        let decision = machine.handle(.otherKeyDown(0.3))
        #expect(decision.action == .cancel)
        #expect(decision.swallow == false)
        #expect(machine.handle(.fnUp(0.5)).action == .none)
        #expect(machine.state == .idle)
    }

    @Test func spaceSwitchesToHandsFreeAndNextFnStops() {
        var machine = HotkeyStateMachine()
        _ = machine.handle(.fnDown(0))
        let space = machine.handle(.spaceDown(0.4))
        #expect(space == .init(.enterHandsFree, swallow: true))
        #expect(machine.handle(.fnUp(0.6)).action == .none)
        #expect(machine.isRecording)
        #expect(machine.handle(.otherKeyDown(2)).action == .none)
        #expect(machine.handle(.fnDown(5)).action == .stopAndProcess)
        #expect(machine.handle(.fnUp(5.1)).action == .none)
        #expect(machine.state == .idle)
    }

    @Test func escapeCancelsWhileHolding() {
        var machine = HotkeyStateMachine()
        _ = machine.handle(.fnDown(0))
        #expect(machine.handle(.escapeDown(0.5)) == .init(.cancel, swallow: true))
        #expect(machine.handle(.fnUp(0.7)).action == .none)
        #expect(machine.state == .idle)
    }

    @Test func escapeCancelsHandsFree() {
        var machine = HotkeyStateMachine()
        _ = machine.handle(.fnDown(0))
        _ = machine.handle(.spaceDown(0.3))
        _ = machine.handle(.fnUp(0.4))
        #expect(machine.handle(.escapeDown(3)) == .init(.cancel, swallow: true))
        #expect(machine.state == .idle)
    }

    @Test func keysWhileIdleAreNotSwallowed() {
        var machine = HotkeyStateMachine()
        #expect(machine.handle(.spaceDown(0)) == .init(.none))
        #expect(machine.handle(.escapeDown(0)) == .init(.none))
        #expect(machine.handle(.fnUp(0)) == .init(.none))
    }
}
