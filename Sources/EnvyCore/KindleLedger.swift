import Foundation

/// The record of which Kindle highlights have already been imported into a
/// vault, so re-importing an append-only `My Clippings.txt` only ever adds
/// what's new. Vault-bound derived state: it lives inside the Index (in
/// `Envy Data/`, see NoteStore.dataFolderName) so it's per-vault and travels
/// with the vault across machines via whatever syncs it — not a preference,
/// not per-Mac. Just a set of record fingerprints (see
/// KindleClippings.Record.key).
public enum KindleLedger {
    private static let filename = "kindle-imported.json"

    public static func url(for indexDirectory: URL) -> URL {
        indexDirectory
            .appendingPathComponent(NoteStore.dataFolderName, isDirectory: true)
            .appendingPathComponent(filename)
    }

    public static func decode(at url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode(Set<String>.self, from: data) else { return nil }
        return keys
    }

    public static func save(_ keys: Set<String>, for indexDirectory: URL) {
        let target = url(for: indexDirectory)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(keys) {
            try? data.write(to: target, options: .atomic)
        }
    }

    /// The vault ledger, folding in a legacy (pre-1.8.9, per-Mac Application
    /// Support) ledger the first time so anyone who imported before the move
    /// keeps their history. The union is intentional — a machine with vault
    /// history *and* its own leftover legacy file loses nothing — and the
    /// migration is persisted, then the legacy file retired, so it runs once.
    public static func load(for indexDirectory: URL, migratingFrom legacyURL: URL?) -> Set<String> {
        let current = decode(at: url(for: indexDirectory)) ?? []
        guard let legacyURL, let legacy = decode(at: legacyURL) else { return current }
        let merged = current.union(legacy)
        save(merged, for: indexDirectory)
        try? FileManager.default.removeItem(at: legacyURL)
        return merged
    }
}
