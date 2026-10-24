import DictationCore
import EventKit
import Foundation

/// Upcoming meetings, read only. With Microsoft 365 connected they come straight from Outlook
/// through `GraphCalendar`; otherwise, or when Microsoft cannot be reached, from the macOS
/// Calendar (which also shows Outlook and Google calendars added in System Settings › Internet
/// Accounts).
final class CalendarService: ObservableObject {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        var organizer: MeetingParticipant? = nil
        /// Everyone invited, the organiser included.
        var participants: [MeetingParticipant] = []
        /// The Teams (or other online meeting) link to join with.
        var joinURL: URL? = nil
        /// Marked free in the calendar: a note such as a support shift or a focus block, shown
        /// lighter and never taken as the meeting a recording belongs to.
        var isInfo = false

        /// Other people take part and it is not just an info entry.
        var isMeeting: Bool { !isInfo && participants.count >= 2 }
    }

    /// One calendar macOS knows, with the account it belongs to ("Exchange", "iCloud", …).
    struct CalendarInfo: Identifiable, Equatable {
        let id: String
        let title: String
        let account: String
        let color: CGColor?
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var authorized = false
    @Published private(set) var calendars: [CalendarInfo] = []
    /// The calendar identifiers to leave out, from the settings.
    var excluded: () -> [String] = { [] }

    /// Where the list comes from now: "Microsoft 365" or "macOS Calendar", for the settings.
    @Published private(set) var source = "macOS Calendar"
    @Published private(set) var microsoftConnected: Bool

    let graph = GraphCalendar()
    private let store = EKEventStore()
    private var graphEvents: [Event]?
    private var graphFetched = Date.distantPast
    private var graphFetching = false
    private var timer: Timer?

    init() {
        microsoftConnected = graph.isConnected
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        refresh()
        // Outlook changes do not notify the Mac; the list asks Microsoft every two minutes.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Asks for calendar access; macOS shows its dialog once.
    func connect() {
        if DemoMode.isOn { return refresh() }
        store.requestFullAccessToEvents { [weak self] granted, error in
            if let error { AppLog.error("calendar access failed: \(error)") }
            DispatchQueue.main.async {
                self?.authorized = granted
                self?.refresh()
            }
        }
    }

    /// The meeting a recording started now belongs to, after `MeetingMatch`: a meeting with
    /// other people that runs or starts within two minutes; nil for a note of its own.
    func currentMeeting(at now: Date = Date()) -> Event? {
        refresh()
        let candidates = events.map { MeetingMatch.Candidate(start: $0.start, end: $0.end, people: $0.isInfo ? 0 : $0.participants.count) }
        return MeetingMatch.pick(candidates, now: now).map { events[$0] }
    }

    /// Today's meetings that have not ended yet.
    var remainingToday: [Event] {
        events.filter { Calendar.current.isDateInToday($0.start) }
    }

    /// Meetings that have not ended yet, today and tomorrow, without all-day events.
    /// Exchange keeps a cancelled meeting with "Canceled:" in front of its title until it is
    /// removed from the calendar.
    static func isCancelledTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return ["canceled:", "cancelled:", "abgesagt:", "abgesagt -"].contains { lower.hasPrefix($0) }
    }

    private var loggedToday = ""
    private var sourcesRefreshed = Date.distantPast

    /// Every entry macOS has for today in the chosen calendars, also those the list leaves out
    /// (all-day, ended), written to the log when it changes; for finding a meeting that does
    /// not show.
    private func logToday(_ calendars: [EKCalendar], now: Date) {
        let day = Calendar.current.startOfDay(for: now)
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return }
        let lines = store.events(matching: store.predicateForEvents(withStart: day, end: next, calendars: calendars))
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let time = event.isAllDay ? "all day" : event.startDate.formatted(date: .omitted, time: .shortened)
                    + "–" + event.endDate.formatted(date: .omitted, time: .shortened)
                return "\(time) \(event.title ?? "?") [\(event.calendar.title)]\(event.endDate <= now ? " ended" : "")"
            }
        let text = lines.joined(separator: "; ")
        guard text != loggedToday else { return }
        loggedToday = text
        AppLog.info("calendar today: " + text)
    }

    /// The first Teams join link in a text, such as an invitation's body or notes.
    static func teamsLink(in text: String) -> URL? {
        guard let range = text.range(of: #"https://teams\.microsoft\.com/(l/meetup-join|meet)/[^\s<>"]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    /// Signs in to Microsoft 365: `show` gets the code to enter on Microsoft's page.
    func connectMicrosoft(show: @escaping @MainActor (GraphCalendar.DeviceCode) -> Void) async throws {
        let code = try await graph.startSignIn()
        await show(code)
        try await graph.finishSignIn(code)
        await MainActor.run {
            microsoftConnected = true
            authorized = true
            graphFetched = .distantPast
            refresh()
        }
    }

    func disconnectMicrosoft() {
        graph.signOut()
        graphEvents = nil
        microsoftConnected = false
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        refresh()
    }

    /// Fetches from Microsoft at most every 60 seconds; the list updates when the answer is in.
    private func refreshMicrosoft(now: Date) {
        guard microsoftConnected, !graphFetching, now.timeIntervalSince(graphFetched) > 60 else { return }
        graphFetching = true
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: start) ?? now
        Task { [graph] in
            let result = await Task.detached { try await graph.events(from: start, to: end) }.result
            await MainActor.run {
                self.graphFetching = false
                self.graphFetched = Date()
                switch result {
                case .success(let events):
                    if self.graphEvents == nil { AppLog.info("calendar: \(events.count) entries from Microsoft 365") }
                    self.graphEvents = events
                case .failure(let error):
                    AppLog.error("calendar: Microsoft 365 failed, using the macOS calendar: \(error.localizedDescription)")
                    self.graphEvents = nil
                    self.microsoftConnected = self.graph.isConnected
                }
                self.refresh(fetch: false)
            }
        }
    }

    func refresh() { refresh(fetch: true) }

    private func refresh(fetch: Bool) {
        let now = Date()
        if DemoMode.isOn {
            authorized = true
            source = "Demo calendar"
            events = Array(Self.upcoming(DemoCalendar.events(now: now), now: now))
            return
        }
        if fetch { refreshMicrosoft(now: now) }
        if microsoftConnected, let graphEvents {
            authorized = true
            source = "Microsoft 365"
            events = Array(Self.upcoming(graphEvents, now: now))
            return
        }
        source = "macOS Calendar"
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess || microsoftConnected
        refreshMac(now: now)
    }

    /// Not ended, not cancelled, each meeting once (the same one can sit in two calendars),
    /// in order of start.
    private static func upcoming(_ events: [Event], now: Date) -> ArraySlice<Event> {
        var seen = Set<String>()
        return events
            .filter { $0.end > now && !isCancelledTitle($0.title) }
            .sorted { $0.start < $1.start }
            .filter { seen.insert($0.title + "\u{1}" + String($0.start.timeIntervalSince1970)).inserted }
            .prefix(60)
    }

    private func refreshMac(now: Date) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return }
        let all = store.calendars(for: .event)
        let known = all.map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "", color: $0.cgColor) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        if known != calendars {
            calendars = known
            AppLog.info("calendars: " + Dictionary(grouping: known, by: \.account).map { "\($0.key) (\($0.value.count))" }.sorted().joined(separator: ", "))
        }
        let skip = Set(excluded())
        let chosen = all.filter { !skip.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else {
            events = []
            return
        }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: chosen)
        if now.timeIntervalSince(sourcesRefreshed) > 120 {
            sourcesRefreshed = now
            store.refreshSourcesIfNecessary()
        }
        logToday(chosen, now: now)
        let entries = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .map { event in
                let organizer = event.organizer.map(Self.participant)
                var people = (event.attendees ?? []).map(Self.participant)
                if let organizer, !people.contains(where: { $0.email == organizer.email }) { people.insert(organizer, at: 0) }
                let join = event.url.flatMap { $0.host?.hasSuffix("teams.microsoft.com") == true ? $0 : nil }
                    ?? Self.teamsLink(in: (event.notes ?? "") + " " + (event.location ?? ""))
                return Event(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled meeting",
                             start: event.startDate, end: event.endDate, organizer: organizer, participants: people,
                             joinURL: join, isInfo: event.availability == .free)
            }
        events = Array(Self.upcoming(entries, now: now))
    }

    private static func participant(_ person: EKParticipant) -> MeetingParticipant {
        let email = person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").removingPercentEncoding ?? ""
        return MeetingParticipant(name: person.name ?? "", email: email)
    }

    func event(id: String) -> Event? { events.first { $0.id == id } }
}
