import AppKit
import DictationCore
import SwiftUI

/// The Style page, laid out like Wispr Flow's: one tab per app category, a banner with the apps
/// it covers, and three cards to pick how formal the text reads there. The examples run through
/// the same rules dictation uses, so they show exactly what will be inserted.
struct StyleView: View {
    @ObservedObject var model: AppModel
    @State private var category = StyleCategory.personal

    private static let example: [StyleCategory: String] = [
        .personal: "Hey, hast du morgen Zeit zum Mittagessen? Lass uns um 12 gehen, wenn das passt.",
        .work: "Hi, kannst du dir das Ticket heute noch anschauen? Der Kunde wartet auf eine Antwort.",
        .email: "Hallo Paul, danke für deine Nachricht. Ich schicke dir die Unterlagen bis Freitag.",
        .other: "Die Tests laufen bis Donnerstag. Danach gehen wir in die Abnahme.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Style").font(.system(size: 26, weight: .medium))
                tabs
                StyleBanner(category: category, apps: apps, add: addApp, remove: removeApp)
                HStack(alignment: .top, spacing: 20) {
                    ForEach(Tone.allCases, id: \.self) { tone in
                        ToneCard(tone: tone, example: ToneRules.apply(tone, to: Self.example[category] ?? ""),
                                 initial: initial, selected: selectedTone == tone) {
                            model.settings.tones[category.style.rawValue] = tone
                        }
                    }
                }
                recognition
            }
            .pageLayout()
        }
    }

    private var tabs: some View {
        HStack(spacing: 34) {
            ForEach(StyleCategory.allCases, id: \.self) { item in
                Button { category = item } label: {
                    Text(item.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(category == item ? Theme.text : Theme.secondary)
                        .padding(.bottom, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(category == item ? Theme.text : .clear).frame(height: 2) }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var selectedTone: Tone { model.settings.tone(for: category.style) }

    /// How speech is recognised in this category: a fixed language, and which dictionary groups
    /// Whisper gets first as hints.
    private var recognition: some View {
        let style = category.style.rawValue
        let chosen = model.settings.styleGroups[style] ?? []
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Language").font(.system(size: 15, weight: .medium))
                    Text("Fixed when you always speak one language here; faster and no slips into the other one.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                SelectBox(options: [("", "Automatic", nil), ("de", "Deutsch", nil), ("en", "English", nil)],
                          selection: Binding(get: { model.settings.styleLanguages[style] ?? "" },
                                             set: { model.settings.styleLanguages[style] = $0.isEmpty ? nil : $0 }),
                          width: 180, height: 34, fontSize: 14)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Dictionary groups first").font(.system(size: 15, weight: .medium))
                Text("Their words are the first hints for recognition in these apps.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                HStack(spacing: 8) {
                    ForEach(model.settings.dictionaryGroups, id: \.self) { group in
                        let on = chosen.contains(group)
                        Button {
                            var groups = chosen
                            if on { groups.removeAll { $0 == group } } else { groups.append(group) }
                            model.settings.styleGroups[style] = groups
                        } label: {
                            Text(group).font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Capsule().fill(on ? Theme.text : Theme.card))
                                .foregroundStyle(on ? Theme.panel : Theme.text)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private var initial: String {
        String(DemoMode.fullUserName.first ?? "?").uppercased()
    }

    private var resolver: AppStyleResolver { AppStyleResolver(overrides: model.settings.appStyles) }

    /// The installed apps of the category.
    private var apps: [String] {
        resolver.apps(for: category.style).filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "App für \(category.title) wählen"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { model.settings.appStyles[id] = category.style }
        }
    }

    /// Moves an app to "Other", or back there when it was added to "Other".
    private func removeApp(_ id: String) {
        if AppStyleResolver.builtIn[id] == .plain || category == .other {
            model.settings.appStyles.removeValue(forKey: id)
        } else {
            model.settings.appStyles[id] = .plain
        }
    }
}

private struct StyleBanner: View {
    let category: StyleCategory
    let apps: [String]
    let add: () -> Void
    let remove: (String) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.27, blue: 0.33), Color(red: 0.12, green: 0.10, blue: 0.09),
                                              Color(red: 0.33, green: 0.30, blue: 0.25)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(category.bannerTitle).font(.system(size: 30, design: .serif)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(category == .other ? "Everything that is not a messenger or an email app, notes included. Code editors and terminals always keep text as spoken."
                                            : "Style formatting applies in German and English.")
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                HStack(spacing: -14) {
                    ForEach(apps.prefix(6), id: \.self) { id in
                        AppBubble(id: id).contextMenu {
                            Button("Remove from \(category.title)") { remove(id) }
                        }
                    }
                    Button(action: add) {
                        Image(systemName: "plus").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.8))
                            .frame(width: 58, height: 58)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help("Add an app")
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
        }
    }
}

private struct AppBubble: View {
    let id: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        ZStack {
            Circle().fill(Color.white.opacity(0.12))
            if let url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 38, height: 38) }
        }
        .frame(width: 58, height: 58)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 2))
        .help(url?.deletingPathExtension().lastPathComponent ?? id)
    }
}

private struct ToneCard: View {
    let tone: Tone
    let example: String
    let initial: String
    let selected: Bool
    let action: () -> Void

    private static let accent = Color(red: 0.60, green: 0.45, blue: 0.78)

    private var heading: (String, String) {
        switch tone {
        case .formal: return ("Formal.", "Caps + Punctuation")
        case .casual: return ("Casual", "Caps + Less punctuation")
        case .veryCasual: return ("very casual", "No Caps + Less punctuation")
        }
    }

    private var avatar: Color {
        switch tone {
        case .formal: return Color(red: 0.91, green: 0.85, blue: 0.97)
        case .casual: return Color(red: 0.96, green: 0.78, blue: 0.93)
        case .veryCasual: return Color(red: 0.47, green: 0.15, blue: 0.22)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(heading.0).font(.system(size: 16, weight: .medium))
                Text(heading.1).font(.system(size: 16))
                Spacer(minLength: 60)
                Text(example)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 0,
                                                       topTrailingRadius: 12).fill(Self.accent.opacity(0.06)))
                HStack {
                    Spacer()
                    Text(initial).font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(avatar))
                }
                Spacer(minLength: 16)
            }
            .foregroundStyle(Theme.text)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Self.accent : Theme.border, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
