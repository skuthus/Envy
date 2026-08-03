import Foundation
import EnvyCore

/// Imports Kindle highlights and typed notes from a device's
/// `My Clippings.txt` into the Inbox as fleeting notes — one per highlight,
/// titled "first few words, p92", body a blockquote with attribution and
/// #quote (see KindleClippings for the shapes).
///
/// Unlike the Apple Notes importer — whose source is an outbox it drains, so
/// it needs no memory — the Clippings file is append-only and belongs to the
/// Kindle (never rewritten from here). Idempotency therefore comes from a
/// ledger of imported record keys, kept in Application Support: derived
/// bookkeeping, not user data, so it never pollutes or syncs with the vault.
/// The ledger is independent of the notes themselves — submitting, retitling,
/// or deleting an imported fleeting note never resurrects it on re-import.
@MainActor
final class KindleImporter: ObservableObject {

    enum Phase: Equatable {
        case idle
        case reading
        case writing(done: Int, total: Int)
        case finished(imported: Int, alreadyImported: Int)
        case failed(String)
    }

    /// Shared so the File-menu command and the Settings tab drive the same
    /// importer — one can't run while the other is mid-import, and progress
    /// shows in both. (Same shape as AppleNotesImporter.shared.)
    static let shared = KindleImporter()

    @Published private(set) var phase: Phase = .idle

    // MARK: - Device detection

    /// The mounted Kindle's Clippings file, if one is available — any mount
    /// carrying `documents/My Clippings.txt` counts, rather than trusting
    /// its name. Two roots are searched: `/Volumes` (an older Kindle that
    /// mounts as a USB drive) and `~/Moorage` (an MTP Kindle surfaced by the
    /// Moorage mounter, which puts each device at `~/Moorage/<device name>/`
    /// — this is what brings newer, MTP-only Kindles into reach).
    nonisolated static func detectClippingsFile() -> URL? {
        let roots = [
            URL(fileURLWithPath: "/Volumes", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Moorage", isDirectory: true),
        ]
        for root in roots {
            let mounts = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for mount in mounts {
                let candidate = mount.appendingPathComponent("documents/My Clippings.txt")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    // MARK: - Ledger

    /// The pre-1.8.9 per-Mac home, handed to KindleLedger.load once for
    /// migration into the vault.
    nonisolated private static var legacyLedgerURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.skylerschoos.envy"
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("kindle-imported.json")
    }

    // MARK: - Import

    /// Parses the file, writes a fleeting note for every record whose key
    /// isn't in the ledger, and records the newly written keys. The whole
    /// file is scanned every time (it's append-only and small); only new
    /// records cost anything.
    func importClippings(from file: URL, into indexDirectory: URL) async {
        guard phase != .reading, !isWriting else { return }
        phase = .reading

        let parsed: [KindleClippings.Record]
        do {
            let raw = try await Task.detached { try String(contentsOf: file, encoding: .utf8) }.value
            parsed = await Task.detached { KindleClippings.parse(raw) }.value
        } catch {
            phase = .failed("Couldn't read the Clippings file: \(error.localizedDescription)")
            return
        }

        var ledger = KindleLedger.load(for: indexDirectory, migratingFrom: Self.legacyLedgerURL)
        let fresh = parsed.filter { !ledger.contains($0.key) }
        let alreadyImported = parsed.count - fresh.count
        guard !fresh.isEmpty else {
            phase = .finished(imported: 0, alreadyImported: alreadyImported)
            return
        }

        let inbox = indexDirectory.appendingPathComponent(NoteStore.inboxFolderName, isDirectory: true)
        // The title's locator is the user's choice (Settings → Import),
        // defaulting to page — matching the hand-written convention this
        // feature automates.
        let reference = KindleClippings.TitleReference(
            rawValue: UserDefaults.standard.string(forKey: "kindleTitleReference") ?? "") ?? .page
        // Body composition, also the user's choice; both default to included
        // (register-less bool reads false, so invert to keep the default on).
        let includeAuthor = !UserDefaults.standard.bool(forKey: "kindleBodyOmitAuthor")
        let includeLocation = !UserDefaults.standard.bool(forKey: "kindleBodyOmitLocation")
        phase = .writing(done: 0, total: fresh.count)
        var written = 0
        for (index, record) in fresh.enumerated() {
            let url = await Task.detached { () -> URL? in
                NoteStore.writeImportedNote(
                    titled: KindleClippings.title(for: record, reference: reference),
                    content: KindleClippings.noteBody(for: record, includeAuthor: includeAuthor, includeLocation: includeLocation),
                    date: Date(),
                    directory: inbox)
            }.value
            if url != nil {
                written += 1
                ledger.insert(record.key)
            }
            phase = .writing(done: index + 1, total: fresh.count)
        }
        KindleLedger.save(ledger, for: indexDirectory)
        phase = .finished(imported: written, alreadyImported: alreadyImported)
    }

    private var isWriting: Bool {
        if case .writing = phase { return true }
        return false
    }
}
