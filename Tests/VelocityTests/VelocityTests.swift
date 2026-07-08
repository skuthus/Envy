import Testing
import Foundation
@testable import VelocityCore

@MainActor
private func makeTempStore() -> NoteStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("VelocityTests-\(UUID().uuidString)", isDirectory: true)
    return NoteStore(directory: dir)
}

@Test @MainActor func createNoteWritesFileAndAppearsInList() throws {
    let store = makeTempStore()
    let note = store.create(title: "Hello World")

    #expect(store.notes.count == 1)
    #expect(note.title == "Hello World")
    #expect(FileManager.default.fileExists(atPath: note.url.path))
}

@Test @MainActor func saveUpdatesContentAndPersistsAcrossReload() throws {
    let store = makeTempStore()
    var note = store.create(title: "Draft")
    note.content = "Draft\nSome body text."
    store.save(note)

    let reloaded = NoteStore(directory: store.notesDirectory)
    #expect(reloaded.notes.count == 1)
    #expect(reloaded.notes.first?.content == "Draft\nSome body text.")
}

@Test @MainActor func deleteRemovesNoteFromListAndDisk() throws {
    let store = makeTempStore()
    let note = store.create(title: "Temporary")
    store.delete(note)

    #expect(store.notes.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: note.url.path))
}

@Test @MainActor func duplicateTitlesGetUniqueFilenames() throws {
    let store = makeTempStore()
    let first = store.create(title: "Untitled")
    let second = store.create(title: "Untitled")

    #expect(first.url.lastPathComponent != second.url.lastPathComponent)
    #expect(store.notes.count == 2)
}

@Test @MainActor func exactTitleMatchIsCaseInsensitiveButRequiresFullTitle() throws {
    let store = makeTempStore()
    var note = store.create(title: "Meeting Notes")
    note.content = "Meeting Notes\nAgenda here."
    store.save(note)

    #expect(store.exactTitleMatch(for: "meeting notes")?.id == note.id)
    #expect(store.exactTitleMatch(for: "Meeting") == nil)
}

@Test @MainActor func filteredRanksTitleMatchesAboveContentOnlyMatches() throws {
    let store = makeTempStore()

    var titleMatch = store.create(title: "Grocery List")
    titleMatch.content = "Grocery List\nmilk, eggs"
    store.save(titleMatch)

    var contentOnlyMatch = store.create(title: "Random Thoughts")
    contentOnlyMatch.content = "Random Thoughts\nneed to buy groceries later"
    store.save(contentOnlyMatch)

    let results = store.filtered(query: "grocer")

    #expect(results.count == 2)
    #expect(results.first?.id == titleMatch.id)
    #expect(results.last?.id == contentOnlyMatch.id)
}

@Test @MainActor func filteredExcludesNonMatchingNotes() throws {
    let store = makeTempStore()
    store.create(title: "Apples")
    store.create(title: "Oranges")

    let results = store.filtered(query: "zzz-no-match")
    #expect(results.isEmpty)
}
