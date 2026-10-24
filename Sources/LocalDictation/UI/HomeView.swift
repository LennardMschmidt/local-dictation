import AppKit
import DictationCore
import SwiftUI

/// Greeting, the styles banner, statistics and the history of dictations grouped by day.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var searching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                Theme.headline("Welcome back, \(model.firstName)")

                HStack(alignment: .top, spacing: 18) {
                    StylesBanner { model.section = .style }
                    stats.frame(width: 229)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Theme.sectionLabel(days.first.map { Self.title(for: $0.day) } ?? "History")
                        Spacer()
                        if searching {
                            TextField("Search your dictations", text: $query)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 184)
                        }
                        Button {
                            searching.toggle()
                            if !searching { query = "" }
                        } label: {
                            Image(systemName: searching ? "xmark" : "magnifyingglass")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Search")
                    }

                    if days.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                            if index > 0 {
                                Theme.sectionLabel(Self.title(for: day.day)).padding(.top, 8)
                            }
                            Card {
                                ForEach(Array(day.entries.enumerated()), id: \.offset) { row, entry in
                                    if row > 0 { Divider().overlay(Theme.border) }
                                    HistoryRow(entry: entry)
                                }
                            }
                        }
                    }
                }
            }
            .pageLayout()
        }
    }

    private var days: [HistoryDay] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let entries = trimmed.isEmpty
            ? model.history
            : model.history.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
        return HistoryDay.group(entries)
    }

    private var stats: some View {
        let stats = model.stats
        return VStack(alignment: .leading, spacing: 14) {
            StatLine(value: Self.compact(stats.totalWords), label: "total words")
            StatLine(value: "\(stats.wordsPerMinute)", label: "wpm")
            StatLine(value: "\(stats.dayStreak)", label: stats.dayStreak == 1 ? "day streak" : "days streak")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
    }

    private var emptyState: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 23)).foregroundStyle(Theme.secondary)
                Text(query.isEmpty ? "Hold fn and speak. Your dictations show up here." : "No dictation matches \"\(query)\".")
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(37)
        }
    }

    static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func compact(_ value: Int) -> String {
        value >= 10_000 ? String(format: "%.1fK", Double(value) / 1000) : "\(value)"
    }
}

/// The dark banner that leads to the styles, like Wispr Flow's "Make Flow sound like you".
private struct StylesBanner: View {
    let action: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(white: 0.03), Color(red: 0.16, green: 0.12, blue: 0.10),
                                              Color(red: 0.42, green: 0.30, blue: 0.20)],
                                     startPoint: .leading, endPoint: .trailing))
            HStack {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 91, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(0.12))
                    .padding(.trailing, 31)
            }
            VStack(alignment: .leading, spacing: 8) {
                (Text("Make dictation sound like ").font(.system(size: 23, design: .serif))
                    + Text("you").font(.system(size: 23, design: .serif)).italic())
                    .foregroundStyle(.white)
                Text("Set up different writing styles for different apps.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                Button(action: action) {
                    Text("Start now")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 17)
                        .frame(height: 31)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.95)))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
            .padding(.horizontal, 34)
        }
        .frame(height: 175)
    }
}

private struct StatLine: View {
    let value: String
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(.system(size: 26, weight: .regular, design: .serif)).monospacedDigit()
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.text.opacity(0.85))
        }
    }
}

/// One dictation: time, app, text, and a copy button on hover.
struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
                if let app = AppNames.name(for: entry.bundleId) {
                    Text(app).font(.system(size: 13)).foregroundStyle(Theme.secondary.opacity(0.8)).lineLimit(1)
                }
            }
            .frame(width: 110, alignment: .leading)

            Text(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(entry.text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy")
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .background(hovering ? Theme.cardHover.opacity(0.5) : .clear)
        .onHover { hovering = $0 }
    }
}
