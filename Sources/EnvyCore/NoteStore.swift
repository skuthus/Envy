import Foundation
import Combine
import CoreServices

/// What an "ai:" / "-ai:" search token constrains to — `any` for a bare
/// "ai:" (touched by an AI at all), or a specific provenance verb.
private enum AIFilter {
    case any, created, edited

    func matches(_ provenance: AIProvenance) -> Bool {
        switch self {
        case .any: return provenance != .none
        case .created: return provenance == .created
        case .edited: return provenance == .edited
        }
    }

    /// nil for an unrecognized value ("ai:cats") — treated as no constraint,
    /// the same lenient handling date: uses, rather than due:'s stricter
    /// match-nothing.
    static func parse(_ suffix: String) -> AIFilter? {
        switch suffix {
        case "": return .any
        case "created": return .created
        case "edited": return .edited
        default: return nil
        }
    }
}

/// A template is just a plain `.md` file living in The Index's own
/// `Templates` subfolder — never a Note itself. scanDirectory() explicitly
/// skips descending into `Templates/` even when subfolders are included, so
/// it's never visible to search/list/backlinks. `.trash/` folders (see
/// NoteStore's own doc comment on trashedNotes) don't need the same explicit
/// treatment — being hidden, they're already excluded by skipsHiddenFiles.
public struct NoteTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
}

@MainActor
public final class NoteStore: ObservableObject {
    @Published public private(set) var notes: [Note] = []
    /// The Index — the one folder Envy reads and watches. Singular by
    /// design: Envy used to support several folders merged into one list,
    /// but that flexibility mostly bought confusion (which folder does a
    /// new note land in, what does "move to folder" even mean, does a
    /// search span all of them) for a feature almost nobody used across
    /// more than one. One well-known folder is simpler to reason about
    /// and simpler to explain.
    @Published public private(set) var noteDirectory: URL
    /// Whether reload()/scanDirectory() descend into subfolders of The Index
    /// (excluding `Templates/`, which is never treated as notes regardless).
    /// Off by default — a flat top-level folder is the simpler, original
    /// model, and this is opt-in for people who already organize with
    /// subfolders.
    @Published public private(set) var includeSubfolders: Bool
    @Published public private(set) var isLoading = false

    // FSEventStreamRef (an OpaquePointer) isn't Sendable, which the compiler
    // otherwise flags on the nonisolated deinit below — safe in practice since
    // every mutation happens on the main actor, and deinit only runs once
    // nothing else can be concurrently touching it.
    nonisolated(unsafe) private var eventStream: FSEventStreamRef?
    private var suppressReloadUntil: Date = .distantPast
    private var reloadGeneration = 0
    private var reloadDebounceTask: Task<Void, Never>?

    public init(directory: URL? = nil, includeSubfolders: Bool = false) {
        let dir = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolved once here (after creation, so resolution has something to
        // resolve against) so every note's id/url and the FSEvents watch below
        // consistently agree on one path form — see the note on
        // startWatching for why a mismatch there is a real problem, not
        // just a cosmetic one.
        self.noteDirectory = dir.resolvingSymlinksInPath()
        self.includeSubfolders = includeSubfolders
        reload()
        startWatching()
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

    /// Re-points The Index at a different folder without recreating the
    /// store, so SwiftUI views holding onto it (and their selection state)
    /// don't have to be torn down just to look at a different folder.
    public func setDirectory(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolved = directory.resolvingSymlinksInPath()
        guard resolved != noteDirectory else { return }
        stopWatching()
        noteDirectory = resolved
        reload()
        startWatching()
    }

    /// Toggles whether The Index's subfolders (aside from `Templates/`) are
    /// scanned for notes — watching doesn't need to change, since FSEvents
    /// already monitors the whole subtree under noteDirectory regardless of
    /// this setting; only what reload()/scanDirectory() actually reads does.
    public func setIncludeSubfolders(_ include: Bool) {
        guard include != includeSubfolders else { return }
        includeSubfolders = include
        reload()
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

    /// Scans The Index and re-publishes `notes`. The actual file reading
    /// happens off the main thread — with a folder full of notes, doing
    /// this synchronously on the main actor (as this used to) froze the UI.
    public func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let directory = noteDirectory
        let includeSubfolders = includeSubfolders
        isLoading = true

        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.scanDirectory(directory, includeSubfolders: includeSubfolders)
            }.value

            // A newer reload may have been kicked off (e.g. the folder
            // changed again) while this scan was in flight — don't clobber
            // its result.
            guard generation == self.reloadGeneration else { return }
            self.notes = loaded
            self.isLoading = false
            self.refreshTrashedNotes()
        }
    }

    // A plain UnsafeMutableBufferPointer isn't Sendable as far as the
    // compiler's concerned, even though writing to disjoint, fixed indices
    // from multiple threads (as scanDirectory does below) is genuinely
    // safe — this box exists purely to make that assertion explicit and
    // contained in one place, rather than silencing the warning at the call
    // site.
    private struct UnsafeParallelWriteBox<T>: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<T>
    }

    /// Every `.md` file anywhere under `directory`, except inside
    /// `Templates/` — never notes, whether or not subfolder scanning is on.
    /// `.trash/` folders need no equivalent special-casing here: they're
    /// hidden (dot-prefixed), and skipsHiddenFiles below already excludes a
    /// hidden directory's entire subtree, not just the directory entry
    /// itself — confirmed empirically, not just assumed from the docs.
    nonisolated private static func notesRecursively(under directory: URL, fm: FileManager) -> [URL] {
        let templatesDirectory = directory.appendingPathComponent("Templates", isDirectory: true).resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            if url.resolvingSymlinksInPath() == templatesDirectory {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            results.append(url)
        }
        return results
    }

    nonisolated private static func scanDirectory(_ directory: URL, includeSubfolders: Bool) -> [Note] {
        let fm = FileManager.default
        let urls: [URL]
        if includeSubfolders {
            urls = notesRecursively(under: directory, fm: fm)
        } else {
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            // Inbox/ is read whether or not subfolder scanning is on — it
            // isn't a folder the user made to organise things, it's where
            // captures land, and a fleeting note that only appears if an
            // unrelated setting happens to be enabled is a lost note.
            let inbox = (try? fm.contentsOfDirectory(
                at: directory.appendingPathComponent(Self.inboxFolderName, isDirectory: true),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            urls = (entries + inbox).filter { $0.pathExtension.lowercased() == "md" }
        }

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
    private func startWatching() {
        // noteDirectory is already resolved (see init/setDirectory) — both
        // so FSEvents watches the real underlying path (a path that traverses
        // a symlink, like anything under /tmp or /var, silently fails to
        // watch correctly otherwise) and so every note's id/url agrees with
        // what a later reload() reports for the same file, symlink or not.
        let paths = [noteDirectory.path] as CFArray
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

    private func stopWatching() {
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
        let filename = Self.uniqueFilename(for: base, in: noteDirectory)
        let url = noteDirectory.appendingPathComponent(filename)

        markInternalWrite()
        try? "".write(to: url, atomically: true, encoding: .utf8)

        let note = Note(id: url.path, url: url, content: "", modifiedDate: Date())
        notes.insert(note, at: 0)
        return note
    }

    /// Every template in The Index's own `Templates/` subfolder.
    public func templates() -> [NoteTemplate] {
        let templatesDirectory = noteDirectory.appendingPathComponent("Templates", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: templatesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { NoteTemplate(id: $0.path, name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Creates a new, empty template file in The Index's own `Templates/`
    /// subfolder.
    @discardableResult
    public func createTemplate(named name: String) -> NoteTemplate {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedName.isEmpty ? "Untitled Template" : trimmedName
        let templatesDirectory = noteDirectory.appendingPathComponent("Templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        let filename = Self.uniqueFilename(for: base, in: templatesDirectory)
        let url = templatesDirectory.appendingPathComponent(filename)
        markInternalWrite()
        try? "".write(to: url, atomically: true, encoding: .utf8)
        return NoteTemplate(id: url.path, name: url.deletingPathExtension().lastPathComponent, url: url)
    }

    /// Creates a note whose starting content is `template`'s content, with
    /// {{date}}/{{time}}/{{title}} substituted in. The title itself gets
    /// the same substitution before it's used, so a template literally
    /// named e.g. "Daily Notes {{date}}" produces a note titled with
    /// today's actual date, not the literal token. `dateText` is
    /// caller-formatted (rather than a fixed style here) so the app
    /// layer's own date-format setting applies — EnvyCore stays
    /// platform/UI-agnostic and doesn't own a preferred date style itself.
    @discardableResult
    public func create(title: String, fromTemplate template: NoteTemplate, dateText: String) -> Note {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBase = trimmedTitle.isEmpty ? template.name : trimmedTitle
        let base = Self.applyingTemplateTokens(rawBase, title: rawBase, dateText: dateText)
        let filename = Self.uniqueFilename(for: base, in: noteDirectory)
        let url = noteDirectory.appendingPathComponent(filename)

        let rawContent = (try? String(contentsOf: template.url, encoding: .utf8)) ?? ""
        let content = Self.applyingTemplateTokens(rawContent, title: base, dateText: dateText)

        markInternalWrite()
        try? content.write(to: url, atomically: true, encoding: .utf8)

        let note = Note(id: url.path, url: url, content: content, modifiedDate: Date())
        notes.insert(note, at: 0)
        return note
    }

    /// Moves a note's file into The Index's `Templates/` subfolder,
    /// dropping it out of `notes` in the process.
    @discardableResult
    public func convertToTemplate(_ note: Note) -> NoteTemplate? {
        let templatesDirectory = noteDirectory.appendingPathComponent("Templates", isDirectory: true)
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
        return NoteTemplate(id: newURL.path, name: newURL.deletingPathExtension().lastPathComponent, url: newURL)
    }

    /// The inverse of convertToTemplate(_:) — moves a template's file back
    /// up out of `Templates/` into The Index itself.
    @discardableResult
    public func convertToNote(_ template: NoteTemplate) -> Note? {
        let filename = Self.uniqueFilename(for: template.name, in: noteDirectory)
        let newURL = noteDirectory.appendingPathComponent(filename)

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

    /// A folder's own `.trash` subfolder is where delete(_:) sends its notes
    /// first, ahead of the real macOS Trash — not one single Trash/ at The
    /// Index's top level, but one hidden `.trash` sibling per folder a note
    /// actually lives in. That's what makes restoreFromTrash(_:) trivial:
    /// a trashed note's own parent folder always *is* the folder it came
    /// from, no separate bookkeeping of "original location" required, and
    /// it survives across app restarts for free. Being dot-prefixed also
    /// means it's simply never visible — not in Finder, not to
    /// scanDirectory()/notesRecursively() (skipsHiddenFiles already
    /// excludes a hidden directory's whole subtree), and it can never
    /// collide with a real folder of the user's own already named "Trash".
    nonisolated private static let trashDirectoryName = ".trash"

    /// Every `.trash` directory anywhere under `directory`, however deep —
    /// there's one per folder that's ever had a note deleted from it, not
    /// just one at the top.
    nonisolated private static func allTrashDirectories(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == trashDirectoryName,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            results.append(url)
            enumerator.skipDescendants()
        }
        return results
    }

    /// Every note currently sitting in any of The Index's `.trash`
    /// subfolders — what backs the `trash:` search operator (browse,
    /// restore, or permanently delete a trashed note without leaving
    /// Envy). A real published property (not computed on demand, the way
    /// templates() is) since it needs to update immediately after
    /// delete(_:)/restoreFromTrash(_:)/deleteFromTrash(_:)/emptyTrash(), all
    /// of which refresh it explicitly rather than waiting on the next
    /// unrelated reload.
    @Published public private(set) var trashedNotes: [Note] = []

    /// Not parallelized like scanDirectory() — trash is expected to hold far
    /// fewer notes than the whole Index at any given time (it only
    /// accumulates between emptyTrash() sweeps), so a plain synchronous
    /// scan on the main actor is simpler and in practice just as fast.
    nonisolated private static func scanTrashedNotes(under directory: URL) -> [Note] {
        let fm = FileManager.default
        var results: [Note] = []
        for trashDirectory in allTrashDirectories(under: directory) {
            guard let entries = try? fm.contentsOfDirectory(
                at: trashDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension.lowercased() == "md" {
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                results.append(Note(id: url.path, url: url, content: content, modifiedDate: modified))
            }
        }
        return results.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    // MARK: - Inbox

    /// Fleeting notes live in `Inbox/` inside The Index. They are ordinary
    /// notes in every respect — same `notes` array, same editor, same
    /// rename, same delete — and the folder is the *only* difference: it's
    /// what the list marks with a dot, what `inbox:` filters on, and what
    /// Submit moves them out of.
    ///
    /// Visible rather than dot-hidden, on the `Templates/` model: these are
    /// the user's own words, they should be findable in Finder, and a mobile
    /// capture app writing here shouldn't depend on sync clients handling
    /// dot-directories correctly.
    nonisolated public static let inboxFolderName = "Inbox"

    public var inboxDirectory: URL {
        noteDirectory.appendingPathComponent(Self.inboxFolderName, isDirectory: true)
    }

    public func isInboxNote(_ note: Note) -> Bool {
        note.url.deletingLastPathComponent().standardizedFileURL == inboxDirectory.standardizedFileURL
    }

    /// Captures a fleeting note. Creates `Inbox/` on demand, so the feature
    /// works without anyone making the folder by hand first.
    @discardableResult
    public func createInboxNote(titled title: String) -> Note {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled" : trimmed
        markInternalWrite()
        try? FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        let url = inboxDirectory.appendingPathComponent(Self.uniqueFilename(for: base, in: inboxDirectory))
        try? "".write(to: url, atomically: true, encoding: .utf8)
        let note = Note(id: url.path, url: url, content: "", modifiedDate: Date())
        notes.insert(note, at: 0)
        return note
    }

    /// Writes an imported note (e.g. from Apple Notes) straight into `Inbox/`
    /// as a fleeting note, stamping the file's dates to `date` so it sorts by
    /// when it was actually written rather than the moment of import.
    ///
    /// Unlike `createInboxNote`, this carries a body and a date — an import is
    /// a finished note arriving from elsewhere, not a blank one being started.
    /// It reuses the same `Inbox/` naming so imported and hand-captured
    /// fleeting notes are indistinguishable once they land.
    @discardableResult
    public func importInboxNote(titled title: String, content: String, date: Date) -> Note {
        markInternalWrite()
        try? FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        let url = inboxDirectory.appendingPathComponent(Self.uniqueFilename(for: title, in: inboxDirectory))
        try? content.write(to: url, atomically: true, encoding: .utf8)
        // Stamp both dates: creation so a future "sort by created" is honest,
        // modification because that's what the list actually sorts on today.
        try? FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        let note = Note(id: url.path, url: url, content: content, modifiedDate: date)
        notes.insert(note, at: 0)
        return note
    }

    /// Files a fleeting note into The Index proper — a plain move out of
    /// `Inbox/`. The note's text is untouched, so nothing about having been
    /// fleeting survives in the file.
    @discardableResult
    public func submitFromInbox(_ note: Note) -> Note? {
        guard isInboxNote(note) else { return nil }
        markInternalWrite()
        let destination = Self.availableURL(for: note.title, in: noteDirectory)
        guard (try? FileManager.default.moveItem(at: note.url, to: destination)) != nil else { return nil }
        let moved = Note(id: destination.path, url: destination, content: note.content, modifiedDate: note.modifiedDate)
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = moved
        }
        return moved
    }

    /// Renames a loose `.md` file in place. Used by the template and inbox
    /// editors, which own their files directly rather than through `notes`,
    /// so `rename(_:to:)` — which also rewrites every wiki-link pointing at
    /// the note — doesn't apply: nothing links to a template or to a note
    /// that hasn't been filed yet.
    ///
    /// Returns the file's new location, or nil if the rename failed.
    @discardableResult
    public func renameFile(at url: URL, to newTitle: String) -> URL? {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !trimmed.isEmpty else { return nil }

        let directory = url.deletingLastPathComponent()
        let current = url.deletingPathExtension().lastPathComponent
        guard trimmed != current else { return url }

        markInternalWrite()
        let destination: URL
        if trimmed.lowercased() == current.lowercased() {
            // A case-only change ("test" → "Test") collides with the file
            // itself on a case-insensitive volume, so asking availableURL
            // for a free name would hand back "Test (2)". Move straight to
            // the new spelling instead.
            destination = directory.appendingPathComponent("\(trimmed).md")
        } else {
            destination = Self.availableURL(for: trimmed, in: directory)
        }
        guard (try? FileManager.default.moveItem(at: url, to: destination)) != nil else { return nil }
        return destination
    }

    /// A free filename in `directory` for `title`, disambiguating with
    /// " (2)", " (3)" and so on.
    ///
    /// Parenthesised rather than Finder's bare " 2", which reads as part of
    /// a title — a note actually called "Ideas 2" is entirely plausible.
    /// Compared case-insensitively because APFS is: "ideas" and "Ideas"
    /// already collide at the filesystem level, so matching only exact case
    /// would happily generate a name the OS then refuses.
    nonisolated static func availableURL(for title: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let existing = Set(
            ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
                .map { ($0 as NSString).deletingPathExtension.lowercased() }
        )
        let base = title.replacingOccurrences(of: "/", with: "-")
        guard existing.contains(base.lowercased()) else {
            return directory.appendingPathComponent("\(base).md")
        }
        var counter = 2
        while existing.contains("\(base) (\(counter))".lowercased()) { counter += 1 }
        return directory.appendingPathComponent("\(base) (\(counter)).md")
    }

    private func refreshTrashedNotes() {
        trashedNotes = Self.scanTrashedNotes(under: noteDirectory)
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

    /// Soft-deletes by moving each note's file into its own parent folder's
    /// `.trash` subfolder — not straight to the real macOS Trash, so it
    /// stays fully reversible via restoreLastDeleted() (or, later,
    /// restoreFromTrash(_:)) until emptyTrash() eventually sweeps it further.
    public func delete(_ notesToDelete: [Note]) {
        guard !notesToDelete.isEmpty else { return }
        markInternalWrite()
        var trashed: [(note: Note, trashedURL: URL)] = []
        for note in notesToDelete {
            let trashDirectory = note.url.deletingLastPathComponent().appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let filename = Self.uniqueFilename(for: note.title, in: trashDirectory)
            let destination = trashDirectory.appendingPathComponent(filename)
            do {
                try FileManager.default.moveItem(at: note.url, to: destination)
                trashed.append((note, destination))
            } catch {
                continue
            }
        }
        lastDeleted = trashed
        let deletedIDs = Set(notesToDelete.map(\.id))
        notes.removeAll { deletedIDs.contains($0.id) }
        refreshTrashedNotes()
    }

    /// Moves the most recently deleted note(s) back out of .trash/ to their
    /// original location and re-adds them to `notes`. A note whose original
    /// location has since been reused (e.g. a new note created with the same
    /// filename), or that emptyTrash()/deleteFromTrash(_:) already swept on
    /// to the real macOS Trash in the meantime, is silently skipped rather
    /// than overwriting it or failing loudly.
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
        refreshTrashedNotes()
        return restored
    }

    /// Restores an arbitrary trashed note found via `trashedNotes`/`trash:`
    /// search — unlike restoreLastDeleted() (which only remembers the most
    /// recent delete, and only for the lifetime of the app process), this
    /// works for anything currently sitting in any `.trash` subfolder,
    /// including ones left over from a previous session. Always lands back
    /// in its `.trash` folder's own parent directory — the same folder it
    /// was deleted from, which is exactly what the per-folder `.trash`
    /// layout guarantees without needing to separately remember it.
    @discardableResult
    public func restoreFromTrash(_ note: Note) -> Note? {
        let trashDirectory = note.url.deletingLastPathComponent()
        let destinationDirectory = trashDirectory.deletingLastPathComponent()
        let filename = Self.uniqueFilename(for: note.title, in: destinationDirectory)
        let destination = destinationDirectory.appendingPathComponent(filename)
        markInternalWrite()
        do {
            try FileManager.default.moveItem(at: note.url, to: destination)
        } catch {
            return nil
        }
        let restored = Note(id: destination.path, url: destination, content: note.content, modifiedDate: Date())
        notes.insert(restored, at: 0)
        refreshTrashedNotes()
        return restored
    }

    /// Moves one trashed note straight into the real macOS Trash — the same
    /// thing emptyTrash() does in bulk on its own schedule, just for a
    /// single item picked out via `trashedNotes`/`trash:` search, still
    /// recoverable afterward via Finder's own Trash.
    public func deleteFromTrash(_ note: Note) {
        markInternalWrite()
        try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        refreshTrashedNotes()
    }

    /// Sweeps everything currently sitting in any of The Index's `.trash`
    /// subfolders into the real macOS Trash — the second, slower stage of
    /// deletion after delete(_:)'s own soft-delete. Called on a schedule by
    /// TrashPreference in the app layer, not tied to any particular delete;
    /// a lastDeleted entry pointing at something this just swept away simply
    /// fails its restore silently (see restoreLastDeleted()'s own doc
    /// comment), so no extra bookkeeping is needed here for that.
    public func emptyTrash() {
        let directories = Self.allTrashDirectories(under: noteDirectory)
        guard !directories.isEmpty else { return }
        var swept = false
        for trashDirectory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: trashDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ), !entries.isEmpty else { continue }
            for url in entries {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            swept = true
        }
        guard swept else { return }
        markInternalWrite()
        refreshTrashedNotes()
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
        updateWikiLinkReferences(from: note.title, to: renamed.title)
        return renamed
    }

    /// After a rename, rewrite every `[[old]]` / `![[old]]` reference across
    /// the vault to point at the new title, so links and embeds don't break.
    /// Matching is case-insensitive (the same way a wiki-link resolves) and an
    /// embed's leading `!` is preserved. Candidates come from the wikiLinks
    /// cache, so only notes that actually reference the old title are read.
    /// A reference-only rewrite keeps each note's modified date (both in
    /// memory and on disk), so renaming a widely-linked note doesn't shove all
    /// its referrers to the top of a date-sorted list — the user renamed one
    /// note, they didn't edit thirty others.
    private func updateWikiLinkReferences(from oldTitle: String, to newTitle: String) {
        guard oldTitle.caseInsensitiveCompare(newTitle) != .orderedSame else { return }
        let oldLower = oldTitle.lowercased()
        let escaped = NSRegularExpression.escapedPattern(for: oldTitle)
        // Group 2 captures any alias or heading suffix so it survives the
        // rewrite: [[Old|yesterday's notes]] becomes [[New|yesterday's
        // notes]], not [[New]]. Without it a rename would silently discard
        // the words the author actually wrote into their sentence.
        guard let regex = try? NSRegularExpression(
            pattern: "(!?)\\[\\[[ \\t]*\(escaped)[ \\t]*((?:#|\\|)[^\\[\\]]*)?\\]\\]",
            options: [.caseInsensitive]
        ) else { return }
        let template = "$1[[" + NSRegularExpression.escapedTemplate(for: newTitle) + "$2]]"

        let candidateIDs = notes.filter { $0.wikiLinks.contains(oldLower) }.map(\.id)
        for id in candidateIDs {
            guard let idx = notes.firstIndex(where: { $0.id == id }) else { continue }
            let content = notes[idx].content
            let updated = regex.stringByReplacingMatches(
                in: content,
                range: NSRange(location: 0, length: (content as NSString).length),
                withTemplate: template
            )
            guard updated != content else { continue }
            let url = notes[idx].url
            let originalDate = notes[idx].modifiedDate
            markInternalWrite()
            do {
                try updated.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                continue
            }
            try? FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: url.path)
            // Assigning `.content` swaps the derived cache (so wikiLinks/
            // backlinks recompute) without touching modifiedDate.
            notes[idx].content = updated
        }
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

    /// Whether `phrase` appears in `haystack` bounded by non-word characters
    /// on both sides — the exact-match half of a closed "quoted phrase", so
    /// "nee" doesn't match inside "needed". Unicode-aware word classes, so
    /// accented letters and digits count as part of a word.
    nonisolated private static func wholeWordContains(_ haystack: String, _ phrase: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(haystack.startIndex..., in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
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

    /// Whether a note's file sits directly in an `Inbox/` folder. Compares
    /// the parent folder's name rather than a full path, so this stays
    /// nonisolated — the search runs off the main actor and can't reach the
    /// store's own noteDirectory.
    nonisolated public static func isInInboxFolder(_ note: Note) -> Bool {
        note.url.deletingLastPathComponent().lastPathComponent == inboxFolderName
    }

    nonisolated private static func rankedHigherFirst(_ lhs: (Note, Int), _ rhs: (Note, Int)) -> Bool {
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.modifiedDate > rhs.0.modifiedDate
    }

    /// One comma-separated group's own self-contained search — operators
    /// (tag:/date:/due:/todo:), exclusions (-word, -tag:x, -due:x, -todo:),
    /// and free terms all combine with AND semantics *within* a group,
    /// same as the whole query used to before groups existed. Returns
    /// (Note, score) pairs for whatever survives every filter in this group.
    /// Splits a group into tokens on spaces, except inside double quotes:
    /// `dog "bone leash"` is two tokens, the second carrying its space. That
    /// makes a quoted phrase a single free term, and since fastContains does
    /// substring matching, "bone leash" only matches where those words sit
    /// adjacent — the phrase search users expect. It also lets an operator
    /// take a spaced argument, `link:"Meeting Notes"`, without the space
    /// ending the token.
    nonisolated public static func tokenize(_ q: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in q {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == " " && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Drops surrounding double quotes. Tolerant of a missing closing one,
    /// so a phrase still being typed — `"mater` before the closing quote —
    /// searches as `mater` and shows results as you go, rather than looking
    /// for the literal string `"mater` and finding nothing until you finish
    /// the quote. The interior stays intact, so `"material sci` matches that
    /// text adjacently, tightening the phrase live as you type it.
    nonisolated public static func unquote(_ text: String) -> String {
        var result = text
        if result.hasPrefix("\"") { result.removeFirst() }
        if result.hasSuffix("\"") { result.removeLast() }
        return result
    }

    nonisolated private static func matched(in notes: [Note], forGroup group: String) -> [(Note, Int)] {
        let q = group.lowercased()
        let tokens = Self.tokenize(q)

        var tagFilter: String?
        var excludeTags: [String] = []
        var dateFilter: (start: Date, end: Date)?
        var dueCondition: DueCondition?
        var excludeDueCondition: DueCondition?
        var isDueInvalid = false
        var dueTokenSeen = false
        var excludeDueTokenSeen = false
        var isTodoOnly = false
        var isTodoExcluded = false
        var aiCondition: AIFilter?
        var excludeAiCondition: AIFilter?
        var isInboxOnly = false
        var isInboxExcluded = false
        var linkFilter: String?
        var excludeLinks: [String] = []
        var isOrphanOnly = false
        var isLinkedOnly = false
        // Closed quotes are exact — matched on word boundaries, so "nee"
        // finds the word "nee", not the "nee" inside "needed". An *open*
        // quote (still being typed) stays a substring free term, so results
        // appear as you type. That's the whole open-vs-closed distinction.
        var phraseTerms: [String] = []
        var excludePhrases: [String] = []
        var excludeTerms: [String] = []
        var freeTerms: [String] = []

        // Only the first tag:/date:/due: token (of each polarity) is
        // honored if more than one of the same kind appears — combining
        // multiple has ambiguous AND-vs-OR semantics not worth guessing at
        // (that's what the comma groups above are for). Every "-"-prefixed
        // exclusion is honored, though — there's no such ambiguity in
        // excluding more than one thing.
        for token in tokens {
            if token == "-inbox:" {
                isInboxExcluded = true
            } else if token.hasPrefix("inbox:") {
                // A bare "inbox:" scopes to fleeting notes; anything after
                // the colon is ordinary search text within them, so it falls
                // through to freeTerms below like any other operator's
                // trailing words.
                isInboxOnly = true
                let rest = String(token.dropFirst("inbox:".count))
                if !rest.isEmpty { freeTerms.append(rest) }
            } else if token == "-todo:" {
                isTodoExcluded = true
            } else if token == "todo:" {
                isTodoOnly = true
            } else if token.hasPrefix("-ai:") {
                if excludeAiCondition == nil {
                    excludeAiCondition = AIFilter.parse(String(token.dropFirst("-ai:".count)))
                }
            } else if token.hasPrefix("ai:") {
                if aiCondition == nil {
                    aiCondition = AIFilter.parse(String(token.dropFirst("ai:".count)))
                }
            } else if token.hasPrefix("-tag:") {
                let name = String(token.dropFirst("-tag:".count))
                if !name.isEmpty { excludeTags.append(name) }
            } else if token.hasPrefix("tag:") {
                if tagFilter == nil {
                    let name = String(token.dropFirst("tag:".count))
                    tagFilter = name.isEmpty ? nil : name
                }
            } else if token.hasPrefix("date:") {
                if dateFilter == nil {
                    dateFilter = Self.dateRange(for: String(token.dropFirst("date:".count)))
                }
            } else if token.hasPrefix("-due:") {
                if !excludeDueTokenSeen {
                    excludeDueTokenSeen = true
                    let value = String(token.dropFirst("-due:".count))
                    if let condition = Self.dueCondition(for: value) {
                        excludeDueCondition = condition
                    } else {
                        isDueInvalid = true
                    }
                }
            } else if token.hasPrefix("due:") {
                // Unlike date:, an unrecognized value here (not empty, not
                // "overdue", not a bucket, not a parseable date — "due:cats")
                // means "match nothing," not "no filter, show everything."
                // date:'s own fallback intentionally treats an unrecognized
                // bucket as "show everything" so a typo doesn't dump you
                // into a confusing empty list — but "due:cats" isn't a typo
                // of a real bucket, it's simply invalid, and silently
                // matching every note (due or not) hides that rather than
                // surfacing it. Same reasoning applies to -due:cats above —
                // an invalid value is invalid regardless of which polarity
                // asked for it, so either one flags the whole group broken
                // rather than inventing a separate meaning for a negated
                // invalid condition.
                if !dueTokenSeen {
                    dueTokenSeen = true
                    let value = String(token.dropFirst("due:".count))
                    if let condition = Self.dueCondition(for: value) {
                        dueCondition = condition
                    } else {
                        isDueInvalid = true
                    }
                }
            } else if token == "linked:" {
                // The complement of orphan: — notes with at least one link
                // in or out, i.e. part of the web rather than adrift.
                isLinkedOnly = true
            } else if token == "orphan:" {
                // Notes adrift from the link graph — nothing points at them
                // and they point at nothing. Zettelkasten hygiene: the
                // backlink half is corpus-wide, computed once below.
                isOrphanOnly = true
            } else if token.hasPrefix("-link:") {
                let target = unquote(String(token.dropFirst("-link:".count)))
                if !target.isEmpty { excludeLinks.append(target) }
            } else if token.hasPrefix("link:") {
                // Notes containing [[Target]] — search as graph traversal,
                // the keyboard-driven twin of the backlinks footer. First
                // one wins, like tag:.
                if linkFilter == nil {
                    let target = unquote(String(token.dropFirst("link:".count)))
                    linkFilter = target.isEmpty ? nil : target
                }
            } else if token.hasPrefix("-\"") {
                let rest = String(token.dropFirst())
                let phrase = unquote(rest)
                if !phrase.isEmpty {
                    if rest.count >= 2 && rest.hasSuffix("\"") { excludePhrases.append(phrase) }
                    else { excludeTerms.append(phrase) }
                }
            } else if token.hasPrefix("-"), token.count > 1 {
                excludeTerms.append(String(token.dropFirst()))
            } else if token.hasPrefix("\"") {
                // Closed "phrase" → exact, word-boundary matched. Open
                // "phrase (no closing quote yet) → substring free term, for
                // live incremental results as it's typed.
                let phrase = unquote(token)
                if !phrase.isEmpty {
                    if token.count >= 2 && token.hasSuffix("\"") { phraseTerms.append(phrase) }
                    else { freeTerms.append(phrase) }
                }
            } else {
                freeTerms.append(token)
            }
        }

        let hasOperator = isInboxOnly || isInboxExcluded
            || linkFilter != nil || !excludeLinks.isEmpty || isOrphanOnly || isLinkedOnly
            || isTodoOnly || isTodoExcluded || tagFilter != nil || !excludeTags.isEmpty
            || dateFilter != nil
            || dueCondition != nil || excludeDueCondition != nil || isDueInvalid
            || aiCondition != nil || excludeAiCondition != nil

        // Every note anything links *to*, across the corpus — the backlink
        // half of orphan:. Computed once, and only when orphan: is actually
        // in the query, since it's a full pass over every note's links.
        let linkedToTitles: Set<String> = (isOrphanOnly || isLinkedOnly)
            ? Set(notes.flatMap { $0.wikiLinks })
            : []

        // Computed once for the whole group rather than per-note — same
        // reasoning as dateRange's own `now`, just needing today's start
        // rather than the current instant.
        let overdueThreshold = Calendar.current.startOfDay(for: Date())

        return notes.compactMap { note -> (Note, Int)? in
            // Membership is the folder the file sits in — there's no flag on
            // a note saying it's fleeting, and there shouldn't be: moving it
            // out of Inbox/ in Finder should file it just as surely as
            // pressing Submit does.
            if isInboxOnly, !Self.isInInboxFolder(note) { return nil }
            if isInboxExcluded, Self.isInInboxFolder(note) { return nil }
            if let linkFilter, !note.wikiLinks.contains(linkFilter) { return nil }
            if !excludeLinks.isEmpty, note.wikiLinks.contains(where: { excludeLinks.contains($0) }) { return nil }
            let noteIsOrphan = note.wikiLinks.isEmpty && !linkedToTitles.contains(note.lowercasedTitle)
            if isOrphanOnly, !noteIsOrphan { return nil }
            if isLinkedOnly, noteIsOrphan { return nil }
            if !phraseTerms.isEmpty {
                let t = note.lowercasedTitle, c = note.lowercasedContent
                for phrase in phraseTerms where !(Self.wholeWordContains(t, phrase) || Self.wholeWordContains(c, phrase)) {
                    return nil
                }
            }
            if !excludePhrases.isEmpty {
                let t = note.lowercasedTitle, c = note.lowercasedContent
                if excludePhrases.contains(where: { Self.wholeWordContains(t, $0) || Self.wholeWordContains(c, $0) }) { return nil }
            }
            if isTodoOnly, !note.hasUncheckedTask { return nil }
            if isTodoExcluded, note.hasUncheckedTask { return nil }
            if let tagFilter, !note.tags.contains(where: { Self.fastContains($0, tagFilter) }) { return nil }
            if !excludeTags.isEmpty, note.tags.contains(where: { tag in excludeTags.contains { Self.fastContains(tag, $0) } }) { return nil }
            if let dateFilter, !(note.modifiedDate >= dateFilter.start && note.modifiedDate < dateFilter.end) { return nil }
            if isDueInvalid { return nil }
            if let dueCondition, !Self.dueConditionMatches(dueCondition, note: note, overdueThreshold: overdueThreshold) { return nil }
            if let excludeDueCondition, Self.dueConditionMatches(excludeDueCondition, note: note, overdueThreshold: overdueThreshold) { return nil }
            if let aiCondition, !aiCondition.matches(note.aiProvenance) { return nil }
            if let excludeAiCondition, excludeAiCondition.matches(note.aiProvenance) { return nil }
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

    /// What a `due:` (or `-due:`) token's value resolved to — "overdue" and
    /// "future" are open-ended, not a [start, end) window like the rest, so
    /// they get their own cases rather than something dueRange(for:) could
    /// express as a range.
    private enum DueCondition {
        case any
        case overdue
        case future
        case range(start: Date, end: Date)
    }

    /// Parses a due:/-due: value into the condition it represents. nil means
    /// invalid — see the "due:cats" reasoning at each call site — not "no
    /// filter."
    nonisolated private static func dueCondition(for value: String) -> DueCondition? {
        if value.isEmpty { return .any }
        // "past" is a plain alias for "overdue" — same meaning, different
        // word for anyone who reaches for past/future as the natural
        // opposite pair rather than overdue/future.
        if value == "overdue" || value == "past" { return .overdue }
        if value == "future" { return .future }
        if let range = Self.dueRange(for: value) { return .range(start: range.start, end: range.end) }
        return nil
    }

    nonisolated private static func dueConditionMatches(_ condition: DueCondition, note: Note, overdueThreshold: Date) -> Bool {
        switch condition {
        case .any:
            return note.due != nil
        case .overdue:
            return note.due.map { $0 < overdueThreshold } ?? false
        case .future:
            // The exact complement of .overdue — due today or later, same
            // threshold, flipped comparison. Like overdue, a note with no
            // due date matches neither: "future" isn't "undated," it's
            // "dated and not yet due."
            return note.due.map { $0 >= overdueThreshold } ?? false
        case .range(let start, let end):
            return note.due.map { $0 >= start && $0 < end } ?? false
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
    ///
    /// This live resolution is now a fallback: the editor freezes relative
    /// tokens to absolute dates at type-time, so a token only reaches here
    /// still-relative if it was never typed in Envy (paste, external edit,
    /// sync). Such a token tracks the calendar and can't go overdue — the
    /// freeze is what fixes that for tokens Envy itself creates.
    nonisolated public static func resolveDueToken(_ token: String) -> Date? {
        let lowered = token.lowercased()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch lowered {
        case "today": return today
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
        default: break
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
