import Foundation
@testable import EnvyCore

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
                .appendingPathComponent("EnvySelfCheck-\(UUID().uuidString)", isDirectory: true)
            let store = NoteStore(directory: dir)
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

            let reloaded = NoteStore(directory: store.noteDirectory)
            await waitForLoad(reloaded)
            check("save persists count", reloaded.notes.count == 1)
            check("save persists content", reloaded.notes.first?.content == "Draft\nSome body text.")
        }

        // renameUpdatesWikiLinkReferencesAcrossTheVault
        do {
            let store = await makeTempStore()
            var target = store.create(title: "Old Name")
            target.content = "the target note"
            store.save(target)

            var referrer = store.create(title: "Referrer")
            referrer.content = "see [[Old Name]] and embed ![[old name]] here"
            store.save(referrer)

            var unrelated = store.create(title: "Unrelated")
            unrelated.content = "links elsewhere [[Something Else]]"
            store.save(unrelated)

            let referrerDateBefore = store.notes.first { $0.title == "Referrer" }?.modifiedDate

            let renamed = store.rename(target, to: "New Name")
            check("rename yields the new title", renamed.title == "New Name")

            let updated = store.notes.first { $0.title == "Referrer" }
            check("rename rewrote the [[link]]", updated?.content.contains("[[New Name]]") == true)
            check("rename removed the old [[link]]", updated?.content.contains("[[Old Name]]") == false)
            check("rename rewrote a case-insensitive embed", updated?.content.contains("![[New Name]]") == true)
            check("rename preserves the referrer's modified date",
                  store.notes.first { $0.title == "Referrer" }?.modifiedDate == referrerDateBefore)
            check("rename leaves unrelated notes untouched",
                  store.notes.first { $0.title == "Unrelated" }?.content.contains("[[Something Else]]") == true)

            // Persisted to disk, not just in memory.
            let reloaded = NoteStore(directory: store.noteDirectory)
            await waitForLoad(reloaded)
            check("rename's reference rewrite persisted to disk",
                  reloaded.notes.first { $0.title == "Referrer" }?.content.contains("[[New Name]]") == true)
        }

        // deleteRemovesNoteFromListAndDisk
        do {
            let store = await makeTempStore()
            let note = store.create(title: "Temporary")
            store.delete(note)
            check("delete empties list", store.notes.isEmpty)
            check("delete removes file", !FileManager.default.fileExists(atPath: note.url.path))
        }

        // deleteSendsToAHiddenDotTrashSubfolder
        do {
            let store = await makeTempStore()
            let note = store.create(title: "Soft Delete Me")
            let trashDirectory = store.noteDirectory.appendingPathComponent(".trash", isDirectory: true)
            store.delete(note)
            check("delete lands in a hidden .trash/, not macOS Trash directly", FileManager.default.fileExists(atPath: trashDirectory.appendingPathComponent("Soft Delete Me.md").path))
            check("delete publishes it via trashedNotes", store.trashedNotes.contains { $0.title == "Soft Delete Me" })

            let restored = store.restoreLastDeleted()
            check("restoreLastDeleted brings back exactly one note", restored.count == 1)
            check("restoreLastDeleted restores the original file", FileManager.default.fileExists(atPath: note.url.path))
            check("restoreLastDeleted removes it from .trash/", !FileManager.default.fileExists(atPath: trashDirectory.appendingPathComponent("Soft Delete Me.md").path))
            check("restoreLastDeleted re-adds it to notes", store.notes.contains { $0.id == note.id })
            check("restoreLastDeleted clears it from trashedNotes", !store.trashedNotes.contains { $0.title == "Soft Delete Me" })
        }

        // trashSubfolderIsNeverScannedAsNotes
        do {
            let store = await makeTempStore()
            store.setIncludeSubfolders(true)
            await waitForLoad(store)
            let note = store.create(title: "Will Be Trashed")
            store.delete(note)
            await waitForLoad(store)
            check("a note sitting in .trash/ never reappears as a note, even with subfolders included", !store.notes.contains { $0.title == "Will Be Trashed" })
        }

        // eachSubfolderGetsItsOwnTrashAndRestoresBackIntoItself
        do {
            let store = await makeTempStore()
            store.setIncludeSubfolders(true)
            await waitForLoad(store)
            let subfolder = store.noteDirectory.appendingPathComponent("Work", isDirectory: true)
            try? FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
            let nestedURL = subfolder.appendingPathComponent("Nested.md")
            try? "nested content".write(to: nestedURL, atomically: true, encoding: .utf8)
            store.reload()
            await waitForLoad(store)
            if let nestedNote = store.notes.first(where: { $0.title == "Nested" }) {
                store.delete(nestedNote)
                let siblingTrash = subfolder.appendingPathComponent(".trash", isDirectory: true)
                check("a subfolder note gets its own sibling .trash/, not the top-level one", FileManager.default.fileExists(atPath: siblingTrash.appendingPathComponent("Nested.md").path))
                check("nothing landed in the top-level .trash/ for a subfolder delete", !FileManager.default.fileExists(atPath: store.noteDirectory.appendingPathComponent(".trash/Nested.md").path))

                if let trashedNested = store.trashedNotes.first(where: { $0.title == "Nested" }) {
                    let restored = store.restoreFromTrash(trashedNested)
                    check("restoreFromTrash succeeds", restored != nil)
                    check("restoreFromTrash puts it back in the same subfolder it came from", FileManager.default.fileExists(atPath: nestedURL.path))
                    check("restoreFromTrash re-adds it to notes", store.notes.contains { $0.title == "Nested" })
                } else {
                    check("trashedNotes finds the nested note in its own .trash/", false)
                }
            } else {
                check("nested note was found before trashing it", false)
            }
        }

        // deleteFromTrashMovesJustThatOneItemToMacOSTrash
        do {
            let store = await makeTempStore()
            let keep = store.create(title: "Keep Me")
            let removeMe = store.create(title: "Remove Me")
            store.delete(keep)
            store.delete(removeMe)
            check("both trashed notes show up in trashedNotes", store.trashedNotes.count == 2)

            if let toRemove = store.trashedNotes.first(where: { $0.title == "Remove Me" }) {
                store.deleteFromTrash(toRemove)
                check("deleteFromTrash removes just that one item from trashedNotes", store.trashedNotes.count == 1)
                check("deleteFromTrash leaves the other trashed note alone", store.trashedNotes.contains { $0.title == "Keep Me" })
            } else {
                check("found the note to remove from trash", false)
            }
        }

        // emptyTrashSweepsEveryDotTrashFolderUnderTheIndex
        do {
            let store = await makeTempStore()
            let note = store.create(title: "Long Gone")
            let trashDirectory = store.noteDirectory.appendingPathComponent(".trash", isDirectory: true)
            store.delete(note)
            check("note is in .trash/ before emptying", FileManager.default.fileExists(atPath: trashDirectory.appendingPathComponent("Long Gone.md").path))

            store.emptyTrash()
            check("emptyTrash clears the .trash/ folder", !FileManager.default.fileExists(atPath: trashDirectory.appendingPathComponent("Long Gone.md").path))
            check("emptyTrash clears trashedNotes too", store.trashedNotes.isEmpty)

            let restoredAfterEmpty = store.restoreLastDeleted()
            check("restoring after emptyTrash silently finds nothing to restore", restoredAfterEmpty.isEmpty)
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

        // setDirectoryLoadsNewFolderAndStopsWatchingOld
        do {
            let storeA = await makeTempStore()
            storeA.create(title: "In The Index")

            let dirB = FileManager.default.temporaryDirectory
                .appendingPathComponent("EnvySelfCheck-\(UUID().uuidString)", isDirectory: true)
            storeA.setDirectory(dirB)
            await waitForLoad(storeA)
            check("setDirectory updates noteDirectory", storeA.noteDirectory == dirB)
            check("setDirectory clears old folder's notes", storeA.notes.isEmpty)

            storeA.create(title: "In New Index")
            check("setDirectory create lands in new folder", FileManager.default.fileExists(atPath: dirB.appendingPathComponent("In New Index.md").path))
        }

        // includeSubfoldersScansNestedNotesButNeverTemplates
        do {
            let store = await makeTempStore()
            let subfolder = store.noteDirectory.appendingPathComponent("Work", isDirectory: true)
            try? FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
            try? "nested".write(to: subfolder.appendingPathComponent("Nested Note.md"), atomically: true, encoding: .utf8)

            let templatesDirectory = store.noteDirectory.appendingPathComponent("Templates", isDirectory: true)
            try? FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
            try? "template body".write(to: templatesDirectory.appendingPathComponent("Should Not Appear.md"), atomically: true, encoding: .utf8)

            store.reload()
            await waitForLoad(store)
            check("subfolder notes are invisible by default", !store.notes.contains { $0.title == "Nested Note" })

            store.setIncludeSubfolders(true)
            await waitForLoad(store)
            check("includeSubfolders picks up a nested note", store.notes.contains { $0.title == "Nested Note" })
            check("includeSubfolders still excludes Templates/", !store.notes.contains { $0.title == "Should Not Appear" })

            store.setIncludeSubfolders(false)
            await waitForLoad(store)
            check("turning includeSubfolders back off hides the nested note again", !store.notes.contains { $0.title == "Nested Note" })
        }

        // reloadInFlightAtLaunchDoesNotClobberAnImmediateCreate
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("EnvySelfCheck-\(UUID().uuidString)", isDirectory: true)
            // Don't wait for the initial load — create immediately, racing the
            // in-flight background scan of what was (at construction time) an
            // empty folder.
            let store = NoteStore(directory: dir)
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

        // filteredTodoQueryMatchesOnlyNotesWithAnUncheckedTask
        do {
            let store = await makeTempStore()
            var withTodo = store.create(title: "Chores")
            withTodo.content = "- [ ] take out trash\n- [x] pay rent"
            store.save(withTodo)

            var allDone = store.create(title: "Finished List")
            allDone.content = "- [x] first\n- [x] second"
            store.save(allDone)

            var noTasks = store.create(title: "Plain Note")
            noTasks.content = "Nothing to do here."
            store.save(noTasks)

            let results = store.filtered(query: "todo:")
            check("todo: matches note with an unchecked task", results.contains { $0.id == withTodo.id })
            check("todo: excludes a fully-checked note", !results.contains { $0.id == allDone.id })
            check("todo: excludes a note with no tasks", !results.contains { $0.id == noTasks.id })

            let excludeResults = store.filtered(query: "-todo:")
            check("-todo: excludes a note with an unchecked task", !excludeResults.contains { $0.id == withTodo.id })
            check("-todo: matches a fully-checked note", excludeResults.contains { $0.id == allDone.id })
            check("-todo: matches a note with no tasks", excludeResults.contains { $0.id == noTasks.id })
        }

        // filteredAIProvenanceOperator
        do {
            let store = await makeTempStore()
            var aiCreated = store.create(title: "AI Made This")
            aiCreated.content = "Some generated content.\n\n⎈ created by claude · 2026-07-17"
            store.save(aiCreated)

            var aiEdited = store.create(title: "AI Touched This")
            aiEdited.content = "My own note, then changed.\n\n⎈ edited by claude · 2026-07-17"
            store.save(aiEdited)

            var human = store.create(title: "All Mine")
            human.content = "Purely my own writing."
            store.save(human)

            check("aiProvenance parses created", aiCreated.aiProvenance == .created)
            check("aiProvenance parses edited", aiEdited.aiProvenance == .edited)
            check("aiProvenance is none for a plain note", human.aiProvenance == .none)

            let anyAI = store.filtered(query: "ai:")
            check("ai: matches an AI-created note", anyAI.contains { $0.id == aiCreated.id })
            check("ai: matches an AI-edited note", anyAI.contains { $0.id == aiEdited.id })
            check("ai: excludes a purely human note", !anyAI.contains { $0.id == human.id })

            let created = store.filtered(query: "ai:created")
            check("ai:created matches only the created note", created.contains { $0.id == aiCreated.id } && !created.contains { $0.id == aiEdited.id })

            let edited = store.filtered(query: "ai:edited")
            check("ai:edited matches only the edited note", edited.contains { $0.id == aiEdited.id } && !edited.contains { $0.id == aiCreated.id })

            let mineOnly = store.filtered(query: "-ai:")
            check("-ai: matches a purely human note", mineOnly.contains { $0.id == human.id })
            check("-ai: excludes any AI-touched note", !mineOnly.contains { $0.id == aiCreated.id } && !mineOnly.contains { $0.id == aiEdited.id })
        }

        // filteredExcludeTermRemovesMatchingNotes
        do {
            let store = await makeTempStore()
            var keep = store.create(title: "Dog Walk")
            keep.content = "Took the dog to the park."
            store.save(keep)

            var excluded = store.create(title: "Dog and Cat")
            excluded.content = "The dog and the cat get along fine."
            store.save(excluded)

            let results = store.filtered(query: "dog -cat")
            check("-term excludes notes containing it", !results.contains { $0.id == excluded.id })
            check("-term still matches notes without it", results.contains { $0.id == keep.id })
        }

        // filteredExcludeTagRemovesTaggedNotes
        do {
            let store = await makeTempStore()
            var archived = store.create(title: "Old Project")
            archived.content = "Wrapped up. #archive"
            store.save(archived)

            var active = store.create(title: "Current Project")
            active.content = "Still in progress. #active"
            store.save(active)

            let results = store.filtered(query: "-tag:archive")
            check("-tag: excludes notes with that tag", !results.contains { $0.id == archived.id })
            check("-tag: keeps notes without that tag", results.contains { $0.id == active.id })
        }

        // filteredCommaSeparatedGroupsAreOrEd
        do {
            let store = await makeTempStore()
            var dogNote = store.create(title: "Dog Note")
            dogNote.content = "Walked the dog today."
            store.save(dogNote)

            var boneNote = store.create(title: "Bone Note")
            boneNote.content = "Found a bone in the yard."
            store.save(boneNote)

            var leashNote = store.create(title: "Leash Note")
            leashNote.content = "Bought a new leash."
            store.save(leashNote)

            var unrelated = store.create(title: "Unrelated")
            unrelated.content = "Nothing to see here."
            store.save(unrelated)

            let orResults = store.filtered(query: "dog, bone, leash")
            check("comma groups match any one term", orResults.count == 3)
            check("comma groups include the dog note", orResults.contains { $0.id == dogNote.id })
            check("comma groups include the bone note", orResults.contains { $0.id == boneNote.id })
            check("comma groups include the leash note", orResults.contains { $0.id == leashNote.id })
            check("comma groups exclude unrelated notes", !orResults.contains { $0.id == unrelated.id })

            // No comma at all still means every term must appear somewhere —
            // completely unchanged behavior for a query that was never split.
            let andResults = store.filtered(query: "dog bone leash")
            check("no comma still means every term required", andResults.isEmpty)
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

        // noteDueExtractsAbsoluteDateToken
        do {
            var withDue = Note(id: "x", url: URL(fileURLWithPath: "/tmp/x.md"), content: "", modifiedDate: Date())
            withDue.content = "Ship the report @04-16-26 before the deadline."
            let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 16))
            check("due extracts an absolute date token", withDue.due == expected)

            var withoutDue = Note(id: "y", url: URL(fileURLWithPath: "/tmp/y.md"), content: "", modifiedDate: Date())
            withoutDue.content = "This note has no due date at all."
            check("due is nil when no @ token is present", withoutDue.due == nil)

            var unparseable = Note(id: "z", url: URL(fileURLWithPath: "/tmp/z.md"), content: "", modifiedDate: Date())
            unparseable.content = "@whenever-i-get-to-it"
            check("due is nil for an unparseable token rather than crashing", unparseable.due == nil)

            var mention = Note(id: "t", url: URL(fileURLWithPath: "/tmp/t.md"), content: "", modifiedDate: Date())
            mention.content = "cc @sarah about this"
            check("due is nil for an ordinary @mention (not a day name or date)", mention.due == nil)

            var midWord = Note(id: "w", url: URL(fileURLWithPath: "/tmp/w.md"), content: "", modifiedDate: Date())
            midWord.content = "someone@04-16-26 shouldn't count as a due token"
            check("due regex excludes mid-word matches (an '@' preceded by a word character)", midWord.due == nil)

            // Regression: a greedy \S+ capture used to swallow trailing
            // punctuation with no space before it, breaking Int parsing of
            // the year and silently producing no due date at all.
            var trailingComma = Note(id: "v", url: URL(fileURLWithPath: "/tmp/v.md"), content: "", modifiedDate: Date())
            trailingComma.content = "Long-range planning doc, @09-16-26, not urgent yet."
            let expectedTrailingComma = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 16))
            check("due parses correctly when followed by a comma with no space", trailingComma.due == expectedTrailingComma)

            var trailingPeriod = Note(id: "u", url: URL(fileURLWithPath: "/tmp/u.md"), content: "", modifiedDate: Date())
            trailingPeriod.content = "Ship it @04-16-26."
            let expectedTrailingPeriod = Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 16))
            check("due parses correctly when followed by a period with no space", trailingPeriod.due == expectedTrailingPeriod)
        }

        // noteDueResolvesDayNamesToTheirNextOccurrence
        do {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let todayWeekday = calendar.component(.weekday, from: today)
            let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

            for (index, name) in weekdayNames.enumerated() {
                let weekdayNumber = index + 1 // Calendar: 1 = Sunday ... 7 = Saturday
                var offset = (weekdayNumber - todayWeekday + 7) % 7
                // "Next" never means "today" — a day name matching today's
                // own weekday should resolve a full week out, not to today.
                if offset == 0 { offset = 7 }
                let expected = calendar.date(byAdding: .day, value: offset, to: today)

                var note = Note(id: "day-\(name)", url: URL(fileURLWithPath: "/tmp/day-\(name).md"), content: "", modifiedDate: Date())
                note.content = "Follow up @\(name)"
                check("@\(name) resolves to the next \(name), never today", note.due == expected)

                var upper = Note(id: "day-upper-\(name)", url: URL(fileURLWithPath: "/tmp/day-upper-\(name).md"), content: "", modifiedDate: Date())
                upper.content = "Follow up @\(name.uppercased())"
                check("@\(name.uppercased()) matches case-insensitively", upper.due == expected)
            }

            // The specific case called out when this was designed: naming
            // today's own weekday must still land 7 days out, not 0.
            let todayName = weekdayNames[todayWeekday - 1]
            var sameDay = Note(id: "day-same", url: URL(fileURLWithPath: "/tmp/day-same.md"), content: "", modifiedDate: Date())
            sameDay.content = "@\(todayName)"
            let expectedSameDay = calendar.date(byAdding: .day, value: 7, to: today)
            check("naming today's own weekday resolves a full week out, not today", sameDay.due == expectedSameDay)

            var partialWord = Note(id: "day-partial", url: URL(fileURLWithPath: "/tmp/day-partial.md"), content: "", modifiedDate: Date())
            partialWord.content = "@mondayish isn't a real day name"
            check("a day name followed by more letters doesn't partially match", partialWord.due == nil)

            // "@today" is the one token that isn't "next" anything —
            // literally today, distinct from naming today's own weekday
            // (tested above), which deliberately means a week out instead.
            var today_ = Note(id: "day-today", url: URL(fileURLWithPath: "/tmp/day-today.md"), content: "", modifiedDate: Date())
            today_.content = "Follow up @today"
            check("@today resolves to today, not a week out", today_.due == today)

            var todayUpper = Note(id: "day-today-upper", url: URL(fileURLWithPath: "/tmp/day-today-upper.md"), content: "", modifiedDate: Date())
            todayUpper.content = "@TODAY"
            check("@TODAY matches case-insensitively", todayUpper.due == today)

            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
            var tomorrowNote = Note(id: "day-tomorrow", url: URL(fileURLWithPath: "/tmp/day-tomorrow.md"), content: "", modifiedDate: Date())
            tomorrowNote.content = "Follow up @tomorrow"
            check("@tomorrow resolves to tomorrow", tomorrowNote.due == tomorrow)

            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
            var yesterdayNote = Note(id: "day-yesterday", url: URL(fileURLWithPath: "/tmp/day-yesterday.md"), content: "", modifiedDate: Date())
            yesterdayNote.content = "Was due @yesterday"
            check("@yesterday resolves to yesterday", yesterdayNote.due == yesterday)

            var tomorrowUpper = Note(id: "day-tomorrow-upper", url: URL(fileURLWithPath: "/tmp/day-tomorrow-upper.md"), content: "", modifiedDate: Date())
            tomorrowUpper.content = "@TOMORROW"
            check("@TOMORROW matches case-insensitively", tomorrowUpper.due == tomorrow)
        }

        // noteDueIgnoresCrossedOutTokens
        do {
            let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 16))

            var crossedOut = Note(id: "due-crossed", url: URL(fileURLWithPath: "/tmp/due-crossed.md"), content: "", modifiedDate: Date())
            crossedOut.content = "Ship the report ~~@04-16-26~~ done already"
            check("a due token tightly wrapped in ~~ isn't recognized as a due date", crossedOut.due == nil)

            var crossedOutSentence = Note(id: "due-crossed-sentence", url: URL(fileURLWithPath: "/tmp/due-crossed-sentence.md"), content: "", modifiedDate: Date())
            crossedOutSentence.content = "~~Ship the report @04-16-26~~"
            check("a due token crossed out as part of a longer struck sentence isn't recognized either", crossedOutSentence.due == nil)

            var notCrossedOut = Note(id: "due-not-crossed", url: URL(fileURLWithPath: "/tmp/due-not-crossed.md"), content: "", modifiedDate: Date())
            notCrossedOut.content = "Ship the report @04-16-26, not done yet"
            check("an ordinary (not crossed out) due token still resolves normally", notCrossedOut.due == expected)

            // The first token is crossed out, but a second, later one isn't
            // — the second should still be picked up rather than the whole
            // note reading as having no due date at all.
            var secondTokenActive = Note(id: "due-second-active", url: URL(fileURLWithPath: "/tmp/due-second-active.md"), content: "", modifiedDate: Date())
            secondTokenActive.content = "~~@01-01-26~~ moved to @04-16-26"
            check("a later, non-crossed-out token is used when the first is crossed out", secondTokenActive.due == expected)
        }

        // noteDueIgnoresTokensOnACheckedTaskLine
        do {
            let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 16))

            var checkedWithDash = Note(id: "due-checked-dash", url: URL(fileURLWithPath: "/tmp/due-checked-dash.md"), content: "", modifiedDate: Date())
            checkedWithDash.content = "- [x] Ship the report @04-16-26"
            check("a due token on a checked \"- [x]\" line isn't recognized, no ~~ needed", checkedWithDash.due == nil)

            var checkedNoDash = Note(id: "due-checked-no-dash", url: URL(fileURLWithPath: "/tmp/due-checked-no-dash.md"), content: "", modifiedDate: Date())
            checkedNoDash.content = "[x] Ship the report @04-16-26"
            check("a due token on a checked \"[x]\" line (no leading dash) isn't recognized either", checkedNoDash.due == nil)

            var checkedUppercase = Note(id: "due-checked-upper", url: URL(fileURLWithPath: "/tmp/due-checked-upper.md"), content: "", modifiedDate: Date())
            checkedUppercase.content = "- [X] Ship the report @04-16-26"
            check("\"[X]\" (uppercase) counts as checked too", checkedUppercase.due == nil)

            var uncheckedWithDue = Note(id: "due-unchecked", url: URL(fileURLWithPath: "/tmp/due-unchecked.md"), content: "", modifiedDate: Date())
            uncheckedWithDue.content = "- [ ] Ship the report @04-16-26"
            check("an unchecked task's due token still resolves normally", uncheckedWithDue.due == expected)

            // Completing one task shouldn't blind the whole note to a due
            // date that lives on a different, unrelated line.
            var otherLineActive = Note(id: "due-other-line", url: URL(fileURLWithPath: "/tmp/due-other-line.md"), content: "", modifiedDate: Date())
            otherLineActive.content = "- [x] Unrelated finished task\nFollow up @04-16-26"
            check("a due token on a plain (non-task) line still resolves even when another line is checked", otherLineActive.due == expected)
        }

        // noteDueReportsTheEarliestActiveDateNotTheFirstTokenInText
        do {
            let earlier = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 1))
            let later = Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 16))

            // Regression: this used to report whichever token appeared
            // first in the raw text (April, here), not the earliest date
            // (March) -- a note mentioning a later date before an earlier
            // one silently reported the less-urgent date as "the" due date.
            var laterTokenFirst = Note(id: "due-later-first", url: URL(fileURLWithPath: "/tmp/due-later-first.md"), content: "", modifiedDate: Date())
            laterTokenFirst.content = "Originally due @04-16-26, moved earlier to @03-01-26"
            check("due reports the earliest date even when a later one is mentioned first", laterTokenFirst.due == earlier)

            var singleToken = Note(id: "due-single", url: URL(fileURLWithPath: "/tmp/due-single.md"), content: "", modifiedDate: Date())
            singleToken.content = "Ship it @04-16-26"
            check("dueDateCount is 1 for a note with exactly one active due date", singleToken.dueDateCount == 1)

            check("dueDateCount is 2 for a note with two active due dates", laterTokenFirst.dueDateCount == 2)

            var noDue = Note(id: "due-none", url: URL(fileURLWithPath: "/tmp/due-none.md"), content: "", modifiedDate: Date())
            noDue.content = "Nothing due here at all."
            check("dueDateCount is 0 for a note with no due date", noDue.dueDateCount == 0)

            // A retired token (crossed out or on a checked task line)
            // shouldn't count toward dueDateCount either -- it's exactly
            // as invisible to the count as it is to `due` itself.
            var oneRetiredOneActive = Note(id: "due-one-retired", url: URL(fileURLWithPath: "/tmp/due-one-retired.md"), content: "", modifiedDate: Date())
            oneRetiredOneActive.content = "~~@01-01-26~~ moved to @04-16-26"
            check("dueDateCount only counts active tokens, not retired ones", oneRetiredOneActive.dueDateCount == 1)
            check("due still resolves to the one active token when the other is retired", oneRetiredOneActive.due == later)
        }
        // MarkdownStyler.dueTokenRanges (the click-toggle hit-testing/state
        // logic) lives in the Envy module, not EnvyCore, and isn't reachable
        // from this target — covered instead by manual testing in
        // EnvyTest.app: wrap/unwrap via click, and confirm Note.due (tested
        // above) agrees with what the pill/search show.

        // filteredDueQuerySupportsTodayOverdueAndWeekBuckets
        do {
            let store = await makeTempStore()
            let calendar = Calendar.current
            let now = Date()

            func dueToken(daysFromNow: Int) -> String {
                let date = calendar.date(byAdding: .day, value: daysFromNow, to: now) ?? now
                let comps = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "@%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
            }

            var dueToday = store.create(title: "Due Today")
            dueToday.content = dueToken(daysFromNow: 0)
            store.save(dueToday)

            var overdue = store.create(title: "Overdue Note")
            overdue.content = dueToken(daysFromNow: -1)
            store.save(overdue)

            var dueTomorrow = store.create(title: "Due Tomorrow")
            dueTomorrow.content = dueToken(daysFromNow: 1)
            store.save(dueTomorrow)

            var dueInThreeDays = store.create(title: "Due In Three Days")
            dueInThreeDays.content = dueToken(daysFromNow: 3)
            store.save(dueInThreeDays)

            var dueNextMonth = store.create(title: "Due Next Month")
            dueNextMonth.content = dueToken(daysFromNow: 20)
            store.save(dueNextMonth)

            let noDue = store.create(title: "No Due Date")

            // "tomorrow" must be a single-day window (today+1 only), not
            // "tomorrow and everything after" — the exact bug this guards
            // against would make this match dueInThreeDays/dueNextMonth too.
            let tomorrowResults = store.filtered(query: "due:tomorrow")
            check("due:tomorrow matches a note due tomorrow", tomorrowResults.contains { $0.id == dueTomorrow.id })
            check("due:tomorrow excludes a note due today", !tomorrowResults.contains { $0.id == dueToday.id })
            check("due:tomorrow excludes a note due in 3 days", !tomorrowResults.contains { $0.id == dueInThreeDays.id })
            check("due:tomorrow excludes a note due in 20 days", !tomorrowResults.contains { $0.id == dueNextMonth.id })

            let yesterdayResults = store.filtered(query: "due:yesterday")
            check("due:yesterday matches a note due yesterday", yesterdayResults.contains { $0.id == overdue.id })
            check("due:yesterday excludes a note due today", !yesterdayResults.contains { $0.id == dueToday.id })

            let todayResults = store.filtered(query: "due:today")
            check("due:today matches a note due today", todayResults.contains { $0.id == dueToday.id })
            check("due:today excludes an overdue note", !todayResults.contains { $0.id == overdue.id })

            let overdueResults = store.filtered(query: "due:overdue")
            check("due:overdue matches a note due yesterday", overdueResults.contains { $0.id == overdue.id })
            check("due:overdue excludes a note due today", !overdueResults.contains { $0.id == dueToday.id })
            check("due:overdue excludes a note with no due date", !overdueResults.contains { $0.id == noDue.id })

            // past: is a plain alias for overdue: — identical behavior.
            let pastResults = store.filtered(query: "due:past")
            check("due:past matches a note due yesterday", pastResults.contains { $0.id == overdue.id })
            check("due:past excludes a note due today", !pastResults.contains { $0.id == dueToday.id })

            // future: is the exact complement of overdue: — same threshold,
            // flipped. A note due exactly today counts as future (not yet
            // overdue), and an undated note matches neither.
            let futureResults = store.filtered(query: "due:future")
            check("due:future matches a note due today", futureResults.contains { $0.id == dueToday.id })
            check("due:future matches a note due tomorrow", futureResults.contains { $0.id == dueTomorrow.id })
            check("due:future excludes an overdue note", !futureResults.contains { $0.id == overdue.id })
            check("due:future excludes a note with no due date", !futureResults.contains { $0.id == noDue.id })

            let monthResults = store.filtered(query: "due:month")
            check("due:month matches a note due in 20 days", monthResults.contains { $0.id == dueNextMonth.id })
        }

        // dueUrgencyClassifiesOverdueSoonAndLater
        do {
            let calendar = Calendar.current
            let now = Date()

            let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
            check("a date before today is overdue", NoteStore.dueUrgency(for: yesterday, now: now) == .overdue)

            check("today itself is soon, not overdue", NoteStore.dueUrgency(for: now, now: now) == .soon)

            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!
            let lastMomentOfThisWeek = thisWeek.end.addingTimeInterval(-1)
            check("the last moment of this calendar week is still soon", NoteStore.dueUrgency(for: lastMomentOfThisWeek, now: now) == .soon)

            let nextWeekStart = thisWeek.end
            check("the moment this week ends is later, not soon", NoteStore.dueUrgency(for: nextWeekStart, now: now) == .later)

            let farFuture = calendar.date(byAdding: .month, value: 2, to: now)!
            check("a date months away is later", NoteStore.dueUrgency(for: farFuture, now: now) == .later)
        }

        // filteredDueWeekAndNextweekAreCalendarAlignedNotRolling
        do {
            let store = await makeTempStore()
            let calendar = Calendar.current
            let now = Date()

            func dueToken(at date: Date) -> String {
                let comps = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "@%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
            }

            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!
            let lastWeek = calendar.dateInterval(of: .weekOfYear, for: calendar.date(byAdding: .weekOfYear, value: -1, to: now)!)!
            let nextWeek = calendar.dateInterval(of: .weekOfYear, for: calendar.date(byAdding: .weekOfYear, value: 1, to: now)!)!

            // Deliberately not tied to "now ± N days" like the other
            // buckets — due:week is calendar-aligned (Mon–Sun or locale
            // equivalent), so a note due earlier in the current week (already
            // passed) must still count as "due this week," which a rolling
            // window wouldn't have allowed.
            var earlierThisWeek = store.create(title: "Due Earlier This Week")
            earlierThisWeek.content = dueToken(at: thisWeek.start.addingTimeInterval(3600))
            store.save(earlierThisWeek)

            var laterThisWeek = store.create(title: "Due Later This Week")
            laterThisWeek.content = dueToken(at: thisWeek.end.addingTimeInterval(-3600))
            store.save(laterThisWeek)

            var dueLastWeek = store.create(title: "Due Last Week")
            dueLastWeek.content = dueToken(at: lastWeek.end.addingTimeInterval(-3600))
            store.save(dueLastWeek)

            var dueNextWeek = store.create(title: "Due Next Week")
            dueNextWeek.content = dueToken(at: nextWeek.start.addingTimeInterval(3600))
            store.save(dueNextWeek)

            let weekResults = store.filtered(query: "due:week")
            check("due:week matches a note due earlier this calendar week", weekResults.contains { $0.id == earlierThisWeek.id })
            check("due:week matches a note due later this calendar week", weekResults.contains { $0.id == laterThisWeek.id })
            check("due:week excludes a note due last calendar week", !weekResults.contains { $0.id == dueLastWeek.id })
            check("due:week excludes a note due next calendar week", !weekResults.contains { $0.id == dueNextWeek.id })

            let nextWeekResults = store.filtered(query: "due:nextweek")
            check("due:nextweek matches a note due next calendar week", nextWeekResults.contains { $0.id == dueNextWeek.id })
            check("due:nextweek excludes a note due this calendar week", !nextWeekResults.contains { $0.id == laterThisWeek.id })
            check("due:nextweek excludes a note due last calendar week", !nextWeekResults.contains { $0.id == dueLastWeek.id })
        }

        // filteredBareDueQueryMatchesOnlyNotesWithAnyDueDate
        do {
            let store = await makeTempStore()
            var withDue = store.create(title: "Has Due Date")
            withDue.content = "@2026-08-01"
            store.save(withDue)

            let withoutDue = store.create(title: "No Due Date")

            let results = store.filtered(query: "due:")
            check("bare due: matches a note with any due date", results.contains { $0.id == withDue.id })
            check("bare due: excludes a note with no due date", !results.contains { $0.id == withoutDue.id })
        }

        // filteredInvalidDueQueryMatchesNothing
        do {
            let store = await makeTempStore()
            var withDue = store.create(title: "Has Due Date")
            withDue.content = "@2026-08-01"
            store.save(withDue)

            let withoutDue = store.create(title: "No Due Date")

            let results = store.filtered(query: "due:cats")
            check("an unrecognized due: value matches nothing, not everything", results.isEmpty)
            check("invalid due: excludes a note that does have a due date", !results.contains { $0.id == withDue.id })
            check("invalid due: excludes a note with no due date", !results.contains { $0.id == withoutDue.id })
        }

        // filteredDueQueryMatchesExactDate
        do {
            let store = await makeTempStore()
            var note = store.create(title: "Fixed Due Date")
            note.content = "@2026-04-16"
            store.save(note)

            check("due: matches an exact ISO date", store.filtered(query: "due:2026-04-16").contains { $0.id == note.id })
            check("due: excludes a non-matching exact date", !store.filtered(query: "due:2026-04-17").contains { $0.id == note.id })
        }

        // filteredExcludeDueQueryInvertsTheMatchingBucket
        do {
            let store = await makeTempStore()
            let calendar = Calendar.current
            let now = Date()

            func dueToken(daysFromNow: Int) -> String {
                let date = calendar.date(byAdding: .day, value: daysFromNow, to: now)!
                let comps = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "@%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
            }

            var overdue = store.create(title: "Overdue Note")
            overdue.content = dueToken(daysFromNow: -1)
            store.save(overdue)

            var dueToday = store.create(title: "Due Today Note")
            dueToday.content = dueToken(daysFromNow: 0)
            store.save(dueToday)

            let noDue = store.create(title: "No Due Date Note")

            let excludeOverdueResults = store.filtered(query: "-due:overdue")
            check("-due:overdue excludes an overdue note", !excludeOverdueResults.contains { $0.id == overdue.id })
            check("-due:overdue keeps a note due today", excludeOverdueResults.contains { $0.id == dueToday.id })
            check("-due:overdue keeps a note with no due date", excludeOverdueResults.contains { $0.id == noDue.id })

            let excludeAnyResults = store.filtered(query: "-due:")
            check("bare -due: excludes any note with a due date", !excludeAnyResults.contains { $0.id == overdue.id })
            check("bare -due: excludes a note due today too", !excludeAnyResults.contains { $0.id == dueToday.id })
            check("bare -due: keeps a note with no due date", excludeAnyResults.contains { $0.id == noDue.id })

            let excludeInvalidResults = store.filtered(query: "-due:cats")
            check("an unrecognized -due: value matches nothing, not everything", excludeInvalidResults.isEmpty)
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

        // applyPinningMovesOnlyPinnedNotesToFrontPreservingOrder
        do {
            let a = Note(id: "a", url: URL(fileURLWithPath: "/a.md"), content: "", modifiedDate: Date())
            let b = Note(id: "b", url: URL(fileURLWithPath: "/b.md"), content: "", modifiedDate: Date())
            let c = Note(id: "c", url: URL(fileURLWithPath: "/c.md"), content: "", modifiedDate: Date())
            let d = Note(id: "d", url: URL(fileURLWithPath: "/d.md"), content: "", modifiedDate: Date())

            let noPins = NoteStore.applyPinning([a, b, c, d], pinnedIDs: [])
            check("no pinned ids leaves order untouched", noPins.map(\.id) == ["a", "b", "c", "d"])

            let onePinned = NoteStore.applyPinning([a, b, c, d], pinnedIDs: ["c"])
            check("a single pinned note moves to the front", onePinned.map(\.id) == ["c", "a", "b", "d"])

            let twoPinned = NoteStore.applyPinning([a, b, c, d], pinnedIDs: ["d", "b"])
            check("multiple pinned notes keep their relative order at the front", twoPinned.map(\.id) == ["b", "d", "a", "c"])

            // A pinned note absent from the input (already filtered out by a
            // search that doesn't match it) simply has nothing to move —
            // pinning never reintroduces a note the search excluded.
            let filteredOut = NoteStore.applyPinning([a, d], pinnedIDs: ["c", "d"])
            check("a pinned note excluded by search filtering stays excluded", filteredOut.map(\.id) == ["d", "a"])
        }

        do {
            print("Wiki-link parsing")

            let plain = WikiLink.parse("Meeting Notes")
            check("a plain link targets and displays the same title",
                  plain.target == "Meeting Notes" && plain.display == "Meeting Notes" && plain.aliasPipeOffset == nil)

            // The point of aliases: the target keeps the filename, the
            // sentence gets readable words.
            let alias = WikiLink.parse("2026-07-18 Meeting Notes|yesterday's meeting")
            check("an alias targets the note and displays the alias",
                  alias.target == "2026-07-18 Meeting Notes" && alias.display == "yesterday's meeting")

            // Previously the whole body became the title, so this looked for
            // a note literally named "Note#Heading" and found nothing.
            let heading = WikiLink.parse("Project Plan#Milestones")
            check("a heading reference resolves to the note",
                  heading.target == "Project Plan")
            check("a heading reference still shows the heading it meant",
                  heading.display == "Project Plan#Milestones")

            let both = WikiLink.parse("Project Plan#Milestones|the milestones")
            check("an alias wins over the heading for display text",
                  both.target == "Project Plan" && both.display == "the milestones")

            let padded = WikiLink.parse("  Spaced Note  |  Shown  ")
            check("surrounding whitespace is trimmed from both halves",
                  padded.target == "Spaced Note" && padded.display == "Shown")

            // An empty alias is a typo, not an instruction to render nothing.
            let emptyAlias = WikiLink.parse("Real Note|")
            check("an empty alias falls back to the target",
                  emptyAlias.target == "Real Note" && emptyAlias.display == "Real Note")

            let note = Note(
                id: "n",
                url: URL(fileURLWithPath: "/tmp/Referrer.md"),
                content: "see [[Real Note|an alias]] and [[Other#Section]]",
                modifiedDate: Date()
            )
            check("wikiLinks records targets, not raw link bodies",
                  note.wikiLinks == ["real note", "other"])
        }

        do {
            print("Inbox filtering")

            func note(_ title: String, in folder: String?, content: String = "") -> Note {
                var url = URL(fileURLWithPath: "/tmp/TheIndex")
                if let folder { url.appendPathComponent(folder) }
                url.appendPathComponent("\(title).md")
                return Note(id: url.path, url: url, content: content, modifiedDate: Date())
            }

            let filed = note("Filed thought", in: nil, content: "about bauhaus")
            let fleetingA = note("Fleeting one", in: "Inbox", content: "about bauhaus")
            let fleetingB = note("Fleeting two", in: "Inbox", content: "about lunch")
            let all = [filed, fleetingA, fleetingB]

            let inboxOnly = NoteStore.filtered(all, query: "inbox:")
            check("inbox: returns only notes in the Inbox folder",
                  Set(inboxOnly.map(\.title)) == ["Fleeting one", "Fleeting two"])

            // The words after the operator are ordinary search text, scoped
            // to the box — the same shape tag:/due: already have.
            let narrowed = NoteStore.filtered(all, query: "inbox: bauhaus")
            check("inbox: narrows by trailing search text",
                  narrowed.map(\.title) == ["Fleeting one"])

            let excluded = NoteStore.filtered(all, query: "-inbox:")
            check("-inbox: hides fleeting notes",
                  excluded.map(\.title) == ["Filed thought"])

            // Membership is the folder, not a flag in the file — so moving a
            // note out in Finder files it exactly as Submit does.
            check("membership follows the folder, not the note's text",
                  NoteStore.isInInboxFolder(fleetingA) && !NoteStore.isInInboxFolder(filed))

            // The "hide from the main list" preference is applied on top of
            // the search, and must never win over an explicit inbox: query.
            func visible(_ query: String, showInbox: Bool) -> [String] {
                var out = NoteStore.filtered(all, query: query)
                if !showInbox, !query.lowercased().contains("inbox:") {
                    out = out.filter { !NoteStore.isInInboxFolder($0) }
                }
                return out.map(\.title)
            }
            check("hiding fleeting notes keeps them out of an ordinary search",
                  visible("bauhaus", showInbox: false) == ["Filed thought"])
            check("hiding them never overrides an explicit inbox: query",
                  Set(visible("inbox:", showInbox: false)) == ["Fleeting one", "Fleeting two"])
            check("showing them leaves ordinary searches untouched",
                  Set(visible("bauhaus", showInbox: true)) == ["Filed thought", "Fleeting one"])

            let plain = NoteStore.filtered(all, query: "bauhaus")
            check("an ordinary search still reaches fleeting notes",
                  Set(plain.map(\.title)) == ["Filed thought", "Fleeting one"])
        }

        do {
            print("Search operators")

            func note(_ title: String, _ content: String) -> Note {
                Note(id: title, url: URL(fileURLWithPath: "/tmp/\(title).md"), content: content, modifiedDate: Date())
            }
            func titles(_ query: String, _ notes: [Note]) -> Set<String> {
                Set(NoteStore.filtered(notes, query: query).map(\.title))
            }

            // --- quoted phrases ---
            let a = note("A", "the dog ate the bone")
            let b = note("B", "the bone was near the dog")
            let both = [a, b]
            check("unquoted words match either order",
                  titles("dog bone", both) == ["A", "B"])
            check("a quoted phrase forces adjacency",
                  titles("\"dog ate\"", both) == ["A"])
            check("a quoted phrase absent everywhere matches nothing",
                  titles("\"ate near\"", both).isEmpty)
            // An unterminated quote — a phrase still being typed — searches
            // as the text so far rather than for a literal quote character,
            // so results appear as you go.
            check("an open quote still matches incrementally",
                  titles("\"do", both) == ["A", "B"])
            check("an open quote tightens adjacency as you type",
                  titles("\"dog a", both) == ["A"])

            // Closed = exact word; open = substring. The whole point of the
            // open/closed distinction.
            let c = note("C", "this is needed")
            let words = [a, c]  // A: "the dog ate the bone", C: "this is needed"
            check("a closed quote matches only the whole word",
                  titles("\"nee\"", words).isEmpty)
            check("an open quote still substring-matches mid-word",
                  titles("\"nee", words) == ["C"])
            check("a closed quote matches the exact word",
                  titles("\"needed\"", words) == ["C"])
            check("-\"word\" excludes on the whole word",
                  titles("is -\"needed\"", words) == [])  // only C has "is", and it's excluded
            check("-\"phrase\" excludes the adjacent match",
                  titles("dog -\"dog ate\"", both) == ["B"])

            // --- link: ---
            let hub = note("Hub", "see [[Meeting Notes]] and [[Ideas]]")
            let leaf = note("Leaf", "just [[Ideas]]")
            let lonely = note("Lonely", "nothing here")
            let graph = [hub, leaf, lonely]
            check("link: finds notes containing that wiki-link",
                  titles("link:Ideas", graph) == ["Hub", "Leaf"])
            check("link: takes a quoted multi-word title",
                  titles("link:\"Meeting Notes\"", graph) == ["Hub"])
            check("-link: excludes notes containing that link",
                  titles("-link:Ideas", graph) == ["Lonely"])

            // --- orphan: ---
            // "Meeting Notes" and "Ideas" are linked-to; Hub and Leaf link
            // out. Lonely does neither — the only orphan here. A note that
            // is linked-to but links nowhere is not an orphan.
            let target = note("Ideas", "content")
            let orphanSet = [hub, leaf, lonely, target]
            check("orphan: finds notes with no links in or out",
                  titles("orphan:", orphanSet) == ["Lonely"])
            check("linked: is everything except the orphans",
                  titles("linked:", orphanSet) == ["Hub", "Leaf", "Ideas"])
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
