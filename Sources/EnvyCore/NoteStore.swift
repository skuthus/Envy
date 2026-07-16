import Foundation
import Combine
import CoreServices

/// A template is just a plain `.md` file living in a `Templates`
/// subfolder of one of the configured notes folders — never a Note itself,
/// since scanDirectories() only reads `.md` files directly inside each
/// top-level folder and never recurses, so `Templates/` is already
/// invisible to search/list/backlinks without any extra exclusion logic.
public struct NoteTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    /// The notes folder this template's `Templates/` subfolder belongs to
    /// — a note created from this template lands here, not necessarily in
    /// `defaultDirectory`, so per-folder templates keep their notes
    /// together with the template that made them.
    public let sourceDirectory: URL
}

@MainActor
public final class NoteStore: ObservableObject {
    @Published public private(set) var notes: [Note] = []
    @Published public private(set) var noteDirectories: [URL] = []
    @Published public private(set) var isLoading = false

    // FSEventStreamRef (an OpaquePointer) isn't Sendable, which the compiler
    // otherwise flags on the nonisolated deinit below — safe in practice since
    // every mutation happens on the main actor, and deinit only runs once
    // nothing else can be concurrently touching it.
    nonisolated(unsafe) private var eventStream: FSEventStreamRef?
    private var suppressReloadUntil: Date = .distantPast
    private var reloadGeneration = 0
    private var reloadDebounceTask: Task<Void, Never>?

    public init(directories: [URL]? = nil) {
        let dirs = (directories?.isEmpty == false) ? directories! : [Self.defaultDirectory()]
        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Resolved once here (after creation, so resolution has something to
        // resolve against) so every note's id/url and the FSEvents watch below
        // consistently agree on one path form — see the note on
        // startWatchingAll for why a mismatch there is a real problem, not
        // just a cosmetic one.
        self.noteDirectories = dirs.map { $0.resolvingSymlinksInPath() }
        reload()
        startWatchingAll()
    }

    deinit {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
    }

    public static func defaultDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Envy", isDirectory: true)
    }

    /// New notes are created in the first configured folder.
    public var defaultDirectory: URL {
        noteDirectories.first ?? Self.defaultDirectory()
    }

    /// Re-points this store at a different set of folders without recreating it,
    /// so SwiftUI views holding onto the store (and their selection state) don't
    /// have to be torn down just to look at a different set of notes.
    public func setDirectories(_ directories: [URL]) {
        let normalized = directories.isEmpty ? [Self.defaultDirectory()] : directories
        for dir in normalized {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let resolved = normalized.map { $0.resolvingSymlinksInPath() }
        guard resolved != noteDirectories else { return }
        stopWatchingAll()
        noteDirectories = resolved
        reload()
        startWatchingAll()
    }

    // MARK: - Loading

    /// Coalesces bursts of FSEvents callbacks (many files changing in a short
    /// window — an external sync client, a git pull, a bulk import) into a
    /// single reload() once things settle, instead of kicking off a brand
    /// new full-folder scan for every individual callback. FSEventStream's
    /// own 0.3s latency already batches *rapid* changes into fewer
    /// callbacks, but a burst spread across more than that window still
    /// produced several overlapping scans in practice — each one a real,
    /// full read-every-file pass with a few thousand notes, and each
    /// briefly flipping isLoading (and the loading indicator) on and off.
    private func reloadDebounced() {
        reloadDebounceTask?.cancel()
        reloadDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    /// Scans all configured folders and re-publishes `notes`. The actual file
    /// reading happens off the main thread — with a folder full of notes, doing
    /// this synchronously on the main actor (as this used to) froze the UI.
    public func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let directories = noteDirectories
        isLoading = true

        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.scanDirectories(directories)
            }.value

            // A newer reload may have been kicked off (e.g. folders changed
            // again) while this scan was in flight — don't clobber its result.
            guard generation == self.reloadGeneration else { return }
            self.notes = loaded
            self.isLoading = false
        }
    }

    // A plain UnsafeMutableBufferPointer isn't Sendable as far as the
    // compiler's concerned, even though writing to disjoint, fixed indices
    // from multiple threads (as scanDirectories does below) is genuinely
    // safe — this box exists purely to make that assertion explicit and
    // contained in one place, rather than silencing the warning at the call
    // site.
    private struct UnsafeParallelWriteBox<T>: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<T>
    }

    nonisolated private static func scanDirectories(_ directories: [URL]) -> [Note] {
        let fm = FileManager.default
        var mdURLs: [URL] = []

        for directory in directories {
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            mdURLs.append(contentsOf: entries.filter { $0.pathExtension.lowercased() == "md" })
        }
        // Reassigned as a `let` before the concurrent section below —
        // Swift 6 flags capturing a `var` in concurrently-executing code
        // even for read-only access, since it can't prove no one mutates
        // it meanwhile; this one in particular never is past this point.
        let urls = mdURLs

        // Reading each file is its own independent syscall (open/read/close),
        // and doing that one file at a time in a loop means paying each
        // file's latency serially — measured as the dominant cost of a
        // reload with several thousand notes (over a second for 10,000
        // files on a fast local disk, confirmed independent of anything
        // else this function does). concurrentPerform reads them in
        // parallel across the available cores instead. Each iteration only
        // ever writes to its own distinct index, so the concurrent writes
        // below need no locking — Swift's Array isn't safe for concurrent
        // mutation via its normal API, but writing through an unsafe
        // buffer pointer at disjoint, fixed offsets is.
        var results = [Note?](repeating: nil, count: urls.count)
        results.withUnsafeMutableBufferPointer { rawBuffer in
            let box = UnsafeParallelWriteBox(buffer: rawBuffer)
            DispatchQueue.concurrentPerform(iterations: urls.count) { index in
                let url = urls[index]
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                // Filename alone isn't unique across multiple folders, so the id
                // has to be the full path.
                box.buffer[index] = Note(id: url.path, url: url, content: content, modifiedDate: modified)
            }
        }

        return results.compactMap { $0 }.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    // MARK: - Watching for external changes

    /// Uses FSEvents (not a plain DispatchSourceFileSystemObject watching each
    /// directory's own file descriptor) specifically because the latter only
    /// reports a directory's *entry list* changing — a file being added,
    /// removed, or renamed within it — and stays silent when an existing
    /// file's content is overwritten in place (confirmed with a standalone
    /// test: a plain `open`+`write`+`close` from another process produced no
    /// event at all, while a write-to-temp-then-rename-over-original did).
    /// Since another app editing one of these notes in place is exactly the
    /// case this needs to catch, FSEvents' kFSEventStreamCreateFlagFileEvents
    /// mode is required — it reports individual file modifications, not just
    /// directory-entry churn.
    private func startWatchingAll() {
        guard !noteDirectories.isEmpty else { return }
        // noteDirectories is already resolved (see init/setDirectories) — both
        // so FSEvents watches the real underlying path (a path that traverses
        // a symlink, like anything under /tmp or /var, silently fails to
        // watch correctly otherwise) and so every note's id/url agrees with
        // what a later reload() reports for the same file, symlink or not.
        let paths = noteDirectories.map(\.path) as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, _, eventFlags, _ in
                guard let info else { return }
                let store = Unmanaged<NoteStore>.fromOpaque(info).takeUnretainedValue()

                // Spotlight indexing a batch of newly-created/changed files
                // writes its own extended attributes and inode metadata,
                // which FSEvents reports as file-changed events — in the
                // FileEvents flags alone, indistinguishable from a real
                // edit unless inspected. A bulk import was seen producing
                // dozens of these metadata-only events over ~20 seconds
                // after the actual writes finished, each triggering a full
                // reload. Only the flags that mean the file's content or
                // existence itself changed should actually trigger one.
                let meaningfulFlags = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                        | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified
                )
                let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
                guard flags.contains(where: { $0 & meaningfulFlags != 0 }) else { return }

                Task { @MainActor in
                    if Date() < store.suppressReloadUntil { return }
                    store.reloadDebounced()
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func stopWatchingAll() {
        guard let eventStream else { return }
        FSEventStreamStop(eventStream)
        FSEventStreamInvalidate(eventStream)
        FSEventStreamRelease(eventStream)
        self.eventStream = nil
    }

    /// Internal writes trigger the same FS events as external changes; suppress
    /// a brief reload window right after we write so we don't stomp in-memory
    /// edits the user is mid-typing with a redundant reload from disk. Also bumps
    /// the reload generation so a reload already in flight (e.g. the initial scan
    /// at launch) can't land afterward and clobber this fresh direct mutation with
    /// the stale disk state it captured before the write happened.
    private func markInternalWrite() {
        suppressReloadUntil = Date().addingTimeInterval(0.5)
        reloadGeneration += 1
    }

    /// Public wrapper around markInternalWrite(), for callers writing
    /// directly to a file inside a watched folder that NoteStore doesn't
    /// itself have a CRUD method for — a template's own save, in
    /// particular, which writes straight to disk from TemplateEditorView
    /// rather than through this class.
    public func suppressReloadForExternalWrite() {
        markInternalWrite()
    }

    // MARK: - CRUD

    @discardableResult
    public func create(title: String) -> Note {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        let directory = defaultDirectory
        let filename = Self.uniqueFilename(for: base, in: directory)
        let url = directory.appendingPathComponent(filename)

        markInternalWrite()
        try? "".write(to: url, atomically: true, encoding: .utf8)

        let note = Note(id: url.path, url: url, content: "", modifiedDate: Date())
        notes.insert(note, at: 0)
        return note
    }

    /// Every template across the given folders' own `Templates/`
    /// subfolders — `includeAllFolders: false` limits this to
    /// `defaultDirectory` only, for a "one shared Templates folder"
    /// setup; `true` merges every configured folder's own `Templates/`,
    /// for a per-folder setup.
    public func templates(includeAllFolders: Bool) -> [NoteTemplate] {
        let directories = includeAllFolders ? noteDirectories : [defaultDirectory]
        var results: [NoteTemplate] = []
        for directory in directories {
            let templatesDirectory = directory.appendingPathComponent("Templates", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: templatesDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension.lowercased() == "md" {
                let name = url.deletingPathExtension().lastPathComponent
                results.append(NoteTemplate(id: url.path, name: name, url: url, sourceDirectory: directory))
            }
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Creates a new, empty template file in defaultDirectory's own
    /// `Templates/` subfolder — always defaultDirectory regardless of
    /// includeAllFolders scope, same as create(title:) always landing new
    /// notes there too.
    @discardableResult
    public func createTemplate(named name: String) -> NoteTemplate {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedName.isEmpty ? "Untitled Template" : trimmedName
        let directory = defaultDirectory
        let templatesDirectory = directory.appendingPathComponent("Templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        let filename = Self.uniqueFilename(for: base, in: templatesDirectory)
        let url = templatesDirectory.appendingPathComponent(filename)
        markInternalWrite()
        try? "".write(to: url, atomically: true, encoding: .utf8)
        return NoteTemplate(id: url.path, name: url.deletingPathExtension().lastPathComponent, url: url, sourceDirectory: directory)
    }

    /// Creates a note whose starting content is `template`'s content, with
    /// {{date}}/{{time}}/{{title}} substituted in — lands in the
    /// template's own sourceDirectory. The title itself gets the same
    /// substitution before it's used, so a template literally named e.g.
    /// "Daily Notes {{date}}" produces a note titled with today's actual
    /// date, not the literal token. `dateText` is caller-formatted (rather
    /// than a fixed style here) so the app layer's own date-format setting
    /// applies — EnvyCore stays platform/UI-agnostic and doesn't own a
    /// preferred date style itself.
    @discardableResult
    public func create(title: String, fromTemplate template: NoteTemplate, dateText: String) -> Note {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBase = trimmedTitle.isEmpty ? template.name : trimmedTitle
        let base = Self.applyingTemplateTokens(rawBase, title: rawBase, dateText: dateText)
        let directory = template.sourceDirectory
        let filename = Self.uniqueFilename(for: base, in: directory)
        let url = directory.appendingPathComponent(filename)

        let rawContent = (try? String(contentsOf: template.url, encoding: .utf8)) ?? ""
        let content = Self.applyingTemplateTokens(rawContent, title: base, dateText: dateText)

        markInternalWrite()
        try? content.write(to: url, atomically: true, encoding: .utf8)

        let note = Note(id: url.path, url: url, content: content, modifiedDate: Date())
        notes.insert(note, at: 0)
        return note
    }

    /// Moves a note's file into its own folder's `Templates/` subfolder,
    /// dropping it out of `notes` in the process — the same underlying
    /// operation move(_:to:) already does, just always targeting
    /// `<current folder>/Templates` instead of another configured folder.
    @discardableResult
    public func convertToTemplate(_ note: Note) -> NoteTemplate? {
        let currentDirectory = note.url.deletingLastPathComponent()
        let templatesDirectory = currentDirectory.appendingPathComponent("Templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        let filename = Self.uniqueFilename(for: note.title, in: templatesDirectory)
        let newURL = templatesDirectory.appendingPathComponent(filename)

        markInternalWrite()
        do {
            try FileManager.default.moveItem(at: note.url, to: newURL)
        } catch {
            return nil
        }
        notes.removeAll { $0.id == note.id }
        return NoteTemplate(id: newURL.path, name: newURL.deletingPathExtension().lastPathComponent, url: newURL, sourceDirectory: currentDirectory)
    }

    /// The inverse of convertToTemplate(_:) — moves a template's file back
    /// up out of its `Templates/` subfolder into sourceDirectory (the
    /// folder it was made from), or defaultDirectory if sourceDirectory is
    /// no longer one of the currently configured folders (removed in
    /// Settings since the template was created).
    @discardableResult
    public func convertToNote(_ template: NoteTemplate) -> Note? {
        let targetDirectory = noteDirectories.contains(template.sourceDirectory) ? template.sourceDirectory : defaultDirectory
        let filename = Self.uniqueFilename(for: template.name, in: targetDirectory)
        let newURL = targetDirectory.appendingPathComponent(filename)

        markInternalWrite()
        do {
            try FileManager.default.moveItem(at: template.url, to: newURL)
        } catch {
            return nil
        }
        let content = (try? String(contentsOf: newURL, encoding: .utf8)) ?? ""
        let note = Note(id: newURL.path, url: newURL, content: content, modifiedDate: Date())
        notes.insert(note, at: 0)
        return note
    }

    /// A small fixed set of tokens — plain string replacement, not any
    /// kind of scripting, so a template stays a plain markdown file
    /// readable by any other editor too.
    private static func applyingTemplateTokens(_ content: String, title: String, dateText: String) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        return content
            .replacingOccurrences(of: "{{date}}", with: dateText)
            .replacingOccurrences(of: "{{time}}", with: timeFormatter.string(from: Date()))
            .replacingOccurrences(of: "{{title}}", with: title)
    }

    public func save(_ note: Note) {
        markInternalWrite()
        try? note.content.write(to: note.url, atomically: true, encoding: .utf8)
        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx].content = note.content
            notes[idx].modifiedDate = Date()
        }
    }

    /// The most recently deleted note(s) — a single delete or a whole bulk
    /// delete counts as one "action" for undo purposes, so this holds
    /// everything from the last call to `delete(_:)` together, not a full
    /// history stack. Replaced (not appended to) by the next delete, and
    /// cleared once restored.
    private var lastDeleted: [(note: Note, trashedURL: URL)] = []

    public var canRestoreLastDeleted: Bool { !lastDeleted.isEmpty }

    public func delete(_ note: Note) {
        delete([note])
    }

    public func delete(_ notesToDelete: [Note]) {
        guard !notesToDelete.isEmpty else { return }
        markInternalWrite()
        var trashed: [(note: Note, trashedURL: URL)] = []
        for note in notesToDelete {
            var resultingURL: NSURL?
            // trashItem's resultingItemURL is the *actual* on-disk location
            // in Trash, which may differ from a naive guess (macOS renames
            // on a filename collision there) — capturing it is what makes
            // restoring back to the exact right place possible.
            if (try? FileManager.default.trashItem(at: note.url, resultingItemURL: &resultingURL)) != nil,
               let trashedURL = resultingURL as URL? {
                trashed.append((note, trashedURL))
            }
        }
        lastDeleted = trashed
        let deletedIDs = Set(notesToDelete.map(\.id))
        notes.removeAll { deletedIDs.contains($0.id) }
    }

    /// Moves the most recently deleted note(s) back out of Trash to their
    /// original location and re-adds them to `notes`. A note whose original
    /// location has since been reused (e.g. a new note created with the same
    /// filename) is silently skipped rather than overwriting it.
    @discardableResult
    public func restoreLastDeleted() -> [Note] {
        guard !lastDeleted.isEmpty else { return [] }
        markInternalWrite()
        var restored: [Note] = []
        for (note, trashedURL) in lastDeleted {
            guard !FileManager.default.fileExists(atPath: note.url.path) else { continue }
            do {
                try FileManager.default.moveItem(at: trashedURL, to: note.url)
                restored.append(note)
            } catch {
                continue
            }
        }
        lastDeleted = []
        notes.append(contentsOf: restored)
        return restored
    }

    /// Renames the note by moving its underlying file to a new filename derived
    /// from `newTitle`, within whichever folder it already lives in. Returns the
    /// original note unchanged if the title is empty, identical, or the move fails.
    @discardableResult
    public func rename(_ note: Note, to newTitle: String) -> Note {
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle != note.title else { return note }

        let directory = note.url.deletingLastPathComponent()
        let newFilename = Self.uniqueFilename(for: trimmedTitle, in: directory)
        let newURL = directory.appendingPathComponent(newFilename)

        markInternalWrite()
        do {
            try FileManager.default.moveItem(at: note.url, to: newURL)
        } catch {
            return note
        }

        let renamed = Note(id: newURL.path, url: newURL, content: note.content, modifiedDate: Date())
        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx] = renamed
        }
        return renamed
    }

    /// Moves the note's underlying file into a different configured folder,
    /// keeping its title (de-duped against whatever's already there). Returns
    /// the original note unchanged if it's already in that folder or the move fails.
    @discardableResult
    public func move(_ note: Note, to directory: URL) -> Note {
        let currentDirectory = note.url.deletingLastPathComponent()
        guard currentDirectory != directory else { return note }

        let newFilename = Self.uniqueFilename(for: note.title, in: directory)
        let newURL = directory.appendingPathComponent(newFilename)

        markInternalWrite()
        do {
            try FileManager.default.moveItem(at: note.url, to: newURL)
        } catch {
            return note
        }

        let moved = Note(id: newURL.path, url: newURL, content: note.content, modifiedDate: Date())
        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx] = moved
        }
        return moved
    }

    // MARK: - Search

    /// Called from ContentView's body on every render while a query is
    /// typed, so it reads the cached lowercased title rather than
    /// re-lowercasing every note's title (a fresh string allocation per
    /// note per keystroke) just to compare it.
    public func exactTitleMatch(for query: String) -> Note? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        return notes.first { $0.lowercasedTitle == q }
    }

    // Swift's native String.contains(_:) does a Unicode-correct,
    // grapheme-cluster-aware scan, which is dramatically slower than it
    // needs to be for a simple case-insensitive substring search over a
    // few thousand notes' worth of already-lowercased content — measured
    // at 200ms+ per keystroke over 10,000 notes. NSString.range(of:)
    // uses ICU's own optimized search and is an order of magnitude
    // faster for the same check. The bridge to NSString is O(1)
    // (copy-on-write, no copy) since these strings are never mutated
    // here, so there's no cost to doing it inline per call.
    nonisolated private static func fastContains(_ haystack: String, _ needle: String) -> Bool {
        (haystack as NSString).range(of: needle).location != NSNotFound
    }

    /// Comma-separated groups are independent searches, OR'd together —
    /// "dog, bone, leash" means anything matching any one of the three;
    /// "dog bone leash" (no comma) is one group, the existing
    /// match-every-term-somewhere behavior, completely unchanged for a
    /// query that never had commas in it to begin with. A note matching
    /// more than one group keeps whichever group's score ranked it higher.
    public func filtered(query: String) -> [Note] {
        Self.filtered(notes, query: query)
    }

    /// The full search over an explicit snapshot, callable from off the
    /// main actor — with a large library the scan-and-rank is real work
    /// (the first typed character matches nearly everything), and running
    /// it on the main thread visibly delayed the keystrokes queued behind
    /// it. The UI captures `notes` and runs this on a background task,
    /// assigning only the result back on the main actor.
    nonisolated public static func filtered(_ notes: [Note], query: String) -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return notes }

        let groups = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !groups.isEmpty else { return notes }

        if groups.count == 1 {
            return matched(in: notes, forGroup: groups[0]).sorted(by: rankedHigherFirst).map(\.0)
        }

        var bestScoreByID: [String: Int] = [:]
        var noteByID: [String: Note] = [:]
        for group in groups {
            for (note, score) in matched(in: notes, forGroup: group) {
                noteByID[note.id] = note
                bestScoreByID[note.id] = max(bestScoreByID[note.id] ?? Int.min, score)
            }
        }
        return noteByID.values
            .map { ($0, bestScoreByID[$0.id] ?? 0) }
            .sorted(by: rankedHigherFirst)
            .map(\.0)
    }

    nonisolated private static func rankedHigherFirst(_ lhs: (Note, Int), _ rhs: (Note, Int)) -> Bool {
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.modifiedDate > rhs.0.modifiedDate
    }

    /// One comma-separated group's own self-contained search — operators
    /// (tag:/date:/folder:/todo:), exclusions (-word, -tag:x, -folder:x),
    /// and free terms all combine with AND semantics *within* a group,
    /// same as the whole query used to before groups existed. Returns
    /// (Note, score) pairs for whatever survives every filter in this group.
    nonisolated private static func matched(in notes: [Note], forGroup group: String) -> [(Note, Int)] {
        let q = group.lowercased()
        let tokens = q.split(separator: " ").map(String.init).filter { !$0.isEmpty }

        var tagFilter: String?
        var excludeTags: [String] = []
        var dateFilter: (start: Date, end: Date)?
        var dueFilter: (start: Date, end: Date)?
        var isDueOverdueOnly = false
        var isDueFutureOnly = false
        var isDueAnyOnly = false
        var isDueInvalid = false
        var dueTokenSeen = false
        var folderFilter: String?
        var excludeFolders: [String] = []
        var isTodoOnly = false
        var excludeTerms: [String] = []
        var freeTerms: [String] = []

        // Only the first tag:/date:/folder: token is honored if more than
        // one of the same kind appears — combining multiple has ambiguous
        // AND-vs-OR semantics not worth guessing at (that's what the comma
        // groups above are for). Every "-"-prefixed exclusion is honored,
        // though — there's no such ambiguity in excluding more than one thing.
        for token in tokens {
            if token == "todo:" {
                isTodoOnly = true
            } else if token.hasPrefix("-tag:") {
                let name = String(token.dropFirst("-tag:".count))
                if !name.isEmpty { excludeTags.append(name) }
            } else if token.hasPrefix("tag:") {
                if tagFilter == nil {
                    let name = String(token.dropFirst("tag:".count))
                    tagFilter = name.isEmpty ? nil : name
                }
            } else if token.hasPrefix("-folder:") {
                let name = String(token.dropFirst("-folder:".count))
                if !name.isEmpty { excludeFolders.append(name) }
            } else if token.hasPrefix("folder:") {
                if folderFilter == nil {
                    let name = String(token.dropFirst("folder:".count))
                    folderFilter = name.isEmpty ? nil : name
                }
            } else if token.hasPrefix("date:") {
                if dateFilter == nil {
                    dateFilter = Self.dateRange(for: String(token.dropFirst("date:".count)))
                }
            } else if token.hasPrefix("due:") {
                // "overdue" isn't a [start, end) window like the other
                // buckets — it's "due before today," open-ended — so it's
                // its own flag rather than something dueRange(for:) could
                // express. A bare "due:" (no value) means "has a due date
                // at all" — same shape as "todo:" meaning "has an unchecked
                // task."
                //
                // Unlike date:, an unrecognized value here (not empty, not
                // "overdue", not a bucket, not a parseable date — "due:cats")
                // means "match nothing," not "no filter, show everything."
                // date:'s own fallback intentionally treats an unrecognized
                // bucket as "show everything" so a typo doesn't dump you
                // into a confusing empty list — but "due:cats" isn't a typo
                // of a real bucket, it's simply invalid, and silently
                // matching every note (due or not) hides that rather than
                // surfacing it.
                if !dueTokenSeen {
                    dueTokenSeen = true
                    let value = String(token.dropFirst("due:".count))
                    if value.isEmpty {
                        isDueAnyOnly = true
                    } else if value == "overdue" || value == "past" {
                        // "past" is a plain alias for "overdue" — same
                        // meaning, different word for anyone who reaches
                        // for past/future as the natural opposite pair
                        // rather than overdue/future.
                        isDueOverdueOnly = true
                    } else if value == "future" {
                        // The exact complement of "overdue" — due today or
                        // later, same threshold, flipped comparison. Like
                        // overdue, a note with no due date matches neither:
                        // "future" isn't "undated," it's "dated and not
                        // yet due."
                        isDueFutureOnly = true
                    } else if let range = Self.dueRange(for: value) {
                        dueFilter = range
                    } else {
                        isDueInvalid = true
                    }
                }
            } else if token.hasPrefix("-"), token.count > 1 {
                excludeTerms.append(String(token.dropFirst()))
            } else {
                freeTerms.append(token)
            }
        }

        let hasOperator = isTodoOnly || tagFilter != nil || !excludeTags.isEmpty
            || dateFilter != nil || folderFilter != nil || !excludeFolders.isEmpty
            || dueFilter != nil || isDueOverdueOnly || isDueFutureOnly || isDueAnyOnly || isDueInvalid

        // Computed once for the whole group rather than per-note — same
        // reasoning as dateRange's own `now`, just needing today's start
        // rather than the current instant.
        let overdueThreshold = Calendar.current.startOfDay(for: Date())

        return notes.compactMap { note -> (Note, Int)? in
            if isTodoOnly, !note.hasUncheckedTask { return nil }
            if let tagFilter, !note.tags.contains(where: { Self.fastContains($0, tagFilter) }) { return nil }
            if !excludeTags.isEmpty, note.tags.contains(where: { tag in excludeTags.contains { Self.fastContains(tag, $0) } }) { return nil }
            if let dateFilter, !(note.modifiedDate >= dateFilter.start && note.modifiedDate < dateFilter.end) { return nil }
            if isDueInvalid { return nil }
            if isDueAnyOnly, note.due == nil { return nil }
            if isDueOverdueOnly, !(note.due.map { $0 < overdueThreshold } ?? false) { return nil }
            if isDueFutureOnly, !(note.due.map { $0 >= overdueThreshold } ?? false) { return nil }
            if let dueFilter, !(note.due.map { $0 >= dueFilter.start && $0 < dueFilter.end } ?? false) { return nil }
            if let folderFilter, !Self.fastContains(note.folderName.lowercased(), folderFilter) { return nil }
            if !excludeFolders.isEmpty, excludeFolders.contains(where: { Self.fastContains(note.folderName.lowercased(), $0) }) { return nil }
            if !excludeTerms.isEmpty {
                let titleLower = note.lowercasedTitle
                let contentLower = note.lowercasedContent
                if excludeTerms.contains(where: { Self.fastContains(titleLower, $0) || Self.fastContains(contentLower, $0) }) { return nil }
            }

            // An operator (or 2+ free terms) combines with whatever else is
            // typed alongside it via "does every term show up somewhere"
            // scoring — matches original behavior exactly, including that
            // scoreByTermPresence already treats an empty terms list as an
            // automatic 0-score match (a pure operator query like "todo:"
            // with nothing else to search for).
            if hasOperator || freeTerms.count > 1 {
                return Self.scoreByTermPresence(note: note, terms: freeTerms).map { (note, $0) }
            }
            guard let term = freeTerms.first else { return (note, 0) }

            // A single free term, no operators — the original scored
            // exact/prefix/contains ranking.
            let titleLower = note.lowercasedTitle
            let contentLower = note.lowercasedContent
            let score: Int
            if titleLower == term {
                score = 4
            } else if titleLower.hasPrefix(term) {
                score = 3
            } else if Self.fastContains(titleLower, term) {
                score = 2
            } else if Self.fastContains(contentLower, term) {
                score = 1
            } else {
                return nil
            }
            return (note, score)
        }
    }

    /// Number of the given terms found in the note's title (used to rank
    /// results when several notes all match), or nil if any term is missing
    /// from both title and content entirely. An empty terms list always
    /// "matches" with a score of 0 — used when a tag:/date: filter has no
    /// free text alongside it.
    nonisolated private static func scoreByTermPresence(note: Note, terms: [String]) -> Int? {
        guard !terms.isEmpty else { return 0 }
        let titleLower = note.lowercasedTitle
        let contentLower = note.lowercasedContent
        var titleMatches = 0
        for term in terms {
            let inTitle = fastContains(titleLower, term)
            guard inTitle || fastContains(contentLower, term) else { return nil }
            if inTitle { titleMatches += 1 }
        }
        return titleMatches
    }

    // MARK: - Date search

    /// The [start, end) window a "date:" query resolves to — a single
    /// calendar day for an exact date or "today"/"yesterday", or a rolling
    /// window ending now for "week"/"month". nil for anything unrecognized,
    /// which filtered(query:) treats as "show everything" rather than
    /// silently returning zero results for a typo.
    nonisolated private static func dateRange(for dateQuery: String) -> (start: Date, end: Date)? {
        guard !dateQuery.isEmpty else { return nil }
        let calendar = Calendar.current
        let now = Date()

        switch dateQuery {
        case "today":
            let start = calendar.startOfDay(for: now)
            return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? now)
        case "yesterday":
            let todayStart = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
            return (start, todayStart)
        case "week":
            return (calendar.date(byAdding: .day, value: -7, to: now) ?? now, now)
        case "month":
            return (calendar.date(byAdding: .day, value: -30, to: now) ?? now, now)
        default:
            guard let components = parseFlexibleDate(dateQuery), let start = calendar.date(from: components) else { return nil }
            return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        }
    }

    /// Coloring/urgency buckets for a due date — deliberately reuses the
    /// exact same "current calendar week" window due:week resolves to
    /// (via dueRange(for: "week") below), rather than inventing a separate
    /// "soon" threshold: a due-soon color that disagreed with what
    /// due:week actually returned would be its own confusing bug, the same
    /// class as due:week itself disagreeing with date:week earlier.
    public enum DueUrgency: Sendable, Equatable {
        case overdue
        case soon
        case later
    }

    /// `now` is a parameter (not always the live Date()) so this stays
    /// testable without mocking the system clock.
    nonisolated public static func dueUrgency(for date: Date, now: Date = Date()) -> DueUrgency {
        let calendar = Calendar.current
        if date < calendar.startOfDay(for: now) { return .overdue }
        if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now), date < thisWeek.end { return .soon }
        return .later
    }

    /// The [start, end) window a "due:" bucket resolves to. Deliberately its
    /// own function rather than reusing dateRange(for:) above: date:week/
    /// date:month look *backward* from now (the last 7/30 days) because
    /// modifiedDate is naturally in the past — "recently edited." A due
    /// date is naturally in the *future* — something upcoming you're
    /// working toward — so due:month needs to look forward instead (the
    /// next 30 days); reusing dateRange's backward window here would make
    /// "due:month" silently mean "was due sometime last month," which isn't
    /// what it says. due:today and an exact date are direction-agnostic (a
    /// single calendar day either way), so those two cases are identical to
    /// dateRange's own.
    ///
    /// due:week (and due:nextweek) are neither backward nor a rolling
    /// forward window — they're calendar-aligned to the current/next
    /// Mon–Sun-or-locale-equivalent week via Calendar.dateInterval(of:
    /// .weekOfYear, for:), which is what "due this week" actually means:
    /// it includes days earlier in the current week that have already
    /// passed (an overdue Tuesday task still reads as "due this week" on
    /// Wednesday), not just the next 7 days from this exact moment.
    nonisolated private static func dueRange(for dueQuery: String) -> (start: Date, end: Date)? {
        guard !dueQuery.isEmpty else { return nil }
        let calendar = Calendar.current
        let now = Date()

        switch dueQuery {
        case "today":
            let start = calendar.startOfDay(for: now)
            return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? now)
        // "tomorrow"/"yesterday" are single-day windows, exactly like
        // "today" — today's date ± 1, not "tomorrow and everything after"
        // (that's what week/month are for). Without an explicit case here,
        // an unrecognized bucket falls through to the default: branch,
        // fails to parse as a date, and dueRange returns nil — which
        // filtered(query:) then treats as "no filter, show everything" (see
        // dateRange's own doc comment above), not "show nothing." That's
        // the right fallback for a genuine typo, but "tomorrow" isn't a
        // typo, it's a real, expected bucket that needs its own case.
        case "tomorrow":
            let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        case "yesterday":
            let todayStart = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
            return (start, todayStart)
        case "week":
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
            return (interval.start, interval.end)
        case "nextweek":
            guard let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: now),
                  let interval = calendar.dateInterval(of: .weekOfYear, for: nextWeek) else { return nil }
            return (interval.start, interval.end)
        case "month":
            return (now, calendar.date(byAdding: .day, value: 30, to: now) ?? now)
        default:
            guard let components = parseFlexibleDate(dueQuery), let start = calendar.date(from: components) else { return nil }
            return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        }
    }

    /// Accepts "2026-04-15" (ISO, year first) as well as "4-15-26" /
    /// "04-15-2026" (US month-day-year, either "-" or "/" as the separator)
    /// — disambiguated by whether the first component has 4 digits, which
    /// unambiguously identifies the ISO year-first form. A 2-digit year is
    /// assumed to be 2000+, reasonable for a notes app.
    ///
    /// Public (not just internal): Note.swift's `due` parsing reuses this
    /// exact same format within EnvyCore, and MarkdownStyler in the Envy
    /// module also needs it — to resolve each "@" token's own date at
    /// style time for per-match urgency coloring, rather than only ever
    /// reading the note-level `due` (which only captures the *first*
    /// due token, whereas styling has to color every match it finds).
    nonisolated public static func parseFlexibleDate(_ input: String) -> DateComponents? {
        let parts = input.components(separatedBy: CharacterSet(charactersIn: "-/")).filter { !$0.isEmpty }
        guard parts.count == 3,
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else { return nil }

        let year: Int
        let month: Int
        let day: Int
        if parts[0].count == 4 {
            year = a; month = b; day = c
        } else {
            month = a; day = b
            year = c < 100 ? 2000 + c : c
        }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return components
    }

    /// Calendar's own `weekday` component numbering (1 = Sunday ... 7 =
    /// Saturday), keyed by the lowercased day name a due token spells out.
    nonisolated private static let weekdayNumbersByName: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    /// The next date that falls on `weekday` (same numbering as above),
    /// strictly after `reference`'s own calendar day. "Strictly after" is
    /// the deliberate choice for the case where today already is the named
    /// day: writing "@monday" on a Monday means *next* Monday, a week out,
    /// not "today" — the word "next" wouldn't mean anything otherwise.
    nonisolated private static func nextDate(forWeekday weekday: Int, after reference: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        let currentWeekday = calendar.component(.weekday, from: today)
        var offset = (weekday - currentWeekday + 7) % 7
        if offset == 0 { offset = 7 }
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    /// Resolves one "@..." due token — "@today" (literally today, the one
    /// case that isn't "next" anything), a day name ("@monday", always the
    /// *next* occurrence of that day, per nextDate(forWeekday:) above —
    /// naming today's own weekday still means a week out, not today; write
    /// "@today" for that), or an absolute date in parseFlexibleDate's own
    /// accepted formats — to the date it actually means right now. Called
    /// fresh each time a note's derived-value cache is rebuilt (a fresh
    /// disk read constructs a fresh Note, and with it a fresh cache — see
    /// NoteDerivedCache's own comments), so "@today"/a day-name token's
    /// answer tracks the real calendar instead of freezing at whatever day
    /// happened to be current the first time it was read; an absolute
    /// date token, by construction, never depends on "when" at all.
    nonisolated public static func resolveDueToken(_ token: String) -> Date? {
        let lowered = token.lowercased()
        if lowered == "today" {
            return Calendar.current.startOfDay(for: Date())
        }
        if let weekday = weekdayNumbersByName[lowered] {
            return nextDate(forWeekday: weekday, after: Date())
        }
        guard let components = parseFlexibleDate(token) else { return nil }
        return Calendar.current.date(from: components)
    }

    // MARK: - Pinning

    /// Moves every note whose id is in `pinnedIDs` to the front, preserving
    /// relative order otherwise. Applied as the last step after search
    /// filtering and column sorting, so pinned notes stay on top regardless
    /// of sort — but a pinned note that the search doesn't match is still
    /// excluded, since this only ever reorders whatever's already in `notes`.
    nonisolated public static func applyPinning(_ notes: [Note], pinnedIDs: Set<String>) -> [Note] {
        guard !pinnedIDs.isEmpty else { return notes }
        let pinned = notes.filter { pinnedIDs.contains($0.id) }
        let unpinned = notes.filter { !pinnedIDs.contains($0.id) }
        return pinned + unpinned
    }

    // MARK: - Filenames

    private static func uniqueFilename(for title: String, in directory: URL) -> String {
        let sanitized = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty ? "Untitled" : sanitized

        var candidate = "\(base).md"
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(suffix).md"
            suffix += 1
        }
        return candidate
    }
}
