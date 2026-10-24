import AppKit
import Combine
import DictationCore
import Foundation
import SwiftUI

/// Opens the briefing card shortly before a calendar meeting with other people: the earlier
/// meetings with them or their customer from the vault, their open action items, and the open
/// awork tasks of the customer. Each meeting is briefed once.
@MainActor
final class BriefingController {
    let card = BriefingCard()
    private let calendar: CalendarService
    private let notetaker: NotetakerController
    private let settings: () -> DictationSettings
    private let anchor: () -> (centerX: CGFloat, bottom: CGFloat)
    private var timer: Timer?
    private var briefed = Set(UserDefaults.standard.stringArray(forKey: briefedKey) ?? [])
    private var reminded = Set(UserDefaults.standard.stringArray(forKey: remindedKey) ?? [])
    private static let briefedKey = "briefedMeetings"
    private static let remindedKey = "remindedMeetings"

    /// Adds a meeting to the shown ones and stores them, the newest 200.
    private func remember(_ id: String, in set: inout Set<String>, key: String) {
        set.insert(id)
        var stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        stored.append(id)
        UserDefaults.standard.set(Array(stored.suffix(200)), forKey: key)
    }
    /// A meeting with other people starts within the briefing minutes; called once per meeting,
    /// whether or not a recording runs.
    var onUpcoming: ((String, Date) -> Void)?
    private var current: (event: CalendarService.Event, briefing: Briefing)?
    private var notes: (loaded: Date, list: [VaultMeetingNote])?
    private var recording: AnyCancellable?

    init(calendar: CalendarService, notetaker: NotetakerController, settings: @escaping () -> DictationSettings,
         anchor: @escaping () -> (centerX: CGFloat, bottom: CGFloat)) {
        self.calendar = calendar
        self.notetaker = notetaker
        self.settings = settings
        self.anchor = anchor
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // A note that starts for the meeting makes the briefing go.
        recording = notetaker.$isRecording.sink { [weak self] recording in
            if recording { MainActor.assumeIsolated { self?.close() } }
        }
        check()
    }

    private func check() {
        let minutes = settings().briefingMinutes
        guard minutes > 0, calendar.authorized else { return }
        calendar.refresh()
        let now = Date()
        // One reminder per meeting, at the set minutes before it: only while it is between that
        // and one minute less away (the check runs every 30 s), so a start of the app later on
        // does not remind again. Shown meetings are kept across restarts as well.
        let due = calendar.events.filter { event in
            event.participants.count >= 2
                && event.start > now.addingTimeInterval(Double(minutes - 1) * 60)
                && event.start <= now.addingTimeInterval(Double(minutes) * 60 + 20)
        }
        if let event = due.first(where: { !reminded.contains($0.id) }) {
            remember(event.id, in: &reminded, key: Self.remindedKey)
            onUpcoming?(event.title, event.start)
        }
        if let current, now > current.event.start.addingTimeInterval(15 * 60) { close() }
        guard !card.isOpen, !notetaker.isRecording, let event = due.first(where: { !briefed.contains($0.id) }) else { return }
        remember(event.id, in: &briefed, key: Self.briefedKey)
        show(event)
    }

    /// Shows the briefing for the next meeting whose title contains `part`.
    func show(titled part: String?) {
        calendar.refresh()
        guard let part, !part.isEmpty else { return show() }
        show(calendar.events.first { $0.title.localizedCaseInsensitiveContains(part) })
    }

    /// Shows the briefing for `event`, or for the next meeting with other people today when nil.
    func show(_ event: CalendarService.Event? = nil) {
        calendar.refresh()
        guard let event = event ?? calendar.events.first(where: { $0.participants.count >= 2 }) ?? calendar.events.first else {
            AppLog.info("briefing: no upcoming meeting")
            return
        }
        let settings = settings()
        let vault = URL(fileURLWithPath: NSString(string: settings.meetingVault).expandingTildeInPath)
        let map = CustomerRouting.loadMap(from: CustomerRouting.mapFile)
        let cached = notes.flatMap { Date().timeIntervalSince($0.loaded) < 10 * 60 ? $0.list : nil }
        Task {
            let list = await Task.detached { cached ?? VaultMeetingNote.scan(vault: vault, since: Date().addingTimeInterval(-365 * 86_400)) }.value
            self.notes = (Date(), list)
            let briefing = BriefingBuilder.build(title: event.title, start: event.start, participants: event.participants,
                                                 ownName: NotetakerController.ownName, customerMap: map, notes: list, vault: vault)
            self.current = (event, briefing)
            let loadsTasks = briefing.customer != nil
            self.display(briefing, loadingTasks: loadsTasks)
            AppLog.info("briefing shown: \(event.participants.count) participants, \(list.count) vault meetings, \(briefing.previous.count) earlier ones, customer \(briefing.customer == nil ? "none" : "known")")
            guard let customer = briefing.customer else { return }
            let tasks = await AssistantController.first(within: 12) { await Self.openTasks(customer: customer) } ?? []
            guard var latest = self.current?.briefing, latest.title == briefing.title, self.card.isOpen else { return }
            latest.openTasks = tasks
            self.current?.briefing = latest
            self.display(latest, loadingTasks: false)
        }
    }

    private func display(_ briefing: Briefing, loadingTasks: Bool) {
        let event = current?.event
        let view = BriefingCardView(briefing: briefing, loadingTasks: loadingTasks, startNote: { [weak self] in
            guard let self, let event else { return }
            self.close()
            self.notetaker.start(event: event)
        }, openNote: { [weak self] path in
            self?.open(note: path)
        }, close: { [weak self] in
            self?.close()
        })
        card.show(AnyView(view), at: anchor())
    }

    func close() {
        card.close()
        current = nil
    }

    private func open(note: String) {
        let vault = URL(fileURLWithPath: NSString(string: settings().meetingVault).expandingTildeInPath).lastPathComponent
        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [URLQueryItem(name: "vault", value: vault), URLQueryItem(name: "file", value: note)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    /// Open top-level tasks of the awork projects named after the customer, at most six.
    nonisolated static func openTasks(customer: String) async -> [String] {
        guard await AworkClient.shared.isLoggedIn, let projects = try? await AworkClient.shared.projects() else { return [] }
        let key = customer.lowercased()
        let matching = projects.filter { $0.name.lowercased().contains(key) || $0.company.lowercased().contains(key) }.prefix(2)
        var names: [String] = []
        for project in matching {
            let tasks = (try? await AworkClient.shared.parentCandidates(project: project.id)) ?? []
            names += tasks.map { matching.count > 1 ? "\($0.name) (\(project.name))" : $0.name }
        }
        return Array(names.prefix(6))
    }
}
