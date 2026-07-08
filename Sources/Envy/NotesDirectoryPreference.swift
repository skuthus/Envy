import Foundation
import VelocityCore

/// Persists the list of note folders as newline-joined paths under a single
/// AppStorage-friendly String key (avoids the Codable/RawRepresentable
/// recursion trap that a custom `[URL]`-wrapping type would hit — see Theme.swift).
enum NotesDirectoryPreference {
    static let storageKey = "notesDirectoryPaths"
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

    static func decode(_ raw: String) -> [URL] {
        let paths = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return [] }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func encode(_ urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }
}
