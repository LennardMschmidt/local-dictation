import Foundation

/// What to know before a meeting: the earlier meetings with the same people or customer, their
/// open action items and main points, and the customer note. Built from the vault's meeting
/// notes (tl;dv and LocalDictation write the same format), so it also covers meetings from
/// before LocalDictation.
public struct Briefing: Equatable, Sendable {
    public struct PastMeeting: Equatable, Sendable {
        public var title: String
        public var date: Date
        /// Vault path without ".md", for opening the note.
        public var note: String
        public var openItems: [String]
        public var points: [String]

        public init(title: String, date: Date, note: String, openItems: [String], points: [String]) {
            self.title = title
            self.date = date
            self.note = note
            self.openItems = openItems
            self.points = points
        }
    }

    public var title: String
    public var start: Date
    /// The customer note's name, nil for internal meetings or unknown domains.
    public var customer: String?
    public var previous: [PastMeeting]
    /// Open awork tasks of the customer's projects, filled in by the app.
    public var openTasks: [String] = []

    public var isEmpty: Bool { previous.isEmpty && openTasks.isEmpty && customer == nil }

    public init(title: String, start: Date, customer: String?, previous: [PastMeeting], openTasks: [String] = []) {
        self.title = title
        self.start = start
        self.customer = customer
        self.previous = previous
        self.openTasks = openTasks
    }
}

/// One meeting note of the vault, read from its front matter.
public struct VaultMeetingNote: Equatable, Sendable {
    public var path: String
    public var title: String
    public var date: Date
    public var participants: [String]
    public var customer: String

    /// The meeting notes under "08 Meetings", newest first. Only the front matter and the title
    /// are read here; the body is read for the few notes a briefing uses.
    public static func scan(vault: URL, since: Date) -> [VaultMeetingNote] {
        let root = vault.appendingPathComponent("08 Meetings")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var notes: [VaultMeetingNote] = []
        for case let file as URL in files where file.pathExtension == "md" {
            // Both resolved, so a vault behind a symbolic link still gives relative paths.
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let note = parse(text, path: file.resolvingSymlinksInPath().path, vault: vault.resolvingSymlinksInPath().path),
                  note.date >= since else { continue }
            notes.append(note)
        }
        return notes.sorted { $0.date > $1.date }
    }

    static func parse(_ text: String, path: String, vault: String) -> VaultMeetingNote? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var fields: [String: String] = [:]
        var participants: [String] = []
        var inParticipants = false
        for line in lines[1..<end] {
            if line.hasPrefix("  - ") || line.hasPrefix("- ") {
                if inParticipants { participants.append(line.drop { $0 == " " || $0 == "-" }.trimmingCharacters(in: .whitespaces)) }
                continue
            }
            inParticipants = false
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if key == "teilnehmer" { inParticipants = value.isEmpty } else { fields[key] = value }
        }
        guard fields["type"] == "meeting", let day = fields["datum"] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let time = (fields["uhrzeit"] ?? "").prefix(5)
        guard let date = formatter.date(from: "\(day) \(time.count == 5 ? String(time) : "00:00")") else { return nil }
        let title = lines[end...].first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var relative = path.hasPrefix(vault + "/") ? String(path.dropFirst(vault.count + 1)) : path
        if relative.hasSuffix(".md") { relative = String(relative.dropLast(3)) }
        return VaultMeetingNote(path: relative, title: title, date: date, participants: participants,
                                customer: (fields["kunde"] ?? "").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""))
    }
}

public enum BriefingBuilder {
    /// The briefing for a meeting with `participants`: the latest earlier meetings of the same
    /// customer, or for an internal meeting those with the same people.
    public static func build(title: String, start: Date, participants: [MeetingParticipant], ownName: String,
                             customerMap: [String: String], notes: [VaultMeetingNote], vault: URL, limit: Int = 2) -> Briefing {
        // By the participants' domains, otherwise by a customer named in the title ("… x Fabrikam").
        let customer = CustomerRouting.customer(for: participants, map: customerMap)
            ?? Set(customerMap.values).sorted().first { name in
                title.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: [.regularExpression, .caseInsensitive]) != nil
            }
        let others = participants.map(\.displayName).filter { !$0.lowercased().hasPrefix(ownName.lowercased()) }
        let surnames = Set(others.compactMap { $0.split(separator: " ").last.map { $0.lowercased() } }.filter { $0.count > 2 })
        let earlier = notes.filter { $0.date < start.addingTimeInterval(-15 * 60) }
        let matching = earlier.filter { note in
            if let customer, note.customer.localizedCaseInsensitiveCompare(customer) == .orderedSame { return true }
            let names = note.participants.compactMap { $0.split(separator: " ").last.map { $0.lowercased() } }
            // Or the same people: everyone else of this meeting was there before as well.
            return !surnames.isEmpty && surnames.isSubset(of: Set(names))
        }
        let previous = matching.prefix(limit).map { note -> Briefing.PastMeeting in
            let body = (try? String(contentsOf: vault.appendingPathComponent(note.path + ".md"), encoding: .utf8)) ?? ""
            let (items, points) = Self.content(of: body)
            return Briefing.PastMeeting(title: note.title, date: note.date, note: note.path, openItems: items, points: points)
        }
        return Briefing(title: title, start: start, customer: customer, previous: Array(previous))
    }

    /// The open action items ("- [ ] …") and the first points of the topics in a meeting note,
    /// without the time stamps.
    static func content(of note: String) -> (items: [String], points: [String]) {
        var items: [String] = []
        var points: [String] = []
        var inTopics = false
        for raw in note.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") && !line.contains("KI-Notizen") && inTopics { break }
            if line.hasPrefix("### ") { inTopics = !line.lowercased().contains("aufgaben") && !line.lowercased().contains("action") }
            if line.hasPrefix("- [ ] ") { items.append(clean(String(line.dropFirst(6)))) }
            else if inTopics, line.hasPrefix("- "), points.count < 3 { points.append(clean(String(line.dropFirst(2)))) }
        }
        return (items, points)
    }

    /// Without time stamps, also tl;dv's linked ones ("[05:26](/app/meetings/…?t=326)").
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\[\d{1,2}:\d{2}(:\d{2})?\](\([^)]*\))?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
