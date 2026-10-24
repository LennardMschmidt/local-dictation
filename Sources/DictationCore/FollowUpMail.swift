import Foundation

/// A follow-up mail after a meeting: what was agreed and who does what, written from the
/// meeting's notes for the other participants.
public struct FollowUpMail: Codable, Equatable, Sendable {
    public var subject: String
    public var body: String

    public init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": ["subject": ["type": "string"], "body": ["type": "string"]],
        "required": ["subject", "body"],
        "additionalProperties": false,
    ]

    /// Writes the mail with `client`. `recipients` are the other participants' names, `me` signs.
    public static func write(meetingTitle: String, date: Date, notes: String, recipients: [String], me: String,
                             signature: String, language: String, client: ChatCompleter) async throws -> FollowUpMail {
        let german = language != "en"
        let system = """
        You write the follow-up mail after a meeting, from the meeting notes, in \(german ? "German" : "English"). \(me) sends it to \(recipients.isEmpty ? "the other participants" : recipients.joined(separator: ", ")).

        - Greeting by first name if the notes show the people use first names or "du", otherwise formal\(german ? " with \"Sie\"" : "").
        - One or two sentences of thanks and purpose, then the results as a short list, then the agreed action items as a list "Name: what (by when)", then a short closing line. Only what is in the notes; no new facts, no promises nobody made.
        - Plain text that pastes into Outlook: lists with "- ", no Markdown headings, no bold, no em dashes, no filler such as "I hope this mail finds you well".
        - End with the sign-off\(signature.isEmpty ? " and \(me)'s name" : " followed by this signature:\n\(signature)").
        - "subject": short, starting with "Zusammenfassung" or "Follow-up" and the meeting topic.
        """
        let user = "Meeting: \(meetingTitle), \(date.formatted(date: .long, time: .shortened))\n\nNotes:\n\(notes)"
        let reply = try await client.complete(messages: [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)],
                                              maxTokens: 1_500, schema: schema)
        let cleaned = ResponseSanitizer.stripThinking(reply)
        guard let start = cleaned.firstIndex(of: "{"),
              let mail = try? JSONDecoder().decode(FollowUpMail.self, from: Data(cleaned[start...].utf8)) else { throw LLMError.rejected(.empty) }
        return mail
    }

    /// A mailto link for the default mail app, with the participants' addresses.
    public func mailto(to addresses: [String]) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = addresses.joined(separator: ",")
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return components.url
    }
}
