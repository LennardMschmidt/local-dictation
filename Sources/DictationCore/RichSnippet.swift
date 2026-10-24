import AppKit
import Foundation

/// Snippets keep their formatting as Markdown (bold, italic, lists, links). When one is inserted,
/// apps that understand formatted text get it formatted, all others get clean text without the
/// Markdown marks.
public enum RichSnippet {
    /// Whether the text uses any Markdown the snippet editor offers.
    public static func hasFormatting(_ text: String) -> Bool {
        text.range(of: #"\*\*[^*]+\*\*|(?<!\*)\*[^*\s][^*]*\*(?!\*)|\[[^\]]+\]\([^)]+\)|(?m)^(\s*)([-*]|\d+\.)\s"#,
                   options: .regularExpression) != nil
    }

    /// The text as it should read without formatting: marks removed, links as "text (address)".
    public static func plain(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\*)\*([^*\s][^*]*)\*(?!\*)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^(\s*)[-*]\s"#, with: "$1• ", options: .regularExpression)
    }

    /// The text as RTF, line by line, so lists and paragraphs keep their breaks.
    public static func rtf(_ markdown: String, fontSize: CGFloat = 13) -> Data? {
        let result = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: fontSize)
        let lines = markdown.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.replacingOccurrences(of: #"^(\s*)[-*]\s"#, with: "$1• ", options: .regularExpression)
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let parsed = (try? AttributedString(markdown: line, options: options)) ?? AttributedString(line)
            let attributed = NSMutableAttributedString(parsed)
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
                var target = font
                if let intent = attributes[.inlinePresentationIntent] as? UInt,
                   let presentation = InlinePresentationIntent(rawValue: intent) as InlinePresentationIntent? {
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if presentation.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if presentation.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty {
                        target = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: fontSize) ?? font
                    }
                }
                attributed.addAttribute(.font, value: target, range: range)
            }
            result.append(attributed)
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
        }
        return try? result.data(from: NSRange(location: 0, length: result.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
}
