import SwiftUI
import AppKit
import ServiceManagement
import EnvyCore

struct GeneralSettingsView: View {
    @AppStorage("showNotePreview") private var showNotePreview = false
    @AppStorage("showDateModified") private var showDateModified = true
    @AppStorage("newNotesStartInInbox") private var newNotesStartInInbox = false
    @AppStorage("showInboxInMainList") private var showInboxInMainList = true
    @AppStorage("showDueSort") private var showDueSort = true
    @AppStorage("dateDisplayStyle") private var dateDisplayStyleRaw = DateDisplayStyle.smart.rawValue
    @AppStorage("requireModifierForLinkClick") private var requireModifierForLinkClick = true
    @AppStorage("linkPreviewTrigger") private var linkPreviewTriggerRaw = LinkPreviewTrigger.optionClick.rawValue
    @AppStorage("showTagsInTitleBar") private var showTagsInTitleBar = false
    @AppStorage("showDuePill") private var showDuePill = true
    @AppStorage(IndexPreference.storageKey) private var indexPathRaw = ""
    @AppStorage(IndexPreference.includeSubfoldersKey) private var indexIncludeSubfolders = false
    @AppStorage("moveFocusToEditorOnEnter") private var moveFocusToEditorOnEnter = true
    @AppStorage("showFooterClock") private var showFooterClock = false
    @AppStorage("showFooterClockDate") private var showFooterClockDate = false
    @AppStorage("footerClockDateFormat") private var footerClockDateFormatRaw = ClockDateFormat.short.rawValue
    @AppStorage("showFooterClockOnlyWhenFullScreen") private var showFooterClockOnlyWhenFullScreen = false
    @AppStorage("plainTextMode") private var plainTextMode = false
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

    /// The Index's own top-level `.trash` — the one that matters for the
    /// overwhelmingly common case (subfolder scanning off, or a delete that
    /// happened right at the top level). A note deleted from deeper inside a
    /// subfolder gets its own sibling `.trash` there instead; browsing across
    /// all of them at once is what the `trash:` search operator is for.
    private var trashURL: URL {
        indexURL.appendingPathComponent(".trash", isDirectory: true)
    }

    /// Sparkle reports nil until the first check completes, and "Never"
    /// is more useful to someone debugging why they missed a release than a
    /// placeholder date would be.
    private var lastCheckedDescription: String {
        guard let date = updater.lastUpdateCheckDate else { return "Last checked: never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))"
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
                Text("Everything you write begins as a fleeting note, and filing it into The Index becomes a deliberate act. Notes created by following a [[link]], and notes made from a template, are unaffected \u{2014} both are already placed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show fleeting notes in the list", isOn: $showInboxInMainList)
                Text("Notes waiting in Inbox/ appear alongside the rest, marked with a dot. Turn this off to keep them out of the way until you go looking with \u{201C}inbox:\u{201D}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Editor") {
                Toggle("Show tags in title bar", isOn: $showTagsInTitleBar)
                Toggle("Show due date pill in title bar", isOn: $showDuePill)
                Toggle("Require ⌘-click to open note links", isOn: $requireModifierForLinkClick)
                Picker("Preview linked notes", selection: linkPreviewTrigger) {
                    ForEach(LinkPreviewTrigger.allCases) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                Toggle("Plain-text mode (ignore markdown formatting)", isOn: $plainTextMode)
                Toggle("Show interlinks in footer", isOn: $showBacklinks)
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
