import SwiftUI
import EnvyCore

/// Settings tab for the Apple Notes bridge: pick an outbox folder, hit Import,
/// and its notes arrive in the Inbox as fleeting notes. The idea is to let
/// Apple Notes be the everywhere-capture front end (phone, Watch, Siri) that a
/// Mac-only app can't be — you jot there, then pull into Envy when you sit down.
struct ImportSettingsView: View {
    @AppStorage("appleNotesOutboxFolder") private var outboxFolder = ""
    @AppStorage("appleNotesArchiveFolder") private var archiveFolder = "Imported"
    @AppStorage(IndexPreference.storageKey) private var indexPathRaw = ""
    // true = Inbox (fleeting notes, to review and file); false = straight into
    // the Index as ordinary notes.
    @AppStorage("appleNotesImportToInbox") private var importToInbox = true
    // Master switch for the whole feature; off by default so Envy stays inert
    // toward Apple Notes (no folder reads, no Automation prompt) until the user
    // opts in.
    @AppStorage("appleNotesImportEnabled") private var importEnabled = false

    // Shared with the ⌘⌥I File-menu trigger, so progress and results appear
    // here whether the import was started from this button or the menu.
    @ObservedObject private var importer = AppleNotesImporter.shared
    @State private var folders: [String] = []
    @State private var loadingFolders = false
    @State private var folderError: String?

    private var indexDirectory: URL {
        indexPathRaw.isEmpty ? NoteStore.defaultDirectory() : URL(fileURLWithPath: indexPathRaw, isDirectory: true)
    }

    /// Folder names to offer: whatever we've loaded, plus the saved choice even
    /// before a load, so the setting still displays after a relaunch.
    private var folderOptions: [String] {
        var all = folders
        if !outboxFolder.isEmpty && !all.contains(outboxFolder) { all.insert(outboxFolder, at: 0) }
        return all
    }

    var body: some View {
        Form {
            Section("Apple Notes") {
                Toggle("Enable Apple Notes import", isOn: $importEnabled)

                Text("Capture on the go in Apple Notes, then pull those notes into Envy. Envy reads one folder of your choosing, and after importing, moves each note to a chosen folder in Apple Notes so it's never imported twice. See [docs](https://envynote.app/docs.html) for more details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Picker("Import from", selection: $outboxFolder) {
                        if folderOptions.isEmpty {
                            Text("No folder chosen").tag("")
                        }
                        ForEach(folderOptions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    Button {
                        Task { await loadFolders() }
                    } label: {
                        if loadingFolders {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .help("Load your Apple Notes folders")
                    .disabled(loadingFolders)
                }

                if let folderError {
                    Text(folderError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("Move imported notes to", text: $archiveFolder, prompt: Text("Imported"))

                Picker("Import to", selection: $importToInbox) {
                    Text("Inbox (as fleeting notes)").tag(true)
                    Text("The Index (directly)").tag(false)
                }
            }
            .disabled(!importEnabled)

            Section {
                HStack {
                    Button("Import Now") {
                        Task {
                            await importer.run(
                                folder: outboxFolder,
                                archive: archiveFolder.trimmingCharacters(in: .whitespaces).isEmpty ? "Imported" : archiveFolder,
                                indexDirectory: indexDirectory,
                                toInbox: importToInbox)
                        }
                    }
                    .disabled(outboxFolder.isEmpty || importer.isRunning)

                    Spacer()
                    statusView
                }
            } footer: {
                Text("Images and attachments don't transfer over — they arrive as an “[image omitted]” marker, and Apple Notes checklists come in as plain bullet lists. Everything else (text, formatting, lists, links) comes across as Markdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!importEnabled)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task {
            // Returning users (feature on, an outbox already chosen, so
            // Automation was granted on a past run) get their folder list
            // without clicking Refresh. If the feature is off or no outbox is
            // set, this stays quiet and opening the tab never touches Notes.
            if importEnabled && !outboxFolder.isEmpty && folders.isEmpty {
                await loadFolders()
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch importer.phase {
        case .idle:
            EmptyView()
        case .reading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading Apple Notes…").foregroundStyle(.secondary)
            }
            .font(.caption)
        case let .writing(done, total):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Importing \(done) / \(total)…").foregroundStyle(.secondary)
            }
            .font(.caption)
        case let .finished(imported, skipped):
            Text(finishedMessage(imported: imported, skipped: skipped))
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, alignment: .trailing)
        }
    }

    private func finishedMessage(imported: Int, skipped: Int) -> String {
        if imported == 0 && skipped == 0 { return "Nothing to import — that folder is empty." }
        var msg = "Imported \(imported) note\(imported == 1 ? "" : "s")."
        if skipped > 0 { msg += " \(skipped) couldn't be written." }
        return msg
    }

    private func loadFolders() async {
        loadingFolders = true
        folderError = nil
        do {
            folders = try await AppleNotesImporter.listFolders()
            if folders.isEmpty {
                folderError = "No folders found in Apple Notes."
            }
        } catch {
            folderError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loadingFolders = false
    }
}
