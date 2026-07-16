import SwiftUI
import AppKit
import ServiceManagement
import EnvyCore

struct GeneralSettingsView: View {
    @AppStorage("showNotePreview") private var showNotePreview = false
    @AppStorage("showDateModified") private var showDateModified = true
    @AppStorage("showDueSort") private var showDueSort = true
    @AppStorage("dateDisplayStyle") private var dateDisplayStyleRaw = DateDisplayStyle.smart.rawValue
    @AppStorage("requireModifierForLinkClick") private var requireModifierForLinkClick = true
    @AppStorage("linkPreviewTrigger") private var linkPreviewTriggerRaw = LinkPreviewTrigger.optionClick.rawValue
    @AppStorage("showEditorTitleHeader") private var showEditorTitleHeader = true
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
    @AppStorage("showBacklinks") private var showBacklinks = true
    @AppStorage("hideOnFocusLoss") private var hideOnFocusLoss = false
    @AppStorage("restoreFocusOnSummon") private var restoreFocusOnSummon = true
    @AppStorage("appVisibility") private var appVisibilityRaw = AppVisibility.both.rawValue
    @AppStorage("menuBarClickAction") private var menuBarClickActionRaw = MenuBarClickAction.toggleWindow.rawValue
    @AppStorage("menuBarPinnedNotePath") private var menuBarPinnedNotePath = ""
    @AppStorage("templateDateFormatPattern") private var templateDateFormatPattern = TemplateDateFormat.defaultPattern
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

    private var menuBarClickAction: Binding<MenuBarClickAction> {
        Binding(
            get: { MenuBarClickAction(rawValue: menuBarClickActionRaw) ?? .toggleWindow },
            set: { menuBarClickActionRaw = $0.rawValue }
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
                Picker("Clicking the menu bar icon", selection: menuBarClickAction) {
                    ForEach(MenuBarClickAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                if menuBarClickAction.wrappedValue == .showPinnedNote {
                    if let menuBarPinnedNoteTitle {
                        Text("Pinned: \(menuBarPinnedNoteTitle)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No note pinned yet — right-click a note and choose \"Pin to Menu Bar.\"")
                            .foregroundStyle(.secondary)
                    }
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
            }

            Section("Editor") {
                Toggle("Show title bar above note", isOn: $showEditorTitleHeader)
                Toggle("Show tags in title bar", isOn: $showTagsInTitleBar)
                    .disabled(!showEditorTitleHeader)
                Toggle("Show due date pill in title bar", isOn: $showDuePill)
                    .disabled(!showEditorTitleHeader)
                Toggle("Require ⌘-click to open note links", isOn: $requireModifierForLinkClick)
                Picker("Preview linked notes", selection: linkPreviewTrigger) {
                    ForEach(LinkPreviewTrigger.allCases) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                Toggle("Plain-text mode (ignore markdown formatting)", isOn: $plainTextMode)
                Toggle("Show backlinks in footer", isOn: $showBacklinks)
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
