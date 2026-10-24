import DictationCore
import Foundation

/// Meetings straight from Microsoft 365 through Microsoft Graph, so the list is what Outlook and
/// Teams show, independent of how far the macOS calendar has synced. Read only.
///
/// Sign-in is the device-code flow: the app shows a short code, Microsoft's sign-in page takes it
/// and the account's own login (with MFA). The client is Microsoft's public "Microsoft Graph
/// Command Line Tools" app, the one `Connect-MgGraph` uses, so no app registration is needed; it
/// asks only for `Calendars.Read`. The refresh token lives in `graph-credentials.json` next to the
/// awork login, mode 600, outside the repo; access tokens stay in memory.
final class GraphCalendar: @unchecked Sendable {
    static let clientID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
    static let scope = "Calendars.Read offline_access"
    static var fileURL: URL { AppPaths.supportDirectory.appendingPathComponent("graph-credentials.json") }

    struct Credentials: Codable {
        var clientId: String
        var tenantId: String
        var refreshToken: String
    }

    struct DeviceCode {
        let userCode: String
        let verificationURL: URL
        fileprivate let deviceCode: String
        fileprivate let interval: Int
        fileprivate let expires: Date
    }

    enum Failure: LocalizedError {
        case notConnected
        case signIn(String)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Microsoft 365 is not connected."
            case .signIn(let message): return message
            case .http(let status): return "Microsoft Graph answered \(status)."
            }
        }
    }

    private let lock = NSLock()
    private var accessToken: (value: String, expires: Date)?

    var isConnected: Bool { Self.load() != nil }

    /// Asks Microsoft for a code the user enters on its sign-in page; tenant "organizations"
    /// lets any work account sign in, the real tenant is taken from the token afterwards.
    func startSignIn() async throws -> DeviceCode {
        let answer = try await Self.post("https://login.microsoftonline.com/organizations/oauth2/v2.0/devicecode",
                                         ["client_id": Self.clientID, "scope": Self.scope])
        guard let user = answer["user_code"] as? String, let device = answer["device_code"] as? String,
              let url = URL(string: answer["verification_uri"] as? String ?? "") else {
            throw Failure.signIn(answer["error_description"] as? String ?? "Microsoft gave no sign-in code.")
        }
        return DeviceCode(userCode: user, verificationURL: url, deviceCode: device,
                          interval: answer["interval"] as? Int ?? 5,
                          expires: Date().addingTimeInterval(TimeInterval(answer["expires_in"] as? Int ?? 900)))
    }

    /// Waits until the code was entered and saves the refresh token.
    func finishSignIn(_ code: DeviceCode) async throws {
        while Date() < code.expires {
            try await Task.sleep(nanoseconds: UInt64(code.interval) * 1_000_000_000)
            let answer = try await Self.post("https://login.microsoftonline.com/organizations/oauth2/v2.0/token",
                                             ["client_id": Self.clientID, "device_code": code.deviceCode,
                                              "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            if answer["error"] as? String == "authorization_pending" { continue }
            if answer["error"] as? String == "slow_down" { try await Task.sleep(nanoseconds: 5_000_000_000); continue }
            guard let refresh = answer["refresh_token"] as? String else {
                throw Failure.signIn(answer["error_description"] as? String ?? "The sign-in did not finish.")
            }
            Self.save(Credentials(clientId: Self.clientID, tenantId: Self.tenant(of: answer) ?? "organizations", refreshToken: refresh))
            remember(answer)
            return
        }
        throw Failure.signIn("The sign-in code expired. Try again.")
    }

    func signOut() {
        lock.withLock { accessToken = nil }
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    /// Calendar entries from `start` to `end`, all calendars of the mailbox merged by Outlook's
    /// calendar view (recurring meetings expanded, moved instances at their new time).
    func events(from start: Date, to end: Date) async throws -> [CalendarService.Event] {
        let token = try await currentToken()
        let format = ISO8601DateFormatter()
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/calendarView")!
        components.queryItems = [
            URLQueryItem(name: "startDateTime", value: format.string(from: start)),
            URLQueryItem(name: "endDateTime", value: format.string(from: end)),
            URLQueryItem(name: "$select", value: "id,subject,start,end,isAllDay,isCancelled,showAs,isOnlineMeeting,onlineMeeting,organizer,attendees,body"),
            URLQueryItem(name: "$orderby", value: "start/dateTime"),
            URLQueryItem(name: "$top", value: "200"),
        ]
        var next = components.url
        var events: [CalendarService.Event] = []
        while let url = next {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("outlook.timezone=\"UTC\", outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { lock.withLock { accessToken = nil } }
            guard status == 200, let page = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.http(status) }
            events += (page["value"] as? [[String: Any]] ?? []).compactMap(Self.event)
            next = (page["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        return events
    }

    // MARK: Parsing

    private static func event(_ item: [String: Any]) -> CalendarService.Event? {
        guard (item["isCancelled"] as? Bool) != true, (item["isAllDay"] as? Bool) != true,
              let id = item["id"] as? String,
              let start = date(item["start"]), let end = date(item["end"]) else { return nil }
        let organizer = (item["organizer"] as? [String: Any]).flatMap(person)
        var people = (item["attendees"] as? [[String: Any]] ?? []).compactMap(person)
        if let organizer, !people.contains(where: { $0.email.lowercased() == organizer.email.lowercased() }) { people.insert(organizer, at: 0) }
        let online = item["onlineMeeting"] as? [String: Any]
        let body = (item["body"] as? [String: Any])?["content"] as? String ?? ""
        let join = (online?["joinUrl"] as? String).flatMap(URL.init(string:)) ?? CalendarService.teamsLink(in: body)
        return CalendarService.Event(id: id, title: item["subject"] as? String ?? "Untitled meeting", start: start, end: end,
                                     organizer: organizer, participants: people, joinURL: join,
                                     isInfo: (item["showAs"] as? String) == "free")
    }

    private static func person(_ entry: [String: Any]) -> MeetingParticipant? {
        guard let address = entry["emailAddress"] as? [String: Any] else { return nil }
        return MeetingParticipant(name: address["name"] as? String ?? "", email: address["address"] as? String ?? "")
    }

    /// Graph's "2026-10-21T12:00:00.0000000" in the time zone asked for, here UTC.
    private static func date(_ value: Any?) -> Date? {
        guard let text = (value as? [String: Any])?["dateTime"] as? String else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        format.timeZone = TimeZone(identifier: "UTC")
        return format.date(from: String(text.prefix(19)))
    }

    // MARK: Tokens

    private func currentToken() async throws -> String {
        if let token = lock.withLock({ accessToken }), token.expires > Date().addingTimeInterval(60) { return token.value }
        guard let credentials = Self.load() else { throw Failure.notConnected }
        let answer = try await Self.post("https://login.microsoftonline.com/\(credentials.tenantId)/oauth2/v2.0/token",
                                         ["client_id": credentials.clientId, "grant_type": "refresh_token",
                                          "refresh_token": credentials.refreshToken, "scope": Self.scope])
        guard let token = answer["access_token"] as? String else {
            if answer["error"] as? String == "invalid_grant" { signOut() }
            throw Failure.signIn(answer["error_description"] as? String ?? "Microsoft did not renew the sign-in.")
        }
        // Microsoft hands out a new refresh token with each renewal; the old one stays valid
        // for a while, the new one for longer.
        if let refresh = answer["refresh_token"] as? String {
            var renewed = credentials
            renewed.refreshToken = refresh
            Self.save(renewed)
        }
        remember(answer)
        return token
    }

    private func remember(_ answer: [String: Any]) {
        guard let token = answer["access_token"] as? String else { return }
        let seconds = answer["expires_in"] as? Int ?? 3600
        lock.withLock { accessToken = (token, Date().addingTimeInterval(TimeInterval(seconds))) }
    }

    /// The tenant id from the access token's `tid` claim.
    private static func tenant(of answer: [String: Any]) -> String? {
        guard let token = answer["access_token"] as? String else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["tid"] as? String
    }

    private static func load() -> Credentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    private static func save(_ credentials: Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        CredentialFile.writePrivate(data, to: fileURL)
    }

    private static func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
