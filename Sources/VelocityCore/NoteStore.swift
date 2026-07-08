import Foundation
import Combine

@MainActor
public final class NoteStore: ObservableObject {
    @Published public private(set) var notes: [Note] = []
    @Published public private(set) var noteDirectories: [URL] = []
    @Published public private(set) var isLoading = false

    private var monitors: [URL: (source: DispatchSourceFileSystemObject, fd: CInt)] = [:]
    private var suppressReloadUntil: Date = .distantPast
    private var reloadGeneration = 0

    public init(directories: [URL]? = nil) {
        let dirs = (directories?.isEmpty == false) ? directories! : [Self.defaultDirectory()]
        self.noteDirectories = dirs
        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        reload()
        startWatchingAll()
    }

    deinit {
        for (_, monitor) in monitors {
            monitor.source.cancel()
            close(monitor.fd)
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
        guard normalized != noteDirectories else { return }
        stopWatchingAll()
        noteDirectories = normalized
        for dir in normalized {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        reload()
        startWatchingAll()
    }

    // MARK: - Loading

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

    nonisolated private static func scanDirectories(_ directories: [URL]) -> [Note] {
        let fm = FileManager.default
        var loaded: [Note] = []

        for directory in directories {
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries {
                guard url.pathExtension.lowercased() == "md" else { continue }
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                // Filename alone isn't unique across multiple folders, so the id
                // has to be the full path.
                loaded.append(Note(id: url.path, url: url, content: content, modifiedDate: modified))
            }
        }

        return loaded.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    // MARK: - Watching for external changes

    private func startWatchingAll() {
        for directory in noteDirectories {
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if Date() < self.suppressReloadUntil { return }
                self.reload()
            }
            source.resume()
            monitors[directory] = (source, fd)
        }
    }

    private func stopWatchingAll() {
        for (_, monitor) in monitors {
            monitor.source.cancel()
            close(monitor.fd)
        }
        monitors.removeAll()
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

    public func save(_ note: Note) {
        markInternalWrite()
        try? note.content.write(to: note.url, atomically: true, encoding: .utf8)
        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx].content = note.content
            notes[idx].modifiedDate = Date()
        }
    }

    public func delete(_ note: Note) {
        markInternalWrite()
        try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        notes.removeAll { $0.id == note.id }
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

    public func exactTitleMatch(for query: String) -> Note? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        return notes.first { $0.title.lowercased() == q }
    }

    public func filtered(query: String) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return notes }

        return notes
            .compactMap { note -> (Note, Int)? in
                let titleLower = note.title.lowercased()
                let contentLower = note.content.lowercased()

                let score: Int
                if titleLower == q {
                    score = 4
                } else if titleLower.hasPrefix(q) {
                    score = 3
                } else if titleLower.contains(q) {
                    score = 2
                } else if contentLower.contains(q) {
                    score = 1
                } else {
                    return nil
                }
                return (note, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.modifiedDate > rhs.0.modifiedDate
            }
            .map(\.0)
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
