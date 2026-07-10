import Foundation
@testable import VelocityCore

@main
struct SelfCheck {
    @MainActor
    static func main() async {
        var failures: [String] = []

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS: \(name)")
            } else {
                print("FAIL: \(name)")
                failures.append(name)
            }
        }

        func waitForLoad(_ store: NoteStore) async {
            var attempts = 0
            while store.isLoading && attempts < 200 {
                try? await Task.sleep(for: .milliseconds(5))
                attempts += 1
            }
        }

        func makeTempStore() async -> NoteStore {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("VelocitySelfCheck-\(UUID().uuidString)", isDirectory: true)
            let store = NoteStore(directories: [dir])
            await waitForLoad(store)
            return store
        }

        // createNoteWritesFileAndAppearsInList
        do {
            let store = await makeTempStore()
            let note = store.create(title: "Hello World")
            check("create writes file", FileManager.default.fileExists(atPath: note.url.path))
            check("create appears in list", store.notes.count == 1)
            check("create derives title", note.title == "Hello World")
        }

        // saveUpdatesContentAndPersistsAcrossReload
        do {
            let store = await makeTempStore()
            var note = store.create(title: "Draft")
            note.content = "Draft\nSome body text."
            store.save(note)

            let reloaded = NoteStore(directories: store.noteDirectories)
            await waitForLoad(reloaded)
            check("save persists count", reloaded.notes.count == 1)
            check("save persists content", reloaded.notes.first?.content == "Draft\nSome body text.")
        }

        // deleteRemovesNoteFromListAndDisk
        do {
            let store = await makeTempStore()
            let note = store.create(title: "Temporary")
            store.delete(note)
            check("delete empties list", store.notes.isEmpty)
            check("delete removes file", !FileManager.default.fileExists(atPath: note.url.path))
        }

        // duplicateTitlesGetUniqueFilenames
        do {
            let store = await makeTempStore()
            let first = store.create(title: "Untitled")
            let second = store.create(title: "Untitled")
            check("duplicate titles get unique filenames", first.url.lastPathComponent != second.url.lastPathComponent)
            check("duplicate titles both present", store.notes.count == 2)
        }

        // exactTitleMatchIsCaseInsensitiveButRequiresFullTitle
        do {
            let store = await makeTempStore()
            var note = store.create(title: "Meeting Notes")
            note.content = "Meeting Notes\nAgenda here."
            store.save(note)
            check("exact match case-insensitive", store.exactTitleMatch(for: "meeting notes")?.id == note.id)
            check("exact match requires full title", store.exactTitleMatch(for: "Meeting") == nil)
        }

        // filteredRanksTitleMatchesAboveContentOnlyMatches
        do {
            let store = await makeTempStore()
            var titleMatch = store.create(title: "Grocery List")
            titleMatch.content = "Grocery List\nmilk, eggs"
            store.save(titleMatch)

            var contentOnlyMatch = store.create(title: "Random Thoughts")
            contentOnlyMatch.content = "Random Thoughts\nneed to buy groceries later"
            store.save(contentOnlyMatch)

            let results = store.filtered(query: "grocer")
            check("filtered returns both matches", results.count == 2)
            check("filtered ranks title match first", results.first?.id == titleMatch.id)
            check("filtered ranks content-only match last", results.last?.id == contentOnlyMatch.id)
        }

        // renameMovesFileAndUpdatesIdentity
        do {
            let store = await makeTempStore()
            let note = store.create(title: "Old Name")
            let oldURL = note.url

            let renamed = store.rename(note, to: "New Name")
            check("rename changes title", renamed.title == "New Name")
            check("rename moves file", !FileManager.default.fileExists(atPath: oldURL.path) && FileManager.default.fileExists(atPath: renamed.url.path))
            check("rename updates store entry", store.notes.first?.id == renamed.id)
            check("rename preserves content", renamed.content == note.content)
        }

        // moveRelocatesFileToAnotherConfiguredFolder
        do {
            let dirA = FileManager.default.temporaryDirectory
                .appendingPathComponent("VelocitySelfCheck-\(UUID().uuidString)", isDirectory: true)
            let dirB = FileManager.default.temporaryDirectory
                .appendingPathComponent("VelocitySelfCheck-\(UUID().uuidString)", isDirectory: true)
            let store = NoteStore(directories: [dirA, dirB])
            await waitForLoad(store)

            let note = store.create(title: "Relocate Me")
            let oldURL = note.url
            let moved = store.move(note, to: dirB)

            check("move changes folder", moved.url.deletingLastPathComponent() == dirB)
            check("move removes old file", !FileManager.default.fileExists(atPath: oldURL.path))
            check("move creates new file", FileManager.default.fileExists(atPath: moved.url.path))
            check("move preserves title", moved.title == "Relocate Me")
            check("move updates store entry", store.notes.first { $0.title == "Relocate Me" }?.id == moved.id)

            let noOp = store.move(moved, to: dirB)
            check("move to same folder is a no-op", noOp.id == moved.id)
        }

        // setDirectoriesLoadsNewFoldersAndStopsWatchingOld
        do {
            let storeA = await makeTempStore()
            storeA.create(title: "In Folder A")

            let dirB = FileManager.default.temporaryDirectory
                .appendingPathComponent("VelocitySelfCheck-\(UUID().uuidString)", isDirectory: true)
            storeA.setDirectories([dirB])
            await waitForLoad(storeA)
            check("setDirectories updates noteDirectories", storeA.noteDirectories == [dirB])
            check("setDirectories clears old folder's notes", storeA.notes.isEmpty)

            storeA.create(title: "In Folder B")
            check("setDirectories create lands in new folder", FileManager.default.fileExists(atPath: dirB.appendingPathComponent("In Folder B.md").path))
        }

        // multipleFoldersAggregateIntoOneFlatListWithUniqueIDs
        do {
            let dirA = FileManager.default.temporaryDirectory
                .appendingPathComponent("VelocitySelfCheck-\(UUID().uuidString)", isDirectory: true)
            let dirB = FileManager.default.temporaryDirectory
                .appendingPathComponent("VelocitySelfCheck-\(UUID().uuidString)", isDirectory: true)
            let store = NoteStore(directories: [dirA, dirB])
            await waitForLoad(store)

            // Same filename in two different folders — ids must not collide.
            try? "from A".write(to: dirA.appendingPathComponent("Same Name.md"), atomically: true, encoding: .utf8)
            try? "from B".write(to: dirB.appendingPathComponent("Same Name.md"), atomically: true, encoding: .utf8)
            store.reload()
            await waitForLoad(store)

            check("multi-folder aggregates both notes", store.notes.count == 2)
            check("multi-folder ids are unique despite same filename", Set(store.notes.map(\.id)).count == 2)

            let created = store.create(title: "New Note")
            check("create defaults to first folder", created.url.deletingLastPathComponent() == dirA)
        }

        // reloadInFlightAtLaunchDoesNotClobberAnImmediateCreate
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("VelocitySelfCheck-\(UUID().uuidString)", isDirectory: true)
            // Don't wait for the initial load — create immediately, racing the
            // in-flight background scan of what was (at construction time) an
            // empty folder.
            let store = NoteStore(directories: [dir])
            let note = store.create(title: "Immediate")
            await waitForLoad(store)
            check("create survives in-flight initial reload", store.notes.contains { $0.id == note.id })
        }

        // renameToExistingTitleGetsDeduped
        do {
            let store = await makeTempStore()
            store.create(title: "Taken")
            let other = store.create(title: "Other")
            let renamed = store.rename(other, to: "Taken")
            check("rename dedupes collisions", renamed.url.lastPathComponent != "Taken.md")
            check("rename dedupe keeps two notes", store.notes.count == 2)
        }

        // renameToEmptyOrSameTitleIsNoOp
        do {
            let store = await makeTempStore()
            let note = store.create(title: "Stable")
            let unchanged = store.rename(note, to: "  ")
            check("rename ignores blank title", unchanged.id == note.id)
            check("rename ignores blank title (file untouched)", FileManager.default.fileExists(atPath: note.url.path))
        }

        // filteredExcludesNonMatchingNotes
        do {
            let store = await makeTempStore()
            store.create(title: "Apples")
            store.create(title: "Oranges")
            let results = store.filtered(query: "zzz-no-match")
            check("filtered excludes non-matches", results.isEmpty)
        }

        // noteTagsExtractsHashtagsButNotHeadings
        do {
            var note = Note(id: "x", url: URL(fileURLWithPath: "/tmp/x.md"), content: "", modifiedDate: Date())
            note.content = "# Heading\nWorking on #work and #Side-Project, also foo#notatag and ##nope\nSee #work again"
            check("tags extracts hashtags", note.tags == ["work", "side-project"])
        }

        // filteredTagQueryMatchesOnlyTaggedNotes
        do {
            let store = await makeTempStore()
            var tagged = store.create(title: "Work Note")
            tagged.content = "Discussed the roadmap #work"
            store.save(tagged)

            var untagged = store.create(title: "Grocery List")
            untagged.content = "milk, eggs"
            store.save(untagged)

            let results = store.filtered(query: "tag:work")
            check("tag query matches tagged note", results.count == 1)
            check("tag query excludes untagged note", results.first?.id == tagged.id)

            let caseInsensitive = store.filtered(query: "tag:WORK")
            check("tag query is case-insensitive", caseInsensitive.count == 1)
        }

        // filteredTagQuerySupportsPartialMatch
        do {
            let store = await makeTempStore()
            var techNote = store.create(title: "Conference Notes")
            techNote.content = "Talked about #technology trends"
            store.save(techNote)

            var unrelated = store.create(title: "Recipe")
            unrelated.content = "Pasta with garlic and olive oil."
            store.save(unrelated)

            let results = store.filtered(query: "tag:techn")
            check("partial tag query matches longer tag", results.count == 1)
            check("partial tag query finds the right note", results.first?.id == techNote.id)
        }

        // filteredCombinesTagOperatorWithFreeTextSearch
        do {
            let store = await makeTempStore()
            var meetingNote = store.create(title: "Standup")
            meetingNote.content = "Quick meeting about the roadmap #work"
            store.save(meetingNote)

            var otherWorkNote = store.create(title: "Expense Report")
            otherWorkNote.content = "Filed the quarterly expenses #work"
            store.save(otherWorkNote)

            var unrelatedMeeting = store.create(title: "Book Club")
            unrelatedMeeting.content = "Meeting to discuss chapter 5"
            store.save(unrelatedMeeting)

            let results = store.filtered(query: "tag:work meeting")
            check("tag+text query matches note with both", results.count == 1)
            check("tag+text query finds the right note", results.first?.id == meetingNote.id)
            check("tag+text query excludes tag-only match", !results.contains { $0.id == otherWorkNote.id })
            check("tag+text query excludes text-only match", !results.contains { $0.id == unrelatedMeeting.id })
        }

        // filteredMultiWordQueryMatchesScatteredTerms
        do {
            let store = await makeTempStore()
            var scattered = store.create(title: "Evening Walk")
            scattered.content = "Grabbed the leash before heading out.\nThe dog found an old bone in the yard."
            store.save(scattered)

            var partial = store.create(title: "Shopping List")
            partial.content = "Need a new dog bed and some treats."
            store.save(partial)

            var unrelated = store.create(title: "Recipe")
            unrelated.content = "Pasta with garlic and olive oil."
            store.save(unrelated)

            let results = store.filtered(query: "dog bone leash")
            check("multi-word query matches scattered terms", results.count == 1)
            check("multi-word query finds the right note", results.first?.id == scattered.id)
            check("multi-word query excludes partial matches", !results.contains { $0.id == partial.id })
            check("multi-word query excludes unrelated notes", !results.contains { $0.id == unrelated.id })
        }

        // filteredDateQueryMatchesExactDateInMultipleFormats
        do {
            let store = await makeTempStore()
            let note = store.create(title: "Today Note")

            let calendar = Calendar.current
            let now = Date()
            let year = calendar.component(.year, from: now)
            let month = calendar.component(.month, from: now)
            let day = calendar.component(.day, from: now)
            let shortYear = year % 100

            let isoQuery = String(format: "date:%04d-%02d-%02d", year, month, day)
            let usShortQuery = String(format: "date:%d-%d-%02d", month, day, shortYear)
            let usLongQuery = String(format: "date:%02d-%02d-%04d", month, day, year)

            check("date query matches ISO format", store.filtered(query: isoQuery).contains { $0.id == note.id })
            check("date query matches short US format", store.filtered(query: usShortQuery).contains { $0.id == note.id })
            check("date query matches long US format", store.filtered(query: usLongQuery).contains { $0.id == note.id })
        }

        // filteredDateQuerySupportsRelativeKeywords
        do {
            let store = await makeTempStore()
            let note = store.create(title: "Just Created")

            check("date:today matches a just-created note", store.filtered(query: "date:today").contains { $0.id == note.id })
            check("date:yesterday excludes a just-created note", !store.filtered(query: "date:yesterday").contains { $0.id == note.id })
            check("date:week matches a just-created note", store.filtered(query: "date:week").contains { $0.id == note.id })
        }

        // externalInPlaceEditIsPickedUpWithoutManualReload
        do {
            let store = await makeTempStore()
            let note = store.create(title: "Externally Edited")
            // Past the 0.5s window markInternalWrite() suppresses reloads for
            // after our own create() above — otherwise the "external" write
            // below lands inside that window and gets legitimately ignored,
            // same as it would for a real internal write racing itself.
            try? await Task.sleep(for: .milliseconds(600))

            // Simulates another app (Obsidian, TextEdit, etc.) editing the
            // same file directly on disk — bypassing NoteStore entirely,
            // unlike store.save(). A plain in-place write like this is
            // exactly what the old directory-entry-only watcher missed.
            try? "Changed by another app.".write(to: note.url, atomically: false, encoding: .utf8)

            // Matched by filename/content rather than note.id: temp
            // directories live under /var, which resolvingSymlinksInPath()
            // deliberately leaves unresolved (a documented special case for
            // /tmp and /var), while FileManager's own directory enumeration
            // reports the real /private/var path underneath — a mismatch
            // specific to this test's use of the shared temp directory, not
            // something a real notes folder under ~/Documents would hit.
            var picked = false
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(20))
                if store.notes.contains(where: { $0.url.lastPathComponent == note.url.lastPathComponent && $0.content == "Changed by another app." }) {
                    picked = true
                    break
                }
            }
            check("external in-place edit is picked up without manual reload", picked)
        }

        print("")
        if failures.isEmpty {
            print("All checks passed.")
        } else {
            print("\(failures.count) check(s) failed: \(failures.joined(separator: ", "))")
            exit(1)
        }
    }
}
