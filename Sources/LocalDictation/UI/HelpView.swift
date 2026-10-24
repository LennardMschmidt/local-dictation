import AppKit
import DictationCore
import SwiftUI

struct HelpView: View {
    @ObservedObject var model: AppModel

    private let shortcuts: [(keys: String, action: String)] = [
        ("hold fn", "Dictate; release to insert the text"),
        ("fn + space", "Keep recording hands-free; press fn again to stop"),
        ("esc", "Cancel the recording"),
        ("hold ctrl + fn", "Transform the selected text, or write new text, by a spoken instruction"),
        ("⌥ M", "Start or stop the Notetaker"),
    ]

    private let tips: [(title: String, text: String)] = [
        ("Lists", "Say \"erstens, zweitens, drittens\" or \"meine Stichpunkte sind …\" and the items land on separate lines."),
        ("Corrections", "Say \"nein\", \"ich meine\", \"no wait\" or \"actually\" and only the corrected version is kept."),
        ("Words it gets wrong", "Add them to the Dictionary. Names and product terms work best there."),
        ("Tone per app", "Style sets how formal the text reads in messages, emails, notes and other apps."),
        ("Nothing happens on fn", "Check Settings › Permissions, and set System Settings › Keyboard › \"Press 🌐 key to\" to \"Do Nothing\"."),
        ("Text without cleanup", "LM Studio is not running or the model is missing. The app starts it at launch; the bell shows what happened."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Theme.headline("Help")

                Theme.sectionLabel("Shortcuts")
                Card {
                    ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, shortcut in
                        if index > 0 { Divider().overlay(Theme.border) }
                        HStack(spacing: 16) {
                            Text(shortcut.keys)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panel))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
                                .frame(width: 144, alignment: .leading)
                            Text(shortcut.action).font(.system(size: 14))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }

                Theme.sectionLabel("Tips")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ForEach(tips, id: \.title) { tip in
                        Card(padding: 20) {
                            Text(tip.title).font(.system(size: 14, weight: .semibold)).padding(.bottom, 4)
                            Text(tip.text).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }

                Theme.sectionLabel("Troubleshooting")
                HStack(spacing: 10) {
                    Button("Open log") { NSWorkspace.shared.open(AppPaths.logFile) }
                    Button("Open data folder") { NSWorkspace.shared.open(AppPaths.supportDirectory) }
                    Button("Settings") { model.openSettings() }
                }
                Text("LocalDictation \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · Whisper large-v3-turbo · \(model.settings.llm.model) · no data leaves this Mac")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .pageLayout(maxWidth: 900)
        }
    }
}
