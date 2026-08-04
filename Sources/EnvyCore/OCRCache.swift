import Foundation

/// Where recognized text lives: a per-machine JSON map of image content-hash →
/// text, in Application Support. It's derived data (a rebuildable index, like
/// NoteDerivedCache), not user data — so it stays out of the vault, raising no
/// sync question, and any Mac reconstructs it from the images themselves (which
/// do sync). Hash-keyed, so it survives renames and dedupes identical images.
public enum OCRCache {

    /// `<Application Support>/<bundle id>/ocr-text.json`. The bundle id keeps
    /// EnvyTest's cache separate from the real app's, same as every other
    /// per-app store.
    public static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.skylerschoos.envy"
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("ocr-text.json")
    }

    public static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL()),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    public static func save(_ map: [String: String]) {
        let url = fileURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
