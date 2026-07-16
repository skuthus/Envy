import Foundation
import EnvyCore

/// Persists the path to The Index — the one folder Envy reads notes from
/// and watches. Migrates forward from two older schemes: the multi-folder
/// list this app used to support (takes its first *enabled* entry — the
/// rest simply stop being part of Envy's view from here on, untouched on
/// disk), and before that, a single legacy path key from even earlier.
enum IndexPreference {
    static let storageKey = "indexPath"
    private static let legacyMultiFolderKey = "notesDirectoryPaths"
    private static let legacyMultiFolderDisabledKey = "disabledNotesDirectoryPaths"
    private static let legacySingleFolderKey = "notesDirectoryPath"

    /// Reads directly from UserDefaults, including migrating both older
    /// schemes. Used for one-time NoteStore construction at launch.
    ///
    /// Whenever `storageKey` itself was empty (a fresh install, or one
    /// still on either older scheme), the resolved path is written back to
    /// `storageKey` before returning — self-healing, so the very next read
    /// (including the `@AppStorage(IndexPreference.storageKey)` Settings
    /// binds directly to, to display and react to changes) sees the real
    /// path immediately rather than staying blank until the user happens
    /// to change it for the first time.
    @MainActor
    static func load() -> URL {
        if let raw = UserDefaults.standard.string(forKey: storageKey), !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        let resolved = migrateFromMultiFolder()
            ?? UserDefaults.standard.string(forKey: legacySingleFolderKey).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? NoteStore.defaultDirectory()
        save(resolved)
        return resolved
    }

    private static func migrateFromMultiFolder() -> URL? {
        guard let rawList = UserDefaults.standard.string(forKey: legacyMultiFolderKey) else { return nil }
        let paths = rawList.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return nil }
        let disabled = Set(
            (UserDefaults.standard.string(forKey: legacyMultiFolderDisabledKey) ?? "")
                .split(separator: "\n").map(String.init)
        )
        let enabled = paths.first { !disabled.contains($0) } ?? paths[0]
        return URL(fileURLWithPath: enabled, isDirectory: true)
    }

    static func save(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: storageKey)
    }
}
