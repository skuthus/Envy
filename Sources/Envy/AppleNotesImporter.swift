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
    func run(folder: String, archive: String, indexDirectory: URL) async {
        guard !isRunning else { return }
        phase = .reading

        let records: [NoteRecord]
        do {
            records = try await Self.fetchNotes(inFolder: folder)
        } catch let error as ImportError {
            phase = .failed(error.message); return
        } catch {
            phase = .failed("Couldn't read Apple Notes: \(error.localizedDescription)"); return
        }

        if records.isEmpty {
            phase = .finished(imported: 0, skipped: 0); return
        }

        // Write to disk on a background task; the running app's file-watcher
        // picks the new files up on its own.
        phase = .writing(done: 0, total: records.count)
        var importedIDs: [String] = []
        var skipped = 0
        for (index, record) in records.enumerated() {
            let markdown = NotesHTMLToMarkdown.convert(record.html)
            let title = record.title.isEmpty ? "Untitled" : record.title
            let written = await Task.detached {
                NoteStore.writeInboxNote(
                    titled: title, content: markdown, date: record.date,
                    indexDirectory: indexDirectory)
            }.value
            if written != nil {
                importedIDs.append(record.id)
            } else {
                skipped += 1
            }
            phase = .writing(done: index + 1, total: records.count)
        }

        // Move only what actually landed. A write that failed leaves its Apple
        // Note untouched in the outbox, so the next run retries it.
        if !importedIDs.isEmpty {
            do {
                let moved = try await Self.moveNotes(ids: importedIDs, fromFolder: folder, toArchive: archive)
                if moved < importedIDs.count {
                    // Some notes imported but didn't move out, so they'd import
                    // again next run. Surface it rather than let them re-import.
                    phase = .failed(
                        "Imported \(importedIDs.count), but only \(moved) moved to “\(archive)”. "
                        + "The rest are still in “\(folder)” and would import again — move them by hand.")
                    return
                }
            } catch {
                // The notes are safely imported; a failed move just means they
                // linger in the outbox and would re-import next time. Tell the
                // user rather than silently double-importing later.
                phase = .failed(
                    "Imported \(importedIDs.count), but couldn't move them to “\(archive)” in Apple Notes — "
                    + "they're still in “\(folder)” and would import again. Move or delete them there.")
                return
            }
        }

        phase = .finished(imported: importedIDs.count, skipped: skipped)
    }

    func reset() { phase = .idle }

    // MARK: - AppleScript steps

    private struct NoteRecord {
        var id: String
        var title: String
        var date: Date
        var html: String
    }

    private static func fetchNotes(inFolder folder: String) async throws -> [NoteRecord] {
        let name = escapeForAppleScript(folder)
        // Emit id, title, an unambiguous numeric date, and the HTML body for
        // every note, joined by our control-character delimiters.
        let script = """
        tell application "Notes"
            set target to missing value
            repeat with f in folders
                if (name of f) is "\(name)" then set target to f
            end repeat
            if target is missing value then return "\(errNoFolder)"
            set fs to (ASCII character 31)
            set rs to (ASCII character 30)
            set out to ""
            repeat with n in notes of target
                set d to modification date of n
                set stamp to ((year of d) as string) & "-" & my pad(month of d as integer) & "-" & my pad(day of d) & " " & my pad(hours of d) & ":" & my pad(minutes of d) & ":" & my pad(seconds of d)
                set out to out & (id of n as string) & fs & (name of n) & fs & stamp & fs & (body of n) & rs
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

    /// Moves the imported notes into `archive`, returning how many actually
    /// moved. Single-pass — it walks the folder once and collects the matches,
    /// rather than re-searching the whole folder per id (which was quadratic and
    /// slow for a big batch). The moved count lets the caller notice a silent
    /// skip, which would otherwise leave a note to re-import next time.
    @discardableResult
    private static func moveNotes(ids: [String], fromFolder folder: String, toArchive archive: String) async throws -> Int {
        let folderName = escapeForAppleScript(folder)
        let archiveName = escapeForAppleScript(archive)
        let idList = ids.map { "\"\(escapeForAppleScript($0))\"" }.joined(separator: ", ")
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
            set wanted to {\(idList)}
            set toMove to {}
            repeat with n in notes of target
                if ((id of n as string) is in wanted) then set end of toMove to n
            end repeat
            set movedCount to 0
            repeat with n in toMove
                try
                    move n to arch
                    set movedCount to movedCount + 1
                end try
            end repeat
            return "MOVED:" & movedCount
        end tell
        """
        let out = try await runOsascript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        if out == errNoFolder {
            throw ImportError(message: "The folder “\(folder)” no longer exists in Apple Notes.")
        }
        if out.hasPrefix("MOVED:"), let n = Int(out.dropFirst("MOVED:".count)) { return n }
        return 0
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
