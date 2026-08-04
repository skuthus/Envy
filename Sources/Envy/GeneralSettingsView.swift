import SwiftUI
import AppKit
import ServiceManagement
import EnvyCore

struct GeneralSettingsView: View {
    @AppStorage("showNotePreview") private var showNotePreview = false
    @AppStorage("showFooterVaultCounts") private var showFooterVaultCounts = true
    @AppStorage("noteDotTrailing") private var noteDotTrailing = true
    @AppStorage("folderListDisplay") private var folderListDisplayRaw = FolderListDisplay.dot.rawValue
    @AppStorage("showDateModified") private var showDateModified = true
    @AppStorage("newNotesStartInInbox") private var newNotesStartInInbox = false
    @AppStorage("showInboxInMainList") private var showInboxInMainList = true
    @AppStorage("showDueSort") private var showDueSort = true
    @AppStorage("dateDisplayStyle") private var dateDisplayStyleRaw = DateDisplayStyle.smart.rawValue
    @AppStorage("requireModifierForLinkClick") private var requireModifierForLinkClick = true
    @AppStorage("linkPreviewTrigger") private var linkPreviewTriggerRaw = LinkPreviewTrigger.optionClick.rawValue
    @AppStorage("showTagsInTitleBar") private var showTagsInTitleBar = false
    @AppStorage("showFolderInTitleBar") private var showFolderInTitleBar = true
    @AppStorage("showDuePill") private var showDuePill = true
    @AppStorage("linkDomainPills") private var linkDomainPills = true
    @AppStorage(IndexPreference.storageKey) private var indexPathRaw = ""
    @AppStorage(IndexPreference.includeSubfoldersKey) private var indexIncludeSubfolders = false
    @AppStorage("moveFocusToEditorOnEnter") private var moveFocusToEditorOnEnter = true
    @AppStorage("showFooterClock") private var showFooterClock = false
    @AppStorage("showFooterClockDate") private var showFooterClockDate = false
    @AppStorage("footerClockDateFormat") private var footerClockDateFormatRaw = ClockDateFormat.short.rawValue
    @AppStorage("showFooterClockOnlyWhenFullScreen") private var showFooterClockOnlyWhenFullScreen = false
    @AppStorage("plainTextMode") private var plainTextMode = false
    @AppStorage("scanAutoCrop") private var scanAutoCrop = true
    @AppStorage("ocrEnabled") private var ocrEnabled = true
    // AI provenance is hidden until the feature is designed — the control is
    // gone from Settings, so this stays false and the editor's signature pill
    // and delete-protection never engage. Kept declared so restoring the
    // feature is one Toggle again, not a re-wiring.
    @ObservedObject private var updater = Updater.shared
    @AppStorage("protectAISignature") private var protectAISignature = false
    @AppStorage("showBacklinks") private var showBacklinks = true
    @AppStorage("hideOnFocusLoss") private var hideOnFocusLoss = false
    @AppStorage("restoreFocusOnSummon") private var restoreFocusOnSummon = true
    @AppStorage("appVisibility") private var appVisibilityRaw = AppVisibility.both.rawValue
    @AppStorage("menuBarPinnedNotePath") private var menuBarPinnedNotePath = ""
    @AppStorage("templateDateFormatPattern") private var templateDateFormatPattern = TemplateDateFormat.defaultPattern
    @AppStorage(TrashPreference.intervalValueKey) private var trashEmptyIntervalValue = TrashPreference.defaultIntervalValue
    @AppStorage(TrashPreference.intervalUnitKey) private var trashEmptyIntervalUnitRaw = TrashPreference.defaultIntervalUnit.rawValue
    @AppStorage(ShortcutPreferences.storageKey) private var customShortcutsRaw = ""
    @State private var showingMarkupHelp = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    private var dateDisplayStyle: Binding<DateDisplayStyle> {
        Binding(
            get: { DateDisplayStyle(rawValue: dateDisplayStyleRaw) ?? .smart },
            set: { dateDisplayStyleRaw = $0.rawValue }
        )
    }

    private var folderListDisplay: Binding<FolderListDisplay> {
        Binding(
            get: { FolderListDisplay(rawValue: folderListDisplayRaw) ?? .dot },
            set: { folderListDisplayRaw = $0.rawValue }
        )
    }

    private var footerClockDateFormat: Binding<ClockDateFormat> {
        Binding(
            get: { ClockDateFormat(rawValue: footerClockDateFormatRaw) ?? .short },
            set: { footerClockDateFormatRaw = $0.rawValue }
        )
    }

    private var linkPreviewTrigger: Binding<LinkPreviewTrigger> {
        Binding(
            get: { LinkPreviewTrigger(rawValue: linkPreviewTriggerRaw) ?? .optionClick },
            set: { linkPreviewTriggerRaw = $0.rawValue }
        )
    }

    private var appVisibility: Binding<AppVisibility> {
        Binding(
            get: { AppVisibility(rawValue: appVisibilityRaw) ?? .both },
            set: { appVisibilityRaw = $0.rawValue }
        )
    }

    private var trashEmptyIntervalUnit: Binding<TrashEmptyUnit> {
        Binding(
            get: { TrashEmptyUnit(rawValue: trashEmptyIntervalUnitRaw) ?? TrashPreference.defaultIntervalUnit },
            set: { trashEmptyIntervalUnitRaw = $0.rawValue }
        )
    }

    /// Clamped to 1...99 on write — a typed 0, a blank field momentarily
    /// parsing to 0, or anything 100+ all snap back in range rather than
    /// persisting a value that'd make emptyIfDue()'s own math misbehave.
    private var trashEmptyIntervalValueClamped: Binding<Int> {
        Binding(
            get: { trashEmptyIntervalValue },
            set: { trashEmptyIntervalValue = min(max($0, 1), 99) }
        )
    }

    /// Just the filename, not the full path — matches how a note's title
    /// is derived everywhere else (Note.title strips directory + extension).
    private var menuBarPinnedNoteTitle: String? {
        guard !menuBarPinnedNotePath.isEmpty else { return nil }
        return URL(fileURLWithPath: menuBarPinnedNotePath).deletingPathExtension().lastPathComponent
    }

    private var indexURL: URL {
        indexPathRaw.isEmpty ? NoteStore.defaultDirectory() : URL(fileURLWithPath: indexPathRaw, isDirectory: true)
    }

    /// The Index's single visible `Trash/` — everything deleted lands here
    /// now (mirroring its origin folder's structure inside), so this button
    /// shows all of it, not just top-level deletions.
    private var trashURL: URL {
        indexURL.appendingPathComponent(NoteStore.trashFolderName, isDirectory: true)
    }

    // Formatters are expensive to construct, and this one would otherwise be
    // rebuilt on every body evaluation just to render one line of text.
    private static let lastCheckedFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Sparkle reports nil until the first check completes, and "Never"
    /// is more useful to someone debugging why they missed a release than a
    /// placeholder date would be.
    private var lastCheckedDescription: String {
        guard let date = updater.lastUpdateCheckDate else { return "Last checked: never" }
        return "Last checked \(Self.lastCheckedFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Envy at Login", isOn: Binding(
                    get: { openAtLogin },
                    set: { setOpenAtLogin($0) }
                ))
                Toggle("Hide Envy when clicking outside the app", isOn: $hideOnFocusLoss)
                Toggle("Keep focus where it was when summoned", isOn: $restoreFocusOnSummon)
                Picker("Show Envy in", selection: appVisibility) {
                    ForEach(AppVisibility.allCases) { visibility in
                        Text(visibility.label).tag(visibility)
                    }
                }
                if let menuBarPinnedNoteTitle {
                    Text("Clicking the menu bar icon opens \"\(menuBarPinnedNoteTitle)\" — right-click the icon for \"Unpin Note,\" or press \(ShortcutPreferences.binding(for: .unpinFromMenuBar, raw: customShortcutsRaw).displayString) from anywhere.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Clicking the menu bar icon shows or hides Envy. Right-click a note and choose \"Pin to Menu Bar\" to have it open that note instead.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("The Index") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(indexURL.lastPathComponent)
                    Text(indexURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Change Location…") {
                        changeIndexLocation()
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([indexURL])
                    }
                }
                Toggle("Show items in subfolders", isOn: $indexIncludeSubfolders)
            }

            // No Folder Colors section — folders are colored the way tags are:
            // every folder gets a color the moment it exists, and right-clicking
            // its dot (or name chip) in the note list recolors it in place.
            Section("Templates") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("{{date}} Format", text: $templateDateFormatPattern)
                    HStack(spacing: 4) {
                        Text("Preview: \(TemplateDateFormat.string(from: Date(), pattern: templateDateFormatPattern))")
                        Text("· yyyy MM dd MMMM EEEE")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button("Reveal Templates Folder in Finder") {
                    let templatesDirectory = indexURL.appendingPathComponent("Templates", isDirectory: true)
                    try? FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([templatesDirectory])
                }
            }

            Section("Trash") {
                HStack {
                    Text("Empty every")
                    TextField("", value: trashEmptyIntervalValueClamped, format: .number)
                        .frame(width: 40)
                        .multilineTextAlignment(.trailing)
                    Picker("", selection: trashEmptyIntervalUnit) {
                        ForEach(TrashEmptyUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Button("Reveal Trash Folder in Finder") {
                    try? FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([trashURL])
                }
            }

            Section("Note List") {
                Toggle("Move cursor to editor after opening a note", isOn: $moveFocusToEditorOnEnter)
                Toggle("Show content preview next to title", isOn: $showNotePreview)
                Toggle("Show date modified", isOn: $showDateModified)
                Picker("Date Format", selection: dateDisplayStyle) {
                    ForEach(DateDisplayStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .disabled(!showDateModified)
                Toggle("Allow sorting by due date", isOn: $showDueSort)
                Toggle("New notes start in the Inbox", isOn: $newNotesStartInInbox)
                Text("Everything you write begins as a fleeting note, and filing it into The Index becomes a deliberate act \u{2014} including notes you create by following a [[link]] that doesn't exist yet. Notes made from a template are unaffected, since those arrive with structure you chose deliberately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show fleeting notes in the list", isOn: $showInboxInMainList)
                Text("Notes waiting in Inbox/ appear alongside the rest, marked with a dot. Turn this off to keep them out of the way until you go looking with \u{201C}inbox:\u{201D}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Show a note's folder as", selection: folderListDisplay) {
                    ForEach(FolderListDisplay.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!indexIncludeSubfolders)
                Text("For a note in a subfolder: a dot in the folder's color, the folder's name as a chip, or nothing. Needs \u{201C}Show items in subfolders.\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show the folder marker after the title", isOn: $noteDotTrailing)
                Text("A note's folder dot or name chip sits just after the title by default. Turn this off to move it back to the left, before the title. The Inbox mark always stays on the left.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Editor") {
                Toggle("Show tags in title bar", isOn: $showTagsInTitleBar)
                Toggle("Show folder in title bar", isOn: $showFolderInTitleBar)
                Text("A chip in the folder's color naming the pile the open note lives in; click it to see that folder's notes. Never shows for notes at the Index root.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show due date pill in title bar", isOn: $showDuePill)
                Toggle("Show links as domain pills", isOn: $linkDomainPills)
                Text("A bare URL renders as a compact pill of just its domain. Purely visual and entirely offline — the note still holds the full URL, and it shows in full the moment your cursor enters it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Require ⌘-click to open note links", isOn: $requireModifierForLinkClick)
                Picker("Preview linked notes", selection: linkPreviewTrigger) {
                    ForEach(LinkPreviewTrigger.allCases) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                Toggle("Crop scans to the page edge", isOn: $scanAutoCrop)
                Text("When you Scan Documents from an iPhone, Envy trims the background around the page and straightens it. On-device. Turn off to keep the scanner's original framing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Read text in images (OCR)", isOn: $ocrEnabled)
                Text("Envy reads the text inside your images and scans in the background so “img: whiteboard” finds them, and right-click → Copy Text from Image works. On-device, no network. Takes effect on the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Plain-text mode (ignore markdown formatting)", isOn: $plainTextMode)
                Toggle("Show interlinks in footer", isOn: $showBacklinks)
                Toggle("Show note and folder counts in footer", isOn: $showFooterVaultCounts)
                Text("Whole-vault totals, sitting to the right of the word and character counts. The folder count appears only when subfolder scanning is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                HStack {
                    Text(lastCheckedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                }
            }

            Section("Footer Clock") {
                Toggle("Show clock in footer", isOn: $showFooterClock)
                Toggle("Show date with clock", isOn: $showFooterClockDate)
                    .disabled(!showFooterClock)
                Picker("Date Format", selection: footerClockDateFormat) {
                    ForEach(ClockDateFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .disabled(!showFooterClock || !showFooterClockDate)
                Toggle("Only show clock in full screen", isOn: $showFooterClockOnlyWhenFullScreen)
                    .disabled(!showFooterClock)
            }

            Button("View Markup Commands…") {
                showingMarkupHelp = true
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .sheet(isPresented: $showingMarkupHelp) {
            MarkupHelpView()
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            openAtLogin = enabled
        } catch {
            // Reflect whatever actually took effect rather than trusting the
            // requested value if registration failed.
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func changeIndexLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose The Index"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        indexPathRaw = url.path
    }
}
