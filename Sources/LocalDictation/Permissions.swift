import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// The three macOS permissions the app needs and where to grant them.
///
/// - Microphone: recording.
/// - Accessibility: the event tap that can drop the Space and Esc presses during a recording,
///   and the synthesized Cmd+V.
/// - Input Monitoring: reading key events from other apps.
enum Permission: CaseIterable {
    case microphone
    case accessibility
    case inputMonitoring

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    var purpose: String {
        switch self {
        case .microphone: return "to record what you say"
        case .accessibility: return "to paste the text and to handle the Fn key"
        case .inputMonitoring: return "to notice when Fn is held down"
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Shows the system prompt where macOS has one, otherwise opens System Settings.
    func request() {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                NSWorkspace.shared.open(settingsURL)
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { NSWorkspace.shared.open(settingsURL) }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { NSWorkspace.shared.open(settingsURL) }
        }
    }

    static var allGranted: Bool { allCases.allSatisfy(\.isGranted) }
    static var missing: [Permission] { allCases.filter { !$0.isGranted } }
}

/// Screen Recording, needed only for the meeting audio in the Notetaker.
enum ScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func request() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}
