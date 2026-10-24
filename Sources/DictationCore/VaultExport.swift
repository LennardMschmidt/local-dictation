import Foundation

/// Writes a meeting into the Obsidian vault the way the tl;dv sync does
/// (`~/.local/bin/tldv-sync.mjs`): `08 Meetings/<year>-KW<week>/<date>/<title>.md` with the same
/// frontmatter, info table, notes and transcript, and a link in the customer's note. The tl;dv
/// sync rebuilds the meeting MOC from all files, so these notes show up there as well.
public struct VaultMeetingExport {
    public static let library = "08 Meetings"
    public static let customers = "02 Kunden"

    public let vault: URL
    public let customerMap: [String: String]
    let timeZone = TimeZone(identifier: "Europe/Berlin")!

    public init(vault: URL, customerMap: [String: String]) {
        self.vault = vault
        self.customerMap = customerMap
    }

    public struct Result: Equatable {
        public var path: String
        public var customerLink: String
    }

    /// Writes the note and links it in the customer note. `ownName` names the microphone track.
    @discardableResult
    public func write(_ meeting: Meeting, ownName: String) throws -> Result {
        let parts = DateParts(start: meeting.scheduledStart ?? meeting.date, duration: meeting.duration, timeZone: timeZone)
        let folder = vault.appendingPathComponent(Self.library).appendingPathComponent(parts.week).appendingPathComponent(parts.day)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = Self.fileURL(in: folder, title: meeting.title, id: meeting.id)
        try note(meeting, ownName: ownName, parts: parts).write(to: file, atomically: true, encoding: .utf8)
        let relative = "\(Self.library)/\(parts.week)/\(parts.day)/\(file.deletingPathExtension().lastPathComponent)"
        var link = "intern"
        if let customer = CustomerRouting.customer(for: meeting.participants, map: customerMap) {
            link = try linkIntoCustomer(customer, path: relative, title: meeting.title, day: parts.day)
        }
        return Result(path: relative, customerLink: link)
    }

    /// The file for this meeting: its own earlier export, or a free name. A note from tl;dv for the
    /// same meeting keeps its name; this one gets "(LocalDictation)" added.
    static func fileURL(in folder: URL, title: String, id: UUID) -> URL {
        let base = sanitize(title.isEmpty ? "Meeting" : title)
        let marker = "localdictation-id: \(id.uuidString)"
        for name in [base, "\(base) (LocalDictation)"] {
            let url = folder.appendingPathComponent(name + ".md")
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return url }
            if existing.contains(marker) { return url }
        }
        var number = 2
        while true {
            let url = folder.appendingPathComponent("\(base) (LocalDictation \(number)).md")
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return url }
            if existing.contains(marker) { return url }
            number += 1
        }
    }

    func note(_ meeting: Meeting, ownName: String, parts: DateParts) -> String {
        let people = meeting.participants.map(\.displayName)
        let external = meeting.participants.filter { !$0.domain.isEmpty && $0.domain != CustomerRouting.ownDomain }
        let customer = CustomerRouting.customer(for: meeting.participants, map: customerMap)
        let internalMeeting = CustomerRouting.isInternal(meeting.participants)
        var tags = ["meeting", internalMeeting ? "intern" : "kunde"]
        if !internalMeeting && customer == nil { tags.append("unrouted") }
        let organizer = meeting.organizer?.displayName ?? ownName

        var lines = ["---", "type: meeting", "tags:" + Self.yamlList(tags), "created: \(parts.day)", "quelle: localdictation",
                     "localdictation-id: \(meeting.id.uuidString)", "datum: \(parts.day)", "kw: \(parts.weekNumber)",
                     "uhrzeit: \(Self.json(parts.time))", "dauer: \(Self.json(parts.duration))",
                     "organisator: \(Self.yamlScalar(organizer))", "teilnehmer:" + Self.yamlList(people),
                     customer.map { "kunde: \"[[\($0)]]\"" } ?? "kunde:", "vollstaendig: true", "---", ""]
        lines.append("# \(meeting.title.isEmpty ? "Meeting" : meeting.title)")
        lines.append("")
        lines.append("| | |")
        lines.append("|---|---|")
        lines.append("| **Datum** | \(parts.weekday), \(parts.longDate) |")
        lines.append("| **Uhrzeit** | \(parts.time) (Europe/Berlin) |")
        lines.append("| **Dauer** | \(parts.duration) |")
        lines.append("| **Kalenderwoche** | KW \(parts.weekNumber) / \(parts.weekYear) |")
        lines.append("| **Organisator** | \(organizer) |")
        lines.append("| **Teilnehmer** | \(people.isEmpty ? "—" : people.joined(separator: ", ")) |")
        if !external.isEmpty {
            lines.append("| **Extern** | " + external.map { $0.name.isEmpty || $0.name == $0.email ? $0.email : "\($0.name) (\($0.email))" }
                .joined(separator: ", ") + " |")
        }
        lines.append("| **Kunde** | \(customer.map { "[[\($0)]]" } ?? (internalMeeting ? "intern" : "⚠️ nicht zugeordnet")) |")
        if !meeting.segments.isEmpty { lines.append("| **Transkript** | [[#Transkript\\|unten im Dokument]] |") }
        lines.append("| **Aufnahme** | LocalDictation (auf diesem Mac) |")
        lines.append("")
        if !internalMeeting && customer == nil {
            let domains = Set(external.map(\.domain)).sorted().joined(separator: ", ")
            lines.append("> [!todo] Kunde nicht zugeordnet — Domains: \(domains). Mapping ergänzen in `~/.config/tldv/customers.json`.")
            lines.append("")
        }
        lines.append("## KI-Notizen")
        lines.append("")
        lines.append(meeting.notesMarkdown.isEmpty ? (meeting.summary.isEmpty ? "> [!info] Keine Notizen." : meeting.summary)
                                                    : meeting.notesMarkdown)
        lines.append("")
        lines.append("---")
        lines.append("[[\(Self.library)/Meetings MOC|← Meeting-Bibliothek]]")
        if !meeting.segments.isEmpty {
            lines.append("")
            lines.append("## Transkript")
            for segment in meeting.segments {
                lines.append("")
                lines.append("**\(meeting.name(for: segment.speaker, ownName: ownName))** _(\(MeetingNotesWriter.clock(segment.start)))_")
                lines.append(segment.text)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Adds "- <date> — [[path|title]]" under "## Meetings" in the customer note, once.
    func linkIntoCustomer(_ customer: String, path: String, title: String, day: String) throws -> String {
        let url = vault.appendingPathComponent(Self.customers).appendingPathComponent("\(customer).md")
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return "übersprungen (\(Self.customers)/\(customer).md fehlt)" }
        if text.contains(path) { return "schon verlinkt" }
        let line = "- \(day) — [[\(path)|\(title)]]"
        if let range = text.range(of: #"(?m)^## Meetings\s*$"#, options: .regularExpression) {
            text.insert(contentsOf: "\n" + line, at: range.upperBound)
        } else {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## Meetings\n" + line + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return "verlinkt"
    }

    // MARK: Format helpers, as in the tl;dv sync

    struct DateParts {
        var day: String
        var week: String
        var weekNumber: Int
        var weekYear: Int
        var weekday: String
        var longDate: String
        var time: String
        var duration: String

        init(start: Date, duration seconds: Double, timeZone: TimeZone) {
            var calendar = Calendar(identifier: .iso8601)
            calendar.timeZone = timeZone
            let german = Locale(identifier: "de_DE")
            func format(_ pattern: String, _ date: Date) -> String {
                let formatter = DateFormatter()
                formatter.locale = german
                formatter.timeZone = timeZone
                formatter.dateFormat = pattern
                return formatter.string(from: date)
            }
            let end = start.addingTimeInterval(seconds)
            day = format("yyyy-MM-dd", start)
            weekNumber = calendar.component(.weekOfYear, from: start)
            weekYear = calendar.component(.yearForWeekOfYear, from: start)
            week = String(format: "%d-KW%02d", weekYear, weekNumber)
            weekday = format("EEEE", start)
            longDate = format("dd. MMMM yyyy", start)
            time = "\(format("HH:mm", start))–\(format("HH:mm", end))"
            let minutes = Int((seconds / 60).rounded())
            duration = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)min" : "\(minutes)min"
        }
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: #"[/\\:*?"<>|#^\[\]]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Meeting" : String(cleaned.prefix(90))
    }

    static func yamlScalar(_ value: String) -> String {
        value.range(of: #"^[\wÄÖÜäöüß][\wÄÖÜäöüß .&/+-]*$"#, options: .regularExpression) != nil ? value : json(value)
    }

    static func yamlList(_ values: [String]) -> String {
        values.isEmpty ? " []" : "\n" + values.map { "  - \(yamlScalar($0))" }.joined(separator: "\n")
    }

    static func json(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }
}
