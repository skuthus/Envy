import Foundation
import EnvyCore

/// Pulls notes out of Apple Notes and drops them into Envy's Inbox as fleeting
/// notes, so Apple Notes can serve as the ubiquitous capture front-end (phone,
/// Watch, Siri, lock screen, share sheet) that a Mac-only app can't be.
///
/// Design constraints this shape enforces:
///
/// - **A queue, not a dump.** It reads one designated Apple Notes folder — the
///   "outbox" — never the whole library. After a successful import each note is
///   *moved* to an archive folder, so the outbox is self-draining and Envy
///   keeps zero "already seen" state on disk. Re-running only ever sees what's
///   new. (This is why nothing here writes a watermark.)
///
/// - **Off the hot path.** All AppleScript runs on a detached task; the class
///   only touches the main actor to publish progress. It is never invoked on
///   launch or summon — only when the user asks.
///
/// - **Honest failure.** The first run trips macOS's Automation consent prompt;
///   a denial surfaces as a plain instruction to enable it, not a raw osascript
///   error code.
///
/// AppleScript rather than reading NoteStore.sqlite directly: the database
/// stores note bodies as gzipped protobuf, undocumented and version-fragile.
/// AppleScript is slower but stable and hands back clean HTML.
@MainActor
final class AppleNotesImporter: ObservableObject {

    enum Phase: Equatable {
        case idle
        case reading                       // AppleScript is enumerating the folder
        case writing(done: Int, total: Int)
        case finished(imported: Int, skipped: Int)
        case failed(String)
    }

    /// Shared instance so the File-menu command (and its ⌘⌥I shortcut) and the
    /// Settings tab drive the *same* importer — one can't run while the other
    /// is mid-import, and progress shows in both.
    static let shared = AppleNotesImporter()

    @Published private(set) var phase: Phase = .idle

    var isRunning: Bool {
        switch phase {
        case .reading, .writing: return true
        default: return false
        }
    }

    // Control characters as delimiters: note bodies are HTML text and never
    // contain these, so they can't collide with real content the way a comma
    // or pipe could.
    private static let fieldSep = "\u{001F}"    // between fields of one note
    private static let recordSep = "\u{001E}"   // between notes

    // MARK: - Folder listing (to populate the picker)

    /// Every folder name in Apple Notes, across all accounts, de-duplicated and
    /// sorted. Empty if Notes has no folders or access was denied — the caller
    /// distinguishes the two by whether `runOsascript` threw.
    static func listFolders() async throws -> [String] {
        let script = """
        tell application "Notes"
            set out to ""
            repeat with f in folders
                set out to out & (name of f) & linefeed
            end repeat
            return out
        end tell
        """
        let output = try await runOsascript(script)
        let names = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Import

    /// Reads `folder`, writes each note into the Index's Inbox, then moves the
    /// successfully-written notes into `archive` inside the same account.
    func run(folder: String, archive: String, indexDirectory: URL, toInbox: Bool) async {
        guard !isRunning else { return }
        phase = .reading

        let records: [NoteRecord]
        do {
            records = try await Self.fetchAndArchive(inFolder: folder, archive: archive)
        } catch let error as ImportError {
            phase = .failed(error.message); return
        } catch {
            phase = .failed("Couldn't read Apple Notes: \(error.localizedDescription)"); return
        }

        if records.isEmpty {
            phase = .finished(imported: 0, skipped: 0); return
        }

        // By here the notes have already been read and moved to the archive in
        // a single trip to Apple Notes; all that's left is writing each to the
        // Inbox. A write that fails leaves its note safe in the archive folder
        // (recoverable by hand), just not in Envy — the deliberate trade for
        // halving the Apple Notes round-trips. In practice a local Inbox write
        // doesn't fail: the folder is created on demand.
        // Fleeting notes land in Inbox/; a direct import files them in the
        // Index root, the same place a submitted note would end up.
        let destination = toInbox
            ? indexDirectory.appendingPathComponent(NoteStore.inboxFolderName, isDirectory: true)
            : indexDirectory

        phase = .writing(done: 0, total: records.count)
        var skipped = 0
        for (index, record) in records.enumerated() {
            let title = record.title.isEmpty ? "Untitled" : record.title
            // Apple Notes repeats the title as the body's first line; drop it
            // so the note isn't titled and opened by the same line.
            let markdown = NotesHTMLToMarkdown.stripLeadingTitle(
                NotesHTMLToMarkdown.convert(record.html), title: record.title)
            let written = await Task.detached {
                NoteStore.writeImportedNote(
                    titled: title, content: markdown, date: record.date,
                    directory: destination)
            }.value
            if written == nil { skipped += 1 }
            phase = .writing(done: index + 1, total: records.count)
        }

        phase = .finished(imported: records.count - skipped, skipped: skipped)
    }

    func reset() { phase = .idle }

    // MARK: - AppleScript steps

    private struct NoteRecord {
        var id: String
        var title: String
        var date: Date
        var html: String
    }

    /// One trip to Apple Notes that both reads the outbox and moves its notes
    /// to the archive — the notes are read into `out` first, then moved by id
    /// in a second pass over the captured id list (not over live `notes of
    /// target`, whose indices shift as notes leave, which would skip some).
    ///
    /// Because it's a single AppleScript event executed inside Notes, the two
    /// passes cost nothing extra in Apple-event overhead; the win is not paying
    /// to wake and bridge to Notes a second time for a separate move call.
    private static func fetchAndArchive(inFolder folder: String, archive: String) async throws -> [NoteRecord] {
        let folderName = escapeForAppleScript(folder)
        let archiveName = escapeForAppleScript(archive)
        let script = """
        tell application "Notes"
            set target to missing value
            repeat with f in folders
                if (name of f) is "\(folderName)" then set target to f
            end repeat
            if target is missing value then return "\(errNoFolder)"
            set acct to container of target
            set arch to missing value
            repeat with f in folders of acct
                if (name of f) is "\(archiveName)" then set arch to f
            end repeat
            if arch is missing value then set arch to (make new folder at acct with properties {name:"\(archiveName)"})
            set fs to (ASCII character 31)
            set rs to (ASCII character 30)
            set out to ""
            set movedIDs to {}
            repeat with n in notes of target
                set nid to (id of n as string)
                set d to modification date of n
                set stamp to ((year of d) as string) & "-" & my pad(month of d as integer) & "-" & my pad(day of d) & " " & my pad(hours of d) & ":" & my pad(minutes of d) & ":" & my pad(seconds of d)
                set out to out & nid & fs & (name of n) & fs & stamp & fs & (body of n) & rs
                set end of movedIDs to nid
            end repeat
            repeat with theID in movedIDs
                try
                    move (first note of target whose id is theID) to arch
                end try
            end repeat
            return out
        end tell

        on pad(n)
            set s to n as string
            if (count of s) < 2 then set s to "0" & s
            return s
        end pad
        """
        let output = try await runOsascript(script)
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == errNoFolder {
            throw ImportError(message: "The folder “\(folder)” no longer exists in Apple Notes.")
        }
        return output
            .components(separatedBy: recordSep)
            .compactMap { parseRecord($0) }
    }

    private static func parseRecord(_ raw: String) -> NoteRecord? {
        let fields = raw.components(separatedBy: fieldSep)
        guard fields.count >= 4 else { return nil }
        let id = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let title = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let date = dateParser.date(from: fields[2].trimmingCharacters(in: .whitespaces)) ?? Date()
        let html = fields[3...].joined(separator: fieldSep)   // rejoin if body held a separator
        return NoteRecord(id: id, title: title, date: date, html: html)
    }

    // MARK: - Process plumbing

    private struct ImportError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private static let errNoFolder = "ENVY_ERR_NO_FOLDER"

    /// Runs an AppleScript via `/usr/bin/osascript` on a background thread,
    /// returning stdout. Throws a friendly `ImportError` for the Automation
    /// consent denial, which is the one failure a user can actually act on.
    private static func runOsascript(_ script: String) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let err = String(data: errData, encoding: .utf8) ?? ""
                if err.contains("-1743") || err.localizedCaseInsensitiveContains("not authorized") || err.localizedCaseInsensitiveContains("not allowed") {
                    throw ImportError(message:
                        "Envy needs permission to control Apple Notes. Open System Settings → Privacy & "
                        + "Security → Automation, enable Notes under Envy, then try again.")
                }
                throw ImportError(message: err.isEmpty ? "AppleScript failed." : err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(data: outData, encoding: .utf8) ?? ""
        }.value
    }

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Escapes a string for embedding inside an AppleScript double-quoted
    /// literal. Folder names and Apple's own note ids are the only things
    /// interpolated, but a folder named `My "Notes"` would otherwise break the
    /// script (or worse), so both backslashes and quotes are escaped.
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
