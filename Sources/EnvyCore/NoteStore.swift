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
/// it's never visible to search/list/backlinks. `Trash/` and `Attachments/`
/// get the same by-name exclusion (they're visible folders now, so
/// skipsHiddenFiles no longer covers them).
public struct NoteTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
}

@MainActor
public final class NoteStore: ObservableObject {
    @Published public private(set) var notes: [Note] = [] {
        didSet { notesGeneration &+= 1 }
    }

    /// Lazily-rebuilt id → array-position index behind `note(withID:)`.
    /// Entries self-validate on lookup (`notes[i].id == id`), so in-place
    /// content mutations never invalidate anything; the generation counter
    /// exists only to bound rebuilds to one per actual `notes` change even
    /// when the looked-up id genuinely doesn't exist.
    private var idIndex: [String: Int] = [:]
    private var idIndexGeneration = -1
    private var notesGeneration = 0

    /// O(1) note lookup by id. The linear `notes.first { $0.id == id }`
    /// scan this replaces was fine per action, but the editor resolves its
    /// note on every keystroke-triggered render — at 15k notes of long
    /// shared-prefix path ids, that's real per-keystroke work.
    public func note(withID id: String) -> Note? {
        if let i = idIndex[id], i < notes.count, notes[i].id == id { return notes[i] }
        guard idIndexGeneration != notesGeneration else { return nil }
        idIndex = Dictionary(minimumCapacity: notes.count)
        for (i, n) in notes.enumerated() where idIndex[n.id] == nil { idIndex[n.id] = i }
        idIndexGeneration = notesGeneration
        guard let i = idIndex[id] else { return nil }
        return notes[i]
    }

    /// Every distinct tag used anywhere in The Index, most-used first —
    /// feeds the editor's `#tag` ghost-text completion. The search box keeps
    /// its own background-computed copy (ContentView.recomputeAllTags, built
    /// with the same static helper below); this one is rebuilt lazily, at
    /// most once per `notes` change, and only when someone actually asks —
    /// i.e. while a hashtag is being typed — so it costs nothing on the
    /// keystroke/save hot paths.
    private var tagsByFrequencyCache: [(name: String, count: Int)] = []
    private var tagsByFrequencyGeneration = -1

    /// Every tag with its note count, most-used first (ties alphabetical).
    /// Feeds the editor's `#` completion (names only, via
    /// allTagsByFrequency) and the omnibar's bare-`tag:` browser (names and
    /// counts). Rebuilt at most once per notes change, and only when asked.
    public func tagCounts() -> [(name: String, count: Int)] {
        if tagsByFrequencyGeneration != notesGeneration {
            tagsByFrequencyCache = Self.tagCounts(in: notes)
            tagsByFrequencyGeneration = notesGeneration
        }
        return tagsByFrequencyCache
    }

    public func allTagsByFrequency() -> [String] { tagCounts().map(\.name) }

    /// Most-used first, ties alphabetical. Per-note tag sets are memoized
    /// (Note.tags), so this is set iteration, not a regex pass.
    nonisolated public static func tagCounts(in notes: [Note]) -> [(name: String, count: Int)] {
        var frequency: [String: Int] = [:]
        for note in notes {
            for tag in note.tags { frequency[tag, default: 0] += 1 }
        }
        return frequency
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, count: $0.value) }
    }

    nonisolated public static func tagsByFrequency(in notes: [Note]) -> [String] {
        tagCounts(in: notes).map(\.name)
    }
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
        migrateLegacyHiddenFolders()
    }

    /// Moves pre-1.8.3 hidden service folders to their visible homes:
    /// `.attachments` → `Attachments/`, and every per-folder `.trash` into
    /// the single root `Trash/` (mirroring each origin folder's relative
    /// path). Runs detached — the legacy `.trash` hunt walks the whole vault
    /// subtree, which has no business on the main thread at launch — and the
    /// note scan is indifferent to it either way: the legacy folders are
    /// hidden (already skipped) and the destinations are name-excluded.
    /// Idempotent and cheap when there's nothing to migrate.
    private func migrateLegacyHiddenFolders() {
        let directory = noteDirectory
        Task.detached(priority: .utility) { [weak self] in
            let fm = FileManager.default

            // .attachments → Attachments. Whole-folder rename when the
            // visible folder doesn't exist yet; per-file merge (collision-
            // safe) when it does.
            let legacyAttachments = directory.appendingPathComponent(Self.legacyAttachmentsFolderName, isDirectory: true)
            let attachments = directory.appendingPathComponent(Self.attachmentsFolderName, isDirectory: true)
            if fm.fileExists(atPath: legacyAttachments.path) {
                if !fm.fileExists(atPath: attachments.path) {
                    try? fm.moveItem(at: legacyAttachments, to: attachments)
                } else {
                    for entry in (try? fm.contentsOfDirectory(at: legacyAttachments, includingPropertiesForKeys: nil)) ?? [] {
                        let name = Self.availableAttachmentName(entry.lastPathComponent, in: attachments)
                        try? fm.moveItem(at: entry, to: attachments.appendingPathComponent(name))
                    }
                    if ((try? fm.contentsOfDirectory(atPath: legacyAttachments.path)) ?? []).isEmpty {
                        try? fm.removeItem(at: legacyAttachments)
                    }
                }
            }

            // Per-folder .trash → Trash/<origin's relative path>.
            let rootPath = directory.standardizedFileURL.path
            let trashRoot = directory.appendingPathComponent(Self.trashFolderName, isDirectory: true)
            var movedTrash = false
            for legacy in Self.allLegacyTrashDirectories(under: directory) {
                let origin = legacy.deletingLastPathComponent().standardizedFileURL.path
                var destination = trashRoot
                if origin != rootPath, origin.hasPrefix(rootPath + "/") {
                    destination = trashRoot.appendingPathComponent(String(origin.dropFirst(rootPath.count + 1)), isDirectory: true)
                }
                let entries = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
                if !entries.isEmpty {
                    try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    for entry in entries {
                        let title = entry.deletingPathExtension().lastPathComponent
                        let name = entry.pathExtension.lowercased() == "md"
                            ? Self.uniqueFilename(for: title, in: destination)
                            : Self.availableAttachmentName(entry.lastPathComponent, in: destination)
                        try? fm.moveItem(at: entry, to: destination.appendingPathComponent(name))
                        movedTrash = true
                    }
                }
                if ((try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []).isEmpty {
                    try? fm.removeItem(at: legacy)
                }
            }

            if movedTrash {
                await self?.refreshTrashedNotes()
            }
        }
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
        migrateLegacyHiddenFolders()
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
        // Snapshot of what's already loaded, keyed by path — the scan reuses
        // any note whose file hasn't changed on disk since it was read, so a
        // one-file external edit doesn't reread (and re-derive caches for)
        // the whole vault.
        let previous = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        isLoading = true

        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.scanDirectory(directory, includeSubfolders: includeSubfolders, reusing: previous)
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

    /// Every `.md` file anywhere under `directory`, except inside the
    /// Index's own service folders — `Templates/`, `Trash/`, `Attachments/`
    /// — none of which hold notes, whether or not subfolder scanning is on.
    /// (Trash and Attachments used to be dot-hidden and excluded for free by
    /// skipsHiddenFiles; they're visible now so sync clients don't skip
    /// them, which means the scan excludes them by name, the Templates way.)
    nonisolated private static func notesRecursively(under directory: URL, fm: FileManager) -> [URL] {
        let serviceDirectories = Set(
            ["Templates", trashFolderName, attachmentsFolderName, dataFolderName].map {
                directory.appendingPathComponent($0, isDirectory: true).resolvingSymlinksInPath()
            }
        )
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            // resolvingSymlinksInPath() hits the filesystem, so only pay for
            // it on directories (the only thing a service folder could be)
            // rather than on every enumerated file.
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if serviceDirectories.contains(url.resolvingSymlinksInPath()) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            results.append(url)
        }
        return results
    }

    nonisolated private static func scanDirectory(_ directory: URL, includeSubfolders: Bool, reusing previous: [String: Note] = [:]) -> [Note] {
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
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                // Same path, same mtime: the file hasn't changed since it was
                // last read, so keep the existing Note — its derived cache
                // (lowercased content, tags, links) survives with it. An
                // internal save() stamps the in-memory note with Date()
                // rather than the disk mtime, so anything Envy itself wrote
                // recently misses here and gets re-read: the conservative
                // direction. (The classic mtime-cache blind spot — content
                // swapped under an unchanged mtime — is accepted; nothing
                // ordinary does that to a notes folder.)
                if let existing = previous[url.path], existing.modifiedDate == modified {
                    box.buffer[index] = existing
                    return
                }
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
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
    /// Creates an empty note — at the Index root, or directly inside
    /// `subfolder` (a path relative to the root, created on demand) when the
    /// omnibar's "Folder/Title" creation form names one.
    public func create(title: String, inSubfolder subfolder: String? = nil) -> Note {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        var directory = noteDirectory
        // Sanitize the subfolder path so a "../" component can't create/write
        // outside the vault; an unusable path just falls back to the root.
        if let subfolder, !subfolder.isEmpty, let safe = Self.sanitizedSubfolder(subfolder) {
            directory = noteDirectory.appendingPathComponent(safe, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let filename = Self.uniqueFilename(for: base, in: directory)
        let url = directory.appendingPathComponent(filename)

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
        // If an edit was in flight (debounced save scheduled against the old
        // id), let it land in the template file instead of resurrecting the
        // note at its old path — the words the user just typed go where the
        // note went.
        recordFileRelocation(from: note.id, to: newURL)
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
    /// DateFormatter construction is expensive enough to be worth caching
    /// even here, where it only ran per created note.
    private static let templateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static func applyingTemplateTokens(_ content: String, title: String, dateText: String) -> String {
        let timeFormatter = templateTimeFormatter
        return content
            .replacingOccurrences(of: "{{date}}", with: dateText)
            .replacingOccurrences(of: "{{time}}", with: timeFormatter.string(from: Date()))
            .replacingOccurrences(of: "{{title}}", with: title)
    }

    /// oldID → newID for id-changing ops (rename, move, inbox submit), and
    /// oldID → file URL for ops that take the note out of `notes` entirely but
    /// keep its file (convert-to-template, delete-to-trash). A debounced save
    /// is scheduled against the note's identity at typing time; by the time it
    /// fires 400ms later, one of those ops may have moved the note out from
    /// under it — these maps let save(_:) land the content on the note's
    /// current identity instead of resurrecting a file at the stale old path.
    private var renamedIDs: [String: String] = [:]
    private var relocatedFiles: [String: URL] = [:]

    private func recordIDChange(from oldID: String, to newID: String) {
        // Crude but safe growth cap — a forgotten mapping means an orphaned
        // save is skipped (harmless), never a resurrection.
        if renamedIDs.count > 512 { renamedIDs.removeAll() }
        renamedIDs[oldID] = newID
    }

    private func recordFileRelocation(from oldID: String, to url: URL) {
        if relocatedFiles.count > 512 { relocatedFiles.removeAll() }
        relocatedFiles[oldID] = url
    }

    /// Follows rename chains (A→B→C) to the id's current home, if it still
    /// exists in `notes`.
    private func currentID(for id: String) -> String? {
        var current = id
        var hops = 0
        while let next = renamedIDs[current], hops < 16 {
            current = next
            hops += 1
        }
        return note(withID: current) != nil ? current : nil
    }

    public func save(_ note: Note) {
        var target = note
        if self.note(withID: note.id) == nil {
            // The id this save was scheduled against no longer exists — the
            // note was renamed/moved (follow it there), converted or trashed
            // (write into the relocated file so the words survive), or is
            // gone entirely (skip: writing to the stale path would resurrect
            // a file the user just deliberately made not-exist).
            if let liveID = currentID(for: note.id), let current = self.note(withID: liveID) {
                target = Note(id: current.id, url: current.url, content: note.content, modifiedDate: current.modifiedDate)
            } else if let relocated = relocatedFiles[note.id],
                      FileManager.default.fileExists(atPath: relocated.path) {
                markInternalWrite()
                try? note.content.write(to: relocated, atomically: true, encoding: .utf8)
                return
            } else {
                return
            }
        }
        markInternalWrite()
        try? target.content.write(to: target.url, atomically: true, encoding: .utf8)
        if let idx = notes.firstIndex(where: { $0.id == target.id }) {
            notes[idx].content = target.content
            notes[idx].modifiedDate = Date()
        }
    }

    /// Visible, single, and at the Index root (it was a hidden `.trash`
    /// inside each folder before 1.8.3, invisible to the sync clients that
    /// exclude dot-folders — a deleted note was stranded on the machine it
    /// was deleted on). Inside, Trash mirrors the vault's folder structure:
    /// `Trash/Work/x.md` came from `Work/`, which is what lets
    /// restoreFromTrash put things back where they came from without any
    /// separate bookkeeping.
    public nonisolated static let trashFolderName = "Trash"
    nonisolated static let legacyTrashDirectoryName = ".trash"

    /// A visible service folder at the Index root for Envy's vault-bound
    /// derived state — data that belongs to *this* collection of notes and
    /// should travel with it across machines (the Kindle import ledger
    /// today; room for more, e.g. an OCR cache, later). Visible, not a
    /// dot-folder, for the 1.8.3 reason: cloud clients skip hidden items, so
    /// a hidden ledger would look synced while never leaving one Mac. Not
    /// notes, so the scan excludes it by name like Templates/Trash.
    public nonisolated static let dataFolderName = "Envy Data"

    public var dataDirectory: URL {
        noteDirectory.appendingPathComponent(Self.dataFolderName, isDirectory: true)
    }

    public var trashDirectory: URL {
        noteDirectory.appendingPathComponent(Self.trashFolderName, isDirectory: true)
    }

    /// Every legacy per-folder `.trash` directory anywhere under `directory`
    /// — only migration walks these now.
    nonisolated private static func allLegacyTrashDirectories(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == legacyTrashDirectoryName,
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
    /// accumulates between emptyTrash() sweeps). Runs off the main actor via
    /// refreshTrashedNotes(). Walks only the root `Trash/` subtree now — far
    /// cheaper than the old whole-vault hunt for per-folder `.trash` dirs,
    /// which paid a full tree walk even when the trash was empty.
    nonisolated private static func scanTrashedNotes(under directory: URL) -> [Note] {
        let trashRoot = directory.appendingPathComponent(trashFolderName, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: trashRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [Note] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            results.append(Note(id: url.path, url: url, content: content, modifiedDate: modified))
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

    /// Writes an imported note (e.g. from Apple Notes) into `directory`,
    /// stamping the file's dates to `date` so it sorts by when it was actually
    /// written rather than the moment of import. `directory` is the Index's
    /// `Inbox/` folder or the Index root itself, depending on whether the user
    /// wants imports treated as fleeting notes or filed straight in.
    ///
    /// Static and store-free on purpose: the Apple Notes importer runs from the
    /// Settings scene, which has no live NoteStore, and writes straight to disk
    /// — the running app's file-watcher then surfaces the new notes the same way
    /// it would any external edit. Reuses the same filename disambiguation so
    /// imported notes sit beside hand-made ones indistinguishably.
    ///
    /// Returns the file it wrote, or nil if the write failed.
    @discardableResult
    public nonisolated static func writeImportedNote(
        titled title: String, content: String, date: Date, directory: URL
    ) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(uniqueFilename(for: title, in: directory))
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        // Stamp both dates: creation so a future "sort by created" is honest,
        // modification because that's what the list actually sorts on today.
        try? FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Subfolders (for folder-color categorisation)

    /// The Index's subfolders as paths relative to its root (e.g. "Projects",
    /// "Projects/Work"), sorted, excluding the folders that aren't user
    /// categories: `Templates/`, any hidden `.trash/`, and `Inbox/` (which has
    /// its own fleeting-note meaning). Only meaningful with subfolder scanning
    /// on; the caller gates on that.
    nonisolated public static func subfolders(in directory: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]   // also skips a hidden folder's whole subtree
        ) else { return [] }

        let rootPath = directory.standardizedFileURL.path
        var result: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = url.lastPathComponent
            if name == "Templates" || name == inboxFolderName
                || name == trashFolderName || name == attachmentsFolderName
                || name == dataFolderName {
                enumerator.skipDescendants()
                continue
            }
            // Relative path from the Index root.
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            result.append(String(full.dropFirst(rootPath.count + 1)))
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The subfolder a note lives in, relative to the Index root, or nil when
    /// it sits at the root (or, defensively, outside the Index). Used to look up
    /// the note's folder color; `Inbox/` returns nil here so an inbox note keeps
    /// its own dot rather than a folder color.
    public func subfolderPath(of note: Note) -> String? {
        let rootPath = noteDirectory.standardizedFileURL.path
        let parent = note.url.deletingLastPathComponent().standardizedFileURL.path
        guard parent != rootPath, parent.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(parent.dropFirst(rootPath.count + 1))
        return relative == Self.inboxFolderName ? nil : relative
    }

    /// Moves a note into `subfolder` (a path relative to the Index root), or to
    /// the Index root when `subfolder` is nil/empty. Creates the destination on
    /// demand. The title is always unchanged — a move that would collide with a
    /// same-named note in the destination is refused (returns nil) rather than
    /// silently de-dupped to "Foo (2)", so wiki-links pointing at either note
    /// keep resolving to what they meant. Returns the note at its new location,
    /// or nil if the move failed.
    @discardableResult
    public func moveNote(_ note: Note, toSubfolder subfolder: String?) -> Note? {
        // A nil/empty subfolder means "move to the root"; a named one is
        // sanitized so a "../" can't move the note outside the vault (an
        // unusable path refuses the move rather than escaping).
        let targetDir: URL
        if let subfolder, !subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).isEmpty {
            guard let safe = Self.sanitizedSubfolder(subfolder) else { return nil }
            targetDir = noteDirectory.appendingPathComponent(safe, isDirectory: true)
        } else {
            targetDir = noteDirectory
        }

        // No-op if it's already in that folder.
        if note.url.deletingLastPathComponent().standardizedFileURL == targetDir.standardizedFileURL {
            return note
        }

        markInternalWrite()
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let destination = Self.availableURL(for: note.title, in: targetDir)
        // availableURL de-dups a filename collision to "Foo (2)" — but for a
        // *move* that's a silent title change with no single right answer:
        // half the vault's [[Foo]] links would start resolving to whichever
        // Foo remained. Refusing keeps every link intact; the note stays put.
        // Compare against the sanitized base, NOT the raw title — a title can
        // legally carry ":" or "/" that filenames rewrite to "-", and that
        // deterministic difference is not a collision (it used to be misread
        // as one, which made colon-titled notes refuse to move at all).
        guard destination.deletingPathExtension().lastPathComponent == Self.sanitizedBase(for: note.title) else { return nil }
        guard (try? FileManager.default.moveItem(at: note.url, to: destination)) != nil else { return nil }
        let moved = Note(id: destination.path, url: destination, content: note.content, modifiedDate: note.modifiedDate)
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = moved
        }
        recordIDChange(from: note.id, to: moved.id)
        // Sanitization can still change the title (Contact: → Contact-).
        // That's deterministic, not ambiguous — so rewrite the vault's
        // references the same way rename(_:to:) does, and links keep working.
        if moved.title != note.title {
            updateWikiLinkReferences(from: note.title, to: moved.title)
        }
        return moved
    }

    /// Renames a user subfolder — or, when the new relative path names a
    /// different parent, moves it — carrying every note inside along.
    /// Purely a filesystem + bookkeeping operation: wikilinks are
    /// title-based, so no note content changes at all. Each contained
    /// note's id/url is swapped in place with an id-change recorded, so a
    /// debounced save typed against the old path lands on the new one
    /// instead of resurrecting the old folder. Returns the folder's new
    /// relative path (post-sanitization), or nil when refused: an empty or
    /// unchanged name, a reserved root name (Templates/Inbox/Trash/
    /// Attachments) on either side, a missing source, or a name collision —
    /// merging directories would mean resolving file collisions inside,
    /// a different feature; the one allowed "collision" is a case-only
    /// rename of the folder itself.
    public func renameFolder(from oldPath: String, to newPathRaw: String) -> String? {
        // Sanitize each component the way filenames are (":" → "-"), and reject
        // any "." / ".." so a typed path can't traverse out of the vault; "/"
        // stays meaningful as the separator. The old path is guarded the same
        // way so neither side can point outside.
        guard let newPath = Self.sanitizedSubfolder(newPathRaw),
              Self.sanitizedSubfolder(oldPath) != nil,
              newPath != oldPath else { return nil }

        let reserved = ["Templates", Self.inboxFolderName, Self.trashFolderName, Self.attachmentsFolderName, Self.dataFolderName]
        guard let newFirst = newPath.split(separator: "/").first,
              let oldFirst = oldPath.split(separator: "/").first,
              !reserved.contains(where: { $0.caseInsensitiveCompare(newFirst) == .orderedSame }),
              !reserved.contains(where: { $0.caseInsensitiveCompare(oldFirst) == .orderedSame })
        else { return nil }

        let fm = FileManager.default
        let oldURL = noteDirectory.appendingPathComponent(oldPath, isDirectory: true)
        let newURL = noteDirectory.appendingPathComponent(newPath, isDirectory: true)
        // Belt-and-suspenders: both endpoints must resolve inside the vault.
        guard Self.isContained(oldURL, in: noteDirectory), Self.isContained(newURL, in: noteDirectory) else { return nil }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: oldURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let caseOnly = newPath.lowercased() == oldPath.lowercased()
        if !caseOnly, fm.fileExists(atPath: newURL.path) { return nil }

        markInternalWrite()
        try? fm.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? fm.moveItem(at: oldURL, to: newURL)) != nil else { return nil }

        let oldPrefix = oldURL.path + "/"
        let newPrefix = newURL.path + "/"
        for index in notes.indices where notes[index].url.path.hasPrefix(oldPrefix) {
            let old = notes[index]
            let movedURL = URL(fileURLWithPath: newPrefix + old.url.path.dropFirst(oldPrefix.count))
            notes[index] = Note(id: movedURL.path, url: movedURL, content: old.content, modifiedDate: old.modifiedDate)
            recordIDChange(from: old.id, to: movedURL.path)
        }

        // The Trash mirrors the folder structure (Trash/Work/x.md restores
        // to Work/) — carry the mirror along so restores land in the
        // renamed folder rather than resurrecting the old name.
        // Best-effort: left in place if the mirrored destination exists.
        let oldTrash = trashDirectory.appendingPathComponent(oldPath, isDirectory: true)
        if fm.fileExists(atPath: oldTrash.path) {
            let newTrash = trashDirectory.appendingPathComponent(newPath, isDirectory: true)
            if !fm.fileExists(atPath: newTrash.path) {
                markInternalWrite()
                try? fm.createDirectory(at: newTrash.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: oldTrash, to: newTrash)
            }
        }
        return newPath
    }

    // MARK: - Attachments

    /// Where image attachments live: a hidden folder at the Index root.
    /// Dot-prefixed so the note scan's `.skipsHiddenFiles` ignores it
    /// everywhere automatically — the same trick `.trash` uses — meaning a
    /// stored image never shows up as a note or as a colorable subfolder, with
    /// no exclusion code to maintain.
    /// Visible, not dot-hidden (it was `.attachments` before 1.8.3): cloud
    /// sync clients commonly exclude dot-folders by default, which silently
    /// split a vault — notes synced everywhere, images stranded on one
    /// machine. Same reasoning as `Inbox/` being visible: real user data must
    /// survive whatever sync pipeline the vault lives in. The note scan
    /// excludes it by name, the `Templates/` way.
    public nonisolated static let attachmentsFolderName = "Attachments"
    nonisolated static let legacyAttachmentsFolderName = ".attachments"

    /// The folder attachments are stored in (created lazily on first write).
    public var attachmentsDirectory: URL {
        noteDirectory.appendingPathComponent(Self.attachmentsFolderName, isDirectory: true)
    }

    /// Resolves an attachment reference (the bare filename from `![[photo.png]]`)
    /// to its file on disk. Names are unique within `.attachments`, so a
    /// reference resolves the same from any note wherever it sits — mirroring
    /// how a wiki-link resolves by title across the whole Index.
    public func attachmentURL(forName name: String) -> URL {
        // The name is untrusted note text (from `![[name]]`), so contain it to a
        // single leaf inside `.attachments/`: strip any directory parts and
        // refuse "."/"..", so a crafted embed like `![[../../secret.png]]` can
        // never resolve outside the folder (which would otherwise let merely
        // opening a note read, OCR, open, or even move an arbitrary file).
        var leaf = (name as NSString).lastPathComponent
        if leaf == "." || leaf == ".." || leaf.isEmpty { leaf = "\u{FFFD}" }
        return attachmentsDirectory.appendingPathComponent(leaf)
    }

    /// Whether `url` resolves to `base` or somewhere beneath it — the guard
    /// against a path escaping the vault via `..`. Standardizes first so `..`
    /// segments are collapsed before the prefix check.
    nonisolated static func isContained(_ url: URL, in base: URL) -> Bool {
        let basePath = base.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        return urlPath == basePath || urlPath.hasPrefix(basePath + "/")
    }

    /// A subfolder path relative to the Index root, sanitized for safe use: each
    /// component gets the same "/"→"-" and ":"→"-" rewrite filenames do, empty
    /// components (doubled slashes) are dropped, and any "." or ".." component
    /// is rejected outright so a typed or imported path can never traverse out
    /// of the vault. nil when nothing usable remains.
    nonisolated static func sanitizedSubfolder(_ path: String) -> String? {
        // Sanitize each component inline (a colon becomes "-", as in filenames)
        // rather than through sanitizedBase, whose "Untitled" fallback would turn
        // an empty/whitespace component into a real folder. Empty components are
        // dropped; a "." / ".." component refuses the whole path.
        let components = path.split(separator: "/").compactMap { raw -> String? in
            let component = String(raw)
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return component.isEmpty ? nil : component
        }
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return components.joined(separator: "/")
    }

    /// Copies an external file into `.attachments`, leaving the original where
    /// it is, and returns the stored filename to reference as `![[name]]` (nil
    /// on failure). Copy, not move, is deliberate: a file dragged from
    /// Downloads/Desktop stays put and the vault gets its own duplicate.
    @discardableResult
    public func copyAttachment(from source: URL) -> String? {
        let dir = attachmentsDirectory
        markInternalWrite()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = Self.availableAttachmentName(source.lastPathComponent, in: dir)
        guard (try? FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(name))) != nil else { return nil }
        return name
    }

    /// Writes raw image data (e.g. pasted from the clipboard, which has no
    /// source file to copy) into `.attachments` as `base.ext`, returning the
    /// stored filename.
    @discardableResult
    public func saveAttachment(data: Data, base: String, ext: String) -> String? {
        let dir = attachmentsDirectory
        markInternalWrite()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cleaned = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = Self.availableAttachmentName("\(cleaned.isEmpty ? "Pasted image" : cleaned).\(ext)", in: dir)
        guard (try? data.write(to: dir.appendingPathComponent(name))) != nil else { return nil }
        return name
    }

    /// Renames an attachment file, de-duping the target name, and returns the
    /// name it actually landed under (nil if the source is missing or the move
    /// failed). Callers update the `![[...]]` references themselves.
    @discardableResult
    public func renameAttachment(from oldName: String, to newName: String) -> String? {
        let dir = attachmentsDirectory
        // Contain the source: `oldName` is untrusted note text, and a rename
        // moves the file, so a "../" source must never point outside the folder
        // (that would relocate an arbitrary file into the vault).
        let source = attachmentURL(forName: oldName)
        guard Self.isContained(source, in: dir),
              source.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL,
              FileManager.default.fileExists(atPath: source.path) else { return nil }
        markInternalWrite()
        let finalName = Self.availableAttachmentName(newName, in: dir)
        guard finalName != oldName else { return oldName }
        guard (try? FileManager.default.moveItem(at: source, to: dir.appendingPathComponent(finalName))) != nil else { return nil }
        // The same image can be embedded in any number of notes — rewriting
        // only the note the rename was invoked from (which the editor does to
        // its own live text) would leave every other referrer with a permanent
        // missing-image placeholder.
        updateAttachmentReferences(from: oldName, to: finalName)
        return finalName
    }

    /// After an attachment rename, rewrite every `![[old.png]]` (including
    /// `![[old.png|300]]` / `![[old.png|300|caption]]` — the size/caption
    /// suffix survives via group 2) across the vault. Mirrors
    /// updateWikiLinkReferences: candidates come from the wikiLinks cache, and
    /// a reference-only rewrite keeps each note's modified date so renaming a
    /// picture doesn't shove its referrers to the top of a date-sorted list.
    private func updateAttachmentReferences(from oldName: String, to newName: String) {
        guard oldName.caseInsensitiveCompare(newName) != .orderedSame else { return }
        let oldLower = oldName.lowercased()
        let escaped = NSRegularExpression.escapedPattern(for: oldName)
        guard let regex = try? NSRegularExpression(
            pattern: "!\\[\\[[ \\t]*\(escaped)[ \\t]*(\\|[^\\[\\]]*)?\\]\\]",
            options: [.caseInsensitive]
        ) else { return }
        let template = "![[" + NSRegularExpression.escapedTemplate(for: newName) + "$1]]"

        for idx in notes.indices where notes[idx].wikiLinks.contains(oldLower) {
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
            notes[idx].content = updated
        }
    }

    /// Every image in the `.attachments` folder, newest first — for the
    /// "Insert Image" picker, so a picture can be chosen by sight rather than
    /// by remembering its (often meaningless) filename.
    public func imageAttachments() -> [URL] {
        let dir = attachmentsDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return items
            .filter { Note.imageAttachmentExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { modified($0) > modified($1) }
    }

    /// Extension-preserving de-dup (unlike `uniqueFilename`, which forces
    /// `.md`): "photo.png" → "photo.png", then "photo (2).png", … so an
    /// attachment keeps its real type.
    nonisolated static func availableAttachmentName(_ filename: String, in directory: URL) -> String {
        let ns = filename as NSString
        let ext = ns.pathExtension
        let base = (ns.deletingPathExtension as String)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = base.isEmpty ? "attachment" : base
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        func assembled(_ b: String) -> String { ext.isEmpty ? b : "\(b).\(ext)" }
        guard existing.contains(assembled(safeBase)) else { return assembled(safeBase) }
        var counter = 2
        while existing.contains(assembled("\(safeBase) (\(counter))")) { counter += 1 }
        return assembled("\(safeBase) (\(counter))")
    }

    /// Files a fleeting note into The Index proper — a plain move out of
    /// `Inbox/`. The note's text is untouched, so nothing about having been
    /// fleeting survives in the file.
    @discardableResult
    public func submitFromInbox(_ note: Note, toSubfolder subfolder: String? = nil) -> Note? {
        // A thin wrapper now: submit is just "move out of Inbox/" — to the
        // root by default, or straight into a chosen subfolder — and
        // moveNote already carries everything submit used to duplicate
        // (collision refusal, the rename map, sanitization link rewrites).
        guard isInboxNote(note) else { return nil }
        return moveNote(note, toSubfolder: subfolder)
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

    // MARK: - Extracting a selection into its own note

    /// Splits a selection being extracted into its own note into a title and a
    /// body — the "one idea per note" move, done to text you've already written.
    ///
    /// The title is the selection's first non-empty line when that line is short
    /// enough to read as a name, and the rest of the selection becomes the body,
    /// so a note doesn't repeat its own title. When the first line is too long to
    /// serve as one, the title becomes a truncation of it and the *entire*
    /// selection is kept as the body: a shortened title is a summary, not a copy,
    /// so dropping the line it came from would lose words you wrote.
    ///
    /// Leading Markdown markers (`#`, `-`, `>`, `1.`) are stripped from the title
    /// so extracting a heading or a bullet doesn't bake punctuation into a
    /// filename, while the body keeps them exactly as typed.
    public nonisolated static func extractedTitleAndBody(from selection: String) -> (title: String, body: String) {
        let maxTitle = 60
        let lines = selection.components(separatedBy: "\n")
        let whole = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstIdx = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            return ("Untitled", whole)
        }

        let candidate = strippingLeadingMarkers(lines[firstIdx].trimmingCharacters(in: .whitespaces))
        guard !candidate.isEmpty else { return ("Untitled", whole) }

        if candidate.count <= maxTitle {
            let body = lines[(firstIdx + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (sanitizedTitle(candidate), body)
        }

        // Too long for a name: title summarises, body keeps everything.
        var truncated = ""
        for word in candidate.split(separator: " ") {
            if truncated.count + word.count + 1 > maxTitle { break }
            truncated += truncated.isEmpty ? String(word) : " " + word
        }
        if truncated.isEmpty { truncated = String(candidate.prefix(maxTitle)) }
        return (sanitizedTitle(truncated), whole)
    }

    /// Drops a leading heading/bullet/quote/number marker from a line.
    nonisolated private static func strippingLeadingMarkers(_ line: String) -> String {
        var s = line
        while let first = s.first, first == "#" || first == ">" { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") { s.removeFirst(2) }
        // An ordered-list marker ("12. ")
        if let dot = s.firstIndex(of: "."),
           s[s.startIndex..<dot].allSatisfy(\.isNumber), s.startIndex != dot,
           s.index(after: dot) < s.endIndex, s[s.index(after: dot)] == " " {
            s = String(s[s.index(dot, offsetBy: 2)...])
        }
        // A task checkbox left over after the bullet
        if s.hasPrefix("[ ] ") || s.hasPrefix("[x] ") || s.hasPrefix("[X] ") { s.removeFirst(4) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func sanitizedTitle(_ s: String) -> String {
        let cleaned = s
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// The cutoff for `stale:` — notes untouched since this date are stale.
    ///
    /// Bare `stale:` means six months, long enough that anything it surfaces is
    /// genuinely out of mind rather than merely last week's work. Returns nil for
    /// a value that isn't a recognised period, which the caller treats as "no
    /// filter" — the same lenient fallback `date:` uses, so a typo shows you
    /// everything rather than an unexplained empty list.
    nonisolated static func staleCutoff(for value: String) -> Date? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        let calendar = Calendar.current
        let now = Date()
        if v.isEmpty { return calendar.date(byAdding: .month, value: -6, to: now) }
        switch v {
        case "week": return calendar.date(byAdding: .day, value: -7, to: now)
        case "month": return calendar.date(byAdding: .month, value: -1, to: now)
        case "year": return calendar.date(byAdding: .year, value: -1, to: now)
        default:
            let digits = v.hasSuffix("d") ? String(v.dropLast()) : v
            guard let days = Int(digits), days > 0 else { return nil }
            return calendar.date(byAdding: .day, value: -days, to: now)
        }
    }

    nonisolated static func availableURL(for title: String, in directory: URL) -> URL {
        directory.appendingPathComponent(uniqueFilename(for: title, in: directory))
    }

    /// The full rescan, kicked off the main actor: the scan itself is cheap
    /// (trash holds few notes) but *finding* the `.trash` folders walks the
    /// entire vault subtree, which scales with the vault, not the trash.
    /// Only reload() needs this — the store's own trash mutations
    /// (delete/restore/empty) know exactly which notes moved and update
    /// `trashedNotes` in memory instead, keeping the "updates immediately"
    /// guarantee its doc comment makes without any disk walk at all.
    /// Generation-guarded the same way reload() is, so overlapping
    /// refreshes can't assign results out of order.
    private var trashRefreshGeneration = 0
    private func refreshTrashedNotes() {
        trashRefreshGeneration += 1
        let generation = trashRefreshGeneration
        let directory = noteDirectory
        Task {
            let scanned = await Task.detached(priority: .utility) {
                Self.scanTrashedNotes(under: directory)
            }.value
            guard generation == self.trashRefreshGeneration else { return }
            self.trashedNotes = scanned
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

    /// Soft-deletes by moving each note's file into the Index's own `Trash/`
    /// — not straight to the real macOS Trash, so it stays fully reversible
    /// via restoreLastDeleted() (or, later, restoreFromTrash(_:)) until
    /// emptyTrash() eventually sweeps it further. The destination mirrors the
    /// note's origin folder (`Work/x.md` → `Trash/Work/x.md`), which is what
    /// restoreFromTrash reads the way home from.
    public func delete(_ notesToDelete: [Note]) {
        guard !notesToDelete.isEmpty else { return }
        markInternalWrite()
        var trashed: [(note: Note, trashedURL: URL)] = []
        let rootPath = noteDirectory.standardizedFileURL.path
        for note in notesToDelete {
            // Raw relative path, not subfolderPath(of:) — that helper
            // deliberately reports nil for Inbox/ (a folder-color concern),
            // and an inbox note must restore back to the Inbox.
            var destinationDirectory = trashDirectory
            let parent = note.url.deletingLastPathComponent().standardizedFileURL.path
            if parent != rootPath, parent.hasPrefix(rootPath + "/") {
                destinationDirectory = trashDirectory.appendingPathComponent(
                    String(parent.dropFirst(rootPath.count + 1)), isDirectory: true)
            }
            try? FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let filename = Self.uniqueFilename(for: note.title, in: destinationDirectory)
            let destination = destinationDirectory.appendingPathComponent(filename)
            do {
                try FileManager.default.moveItem(at: note.url, to: destination)
                trashed.append((note, destination))
            } catch {
                continue
            }
        }
        lastDeleted = trashed
        // Only the notes whose move actually succeeded leave the list — a note
        // whose trash move threw is still sitting on disk, and dropping it
        // from the UI anyway would make it vanish until the next full reload.
        let deletedIDs = Set(trashed.map(\.note.id))
        notes.removeAll { deletedIDs.contains($0.id) }
        for entry in trashed {
            // A pending debounced save follows the note into .trash, so words
            // typed just before the delete survive a restore.
            recordFileRelocation(from: entry.note.id, to: entry.trashedURL)
        }
        let newlyTrashed = trashed.map { Note(id: $0.trashedURL.path, url: $0.trashedURL, content: $0.note.content, modifiedDate: $0.note.modifiedDate) }
        trashedNotes = (trashedNotes + newlyTrashed).sorted { $0.modifiedDate > $1.modifiedDate }
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
        // A trashed note's id is its path inside .trash/ — collected here so
        // the trashedNotes removal below matches where each note was
        // sitting, not where it went back to.
        var restoredTrashPaths = Set<String>()
        for (note, trashedURL) in lastDeleted {
            guard !FileManager.default.fileExists(atPath: note.url.path) else { continue }
            do {
                try FileManager.default.moveItem(at: trashedURL, to: note.url)
                restored.append(note)
                restoredTrashPaths.insert(trashedURL.path)
            } catch {
                continue
            }
        }
        lastDeleted = []
        notes.append(contentsOf: restored)
        trashedNotes.removeAll { restoredTrashPaths.contains($0.id) }
        return restored
    }

    /// Restores an arbitrary trashed note found via `trashedNotes`/`trash:`
    /// search — unlike restoreLastDeleted() (which only remembers the most
    /// recent delete, and only for the lifetime of the app process), this
    /// works for anything currently sitting in any `.trash` subfolder,
    /// including ones left over from a previous session. Lands back in the
    /// folder it was deleted from — read straight off the note's position
    /// inside `Trash/`, whose subpaths mirror the vault (`Trash/Work/x.md`
    /// came from `Work/`). A file found in a legacy per-folder `.trash`
    /// (pre-1.8.3 leftovers) restores beside that `.trash`, the old way.
    @discardableResult
    public func restoreFromTrash(_ note: Note) -> Note? {
        let parent = note.url.deletingLastPathComponent().standardizedFileURL.path
        let trashRoot = trashDirectory.standardizedFileURL.path
        let destinationDirectory: URL
        if parent == trashRoot {
            destinationDirectory = noteDirectory
        } else if parent.hasPrefix(trashRoot + "/") {
            destinationDirectory = noteDirectory.appendingPathComponent(
                String(parent.dropFirst(trashRoot.count + 1)), isDirectory: true)
        } else {
            destinationDirectory = note.url.deletingLastPathComponent().deletingLastPathComponent()
        }
        // The origin folder may have been deleted/renamed since — recreate it
        // rather than failing the restore.
        try? FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
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
        trashedNotes.removeAll { $0.id == note.id }
        return restored
    }

    /// Moves one trashed note straight into the real macOS Trash — the same
    /// thing emptyTrash() does in bulk on its own schedule, just for a
    /// single item picked out via `trashedNotes`/`trash:` search, still
    /// recoverable afterward via Finder's own Trash.
    public func deleteFromTrash(_ note: Note) {
        markInternalWrite()
        try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        trashedNotes.removeAll { $0.id == note.id }
    }

    /// Sweeps everything currently sitting in any of The Index's `.trash`
    /// subfolders into the real macOS Trash — the second, slower stage of
    /// deletion after delete(_:)'s own soft-delete. Called on a schedule by
    /// TrashPreference in the app layer, not tied to any particular delete;
    /// a lastDeleted entry pointing at something this just swept away simply
    /// fails its restore silently (see restoreLastDeleted()'s own doc
    /// comment), so no extra bookkeeping is needed here for that.
    public func emptyTrash() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: trashDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), !entries.isEmpty else { return }
        // Top-level entries are loose (root-deleted) notes plus the mirror
        // folders; trashing each moves whole subtrees to the macOS Trash in
        // one go and leaves Trash/ itself empty.
        for url in entries {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        markInternalWrite()
        trashedNotes = []
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
        recordIDChange(from: note.id, to: renamed.id)
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
    /// Cleans arbitrary text into a valid tag name: drops a leading `#` and
    /// any character a tag can't contain (Note.tagRegex's `[A-Za-z0-9_-]`).
    /// Empty means "not a usable name."
    nonisolated public static func sanitizedTagName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        return String(String.UnicodeScalarView(body.unicodeScalars.filter { allowed.contains($0) }))
    }

    /// Rewrites every `#oldName` to `#newName` across the whole vault, the
    /// tag-wide twin of the note-rename reference rewrite above. Matches the
    /// tag case-insensitively at its real boundaries (so `#work` is renamed
    /// but `#workshop` and `homework#work` are left alone), preserves each
    /// note's modified date (a global rename shouldn't reshuffle a
    /// date-sorted list), and only touches notes that actually carry the
    /// tag. Caller sanitizes/validates the new name; this no-ops on an empty
    /// or unchanged one.
    public func renameTag(from oldName: String, to newName: String) {
        let old = oldName.lowercased()
        let new = Self.sanitizedTagName(newName)
        guard !new.isEmpty, new != old else { return }
        let escaped = NSRegularExpression.escapedPattern(for: old)
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\w#])#\(escaped)(?![A-Za-z0-9_-])",
            options: [.caseInsensitive]
        ) else { return }
        let template = "#" + NSRegularExpression.escapedTemplate(for: new)

        for idx in notes.indices where notes[idx].tags.contains(old) {
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
            notes[idx].content = updated
        }
    }

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

        for idx in notes.indices where notes[idx].wikiLinks.contains(oldLower) {
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

    /// The whole-word matcher for a closed "quoted phrase" — the phrase
    /// bounded by non-word characters on both sides, so "nee" doesn't match
    /// inside "needed". Unicode-aware word classes, so accented letters and
    /// digits count as part of a word. Compiled once per phrase per search
    /// (the compile is the expensive half; matching is cheap), never per
    /// note — the pattern is fully escaped, so compilation can't realistically
    /// fail.
    nonisolated private static func wholeWordRegex(for phrase: String) -> NSRegularExpression? {
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}_])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    nonisolated private static func wholeWordContains(_ haystack: String, _ regex: NSRegularExpression) -> Bool {
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
        Self.filtered(notes, query: query, root: noteDirectory)
    }

    /// The full search over an explicit snapshot, callable from off the
    /// main actor — with a large library the scan-and-rank is real work
    /// (the first typed character matches nearly everything), and running
    /// it on the main thread visibly delayed the keystrokes queued behind
    /// it. The UI captures `notes` and runs this on a background task,
    /// assigning only the result back on the main actor.
    /// `root` (The Index's own directory) is what folder: paths resolve
    /// against — nil (tests, callers without one) falls back to matching a
    /// note's immediate parent-folder name only.
    nonisolated public static func filtered(_ notes: [Note], query: String, root: URL? = nil, imageText: [String: String] = [:], foldImageText: Bool = false, inboxEnabled: Bool = true) -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return notes }

        let groups = splitGroups(trimmed)
        guard !groups.isEmpty else { return notes }

        if groups.count == 1 {
            return matched(in: notes, forGroup: groups[0], root: root, imageText: imageText, foldImageText: foldImageText, inboxEnabled: inboxEnabled).sorted(by: rankedHigherFirst).map(\.0)
        }

        var bestScoreByID: [String: Int] = [:]
        var noteByID: [String: Note] = [:]
        for group in groups {
            for (note, score) in matched(in: notes, forGroup: group, root: root, imageText: imageText, foldImageText: foldImageText, inboxEnabled: inboxEnabled) {
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
    /// Splits a query into its comma-separated OR groups — but only on
    /// commas *outside* double quotes, mirroring tokenize()'s own quote
    /// handling. A naive split broke any quoted argument containing a
    /// comma: interlink:"Debrief (Sep 24, 2025)" split mid-title into two
    /// meaningless groups. An unterminated quote swallows every comma after
    /// it, matching how an open quote already behaves for spaces.
    nonisolated static func splitGroups(_ query: String) -> [String] {
        var groups: [String] = []
        var current = ""
        var inQuotes = false
        for character in query {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == "," && !inQuotes {
                let group = current.trimmingCharacters(in: .whitespaces)
                if !group.isEmpty { groups.append(group) }
                current = ""
            } else {
                current.append(character)
            }
        }
        let group = current.trimmingCharacters(in: .whitespaces)
        if !group.isEmpty { groups.append(group) }
        return groups
    }

    nonisolated public static func unquote(_ text: String) -> String {
        var result = text
        if result.hasPrefix("\"") { result.removeFirst() }
        if result.hasSuffix("\"") { result.removeLast() }
        return result
    }

    /// An operator's argument, split into its text and whether it was
    /// quoted. Quoting now *demands exactness* — tag:"work" matches only
    /// #work, folder:"Work" only that folder (and its descendants) — while
    /// a bare argument keeps the friendlier partial match (tag:techn
    /// matches #technology). The tag/folder browsers and chips generate the
    /// quoted form, so the count a row shows is exactly what clicking it
    /// yields.
    nonisolated private static func operatorArgument(_ raw: String) -> (text: String, exact: Bool)? {
        let quoted = raw.hasPrefix("\"")
        let text = unquote(raw)
        guard !text.isEmpty else { return nil }
        return (text, quoted)
    }

    /// folder:'s matching rule: exact means the folder itself or anything
    /// nested inside it; partial means the path merely contains the text
    /// (so "work" also hits "workshop" — fine while typing, wrong for a
    /// click on a specific folder).
    nonisolated private static func folderMatches(_ path: String, filter: (text: String, exact: Bool)) -> Bool {
        if filter.exact { return path == filter.text || path.hasPrefix(filter.text + "/") }
        return fastContains(path, filter.text)
    }

    /// tag:'s matching rule, same shape as folderMatches (minus the
    /// descendant case — tags have no hierarchy).
    nonisolated private static func tagMatches(_ tag: String, filter: (text: String, exact: Bool)) -> Bool {
        filter.exact ? tag == filter.text : fastContains(tag, filter.text)
    }

    /// A note's folder path relative to the Index root, lowercased ("" at
    /// the root, "projects/work" nested) — what folder: matches against.
    /// Without a root there's no way to know where the vault starts, so the
    /// fallback matches the immediate parent folder's name only.
    nonisolated private static func relativeFolderPath(of note: Note, rootLower: String?) -> String {
        let parentURL = note.url.deletingLastPathComponent()
        guard let rootLower else { return parentURL.lastPathComponent.lowercased() }
        let parent = parentURL.path.lowercased()
        if parent == rootLower { return "" }
        if parent.hasPrefix(rootLower + "/") { return String(parent.dropFirst(rootLower.count + 1)) }
        return parentURL.lastPathComponent.lowercased()
    }

    nonisolated private static func matched(in notes: [Note], forGroup group: String, root: URL? = nil, imageText: [String: String] = [:], foldImageText: Bool = false, inboxEnabled: Bool = true) -> [(Note, Int)] {
        let q = group.lowercased()
        let tokens = Self.tokenize(q)

        var tagFilter: (text: String, exact: Bool)?
        var excludeTags: [(text: String, exact: Bool)] = []
        var dateFilter: (start: Date, end: Date)?
        var staleCutoff: Date?
        var excludeStaleCutoff: Date?
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
        var isImageOnly = false
        var isImageExcluded = false
        var isEmbedOnly = false
        var isEmbedExcluded = false
        var linkFilter: String?
        var excludeLinks: [String] = []
        var interlinkFilter: String?
        var excludeInterlinks: [String] = []
        var folderFilter: (text: String, exact: Bool)?
        var excludeFolders: [(text: String, exact: Bool)] = []
        var isFolderedOnly = false     // bare folder: — any note in a subfolder
        var isRootOnly = false         // bare -folder: — notes at the Index root
        var titleTerms: [String] = []
        var excludeTitles: [String] = []
        var isTaggedOnly = false       // bare tag: — carries any tag
        var isUntaggedOnly = false     // bare -tag: — completely untagged
        var isGhostOnly = false        // ghost: — has an unresolved [[link]]
        var isGhostExcluded = false    // -ghost: — every link resolves
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
                // With the inbox disabled the operator is inert (the fleeting
                // concept doesn't exist), but the token is still consumed so it
                // never leaks in as a literal free term.
                if inboxEnabled { isInboxExcluded = true }
            } else if token.hasPrefix("inbox:") {
                // A bare "inbox:" scopes to fleeting notes; anything after
                // the colon is ordinary search text within them, so it falls
                // through to freeTerms below like any other operator's
                // trailing words. Disabled: no scoping, but trailing text still
                // searches.
                if inboxEnabled { isInboxOnly = true }
                let rest = String(token.dropFirst("inbox:".count))
                if !rest.isEmpty { freeTerms.append(rest) }
            } else if token == "-todo:" {
                isTodoExcluded = true
            } else if token == "todo:" {
                isTodoOnly = true
            } else if token == "-img:" {
                isImageExcluded = true
            } else if token.hasPrefix("img:") {
                // Bare "img:" scopes to notes holding an image attachment;
                // trailing text searches within them, same shape as inbox:.
                isImageOnly = true
                let rest = String(token.dropFirst("img:".count))
                if !rest.isEmpty { freeTerms.append(rest) }
            } else if token == "-embed:" {
                isEmbedExcluded = true
            } else if token.hasPrefix("embed:") {
                // Bare "embed:" scopes to notes that transclude another note.
                isEmbedOnly = true
                let rest = String(token.dropFirst("embed:".count))
                if !rest.isEmpty { freeTerms.append(rest) }
            } else if token.hasPrefix("-ai:") {
                if excludeAiCondition == nil {
                    excludeAiCondition = AIFilter.parse(String(token.dropFirst("-ai:".count)))
                }
            } else if token.hasPrefix("ai:") {
                if aiCondition == nil {
                    aiCondition = AIFilter.parse(String(token.dropFirst("ai:".count)))
                }
            } else if token == "tag:" {
                // Bare forms, on the folder: model: tag: alone is "carries
                // any tag at all", -tag: alone is the untagged — which makes
                // "-tag: orphan: stale:" the full hygiene sweep.
                isTaggedOnly = true
            } else if token == "-tag:" {
                isUntaggedOnly = true
            } else if token.hasPrefix("-tag:") {
                if let arg = operatorArgument(String(token.dropFirst("-tag:".count))) { excludeTags.append(arg) }
            } else if token.hasPrefix("tag:") {
                if tagFilter == nil {
                    tagFilter = operatorArgument(String(token.dropFirst("tag:".count)))
                }
            } else if token.hasPrefix("-title:") {
                let term = unquote(String(token.dropFirst("-title:".count)))
                if !term.isEmpty { excludeTitles.append(term) }
            } else if token.hasPrefix("title:") {
                // Restricts matching to titles only — free text also matches
                // bodies, which at a large vault buries the note *named* for
                // a thing under every note that merely mentions it. Several
                // title: terms AND together, like free terms.
                let term = unquote(String(token.dropFirst("title:".count)))
                if !term.isEmpty { titleTerms.append(term) }
            } else if token.hasPrefix("date:") {
                if dateFilter == nil {
                    dateFilter = Self.dateRange(for: String(token.dropFirst("date:".count)))
                }
            } else if token.hasPrefix("-stale:") {
                if excludeStaleCutoff == nil {
                    excludeStaleCutoff = Self.staleCutoff(for: String(token.dropFirst("-stale:".count)))
                }
            } else if token.hasPrefix("stale:") {
                if staleCutoff == nil {
                    staleCutoff = Self.staleCutoff(for: String(token.dropFirst("stale:".count)))
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
            } else if token == "ghost:" {
                // Notes carrying at least one unresolved [[link]] — a link
                // whose target note doesn't exist yet. The file-list twin of
                // the editor's dimmed ghost links: where the unkept promises
                // are.
                isGhostOnly = true
            } else if token == "-ghost:" {
                isGhostExcluded = true
            } else if token == "linked:" {
                // The complement of orphan: — notes with at least one link
                // in or out, i.e. part of the web rather than adrift.
                isLinkedOnly = true
            } else if token == "orphan:" {
                // Notes adrift from the link graph — nothing points at them
                // and they point at nothing. Zettelkasten hygiene: the
                // backlink half is corpus-wide, computed once below.
                isOrphanOnly = true
            } else if token == "folder:" {
                isFolderedOnly = true
            } else if token == "-folder:" {
                isRootOnly = true
            } else if token.hasPrefix("-folder:") {
                if let arg = operatorArgument(String(token.dropFirst("-folder:".count))) { excludeFolders.append(arg) }
            } else if token.hasPrefix("folder:") {
                // Notes filed under that folder — bare arguments are partial
                // and case-insensitive like tag: (folder:proj matches
                // Projects), matched against the note's whole relative path,
                // so a nested folder is findable by any of its segments.
                // Quoted arguments are exact-or-descendant (see
                // operatorArgument). First one wins, like tag:.
                if folderFilter == nil {
                    folderFilter = operatorArgument(String(token.dropFirst("folder:".count)))
                }
            } else if token.hasPrefix("-interlink:") {
                let target = unquote(String(token.dropFirst("-interlink:".count)))
                if !target.isEmpty { excludeInterlinks.append(target) }
            } else if token.hasPrefix("interlink:") {
                // Everything connected to Target in either direction — notes
                // containing [[Target]] plus the notes Target itself links
                // out to: the Interlinks footer as a searchable list (minus
                // Suggested, which are mentions, not real links). First one
                // wins, like link:.
                if interlinkFilter == nil {
                    let target = unquote(String(token.dropFirst("interlink:".count)))
                    interlinkFilter = target.isEmpty ? nil : target
                }
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
            || isImageOnly || isImageExcluded || isEmbedOnly || isEmbedExcluded
            || linkFilter != nil || !excludeLinks.isEmpty || isOrphanOnly || isLinkedOnly
            || interlinkFilter != nil || !excludeInterlinks.isEmpty
            || folderFilter != nil || !excludeFolders.isEmpty || isFolderedOnly || isRootOnly
            || !titleTerms.isEmpty || !excludeTitles.isEmpty || isTaggedOnly || isUntaggedOnly
            || isGhostOnly || isGhostExcluded
            || isTodoOnly || isTodoExcluded || tagFilter != nil || !excludeTags.isEmpty
            || dateFilter != nil
            || staleCutoff != nil
            || excludeStaleCutoff != nil
            || dueCondition != nil || excludeDueCondition != nil || isDueInvalid
            || aiCondition != nil || excludeAiCondition != nil

        // Every note anything links *to*, across the corpus — the backlink
        // half of orphan:. Computed once, and only when orphan: is actually
        // in the query, since it's a full pass over every note's links.
        let linkedToTitles: Set<String> = (isOrphanOnly || isLinkedOnly)
            ? Set(notes.flatMap { $0.wikiLinks })
            : []

        // ghost:'s reference set — every real note title, built only when the
        // operator is present (same guard linkedToTitles uses).
        let allNoteTitles: Set<String> = (isGhostOnly || isGhostExcluded)
            ? Set(notes.map(\.lowercasedTitle))
            : []

        // interlink:'s outbound half — what the target note itself links out
        // to. One lookup per group (the inbound half is just each candidate's
        // own wikiLinks). A target that doesn't exist leaves this empty, so
        // interlink: gracefully degrades to link:'s inbound-only meaning.
        let interlinkOutbound: Set<String> = interlinkFilter
            .flatMap { target in notes.first { $0.lowercasedTitle == target }?.wikiLinks } ?? []
        let excludeInterlinkOutbound: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: excludeInterlinks.map { target in
                (target, notes.first { $0.lowercasedTitle == target }?.wikiLinks ?? [])
            }
        )

        // Computed once for the whole group rather than per-note — same
        // reasoning as dateRange's own `now`, just needing today's start
        // rather than the current instant.
        let overdueThreshold = Calendar.current.startOfDay(for: Date())

        // Compiled once per group rather than per note — these used to be
        // rebuilt inside the scan, i.e. one regex compile per note per
        // phrase per keystroke.
        let phraseRegexes = phraseTerms.compactMap(Self.wholeWordRegex(for:))
        let excludePhraseRegexes = excludePhrases.compactMap(Self.wholeWordRegex(for:))

        // folder:'s reference point, computed once per group. The path work
        // per note only runs when a folder token is actually present.
        let needsFolderPath = folderFilter != nil || !excludeFolders.isEmpty || isFolderedOnly || isRootOnly
        let rootLower = root?.path.lowercased()

        return notes.compactMap { note -> (Note, Int)? in
            // Membership is the folder the file sits in — there's no flag on
            // a note saying it's fleeting, and there shouldn't be: moving it
            // out of Inbox/ in Finder should file it just as surely as
            // pressing Submit does.
            if isInboxOnly, !Self.isInInboxFolder(note) { return nil }
            if isInboxExcluded, Self.isInInboxFolder(note) { return nil }
            if needsFolderPath {
                let folderPath = Self.relativeFolderPath(of: note, rootLower: rootLower)
                if isFolderedOnly, folderPath.isEmpty { return nil }
                if isRootOnly, !folderPath.isEmpty { return nil }
                if let folderFilter, !Self.folderMatches(folderPath, filter: folderFilter) { return nil }
                if !excludeFolders.isEmpty, excludeFolders.contains(where: { Self.folderMatches(folderPath, filter: $0) }) { return nil }
            }
            if isImageOnly, !note.hasImageEmbed { return nil }
            if isImageExcluded, note.hasImageEmbed { return nil }
            if isEmbedOnly, !note.hasNoteEmbed { return nil }
            if isEmbedExcluded, note.hasNoteEmbed { return nil }
            if let linkFilter, !note.wikiLinks.contains(linkFilter) { return nil }
            if !excludeLinks.isEmpty, note.wikiLinks.contains(where: { excludeLinks.contains($0) }) { return nil }
            if let interlinkFilter {
                // Connected in either direction, excluding the hub note
                // itself — the footer for X lists X's neighbors, not X.
                let connected = note.wikiLinks.contains(interlinkFilter)
                    || interlinkOutbound.contains(note.lowercasedTitle)
                if !connected || note.lowercasedTitle == interlinkFilter { return nil }
            }
            if !excludeInterlinks.isEmpty {
                for target in excludeInterlinks {
                    if note.wikiLinks.contains(target)
                        || (excludeInterlinkOutbound[target]?.contains(note.lowercasedTitle) ?? false) {
                        return nil
                    }
                }
            }
            if isGhostOnly || isGhostExcluded {
                // A ghost link's target answers to no note — image targets
                // aren't notes, so an attachment reference never counts.
                let hasGhost = note.wikiLinks.contains { target in
                    !allNoteTitles.contains(target)
                        && !Note.imageAttachmentExtensions.contains((target as NSString).pathExtension.lowercased())
                }
                if isGhostOnly, !hasGhost { return nil }
                if isGhostExcluded, hasGhost { return nil }
            }
            let noteIsOrphan = note.wikiLinks.isEmpty && !linkedToTitles.contains(note.lowercasedTitle)
            if isOrphanOnly, !noteIsOrphan { return nil }
            if isLinkedOnly, noteIsOrphan { return nil }
            // A note's recognized image text, folded into every term test below —
            // under a scoped `img:` always, and under `foldImageText` (Settings)
            // for ordinary searches too — so inclusions AND exclusions both see
            // it (an exclusion that couldn't see image text would silently fail
            // to exclude a scanned match). Only image notes pay for it; a plain
            // body search over text notes stays free.
            var ocrBlob = ""
            if !imageText.isEmpty, isImageOnly || foldImageText, note.hasImageEmbed {
                for link in note.wikiLinks
                where Note.imageAttachmentExtensions.contains((link as NSString).pathExtension.lowercased()) {
                    if let recognized = imageText[link] { ocrBlob += recognized + " " }
                }
            }
            if !phraseRegexes.isEmpty {
                let t = note.lowercasedTitle, c = note.lowercasedContent
                for regex in phraseRegexes
                where !(Self.wholeWordContains(t, regex) || Self.wholeWordContains(c, regex)
                        || (!ocrBlob.isEmpty && Self.wholeWordContains(ocrBlob, regex))) {
                    return nil
                }
            }
            if !excludePhraseRegexes.isEmpty {
                let t = note.lowercasedTitle, c = note.lowercasedContent
                if excludePhraseRegexes.contains(where: {
                    Self.wholeWordContains(t, $0) || Self.wholeWordContains(c, $0)
                        || (!ocrBlob.isEmpty && Self.wholeWordContains(ocrBlob, $0))
                }) { return nil }
            }
            if isTodoOnly, !note.hasUncheckedTask { return nil }
            if isTodoExcluded, note.hasUncheckedTask { return nil }
            if !titleTerms.isEmpty {
                for term in titleTerms where !Self.fastContains(note.lowercasedTitle, term) { return nil }
            }
            if !excludeTitles.isEmpty, excludeTitles.contains(where: { Self.fastContains(note.lowercasedTitle, $0) }) { return nil }
            if isTaggedOnly, note.tags.isEmpty { return nil }
            if isUntaggedOnly, !note.tags.isEmpty { return nil }
            if let tagFilter, !note.tags.contains(where: { Self.tagMatches($0, filter: tagFilter) }) { return nil }
            if !excludeTags.isEmpty, note.tags.contains(where: { tag in excludeTags.contains { Self.tagMatches(tag, filter: $0) } }) { return nil }
            if let dateFilter, !(note.modifiedDate >= dateFilter.start && note.modifiedDate < dateFilter.end) { return nil }
            // stale: is date:'s complement — untouched since the cutoff.
            if let staleCutoff, !(note.modifiedDate < staleCutoff) { return nil }
            if let excludeStaleCutoff, note.modifiedDate < excludeStaleCutoff { return nil }
            if isDueInvalid { return nil }
            if let dueCondition, !Self.dueConditionMatches(dueCondition, note: note, overdueThreshold: overdueThreshold) { return nil }
            if let excludeDueCondition, Self.dueConditionMatches(excludeDueCondition, note: note, overdueThreshold: overdueThreshold) { return nil }
            if let aiCondition, !aiCondition.matches(note.aiProvenance) { return nil }
            if let excludeAiCondition, excludeAiCondition.matches(note.aiProvenance) { return nil }
            if !excludeTerms.isEmpty {
                let titleLower = note.lowercasedTitle
                let contentLower = note.lowercasedContent
                if excludeTerms.contains(where: {
                    Self.fastContains(titleLower, $0) || Self.fastContains(contentLower, $0)
                        || (!ocrBlob.isEmpty && Self.fastContains(ocrBlob, $0))
                }) { return nil }
            }

            // An operator (or 2+ free terms) combines with whatever else is
            // typed alongside it via "does every term show up somewhere"
            // scoring — matches original behavior exactly, including that
            // scoreByTermPresence already treats an empty terms list as an
            // automatic 0-score match (a pure operator query like "todo:"
            // with nothing else to search for). `ocrBlob` (computed above) folds
            // the note's image text in.
            if hasOperator || freeTerms.count > 1 {
                return Self.scoreByTermPresence(note: note, terms: freeTerms, extra: ocrBlob).map { (note, $0) }
            }
            guard let term = freeTerms.first else { return (note, 0) }

            // A single free term, no operators — the original scored
            // exact/prefix/contains ranking, with an image-text match added at
            // the content rung (same score as body; Vision gives no better
            // granularity to rank within).
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
            } else if !ocrBlob.isEmpty, Self.fastContains(ocrBlob, term) {
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
    nonisolated private static func scoreByTermPresence(note: Note, terms: [String], extra: String = "") -> Int? {
        guard !terms.isEmpty else { return 0 }
        let titleLower = note.lowercasedTitle
        let contentLower = note.lowercasedContent
        var titleMatches = 0
        for term in terms {
            let inTitle = fastContains(titleLower, term)
            // `extra` is the note's recognized image text under a scoped img:
            // query — a term found only there still counts as a match (like
            // content), just never boosts the title-based ranking.
            guard inTitle || fastContains(contentLower, term)
                || (!extra.isEmpty && fastContains(extra, term)) else { return nil }
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

    /// The one free-filename rule for `title` in `directory`, disambiguating
    /// with " (2)", " (3)" and so on. Every path that names a file —
    /// create, rename, submit-from-inbox, trash — goes through here, so the
    /// same collision always resolves to the same name.
    ///
    /// Parenthesised rather than Finder's bare " 2", which reads as part of
    /// a title — a note actually called "Ideas 2" is entirely plausible.
    /// Compared case-insensitively because APFS is: "ideas" and "Ideas"
    /// already collide at the filesystem level, so matching only exact case
    /// would happily generate a name the OS then refuses. One directory
    /// read up front rather than a fileExists syscall per candidate.
    /// The filename a title produces before any collision de-dup — ":" and
    /// "/" become "-" (path separators on one filesystem layer or the
    /// other). Factored out of uniqueFilename so callers can distinguish
    /// "the filename differs because sanitization rewrote a character"
    /// (deterministic, harmless) from "it differs because a ' (2)' de-dup
    /// was appended" (a real collision with another note).
    nonisolated static func sanitizedBase(for title: String) -> String {
        let sanitized = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Untitled" : sanitized
    }

    nonisolated static func uniqueFilename(for title: String, in directory: URL) -> String {
        let base = sanitizedBase(for: title)
        let existing = Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .map { ($0 as NSString).deletingPathExtension.lowercased() }
        )
        guard existing.contains(base.lowercased()) else { return "\(base).md" }
        var counter = 2
        while existing.contains("\(base) (\(counter))".lowercased()) { counter += 1 }
        return "\(base) (\(counter)).md"
    }
}
