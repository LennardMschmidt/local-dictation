import AppKit
import SwiftUI

/// Colours, fonts and shared building blocks of the window, modelled on Wispr Flow: a warm
/// off-white light theme with teal accents, and a dark counterpart. Every colour adapts to the
/// appearance of the view it is drawn in.
enum Theme {
    static let window = dynamic(light: 0xF2EFEA, dark: 0x141414)
    static let panel = dynamic(light: 0xFCFBF8, dark: 0x1D1D1D)
    static let card = dynamic(light: 0xF5F3EF, dark: 0x252525)
    static let cardHover = dynamic(light: 0xEDEAE4, dark: 0x2E2E2E)
    static let border = dynamic(light: 0xE4E0D8, dark: 0x343434)
    static let selection = dynamic(light: 0xE7E3DC, dark: 0x2C2C2C)
    static let text = dynamic(light: 0x1E1E1E, dark: 0xEDEDED)
    static let secondary = dynamic(light: 0x6E6A64, dark: 0x9C9C9C)
    static let tealDark = dynamic(light: 0x2D5F5C, dark: 0x5DB0A6)
    static let teal = dynamic(light: 0x4F9089, dark: 0x4A8C85)
    static let tealLight = dynamic(light: 0x8FCFC6, dark: 0x356A64)
    static let tealPale = dynamic(light: 0xCEEDE8, dark: 0x24443F)
    static let empty = dynamic(light: 0xD3CCC2, dark: 0x333333)
    static let orange = dynamic(light: 0xF2A65A, dark: 0xE8964A)
    static let banner = dynamic(light: 0x111111, dark: 0x0B0B0B)

    /// Kept for pages that still use the older names.
    static let page = panel

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static func headline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(text.isEmpty ? Theme.secondary : Theme.text)
    }

    static func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(1.4)
            .foregroundStyle(Theme.secondary)
    }

    static func bigNumber(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 28, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.text)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// A rounded panel used for the content blocks on every page.
struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
}

/// The light, dark or system appearance, applied to the whole app.
enum AppearanceMode: String, CaseIterable {
    case light, dark, system

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var icon: String {
        switch self {
        case .light: return "sun.max"
        case .dark: return "moon"
        case .system: return "desktopcomputer"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

/// A white drop-down box like Wispr Flow's selects: the current value with a chevron, the
/// options in a menu.
/// An ⓘ icon that explains a setting in a small popover, on hover and on click.
struct InfoButton: View {
    let text: String
    var size: CGFloat = 14
    @State private var showing = false
    @State private var hoverWork: DispatchWorkItem?

    init(_ text: String, size: CGFloat = 14) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: size))
                .foregroundStyle(showing ? Theme.text : Theme.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoverWork?.cancel()
            let work = DispatchWorkItem { showing = inside }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.3 : 0.15), execute: work)
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

struct SelectBox<Value: Hashable>: View {
    let options: [(value: Value, title: String, icon: String?)]
    @Binding var selection: Value
    var placeholder = "Choose"
    var width: CGFloat = 240
    var height: CGFloat = 36
    var fontSize: CGFloat = 14

    var body: some View {
        let current = options.first { $0.value == selection }
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else if let icon = option.icon {
                        Label(option.title, systemImage: icon)
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let icon = current?.icon { Image(systemName: icon) }
                Text(current?.title ?? placeholder)
                    .foregroundStyle(current == nil ? Theme.secondary : Theme.text)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
            }
            .font(.system(size: fontSize))
            .padding(.horizontal, 14)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
        // The button style with a plain button keeps the label exactly as drawn above.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

extension View {
    /// The frame of every main page: a column centred in the window with the same margins on
    /// every page, as wide as `maxWidth` and narrower when the window is. In full screen the
    /// content fills most of the space, like Wispr Flow's pages.
    func pageLayout(maxWidth: CGFloat = 1240) -> some View {
        padding(.horizontal, 56)
            .padding(.vertical, 40)
            .frame(maxWidth: maxWidth + 112, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

/// The buttons of the sheets in Wispr Flow's style: the main action dark with light text, the
/// others in the soft selection colour; both 36 pt high with rounded corners.
struct SheetButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(primary ? Theme.panel : Theme.text)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Theme.text : Theme.selection))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}
