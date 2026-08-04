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

    // Camera / scanning / OCR — capturing the physical world into notes.
    @AppStorage("scanAutoCrop") private var scanAutoCrop = true
    @AppStorage("ocrEnabled") private var ocrEnabled = true
    @AppStorage("searchImageText") private var searchImageText = true

    // Kindle import — same layout DNA as the Apple Notes section above.
    @AppStorage("kindleImportEnabled") private var kindleEnabled = false
    @AppStorage("kindleTitleReference") private var kindleTitleReference = "page"
    @AppStorage("kindleBodyOmitAuthor") private var kindleOmitAuthor = false
    @AppStorage("kindleBodyOmitLocation") private var kindleOmitLocation = false
    @ObservedObject private var kindleImporter = KindleImporter.shared
    @State private var kindleClippingsFile: URL?
    @State private var showingKindlePicker = false
    @State private var confirmingForget = false

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

    /// The MTP-Kindle warning with "Moorage" as a visibly-distinct link: the
    /// caution text stays yellow, but the link is blue and underlined so it
    /// reads as clickable rather than blending into the warning.
    private var kindleMTPWarning: AttributedString {
        func yellow(_ string: String) -> AttributedString {
            var run = AttributedString(string)
            run.foregroundColor = .yellow
            return run
        }
        var link = AttributedString("Moorage")
        link.foregroundColor = .blue
        link.underlineStyle = .single
        link.link = URL(string: "https://github.com/skuthus/Moorage")
        return yellow("Older Kindles that mount as a USB drive work directly. Newer Kindles use MTP and don't appear in Finder: mount one with ")
            + link
            + yellow(", the official way to bring a newer Kindle in, and Envy imports from it automatically (it looks under ~/Moorage).")
    }

    var body: some View {
        Form {
            Section("Camera & Scanning") {
                Text("Capture the physical world into notes: the camera pill beside the search field (and right-click → Import from iPhone in a note) takes a photo or scans a document straight in. Text in your images and scans is read on-device so you can search it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Crop scans to the page edge", isOn: $scanAutoCrop)
                Text("When you Scan Documents from an iPhone, Envy trims the background around the page and straightens it. On-device. Turn off to keep the scanner's original framing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Read text in images (OCR)", isOn: $ocrEnabled)
                    .onChange(of: ocrEnabled) { _, _ in OCRIndex.shared.applyEnabledSetting() }
                Text("Envy reads the text inside your images and scans in the background so “img: whiteboard” finds them, and right-click → Copy Text from Image works. On-device, no network. Takes effect on the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Include image text in every search", isOn: $searchImageText)
                    .disabled(!ocrEnabled)
                Text("With this on, a plain search like “whiteboard” also finds notes whose images contain the word, no “img:” needed. Off, image text is searchable only through the “img:” operator.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            Section("Kindle") {
                Toggle("Enable Kindle import", isOn: $kindleEnabled)
                Label {
                    Text(kindleMTPWarning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                Text("Plug in your Kindle and pull its highlights and typed notes into the Inbox as fleeting notes, one per highlight, titled by the quote's first words, with the book as a [[link]]. Envy remembers what it has already imported, so re-importing only ever adds what's new.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Title locator", selection: $kindleTitleReference) {
                    Text("Page — first words, p92").tag("page")
                    Text("Location — first words, loc. 210").tag("location")
                    Text("Both — first words, p92 · loc. 210").tag("both")
                    Text("None — first words only").tag("none")
                }
                Text("A book without page numbers falls back to its location, so a title's never left bare unless you choose None.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Include the author in each note", isOn: Binding(
                    get: { !kindleOmitAuthor }, set: { kindleOmitAuthor = !$0 }))
                Toggle("Include the location in each note", isOn: Binding(
                    get: { !kindleOmitLocation }, set: { kindleOmitLocation = !$0 }))
                Text("These control the attribution line under each highlight; the book link and page always stay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    if kindleClippingsFile != nil {
                        Label("Kindle detected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Text("No Kindle detected — plug it in and refresh, or choose the file by hand.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        kindleClippingsFile = KindleImporter.detectClippingsFile()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Look for a plugged-in Kindle again")
                }
                HStack {
                    Button("Import from Kindle") {
                        guard let file = kindleClippingsFile else { return }
                        Task { await kindleImporter.importClippings(from: file, into: indexDirectory) }
                    }
                    .disabled(kindleClippingsFile == nil || kindleImporterBusy)

                    Button("Choose Clippings File…") { showingKindlePicker = true }
                        .disabled(kindleImporterBusy)

                    Spacer()
                    kindleStatusView
                }
                Button("Forget Import History…", role: .destructive) { confirmingForget = true }
                    .disabled(kindleImporterBusy)
                    .confirmationDialog(
                        "Forget which highlights have been imported? The next import will re-offer every highlight — useful for redoing them with a different title format. Notes already in your vault aren't touched.",
                        isPresented: $confirmingForget, titleVisibility: .visible
                    ) {
                        Button("Forget Import History", role: .destructive) {
                            KindleLedger.clear(for: indexDirectory)
                        }
                        Button("Cancel", role: .cancel) {}
                    }
            } footer: {
                Text("Reads the Kindle's My Clippings.txt (every book's highlights in one file). Adjusted highlights are collapsed to their final form, a typed note attaches beneath the passage it belongs to, and bookmarks are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!kindleEnabled)
        }
        .fileImporter(isPresented: $showingKindlePicker, allowedContentTypes: [.plainText, .text]) { result in
            if case let .success(url) = result {
                Task { await kindleImporter.importClippings(from: url, into: indexDirectory) }
            }
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
            // Cheap volume scan, so a Kindle plugged in before the tab opened
            // shows as detected without a manual refresh.
            if kindleEnabled {
                kindleClippingsFile = KindleImporter.detectClippingsFile()
            }
        }
    }

    private var kindleImporterBusy: Bool {
        switch kindleImporter.phase {
        case .reading, .writing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var kindleStatusView: some View {
        switch kindleImporter.phase {
        case .idle:
            EmptyView()
        case .reading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading Clippings…").foregroundStyle(.secondary)
            }
            .font(.caption)
        case let .writing(done, total):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Importing \(done) / \(total)…").foregroundStyle(.secondary)
            }
            .font(.caption)
        case let .finished(imported, alreadyImported):
            Text(imported == 0
                 ? "Nothing new (\(alreadyImported) already imported)."
                 : "Imported \(imported) new · \(alreadyImported) already imported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
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
