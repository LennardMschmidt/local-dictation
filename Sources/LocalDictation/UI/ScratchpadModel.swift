import DictationCore
import Foundation

/// The scratchpad notes, shared by the Scratchpad page and the floating scratchpad window, so
/// both always show the same notes. Changes are written to disk shortly after typing stops.
final class ScratchpadModel: ObservableObject {
    @Published private(set) var notes: [ScratchNote] = []
    private let store: ScratchpadStore
    private var saveWork: DispatchWorkItem?

    init(store: ScratchpadStore = ScratchpadStore(url: AppPaths.scratchpadFile)) {
        self.store = store
        notes = store.load()
    }

    /// Pinned notes first, then the most recently changed.
    var sorted: [ScratchNote] {
        notes.sorted { ($0.pinned ? 1 : 0, $0.updated) > ($1.pinned ? 1 : 0, $1.updated) }
    }

    func note(_ id: UUID) -> ScratchNote? { notes.first { $0.id == id } }

    @discardableResult
    func newNote() -> UUID {
        let note = ScratchNote()
        notes.insert(note, at: 0)
        save()
        return note.id
    }

    func setText(_ text: String, of id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updated = Date()
        save()
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].pinned.toggle()
        save()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    /// Notes left empty are removed when their window closes, so a quick open and close does
    /// not leave blank notes behind.
    func removeIfEmpty(_ id: UUID) {
        guard let note = note(id), note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        delete(id)
    }

    func matching(_ query: String) -> [ScratchNote] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? sorted : sorted.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    private func save() {
        saveWork?.cancel()
        let notes = self.notes
        let store = self.store
        let work = DispatchWorkItem { try? store.save(notes) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
