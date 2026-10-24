import DictationCore
import SwiftUI

/// Usage and voice statistics, computed from the local history. Sizes follow Wispr Flow's
/// Insights page; numbers count up, the gauge and the bars fill and the calendar fades in when
/// a tab opens.
struct InsightsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: Int
    /// A usage log in place of the stored one, for the snapshots.
    private let assistantLog: [AssistantUsage]?

    init(model: AppModel, tab: Int = 0, assistantLog: [AssistantUsage]? = nil) {
        self.model = model
        _tab = State(initialValue: tab)
        self.assistantLog = assistantLog
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Insights").font(.system(size: 22, weight: .medium))
                    .padding(.bottom, 24)

                HStack(spacing: 18) {
                    TabButton(title: "Your usage", selected: tab == 0) { tab = 0 }
                    TabButton(title: "Your voice", selected: tab == 1) { tab = 1 }
                    TabButton(title: "Notetaker", selected: tab == 2) { tab = 2 }
                    TabButton(title: "Assistant", selected: tab == 3) { tab = 3 }
                    Spacer()
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                .padding(.bottom, 34)

                switch tab {
                case 0: UsageTab(insights: model.insights)
                case 1: VoiceTab(insights: model.insights)
                case 2: NotetakerTab(meetings: model.notetaker?.meetings ?? [])
                default: AssistantTab(stats: AssistantStats(assistantLog ?? AssistantUsage.load()))
                }
            }
            .pageLayout()
        }
    }
}

/// Fills from 0 to 1 when a tab appears; everything that animates reads it.
private struct FillUp: ViewModifier {
    @Binding var progress: Double

    func body(content: Content) -> some View {
        content.onAppear {
            guard !Snapshots.isRendering else { progress = 1; return }
            progress = 0
            withAnimation(.easeOut(duration: 0.9).delay(0.05)) { progress = 1 }
        }
    }
}

/// A number that counts up when `value` animates.
private struct CountingNumber: View, Animatable {
    var value: Double
    var size: CGFloat = 26

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Int(value.rounded()).formatted())
            .font(.system(size: size, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.text)
    }
}

private struct TabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.text : Theme.secondary)
                .padding(.bottom, 9)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Theme.text : .clear).frame(height: 2)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct UsageTab: View {
    let insights: Insights
    @State private var progress = 0.0

    var body: some View {
        VStack(spacing: 18) {
            // Side by side when the window is wide enough, otherwise one below the other.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { speed.frame(width: 176); fixes.frame(width: 176); words.frame(minWidth: 300) }
                VStack(spacing: 18) { HStack(alignment: .top, spacing: 18) { speed; fixes }; words }
            }
            .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { usage.frame(minWidth: 340); streak.frame(minWidth: 340) }
                VStack(spacing: 18) { usage; streak }
            }
        }
        .modifier(FillUp(progress: $progress))
    }

    private var speed: some View {
        InsightCard {
            CountingNumber(value: Double(insights.wordsPerMinute) * progress)
            CardLabel("Words per minute", help: "Words you dictated per minute of speaking time.")
            SpeedGauge(factor: insights.typingFactor, progress: progress)
                .frame(width: 115, height: 64)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
        }
    }

    private var fixes: some View {
        InsightCard {
            CountingNumber(value: Double(insights.fixes) * progress)
            CardLabel("Fixes made by cleanup")
            Divider().overlay(Theme.border).padding(.vertical, 12)
            InfoLine(text: "\(insights.wordsCorrected.formatted()) words corrected",
                     help: "Words the cleanup removed or changed: fillers, self-corrections, recognition errors.")
            InfoLine(text: "\(insights.dictionaryFixes.formatted()) dictionary fixes",
                     help: "Dictionary words and replacements in your dictated text.")
        }
    }

    private var words: some View {
        InsightCard {
            CountingNumber(value: Double(insights.totalWords) * progress)
            CardLabel("Total words dictated")
            Divider().overlay(Theme.border).padding(.vertical, 12)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("This Mac", systemImage: "laptopcomputer").font(.system(size: 12)).fixedSize()
                    Text("\(insights.totalWords.formatted()) words").font(.system(size: 12)).fixedSize()
                }
                Spacer(minLength: 10)
                Text("Stays on this Mac")
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            }
        }
    }

    private var usage: some View {
        InsightCard {
            HStack(alignment: .firstTextBaseline) {
                Text("Desktop usage").font(.system(size: 22, weight: .medium)).fixedSize()
                Spacer()
                Theme.sectionLabel("Total apps used | \(insights.appsUsed)").fixedSize()
            }
            .padding(.bottom, 14)
            UsageBars(categories: insights.categories, progress: progress)
        }
    }

    private var streak: some View {
        InsightCard {
            HStack(alignment: .firstTextBaseline) {
                Text("\(insights.currentStreak) day streak").font(.system(size: 22, weight: .medium)).fixedSize()
                Spacer()
                Theme.sectionLabel("Longest streak | \(insights.longestStreak) days").fixedSize()
            }
            .padding(.bottom, 14)
            StreakCalendar(wordsPerDay: insights.wordsPerDay, progress: progress)
        }
    }
}

private struct VoiceTab: View {
    let insights: Insights
    @State private var progress = 0.0

    var body: some View {
        VStack(spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { average; fillers; languages }
                VStack(spacing: 18) { HStack(alignment: .top, spacing: 18) { average; fillers }; languages }
            }
            .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { yourWords.frame(minWidth: 300); hours.frame(minWidth: 300) }
                VStack(spacing: 18) { yourWords; hours }
            }
        }
        .modifier(FillUp(progress: $progress))
    }

    private var average: some View {
        InsightCard {
            CountingNumber(value: Double(insights.averageWords) * progress)
            CardLabel("Words per dictation")
            Text("On average, every time you hold fn.").font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.top, 8)
        }
    }

    private var fillers: some View {
        InsightCard {
            CountingNumber(value: Double(insights.fillersRemoved) * progress)
            CardLabel("Filler words removed")
            Text("Äh, ähm, um, uh and friends that never made it into your text.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var languages: some View {
        InsightCard {
            CardLabel("Languages")
            VStack(spacing: 8) {
                let total = max(1, insights.languages.reduce(0) { $0 + $1.dictations })
                ForEach(insights.languages, id: \.code) { language in
                    ShareBar(label: Self.languageName(language.code),
                             share: Double(language.dictations) / Double(total) * progress, color: Theme.teal)
                }
                if insights.languages.isEmpty { Text("No dictations yet").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            }
            .padding(.top, 10)
        }
    }

    private var yourWords: some View {
        InsightCard {
            Text("Your words").font(.system(size: 22, weight: .medium)).padding(.bottom, 12)
            FlowLayout(spacing: 6) {
                ForEach(insights.topWords, id: \.word) { item in
                    HStack(spacing: 6) {
                        Text(item.word)
                        Text("\(item.count)").foregroundStyle(Theme.secondary).monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.tealPale))
                    .opacity(progress)
                }
            }
            if insights.topWords.isEmpty { Text("No dictations yet").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
        }
    }

    private var hours: some View {
        InsightCard {
            Text("When you dictate").font(.system(size: 22, weight: .medium)).padding(.bottom, 12)
            HourChart(hours: insights.hours, progress: progress)
        }
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}

/// Meetings recorded with the Notetaker: how many, how long, the action items, the last weeks
/// and the people met most.
private struct NotetakerTab: View {
    let meetings: [Meeting]
    @State private var progress = 0.0

    private var done: [Meeting] { meetings.filter { $0.status == .done } }
    private var hours: Double { done.reduce(0) { $0 + $1.duration } / 3600 }

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                InsightCard {
                    CountingNumber(value: Double(done.count) * progress)
                    CardLabel("Meetings recorded")
                    Divider().overlay(Theme.border).padding(.vertical, 12)
                    Text("\(thisWeek.count) this week").font(.system(size: 12))
                }
                InsightCard {
                    Text(String(format: "%.1f", hours * progress)).font(.system(size: 26, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text)
                    CardLabel("Hours in meetings")
                    Divider().overlay(Theme.border).padding(.vertical, 12)
                    Text("\(done.isEmpty ? 0 : Int(hours * 60) / done.count) min on average").font(.system(size: 12))
                }
                InsightCard {
                    CountingNumber(value: Double(done.reduce(0) { $0 + $1.actionItems.count }) * progress)
                    CardLabel("Action items found")
                    Divider().overlay(Theme.border).padding(.vertical, 12)
                    Text("\(thisWeek.reduce(0) { $0 + $1.actionItems.count }) this week").font(.system(size: 12))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { weeks.frame(minWidth: 340); people.frame(minWidth: 340) }
                VStack(spacing: 18) { weeks; people }
            }
        }
        .modifier(FillUp(progress: $progress))
    }

    private var thisWeek: [Meeting] {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return done.filter { $0.date >= start }
    }

    /// The last eight weeks, this week first, by hours recorded.
    private var weeks: some View {
        let sections = MeetingGrouping.week.sections(done, date: \.date).prefix(8)
        let most = max(1, sections.map { $0.items.reduce(0) { $0 + $1.duration } }.max() ?? 1)
        return InsightCard {
            Text("Meetings per week").font(.system(size: 22, weight: .medium)).padding(.bottom, 14)
            if sections.isEmpty { Text("No meetings recorded yet.").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                let seconds = section.items.reduce(0) { $0 + $1.duration }
                CountBar(label: section.title.components(separatedBy: " · ").first ?? section.title,
                         share: seconds / most * progress, value: String(format: "%d · %.1f h", section.items.count, seconds / 3600),
                         color: UsageBars.color(rank: index))
            }
        }
    }

    /// The people in the most recorded meetings, from the calendar's invitations.
    private var people: some View {
        let own = NotetakerController.ownName.lowercased()
        var counts: [String: Int] = [:]
        for meeting in done {
            for name in Set(meeting.participants.map(\.name).filter { !$0.isEmpty && !$0.lowercased().hasPrefix(own) }) {
                counts[name, default: 0] += 1
            }
        }
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(6)
        let most = Double(top.first?.value ?? 1)
        return InsightCard {
            Text("Who you meet most").font(.system(size: 22, weight: .medium)).padding(.bottom, 14)
            if top.isEmpty { Text("Meetings started from the calendar list their participants here.").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            ForEach(Array(top.enumerated()), id: \.element.key) { index, entry in
                CountBar(label: entry.key, share: Double(entry.value) / most * progress,
                         value: "\(entry.value) \(entry.value == 1 ? "meeting" : "meetings")", color: UsageBars.color(rank: index))
            }
        }
    }
}

/// The assistant behind fn + option: requests, the MCP servers it asked and what it opened.
private struct AssistantTab: View {
    let stats: AssistantStats
    @State private var progress = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                InsightCard {
                    CountingNumber(value: Double(stats.requests) * progress)
                    CardLabel("Requests")
                    Divider().overlay(Theme.border).padding(.vertical, 12)
                    Text(String(format: "%.0f s on average", stats.averageSeconds)).font(.system(size: 12))
                }
                InsightCard {
                    CountingNumber(value: Double(stats.toolCalls) * progress)
                    CardLabel("MCP and web calls", help: "Tool calls Claude Code made to answer: MCP servers and web search.")
                    Divider().overlay(Theme.border).padding(.vertical, 12)
                    Text("\(stats.servers.count) \(stats.servers.count == 1 ? "server" : "servers") used").font(.system(size: 12))
                }
                InsightCard {
                    CountingNumber(value: Double(stats.quickOpens) * progress)
                    CardLabel("Quick opens")
                    Divider().overlay(Theme.border).padding(.vertical, 12)
                    Text(stats.opened.first.map { "Most: \($0.name)" } ?? "Apps and sites opened").font(.system(size: 12))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    list("MCP servers", stats.servers, unit: "call", empty: "No tool calls yet.")
                    list("Quick opens", stats.opened, unit: "time", empty: "Nothing opened yet.")
                    list("Request types", stats.kinds, unit: "", empty: "No requests yet.")
                }
                VStack(spacing: 18) {
                    list("MCP servers", stats.servers, unit: "call", empty: "No tool calls yet.")
                    list("Quick opens", stats.opened, unit: "time", empty: "Nothing opened yet.")
                    list("Request types", stats.kinds, unit: "", empty: "No requests yet.")
                }
            }
            Text(stats.since.map { "Counted since \($0.formatted(date: .abbreviated, time: .omitted)). Only on this Mac." }
                 ?? "Counting starts with the next request to the assistant (fn + option). Only on this Mac.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .modifier(FillUp(progress: $progress))
    }

    private func list(_ title: String, _ counts: [AssistantStats.Count], unit: String, empty: String) -> some View {
        let most = Double(counts.first?.count ?? 1)
        return InsightCard {
            Text(title).font(.system(size: 22, weight: .medium)).padding(.bottom, 14)
            if counts.isEmpty { Text(empty).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            ForEach(Array(counts.prefix(8).enumerated()), id: \.element.name) { index, entry in
                CountBar(label: entry.name, share: Double(entry.count) / most * progress,
                         value: unit.isEmpty ? "\(entry.count)" : "\(entry.count) \(unit)\(entry.count == 1 ? "" : "s")", color: UsageBars.color(rank: index))
            }
        }
    }
}

/// A name, a bar relative to the largest entry and the number behind it.
private struct CountBar: View {
    let label: String
    let share: Double
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).lineLimit(1).frame(width: 110, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: max(4, geometry.size.width * share))
            }
            .frame(height: 12)
            Text(value).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary).fixedSize()
        }
        .padding(.vertical, 3)
    }
}

private struct InsightCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(.horizontal, 13)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
}

private struct CardLabel: View {
    let text: String
    var help: String?

    init(_ text: String, help: String? = nil) {
        self.text = text
        self.help = help
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)
                .fixedSize()
            if let help {
                InfoButton(help, size: 10)
            }
        }
    }
}

private struct InfoLine: View {
    let text: String
    let help: String

    var body: some View {
        HStack {
            Text(text).font(.system(size: 12))
            Spacer(minLength: 6)
            InfoButton(help, size: 11)
        }
        .padding(.vertical, 4)
    }
}

/// Half-circle gauge: how many times faster than typing at 40 words per minute.
private struct SpeedGauge: View {
    let factor: Double
    var progress: Double = 1

    var body: some View {
        let target = min(1, factor / 5)
        ZStack {
            Arc(progress: 1).stroke(Theme.empty, style: StrokeStyle(lineWidth: 12, lineCap: .round))
            Arc(progress: target * progress).stroke(Theme.tealDark, style: StrokeStyle(lineWidth: 12, lineCap: .round))
            VStack(spacing: 0) {
                Text("vs. typing").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Text(String(format: "%.1f×", factor * progress)).font(.system(size: 15, weight: .medium)).monospacedDigit()
            }
            .offset(y: 14)
        }
    }

    private struct Arc: Shape {
        var progress: Double

        var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let radius = min(rect.width / 2, rect.height) - 6
            let center = CGPoint(x: rect.midX, y: rect.maxY - 2)
            path.addArc(center: center, radius: radius, startAngle: .degrees(180),
                        endAngle: .degrees(180 + 180 * progress), clockwise: false)
            return path
        }
    }
}

private struct UsageBars: View {
    let categories: [Insights.CategoryUsage]
    var progress: Double = 1

    var body: some View {
        let maxShare = max(0.01, categories.map(\.share).max() ?? 0)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(categories.enumerated()), id: \.element.category) { index, usage in
                HStack(spacing: 12) {
                    Image(systemName: Self.icon(usage.category))
                        .font(.system(size: 13))
                        .frame(width: 20)
                    GeometryReader { geometry in
                        let width = max(26, geometry.size.width * 0.52 * usage.share / maxShare) * progress
                        HStack(spacing: 10) {
                            Text("\(Int((usage.share * 100).rounded()))%")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: max(0, width), height: 20)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Self.color(rank: index)))
                                .clipped()
                            Text("\(usage.dictations) \(usage.category.title)".uppercased())
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.1)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .opacity(progress)
                        }
                    }
                    .frame(height: 20)
                }
            }
        }
    }

    static func color(rank: Int) -> Color {
        switch rank {
        case 0: return Theme.tealDark
        case 1, 2: return Theme.teal
        default: return Theme.tealLight
        }
    }

    static func icon(_ category: UsageCategory) -> String {
        switch category {
        case .aiPrompts: return "cpu"
        case .documents: return "doc.text"
        case .other: return "infinity"
        case .workMessages: return "text.bubble"
        case .emails: return "envelope"
        case .personalMessages: return "ellipsis.bubble"
        }
    }
}

private struct StreakCalendar: View {
    let wordsPerDay: [Date: Int]
    var progress: Double = 1
    @State private var pageOffset = 0
    @State private var weeks = 14

    private let calendar = Calendar.current

    /// Day cell, gap between cells and the width of the weekday labels, as in Wispr Flow's grid.
    static let cell: CGFloat = 13
    static let gap: CGFloat = 4
    static let labelWidth: CGFloat = 32

    var body: some View {
        // As many weeks as fit into the card.
        GeometryReader { geometry in
            grid.onAppear { fit(geometry.size.width) }
                .onChange(of: geometry.size.width) { _, width in fit(width) }
        }
        .frame(height: 16 + 7 * (Self.cell + Self.gap) + 40)
    }

    private func fit(_ width: CGFloat) {
        let fitting = max(6, min(26, Int((width - Self.labelWidth - 14) / (Self.cell + Self.gap))))
        if fitting != weeks { weeks = fitting }
    }

    private var grid: some View {
        let start = firstWeekStart
        let step = Self.cell + Self.gap
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Button { pageOffset += 1 } label: { Image(systemName: "chevron.left").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .frame(width: Self.labelWidth, alignment: .leading)
                ForEach(0..<weeks, id: \.self) { week in
                    Text(monthLabel(start: start, week: week))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize()
                        .frame(width: step, alignment: .leading)
                }
                Button { pageOffset = max(0, pageOffset - 1) } label: { Image(systemName: "chevron.right").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .disabled(pageOffset == 0)
                    .opacity(pageOffset == 0 ? 0.3 : 1)
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(Self.weekdays, id: \.self) { day in
                        Text(day).font(.system(size: 10)).foregroundStyle(Theme.secondary).frame(height: Self.cell)
                    }
                }
                .frame(width: Self.labelWidth, alignment: .leading)
                HStack(spacing: Self.gap) {
                    ForEach(0..<weeks, id: \.self) { week in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { weekday in
                                let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: start)!
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color(for: day))
                                    .frame(width: Self.cell, height: Self.cell)
                                    .opacity(min(1, max(0, progress * 1.6 - Double(week) / Double(weeks) * 0.6)))
                                    .help(tooltip(for: day))
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("More").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach([Theme.tealDark, Theme.teal, Theme.tealLight, Theme.tealPale], id: \.self) { color in
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: Self.cell, height: Self.cell)
                }
                Text("Less").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 10)
        }
    }

    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Sunday of the first column, so that the current week is the last column on page 0.
    private var firstWeekStart: Date {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) - 1
        let thisSunday = calendar.date(byAdding: .day, value: -weekday, to: today)!
        return calendar.date(byAdding: .day, value: -7 * (weeks - 1 + pageOffset * weeks), to: thisSunday)!
    }

    private func monthLabel(start: Date, week: Int) -> String {
        let first = calendar.date(byAdding: .day, value: week * 7, to: start)!
        let previous = calendar.date(byAdding: .day, value: -7, to: first)!
        let month = { (date: Date) in calendar.component(.month, from: date) }
        if week == 0 {
            // The first column names its month only when the next month label is not right beside it.
            let later = (1...2).map { calendar.date(byAdding: .day, value: $0 * 7, to: first)! }
            guard later.allSatisfy({ month($0) == month(first) }) else { return "" }
        } else if month(first) == month(previous) {
            return ""
        }
        return first.formatted(.dateTime.month(.abbreviated))
    }

    private func color(for day: Date) -> Color {
        if day > Date() { return Theme.empty.opacity(0.35) }
        let words = wordsPerDay[calendar.startOfDay(for: day)] ?? 0
        guard words > 0 else { return Theme.empty }
        let top = max(1, wordsPerDay.values.max() ?? 1)
        let ratio = Double(words) / Double(top)
        if ratio > 0.75 { return Theme.tealDark }
        if ratio > 0.4 { return Theme.teal }
        if ratio > 0.15 { return Theme.tealLight }
        return Theme.tealPale
    }

    private func tooltip(for day: Date) -> String {
        let words = wordsPerDay[calendar.startOfDay(for: day)] ?? 0
        return "\(day.formatted(date: .abbreviated, time: .omitted)): \(words) words"
    }
}

private struct ShareBar: View {
    let label: String
    let share: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).frame(width: 70, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.empty.opacity(0.5))
                    RoundedRectangle(cornerRadius: 3).fill(color).frame(width: geometry.size.width * share)
                }
            }
            .frame(height: 10)
            Text("\(Int((share * 100).rounded()))%").font(.system(size: 11)).monospacedDigit().frame(width: 36, alignment: .trailing)
        }
    }
}

private struct HourChart: View {
    let hours: [Int]
    var progress: Double = 1

    var body: some View {
        let top = max(1, hours.max() ?? 1)
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(hours[hour] == top && top > 0 ? Theme.tealDark : Theme.tealLight)
                        .frame(height: max(3, 90 * CGFloat(hours[hour]) / CGFloat(top) * progress))
                        .help("\(hour):00 – \(hours[hour]) dictations")
                }
            }
            .frame(height: 90, alignment: .bottom)
            HStack {
                Text("0:00"); Spacer(); Text("6:00"); Spacer(); Text("12:00"); Spacer(); Text("18:00"); Spacer(); Text("23:00")
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.secondary)
        }
    }
}
