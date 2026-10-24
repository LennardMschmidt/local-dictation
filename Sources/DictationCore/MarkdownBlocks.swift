import Foundation

/// Splits a short Markdown answer into blocks a small card can lay out: headings, list items,
/// tables and paragraphs. Inline formatting (bold, code, links) stays in the text.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(String)
    case bullet(String)
    case numbered(Int, String)
    /// A table as its header and rows. The card shows each row with `titleColumn` as its title,
    /// `keyColumn` (a ticket number or id) in front of it, and the other cells below.
    case table(header: [String], rows: [[String]], titleColumn: Int, keyColumn: Int? = nil)
    /// A table of two columns that names fields and their values ("Field | Value"), shown as
    /// one "label: value" line per row.
    case fields([[String]])
    case paragraph(String)

    static let titleHeaders: Set<String> = ["title", "titel", "subject", "betreff", "name", "task", "aufgabe", "summary", "event", "termin"]
    static let keyHeaders: Set<String> = ["ticket", "case", "key", "id", "nr", "nr.", "number", "nummer", "#", "issue"]
    static let fieldHeaders: Set<String> = ["field", "feld", "property", "eigenschaft", "attribute", "item"]
    static let valueHeaders: Set<String> = ["value", "wert"]

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var tableLines: [[String]] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func flushTable() {
            guard let header = tableLines.first else { return }
            let rows = Array(tableLines.dropFirst())
            tableLines = []
            let names = header.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "*_ ")) }
            if header.count == 2, fieldHeaders.contains(names[0]) || valueHeaders.contains(names[1]) {
                blocks.append(.fields(rows.map { Array($0.prefix(2)) }))
                return
            }
            // A column named like a title is the title; otherwise the one with the longest texts.
            let widths = header.indices.map { column in rows.reduce(0) { $0 + ($1.indices.contains(column) ? $1[column].count : 0) } }
            let title = names.firstIndex(where: titleHeaders.contains) ?? widths.indices.max { widths[$0] < widths[$1] } ?? 0
            let key = names.indices.first { $0 != title && keyHeaders.contains(names[$0]) }
            blocks.append(.table(header: header, rows: rows, titleColumn: title, keyColumn: key))
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                flushParagraph()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The line under the header ("|---|:--|") only marks the alignment.
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                tableLines.append(cells)
                continue
            }
            flushTable()
            if line.isEmpty || line == "---" || line == "***" {
                flushParagraph()
            } else if line.hasPrefix("#") {
                flushParagraph()
                blocks.append(.heading(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]), line[line.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                blocks.append(.numbered(number, String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        flushTable()
        flushParagraph()
        return blocks
    }
}
