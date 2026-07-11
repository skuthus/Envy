import Foundation
import EnvyCore

/// Persists the list of note folders as newline-joined paths under a single
/// AppStorage-friendly String key (avoids the Codable/RawRepresentable
/// recursion trap that a custom `[URL]`-wrapping type would hit — see Theme.swift).
enum NotesDirectoryPreference {
    static let storageKey = "notesDirectoryPaths"
    /// A folder stays in `storageKey`'s full list (so it's still visible and
    /// re-enable-able in Settings) but its notes are excluded from the
    /// aggregated list — a lighter touch than removing the folder outright.
    static let disabledStorageKey = "disabledNotesDirectoryPaths"
    private static let legacyStorageKey = "notesDirectoryPath"

    /// Reads directly from UserDefaults, including migrating the old
    /// single-folder key. Used for one-time NoteStore construction at launch.
    @MainActor
    static func load() -> [URL] {
        if let raw = UserDefaults.standard.string(forKey: storageKey) {
            let urls = decode(raw)
            if !urls.isEmpty { return urls }
        }
        if let legacyPath = UserDefaults.standard.string(forKey: legacyStorageKey), !legacyPath.isEmpty {
            return [URL(fileURLWithPath: legacyPath, isDirectory: true)]
        }
        return [NoteStore.defaultDirectory()]
    }

    /// `load()` filtered down to folders that aren't disabled — what
    /// NoteStore should actually watch/aggregate. Falls back to the full
    /// list if every folder happens to be disabled, rather than letting
    /// NoteStore's own "no directories" fallback silently switch to an
    /// unrelated default folder.
    @MainActor
    static func loadEnabled() -> [URL] {
        let all = load()
        let disabled = decodeDisabled(UserDefaults.standard.string(forKey: disabledStorageKey) ?? "")
        let enabled = all.filter { !disabled.contains($0.path) }
        return enabled.isEmpty ? all : enabled
    }

    static func decode(_ raw: String) -> [URL] {
        let paths = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return [] }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func encode(_ urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }

    static func decodeDisabled(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    static func encodeDisabled(_ paths: Set<String>) -> String {
        paths.sorted().joined(separator: "\n")
    }
}
