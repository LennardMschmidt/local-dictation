import DictationCore
import SwiftUI

/// Vocabulary terms and replacement rules in one list, like Wispr Flow's dictionary, sorted
/// into groups such as colleagues, customers and work terms. A tab per group filters the list.
struct DictionaryView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var searching = false
    @State private var editor: DictionaryEditor.Target?
    /// The selected tab; nil is "All".
    @State private var group: String?
    @State private var groupEditor: GroupEditor.Target?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Theme.headline("Dictionary")
                    Spacer()
                    if searching {
                        TextField("Search your vocabulary", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    Button {
                        searching.toggle()
                        if !searching { query = "" }
                    } label: {
                        Image(systemName: searching ? "xmark" : "magnifyingglass")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Search vocabulary")
                    Button { editor = .new } label: {
                        Text("Add new")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.panel)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.text))
                    }
                    .buttonStyle(.plain)
                }

                if !model.settings.dictionarySuggestions.isEmpty { suggestions }

                tabs

                if entries.isEmpty {
                    Text(!query.isEmpty ? "No words found matching your search"
                         : group != nil ? "No words in this group yet. Add one, or move words here with a right click."
                         : "Add names, product terms and words recognition keeps getting wrong.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
                            if index > 0 { Divider().overlay(Theme.border) }
                            DictionaryRow(entry: entry, starred: model.settings.starredWords.contains(entry.starKey),
                                          group: group == nil ? model.settings.wordGroups[entry.starKey] : nil,
                                          groups: model.settings.dictionaryGroups,
                                          onEdit: { editor = .edit(entry) },
                                          onDelete: { delete(entry) },
                                          onStar: { toggleStar(entry) },
                                          onGroup: { setGroup($0, for: entry) })
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
                }
            }
            .pageLayout()
        }
        .sheet(item: $editor) { target in
            DictionaryEditor(target: target, groups: model.settings.dictionaryGroups,
                             group: groupOf(target) ?? group) { result, chosen in
                if let result {
                    save(result, replacing: target)
                    setGroup(chosen, for: result)
                }
                editor = nil
            }
        }
        .sheet(item: $groupEditor) { target in
            GroupEditor(target: target, existing: model.settings.dictionaryGroups) { name in
                if let name { saveGroup(name, replacing: target) }
                groupEditor = nil
            }
        }
    }

    /// Words the user corrected after dictations, offered as replacements.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggestions from your corrections").font(.system(size: 15, weight: .medium))
            Text("You changed these words after dictating. Add them, and the dictation writes them your way next time.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            VStack(spacing: 0) {
                ForEach(Array(model.settings.dictionarySuggestions.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().overlay(Theme.border) }
                    HStack(spacing: 12) {
                        Text("\(item.from) → \(item.to)").font(.system(size: 15))
                        Spacer()
                        Button("Ignore") {
                            model.settings.dictionarySuggestions.removeAll { $0 == item }
                            model.settings.dismissedSuggestions.append("\(item.from)→\(item.to)")
                        }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        Button {
                            model.settings.dictionarySuggestions.removeAll { $0 == item }
                            if !model.settings.replacements.contains(item) { model.settings.replacements.append(item) }
                        } label: {
                            Text("Add").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.panel)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.text))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).frame(height: 48)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 26) {
                tab(nil, title: "All", count: model.settings.vocabulary.count + model.settings.replacements.count)
                ForEach(model.settings.dictionaryGroups, id: \.self) { name in
                    tab(name, title: name, count: allEntries.filter { model.settings.wordGroups[$0.starKey] == name }.count)
                        .contextMenu {
                            Button("Rename …") { groupEditor = .rename(name) }
                            Button("Delete group", role: .destructive) { deleteGroup(name) }
                        }
                }
                Button { groupEditor = .new } label: {
                    Image(systemName: "plus").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New group")
                .padding(.bottom, 9)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func tab(_ value: String?, title: String, count: Int) -> some View {
        Button { group = value } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text("\(count)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(group == value ? Theme.text : Theme.secondary)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(group == value ? Theme.text : .clear).frame(height: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func groupOf(_ target: DictionaryEditor.Target) -> String? {
        guard case .edit(let entry) = target else { return nil }
        return model.settings.wordGroups[entry.starKey]
    }

    private func setGroup(_ name: String?, for entry: DictionaryEntry) {
        model.settings.wordGroups[entry.starKey] = name
    }

    private func saveGroup(_ name: String, replacing target: GroupEditor.Target) {
        switch target {
        case .new:
            model.settings.dictionaryGroups.append(name)
        case .rename(let old):
            if let index = model.settings.dictionaryGroups.firstIndex(of: old) { model.settings.dictionaryGroups[index] = name }
            for (key, value) in model.settings.wordGroups where value == old { model.settings.wordGroups[key] = name }
            if group == old { group = name }
        }
    }

    /// Removes the group; its words stay in the dictionary without a group.
    private func deleteGroup(_ name: String) {
        model.settings.dictionaryGroups.removeAll { $0 == name }
        model.settings.wordGroups = model.settings.wordGroups.filter { $0.value != name }
        if group == name { group = nil }
    }

    /// Newest first: words, then replacements.
    private var allEntries: [DictionaryEntry] {
        model.settings.vocabulary.reversed().map(DictionaryEntry.word)
            + model.settings.replacements.reversed().filter { !$0.from.isEmpty || !$0.to.isEmpty }.map(DictionaryEntry.replacement)
    }

    /// The entries of the selected group, filtered by the search.
    private var entries: [DictionaryEntry] {
        var result = allEntries
        if let group { result = result.filter { model.settings.wordGroups[$0.starKey] == group } }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return result }
        return result.filter { $0.label.localizedCaseInsensitiveContains(trimmed) }
    }

    private func delete(_ entry: DictionaryEntry) {
        switch entry {
        case .word(let term): model.settings.vocabulary.removeAll { $0 == term }
        case .replacement(let rule): model.settings.replacements.removeAll { $0 == rule }
        }
        model.settings.starredWords.removeAll { $0 == entry.starKey }
        if !allEntries.contains(where: { $0.starKey == entry.starKey }) { model.settings.wordGroups[entry.starKey] = nil }
    }

    private func toggleStar(_ entry: DictionaryEntry) {
        if model.settings.starredWords.contains(entry.starKey) {
            model.settings.starredWords.removeAll { $0 == entry.starKey }
        } else {
            model.settings.starredWords.append(entry.starKey)
        }
    }

    private func save(_ entry: DictionaryEntry, replacing target: DictionaryEditor.Target) {
        var starred = false
        if case .edit(let old) = target {
            starred = model.settings.starredWords.contains(old.starKey)
            delete(old)
        }
        switch entry {
        case .word(let term):
            if !model.settings.vocabulary.contains(term) { model.settings.vocabulary.append(term) }
        case .replacement(let rule):
            model.settings.replacements.removeAll { $0.from.caseInsensitiveCompare(rule.from) == .orderedSame }
            model.settings.replacements.append(rule)
        }
        if starred { model.settings.starredWords.append(entry.starKey) }
    }
}

/// One dictionary entry: a vocabulary term or a replacement rule.
enum DictionaryEntry: Hashable {
    case word(String)
    case replacement(Replacement)

    var label: String {
        switch self {
        case .word(let term): return term
        case .replacement(let rule): return "\(rule.from) → \(rule.to)"
        }
    }

    /// The text a star is stored under: the term, or the correct spelling of a replacement.
    var starKey: String {
        switch self {
        case .word(let term): return term
        case .replacement(let rule): return rule.to
        }
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let starred: Bool
    /// Shown as a tag in the "All" tab.
    let group: String?
    let groups: [String]
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onStar: () -> Void
    let onGroup: (String?) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 18) {
            Text(entry.label)
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .textSelection(.enabled)
            if let group {
                Text(group)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(Theme.card))
            }
            Spacer()
            if hovering {
                RowIcon(symbol: "pencil", help: "Edit", action: onEdit)
                RowIcon(symbol: "trash", help: "Delete", action: onDelete)
            }
            if hovering || starred {
                RowIcon(symbol: starred ? "star.fill" : "star", help: starred ? "Unstar" : "Star", action: onStar)
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .contentShape(Rectangle())
        .background(hovering ? Theme.card : .clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Menu("Group") {
                ForEach(groups, id: \.self) { name in
                    Button { onGroup(name) } label: {
                        if name == group { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
                Divider()
                Button("No group") { onGroup(nil) }
            }
            Button("Edit …", action: onEdit)
            Button(starred ? "Unstar" : "Star", action: onStar)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct RowIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Wispr Flow's "Add to vocabulary" dialog: one word, or with "Correct a misspelling" a rule
/// that replaces a wrong spelling with the right one.
struct DictionaryEditor: View {
    enum Target: Identifiable {
        case new
        case edit(DictionaryEntry)

        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let entry): return entry.label
            }
        }
    }

    let target: Target
    let groups: [String]
    let done: (DictionaryEntry?, String?) -> Void
    @State private var correctsMisspelling = false
    @State private var word = ""
    @State private var misspelling = ""
    @State private var group: String?

    init(target: Target, groups: [String], group: String?, done: @escaping (DictionaryEntry?, String?) -> Void) {
        self.target = target
        self.groups = groups
        self.done = done
        _group = State(initialValue: group)
        if case .edit(let entry) = target {
            switch entry {
            case .word(let term):
                _word = State(initialValue: term)
            case .replacement(let rule):
                _correctsMisspelling = State(initialValue: true)
                _misspelling = State(initialValue: rule.from)
                _word = State(initialValue: rule.to)
            }
        }
    }

    private var title: String {
        guard case .edit = target else { return "Add to vocabulary" }
        return correctsMisspelling ? "Edit replacement" : "Edit word"
    }

    private var result: DictionaryEntry? {
        let to = word.trimmingCharacters(in: .whitespaces)
        let from = misspelling.trimmingCharacters(in: .whitespaces)
        guard !to.isEmpty else { return nil }
        if correctsMisspelling {
            return from.isEmpty ? nil : .replacement(Replacement(from: from, to: to))
        }
        return .word(to)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 20, weight: .medium))
            HStack(spacing: 8) {
                Toggle("Correct a misspelling", isOn: $correctsMisspelling)
                    .toggleStyle(.switch)
                    .tint(Theme.text)
                    .font(.system(size: 13))
                InfoButton("When this is on, your word becomes a correction rule: the wrong spelling is replaced with yours every time you dictate it.", size: 13)
            }
            if correctsMisspelling {
                HStack(spacing: 10) {
                    field("Misspelling", text: $misspelling)
                    Image(systemName: "arrow.right").foregroundStyle(Theme.secondary)
                    field("Correct spelling", text: $word)
                }
            } else {
                field("Add a new word", text: $word)
            }
            if !groups.isEmpty {
                HStack(spacing: 10) {
                    Text("Group").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    SelectBox(options: [(value: String?.none, title: "No group", icon: nil)]
                                  + groups.map { (value: String?.some($0), title: $0, icon: nil) },
                              selection: $group, width: 220, height: 32, fontSize: 13)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil, nil) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    done(result, group)
                } label: {
                    Text({ if case .edit = target { return "Save changes" } else { return "Add word" } }())
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.panel)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.text))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(result == nil)
                .opacity(result == nil ? 0.4 : 1)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
}

/// Names a new dictionary group or renames one.
struct GroupEditor: View {
    enum Target: Identifiable {
        case new
        case rename(String)
        var id: String {
            switch self {
            case .new: return "new"
            case .rename(let name): return "rename " + name
            }
        }
    }

    let target: Target
    let existing: [String]
    let done: (String?) -> Void
    @State private var name: String

    init(target: Target, existing: [String], done: @escaping (String?) -> Void) {
        self.target = target
        self.existing = existing
        self.done = done
        if case .rename(let old) = target { _name = State(initialValue: old) } else { _name = State(initialValue: "") }
    }

    private var valid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if case .rename(let old) = target, trimmed == old { return false }
        return !trimmed.isEmpty && !existing.contains(trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text({ if case .new = target { return "New group" } else { return "Rename group" } }())
                .font(.system(size: 20, weight: .medium))
            TextField("Colleagues, customers, products …", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button { done(name.trimmingCharacters(in: .whitespaces)) } label: {
                    Text("Save")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.panel)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.text))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
                .opacity(valid ? 1 : 0.4)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

/// Snippets, laid out like Wispr Flow's: a spoken trigger drops in stored text. The text keeps
/// Markdown formatting, which apps that take formatted text receive formatted.
struct SnippetsView: View {
    @ObservedObject var model: AppModel
    @State private var editing: SnippetEditor.Target?
    @State private var query = ""
    @State private var searching = false
    @State private var descending = false
    @State private var importMessage: String?
    @AppStorage("snippetsBannerHidden") private var bannerHidden = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Theme.headline("Snippets")
                    Spacer()
                    blackButton("Import") { importSnippets() }
                    blackButton("Add new") { editing = .new }
                }
                HStack(alignment: .bottom, spacing: 18) {
                    Text("All")
                        .font(.system(size: 16, weight: .medium))
                        .padding(.bottom, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.text).frame(height: 2) }
                    Spacer()
                    if searching {
                        TextField("Search snippets", text: $query).textFieldStyle(.roundedBorder).frame(width: 200).padding(.bottom, 8)
                    }
                    iconButton(searching ? "xmark" : "magnifyingglass", help: "Search") {
                        searching.toggle()
                        if !searching { query = "" }
                    }
                    iconButton("arrow.up.arrow.down", help: descending ? "Sorted Z to A" : "Sorted A to Z") { descending.toggle() }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

                if !bannerHidden { banner }
                if let importMessage {
                    Text(importMessage).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }

                if rows.isEmpty {
                    Text(query.isEmpty ? "No snippets yet." : "No snippet matches \"\(query)\".")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Divider().overlay(Theme.border) }
                            SnippetRow(snippet: row.snippet, edit: { editing = .edit(row.index) },
                                       delete: { model.settings.snippets.remove(at: row.index) })
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
                }
            }
            .pageLayout()
        }
        .sheet(item: $editing) { target in
            SnippetEditor(target: target, snippets: $model.settings.snippets) { editing = nil }
        }
    }

    private var rows: [(index: Int, snippet: Snippet)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let all = model.settings.snippets.enumerated().map { (index: $0.offset, snippet: $0.element) }
            .filter { trimmed.isEmpty || $0.snippet.trigger.localizedCaseInsensitiveContains(trimmed)
                || $0.snippet.text.localizedCaseInsensitiveContains(trimmed) }
        let sorted = all.sorted { $0.snippet.trigger.localizedCaseInsensitiveCompare($1.snippet.trigger) == .orderedAscending }
        return descending ? sorted.reversed() : sorted
    }

    private var banner: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.33), Color(red: 0.24, green: 0.18, blue: 0.13),
                                              Color(red: 0.12, green: 0.10, blue: 0.10)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 16) {
                (Text("The stuff ") + Text("you").italic() + Text(" shouldn’t have to re-type."))
                    .font(.system(size: 34, design: .serif)).foregroundStyle(.white)
                Text("Save text you type often, like an email, an intro or a prompt, then say a word to drop it in instantly.")
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    example("“meine Signatur”", "Viele Grüße, Jonas Weber …")
                    example("“rewrite prompt”", "Rewrite this to be more concise …")
                    example("“intro email”", "Hallo, ich melde mich wegen …")
                }
                Button { editing = .new } label: {
                    Text("Add new snippet").font(.system(size: 15, weight: .medium)).foregroundStyle(.black)
                        .padding(.horizontal, 18).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.95)))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(36)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { bannerHidden = true } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .padding(16)
        }
    }

    private func example(_ trigger: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(trigger).italic().padding(.horizontal, 14).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.35)))
            Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            Text(text).padding(.horizontal, 14).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.35)))
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(Color(white: 0.12))
    }

    private func blackButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.panel)
                .padding(.horizontal, 18).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.text))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Theme.secondary).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(help)
        .padding(.bottom, 8)
    }

    /// Reads snippets from a JSON list (`[{"trigger": …, "text": …}]`) or a CSV file with the
    /// trigger in the first column and the text in the second. Triggers that exist are updated.
    private func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        var found: [Snippet] = []
        if let list = try? JSONDecoder().decode([Snippet].self, from: data) {
            found = list
        } else {
            found = Self.csv(String(decoding: data, as: UTF8.self))
        }
        var added = 0
        for snippet in found where !snippet.trigger.trimmingCharacters(in: .whitespaces).isEmpty {
            if let index = model.settings.snippets.firstIndex(where: { $0.trigger.lowercased() == snippet.trigger.lowercased() }) {
                model.settings.snippets[index] = snippet
            } else {
                model.settings.snippets.append(snippet)
            }
            added += 1
        }
        importMessage = added == 0 ? "No snippets found in \(url.lastPathComponent)." : "\(added) snippets imported from \(url.lastPathComponent)."
    }

    /// Two columns, separated by a comma or semicolon, values in double quotes when they hold one.
    static func csv(_ text: String) -> [Snippet] {
        var snippets: [Snippet] = []
        var field = ""
        var fields: [String] = []
        var quoted = false
        let characters = Array(text)
        var index = 0
        func endRow() {
            fields.append(field)
            if fields.count >= 2, fields[0].lowercased() != "trigger" {
                snippets.append(Snippet(trigger: fields[0].trimmingCharacters(in: .whitespaces), text: fields[1]))
            }
            fields = []
            field = ""
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "," || character == ";" {
                fields.append(field)
                field = ""
            } else if character == "\n" || character == "\r\n" {
                endRow()
            } else if character != "\r" {
                field.append(character)
            }
            index += 1
        }
        if !field.isEmpty || !fields.isEmpty { endRow() }
        return snippets
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            (Text(snippet.trigger) + Text(" → ") + Text(RichSnippet.plain(snippet.text).replacingOccurrences(of: "\n", with: " ")))
                .font(.system(size: 15))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if hovering {
                Button(action: edit) { Image(systemName: "pencil").font(.system(size: 16)) }.buttonStyle(.plain).help("Edit")
                Button(action: delete) { Image(systemName: "trash").font(.system(size: 16)) }.buttonStyle(.plain).help("Delete")
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
        .contentShape(Rectangle())
        .background(hovering ? Theme.card : .clear)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: edit)
    }
}

/// Wispr Flow's "Add snippet" dialog: the trigger, the text with a small formatting bar, a counter.
struct SnippetEditor: View {
    enum Target: Identifiable {
        case new
        case edit(Int)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let index): return "edit-\(index)"
            }
        }
    }

    static let limit = 4_000

    let target: Target
    @Binding var snippets: [Snippet]
    let done: () -> Void
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "Add snippet" : "Edit snippet").font(.system(size: 22, weight: .semibold))
            TextField("Snippet", text: $trigger)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 18) {
                    format("bold", "Bold") { wrap("**") }
                    format("italic", "Italic") { wrap("*") }
                    Divider().frame(height: 18)
                    format("list.bullet", "Bulleted list") { prefixLines("- ") }
                    format("list.number", "Numbered list") { numberLines() }
                    Divider().frame(height: 18)
                    format("link", "Link") { text += (text.isEmpty || text.hasSuffix("\n") ? "" : " ") + "[Text](https://)" }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                TextEditor(text: $text)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 220)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.text.opacity(0.7), lineWidth: 1))
            HStack {
                Text("Formatting is kept where the app supports it, for example in Mail, Outlook and Teams.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Text("\(text.count)/\(Self.limit)").font(.system(size: 13)).foregroundStyle(text.count > Self.limit ? .red : Theme.secondary)
            }
            HStack(spacing: 14) {
                Spacer()
                Button(action: done) {
                    Text("Cancel").font(.system(size: 16, weight: .medium)).padding(.horizontal, 22).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.selection))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button(action: save) {
                    Text(isNew ? "Add snippet" : "Save snippet").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.panel)
                        .padding(.horizontal, 22).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.text))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.4)
            }
        }
        .padding(32)
        .frame(width: 640)
        .onAppear {
            if case .edit(let index) = target, snippets.indices.contains(index) {
                trigger = snippets[index].trigger
                text = snippets[index].text
            }
        }
    }

    private var isNew: Bool { if case .new = target { return true } else { return false } }

    private var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespaces).isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= Self.limit
    }

    private func save() {
        let snippet = Snippet(trigger: trigger.trimmingCharacters(in: .whitespaces), text: text)
        if case .edit(let index) = target, snippets.indices.contains(index) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        done()
    }

    private func format(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 16)) }.buttonStyle(.plain).help(help)
    }

    /// Marks the last line (or a placeholder) with `marker` on both sides.
    private func wrap(_ marker: String) {
        var lines = text.components(separatedBy: "\n")
        let last = lines.removeLast()
        lines.append(last.isEmpty ? "\(marker)Text\(marker)" : "\(marker)\(last)\(marker)")
        text = lines.joined(separator: "\n")
    }

    private func prefixLines(_ prefix: String) {
        guard !text.isEmpty else {
            text = prefix
            return
        }
        text = text.components(separatedBy: "\n").map { $0.hasPrefix(prefix) || $0.isEmpty ? $0 : prefix + $0 }.joined(separator: "\n")
    }

    private func numberLines() {
        guard !text.isEmpty else {
            text = "1. "
            return
        }
        var number = 0
        text = text.components(separatedBy: "\n").map { line in
            guard !line.isEmpty else { return line }
            number += 1
            return "\(number). " + line.replacingOccurrences(of: #"^\d+\.\s"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }
}

private struct TermChip: View {
    let term: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text(term)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.4)
            .help("Remove")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        .onHover { hovering = $0 }
    }
}

/// Lays out views in rows and wraps to the next row when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty && current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
