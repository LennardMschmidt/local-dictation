import Foundation

/// How the cleanup formats text for the app it is inserted into.
public enum AppStyle: String, Codable, CaseIterable, Sendable {
    /// Personal messengers (WhatsApp, iMessage, Telegram, Discord, Signal).
    case chat
    /// Work messengers (Teams, Slack).
    case work
    case mail
    case code
    case notes
    case plain

    /// How the cleanup prompt describes this target.
    var instruction: String {
        switch self {
        case .chat:
            return "a chat message. Keep the casual tone."
        case .work:
            return "a work chat message to colleagues."
        case .mail:
            return "an email. A dictated greeting goes on its own first line ending with a comma, then an empty line, the body, an empty line, and the sign-off with the name on its own last line."
        case .code:
            return "a code editor or terminal. Keep identifiers, file names and commands exactly as spoken. Lists follow rule 8, also here."
        case .notes:
            return "a Markdown note. Use Markdown lists for enumerations."
        case .plain:
            return "a general text field."
        }
    }
}

/// How formal the cleaned text reads, set per app category like Wispr Flow's styles.
public enum Tone: String, Codable, CaseIterable, Sendable {
    /// Capitalisation and full punctuation.
    case formal
    /// Capitalisation, lighter punctuation.
    case casual
    /// Lower case and minimal punctuation, like typing in a chat.
    case veryCasual

    var instruction: String {
        switch self {
        case .formal: return ""
        case .casual: return "Tone casual: capitalise normally but leave out the final period of a single-sentence message and optional commas."
        case .veryCasual: return "Tone very casual: write everything in lower case (also German nouns) and leave out periods and optional commas."
        }
    }

    public var title: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        }
    }
}

/// Picks the style for the frontmost app from its bundle id.
public struct AppStyleResolver: Sendable {
    public static let builtIn: [String: AppStyle] = [
        "com.microsoft.teams2": .work,
        "com.microsoft.teams": .work,
        "com.tinyspeck.slackmacgap": .work,
        "com.apple.MobileSMS": .chat,
        "net.whatsapp.WhatsApp": .chat,
        "desktop.WhatsApp": .chat,
        "ru.keepcoder.Telegram": .chat,
        "org.telegram.desktop": .chat,
        "com.hnc.Discord": .chat,
        "org.whispersystems.signal-desktop": .chat,
        "com.microsoft.Outlook": .mail,
        "com.apple.mail": .mail,
        "com.microsoft.VSCode": .code,
        "com.apple.Terminal": .code,
        "com.googlecode.iterm2": .code,
        "com.mitchellh.ghostty": .code,
        "com.cmuxterm.app": .code,
        "com.termius-dmg.mac": .code,
        "dev.warp.Warp-Stable": .code,
        "com.todesktop.230313mzl4w4u92": .code,
        "md.obsidian": .notes,
        "com.apple.Notes": .notes,
    ]

    private let overrides: [String: AppStyle]

    public init(overrides: [String: AppStyle] = [:]) {
        self.overrides = overrides
    }

    /// The apps of a style, built in and added by the user, without the ones moved elsewhere.
    public func apps(for style: AppStyle) -> [String] {
        let builtIn = Self.builtIn.filter { $0.value == style && overrides[$0.key] == nil }.map(\.key)
        return (builtIn + overrides.filter { $0.value == style }.map(\.key)).sorted()
    }

    public func style(for bundleId: String?) -> AppStyle {
        guard let bundleId else { return .plain }
        return overrides[bundleId] ?? Self.builtIn[bundleId] ?? .plain
    }
}

/// The style categories on the Style page, like Wispr Flow's: personal messages, work messages,
/// email, and everything else. Notes use the tone of "Other".
public enum StyleCategory: String, CaseIterable, Sendable {
    case personal, work, email, other

    /// The style whose tone this category sets.
    public var style: AppStyle {
        switch self {
        case .personal: return .chat
        case .work: return .work
        case .email: return .mail
        case .other: return .plain
        }
    }

    public var title: String {
        switch self {
        case .personal: return "Personal messages"
        case .work: return "Work messages"
        case .email: return "Email"
        case .other: return "Other"
        }
    }

    public var bannerTitle: String {
        switch self {
        case .personal: return "This style applies in personal messengers"
        case .work: return "This style applies in work messengers"
        case .email: return "This style applies in email apps"
        case .other: return "This style applies in all other apps"
        }
    }
}

/// Applies a tone to cleaned text by rule, so the chosen style holds even when the model does
/// not follow the instruction. Formal leaves the text as it is.
public enum ToneRules {
    public static func apply(_ tone: Tone, to text: String) -> String {
        switch tone {
        case .formal:
            return text
        case .casual:
            return dropFinalPeriods(dropGreetingComma(text))
        case .veryCasual:
            return dropSentencePeriods(dropGreetingComma(text)).lowercased()
        }
    }

    /// "Hey, are you…" becomes "Hey are you…".
    static func dropGreetingComma(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)^(hey|hi|hallo|hello|moin|servus|na),\s"#, with: "$1 ", options: .regularExpression)
    }

    /// Removes the period at the end of each line.
    static func dropFinalPeriods(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<![.\d])\.(?=[ \t]*(\n|$))"#, with: "", options: .regularExpression)
    }

    /// Removes periods that end a sentence, but not those in numbers, addresses or abbreviations
    /// inside words.
    static func dropSentencePeriods(_ text: String) -> String {
        dropFinalPeriods(text).replacingOccurrences(of: #"(?<![.\d])\.(?=\s)"#, with: "", options: .regularExpression)
    }
}
